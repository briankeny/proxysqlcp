#!/usr/bin/perl

package Cpanel::PhpMyAdminSessionHook;

use strict;
use warnings;
use Cpanel::Logger;
use DBI;
use File::Path qw(make_path);
use POSIX qw(strftime);

# ProxySQL Configuration
my $proxysql_admin_host = '127.0.0.1';
my $proxysql_admin_port = '6032';
my $proxysql_admin_user = 'admin';
my $proxysql_admin_pass = 'admin';
my $proxysql_admin_db   = 'admin';
my $proxysql_default_hostgroup = 1;

# MySQL Configuration
my $mysql_host = '127.0.0.1';
my $mysql_port = '3307';
my $mysql_user = 'stnduser';
my $mysql_pass = 'stnduser';

# Logging configuration
my $log_dir = '/var/log/cpanel/hooks';
my $log_file = "$log_dir/phpmyadmin_session.log";

# Ensure log directory exists
make_path($log_dir) unless -d $log_dir;

my $logger = Cpanel::Logger->new();

sub describe {
    return [
        {
            'category' => 'Cpanel',
            'event'    => 'UAPI::Session::create_temp_user',
            'stage'    => 'post',
            'hook'     => 'Cpanel::PhpMyAdminSessionHook::handle_session_creation',
            'exectype' => 'module',
        }
    ];
}

sub log_to_file {
    my ($message) = @_;
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime());
    
    if (open(my $fh, '>>', $log_file)) {
        print $fh "[$timestamp] $message\n";
        close($fh);
    }
}

sub handle_session_creation {
    my ($context, $data) = @_;
    
    # Extract user information from the context/data
    my $user = $data->{'user'} || $context->{'user'} || 'unknown';
    my $session_id = $data->{'session_id'} || $context->{'session_id'} || 'unknown';
    
    log_to_file("phpMyAdmin session created for user: $user (Session ID: $session_id)");
    
    # Sync the specific user or all users to ProxySQL
    _sync_user_to_proxysql($user);
    
    log_to_file("Session handling complete for user: $user");
}

sub _sync_user_to_proxysql {
    my ($target_user) = @_;
    
    log_to_file("Starting user synchronization for: $target_user");

    # Connect to MySQL
    my $mysql_dsn = "DBI:mysql:database=mysql;host=$mysql_host;port=$mysql_port";
    my $mysql_dbh = DBI->connect($mysql_dsn, $mysql_user, $mysql_pass, {
        RaiseError => 0,
        AutoCommit => 1,
        PrintError => 0
    }) or do {
        log_to_file("Cannot connect to MySQL: $DBI::errstr");
        return 0;
    };
    
    # Connect to ProxySQL
    my $proxysql_dsn = "DBI:mysql:database=$proxysql_admin_db;host=$proxysql_admin_host;port=$proxysql_admin_port";
    my $proxysql_dbh = DBI->connect($proxysql_dsn, $proxysql_admin_user, $proxysql_admin_pass, {
        RaiseError => 0,
        AutoCommit => 1,
        PrintError => 0
    }) or do {
        log_to_file("Cannot connect to ProxySQL: $DBI::errstr");
        $mysql_dbh->disconnect() if $mysql_dbh;
        return 0;
    };
    
    # Query for the specific user or related users
    my $user_query = q{
        SELECT User, authentication_string 
        FROM mysql.user 
        WHERE Host = 'localhost'
          AND authentication_string != ''
          AND authentication_string IS NOT NULL
          AND (User = ? OR User LIKE ?)
    };
    
    my $sth = $mysql_dbh->prepare($user_query);
    my $user_pattern = "${target_user}%"; # Also sync temp users for this account
    
    unless ($sth && $sth->execute($target_user, $user_pattern)) {
        my $error = $mysql_dbh->errstr || "Unknown error";
        log_to_file("Failed to query MySQL users for $target_user: $error");
        $mysql_dbh->disconnect();
        $proxysql_dbh->disconnect();
        return 0;
    }

    # Prepare ProxySQL insert/update statement
    my $user_stmt = $proxysql_dbh->prepare(
        q{INSERT INTO mysql_users 
          (username, password, default_hostgroup, active) 
          VALUES (?, ?, ?, 1)
          ON DUPLICATE KEY UPDATE 
            password = VALUES(password),
            default_hostgroup = VALUES(default_hostgroup),
            active = 1}
    ) or do {
        log_to_file("Failed to prepare ProxySQL statement: " . $proxysql_dbh->errstr);
        $sth->finish();
        $mysql_dbh->disconnect();
        $proxysql_dbh->disconnect();
        return 0;
    };

    my ($synced_count, $error_count) = (0, 0);
    
    while (my ($username, $password_hash) = $sth->fetchrow_array()) {
        next unless $username && $password_hash;
        
        eval {
            $user_stmt->execute($username, $password_hash, $proxysql_default_hostgroup);
            $synced_count++;
            log_to_file("Synced user: $username");
        };
        if ($@) {
            log_to_file("Failed to sync user $username: $@");
            $error_count++;
        }
    }
    $sth->finish();
    
    log_to_file("Synced $synced_count users for $target_user ($error_count errors)");
    
    # Apply ProxySQL changes
    my ($runtime_ok, $disk_ok) = (1, 1);
    
    eval {
        $proxysql_dbh->do("LOAD MYSQL USERS TO RUNTIME");
        log_to_file("Loaded users to runtime");
    } or do {
        log_to_file("LOAD MYSQL USERS TO RUNTIME failed: $@");
        $runtime_ok = 0;
    };
    
    eval {
        $proxysql_dbh->do("SAVE MYSQL USERS TO DISK");
        log_to_file("Saved users to disk");
    } or do {
        log_to_file("SAVE MYSQL USERS TO DISK failed: $@");
        $disk_ok = 0;
    };
    
    # Cleanup resources
    $user_stmt->finish() if $user_stmt;
    $mysql_dbh->disconnect();
    $proxysql_dbh->disconnect();
    
    if ($runtime_ok && $disk_ok) {
        log_to_file("User synchronization completed successfully for $target_user");
        return 1;
    }
    
    log_to_file("User synchronization completed with errors for $target_user");
    return 0;
}


1;