#!/usr/bin/perl

package Cpanel::ProxysqlHook;

use strict;
use warnings;
use Cpanel::Logger;
use DBI;

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

my $logger = Cpanel::Logger->new();
my $proxysql_dbh;  # Persistent ProxySQL connection
my $mysql_dbh;     # Persistent MySQL connection

# Initialize ProxySQL database connection with reconnect
sub init_proxysql_db {
    return if $proxysql_dbh && $proxysql_dbh->ping;
    
    my $dsn = "DBI:mysql:database=$proxysql_admin_db;host=$proxysql_admin_host;port=$proxysql_admin_port";
    $proxysql_dbh = DBI->connect(
        $dsn, 
        $proxysql_admin_user, 
        $proxysql_admin_pass,
        {
            RaiseError          => 0,
            AutoCommit          => 1,
            mysql_auto_reconnect => 1,
            PrintError          => 0
        }
    ) or $logger->warn("ProxySQL connection failed: $DBI::errstr");
}

# Initialize MySQL database connection with reconnect
sub init_mysql_db {
    return if $mysql_dbh && $mysql_dbh->ping;
    
    my $dsn = "DBI:mysql:database=mysql;host=$mysql_host;port=$mysql_port";
    $mysql_dbh = DBI->connect(
        $dsn, 
        $mysql_user, 
        $mysql_pass,
        {
            RaiseError          => 0,
            AutoCommit          => 1,
            mysql_auto_reconnect => 1,
            PrintError          => 0
        }
    ) or $logger->warn("MySQL connection failed: $DBI::errstr");
}

sub describe {
    return [
        {
            'category' => 'Whostmgr',
            'event'    => 'Accounts::Create',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::create_proxysql_default_user',
            'exectype' => 'module',
        },
        {
            'category' => 'Whostmgr',
            'event'    => 'Accounts::Remove',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::remove_proxysql_default_user',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'UAPI::Mysql::create_user',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::create_proxysql_user',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'Api2::MySQLFE::createdbuser',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::create_proxysql_user2',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'UAPI::Mysql::delete_user',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::delete_proxysql_user',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'Api2::MySQLFE::deletedbuser',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::delete_proxysql_user2',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'UAPI::Mysql::set_privileges_on_database',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::set_default_schema',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'Api2::MySQLFE::setdbuserprivileges',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::set_default_schema2',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'UAPI::Mysql::rename_user',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::rename_proxysql_user',
            'exectype' => 'module',
        },
        {
            'category' => 'Cpanel',
            'event'    => 'UAPI::Mysql::set_password',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxysqlHook::set_mysql_user_password',
            'exectype' => 'module',
        }
    ];
}

# Universal sync function
sub _sync_proxysql_user {
    my ($user, $pass) = @_;
    init_proxysql_db();
    
    eval {
        my $exists = $proxysql_dbh->selectrow_array(
            "SELECT username FROM mysql_users WHERE username = ?",
            undef, $user
        );
        
        if ($exists) {
            $proxysql_dbh->do(
                "UPDATE mysql_users SET password=? WHERE username=?",
                undef, $pass, $user
            );
            $logger->info("Updated ProxySQL password for $user");
        } else {
            $proxysql_dbh->do(
                "INSERT INTO mysql_users (username,password,default_hostgroup) VALUES (?,?,?)",
                undef, $user, $pass, $proxysql_default_hostgroup
            );
            $logger->info("Added $user to ProxySQL");
        }
        
        load_mysql_users_table();
    };
    
    $logger->error("ProxySQL sync failed for $user: $@") if $@;
}

# Password update handler
sub set_mysql_user_password {
    my ($context, $data) = @_;
    init_proxysql_db();
    
    my $user = $data->{args}{user} || $data->{args}{dbuser};
    my $pass = $data->{args}{password};
    
    return unless $user && $pass;
    
    $logger->info("Password change detected for $user");
    _sync_proxysql_user($user, $pass);
}

# User creation handlers
sub create_proxysql_user {
    my ($context, $data) = @_;
    init_proxysql_db();
    _sync_proxysql_user($data->{args}{name}, $data->{args}{password});
}

sub create_proxysql_user2 {
    my ($context, $data) = @_;
    init_proxysql_db();
    _sync_proxysql_user($data->{args}{dbuser}, $data->{args}{password});
}

# User deletion handlers
sub delete_proxysql_user {
    my ($context, $data) = @_;
    init_proxysql_db();
    my $user = $data->{args}{name} or return;
    
    eval {
        $proxysql_dbh->do("DELETE FROM mysql_users WHERE username=?", undef, $user);
        $logger->info("Deleted ProxySQL user $user");
        load_mysql_users_table();
    };
    $logger->error("Delete failed for $user: $@") if $@;
}

sub delete_proxysql_user2 {
    my ($context, $data) = @_;
    init_proxysql_db();
    my $user = $data->{args}{dbuser} or return;
    
    eval {
        $proxysql_dbh->do("DELETE FROM mysql_users WHERE username=?", undef, $user);
        $logger->info("Deleted ProxySQL user $user");
        load_mysql_users_table();
    };
    $logger->error("Delete failed for $user: $@") if $@;
}

# Schema update handlers
sub set_default_schema {
    my ($context, $data) = @_;
    init_proxysql_db();
    
    my $user = $data->{args}{user};
    my $dbname = $data->{args}{database};
    
    eval {
        $proxysql_dbh->do(
            "UPDATE mysql_users SET default_schema=? WHERE username=?",
            undef, $dbname, $user
        );
        load_mysql_users_table();
    };
    $logger->error("Schema update failed for $user: $@") if $@;
}

sub set_default_schema2 {
    my ($context, $data) = @_;
    init_proxysql_db();
    
    my $user = $data->{args}{dbuser};
    my $dbname = $data->{args}{db};
    
    eval {
        $proxysql_dbh->do(
            "UPDATE mysql_users SET default_schema=? WHERE username=?",
            undef, $dbname, $user
        );
        load_mysql_users_table();
    };
    $logger->error("Schema update failed for $user: $@") if $@;
}

# User rename handler
sub rename_proxysql_user {
    my ($context, $data) = @_;
    init_proxysql_db();
    
    my $old = $data->{args}{oldname};
    my $new = $data->{args}{newname};
    
    eval {
        $proxysql_dbh->do(
            "UPDATE mysql_users SET username=? WHERE username=?",
            undef, $new, $old
        );
        load_mysql_users_table();
    };
    $logger->error("Rename failed $old -> $new: $@") if $@;
}

# Account creation/removal handlers
sub create_proxysql_default_user {
    my ($context, $data) = @_;
    init_proxysql_db();
    _sync_proxysql_user($data->{user}, $data->{pass});
}

sub remove_proxysql_default_user {
    my ($context, $data) = @_;
    init_proxysql_db();
    my $user = $data->{user} or return;
    
    eval {
        $proxysql_dbh->do("DELETE FROM mysql_users WHERE username=?", undef, $user);
        load_mysql_users_table();
    };
    $logger->error("Account removal failed for $user: $@") if $@;
}

# Runtime/Disk sync
sub load_mysql_users_table {
    init_proxysql_db();
    
    eval {
        $proxysql_dbh->do("LOAD MYSQL USERS TO RUNTIME");
        $proxysql_dbh->do("SAVE MYSQL USERS TO DISK");
    };
    $logger->error("Runtime/Disk sync failed: $@") if $@;
}

1;