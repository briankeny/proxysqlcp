#!/bin/bash
set -e
echo "Adding cPanel PhpMyAdminSessionHook hook..."
[ "$(id -u)" -ne 0 ] && { echo "Run as root: sudo $0"; exit 1; }

echo "Checking Perl modules..."
for module in DBI JSON; do
    /usr/local/cpanel/3rdparty/bin/perl -M$module -e 1 &>/dev/null || {
        echo "Installing $module..."
        /usr/local/cpanel/3rdparty/bin/perl -MCPAN -e "CPAN::Shell->install(\"$module\")"
    }
done

echo "Creating module directory..."
mkdir -p /usr/local/cpanel/Cpanel || exit 1

echo "Enabling hooks..."
echo "enabled" > /var/cpanel/hooks/state

echo "Writing PhpMyAdminSessionHook hook module..."
cat <<'EOF' > /usr/local/cpanel/Cpanel/PhpMyAdminSessionHook.pm
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
    
    # Get the temporary user from the environment variable
    my $temp_user = $ENV{'REMOTE_DBOWNER'};
    
    if ($temp_user) {
        log_to_file("Temporary user created: $temp_user");
        
        # Sync this specific temporary user to ProxySQL
        _sync_specific_user_to_proxysql($temp_user);
    } else {
        log_to_file("No temporary user found in ENV");
    }
}

sub _sync_specific_user_to_proxysql {
    my ($target_user) = @_;
    
    log_to_file("Starting synchronization for temporary user: $target_user");

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
    
    # Query for the specific temporary user
    my $user_query = q{
        SELECT User, authentication_string 
        FROM mysql.user 
        WHERE Host = 'localhost'
          AND User = ?
          AND authentication_string != ''
          AND authentication_string IS NOT NULL
    };
    
    my $sth = $mysql_dbh->prepare($user_query);
    unless ($sth && $sth->execute($target_user)) {
        my $error = $mysql_dbh->errstr || "Unknown error";
        log_to_file("Failed to query MySQL for user $target_user: $error");
        $mysql_dbh->disconnect();
        $proxysql_dbh->disconnect();
        return 0;
    }

    my ($username, $password_hash) = $sth->fetchrow_array();
    
    if ($username && $password_hash) {
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

        eval {
            $user_stmt->execute($username, $password_hash, $proxysql_default_hostgroup);
            log_to_file("Synced user: $username");
        };
        if ($@) {
            log_to_file("Failed to sync user $username: $@");
        }
        
        # Apply ProxySQL changes
        eval {
            $proxysql_dbh->do("LOAD MYSQL USERS TO RUNTIME");
            log_to_file("Loaded users to runtime");
        } or do {
            log_to_file("LOAD MYSQL USERS TO DISK failed: $@");
        };
        
        eval {
            $proxysql_dbh->do("SAVE MYSQL USERS TO DISK");
            log_to_file("Saved users to disk");
        } or do {
            log_to_file("SAVE MYSQL USERS TO DISK failed: $@");
        };
    } else {
        log_to_file("User not found: $target_user");
    }
    
    # Cleanup resources
    $sth->finish() if $sth;
    $mysql_dbh->disconnect();
    $proxysql_dbh->disconnect();
    
    log_to_file("User synchronization completed for $target_user");
    return 1;
}

1;
EOF

echo "Validating syntax..."
/usr/local/cpanel/3rdparty/bin/perl -c /usr/local/cpanel/Cpanel/PhpMyAdminSessionHook.pm || exit 1

echo "Registering hook..."
/usr/local/cpanel/bin/manage_hooks add module Cpanel::PhpMyAdminSessionHook

echo "Verifying..."
/usr/local/cpanel/bin/manage_hooks list | grep -q PhpMyAdminSessionHook && \
echo "Success!" || echo "Installation failed!"