#!/usr/bin/perl

package Cpanel::ProxyRestoreHook;

use strict;
use warnings;
use Cpanel::Logger;
use DBI;

my $logger = Cpanel::Logger->new();

sub describe {
    return [
       {
            'category' => 'System',
            'event'    => 'restorepkg::pre',
            'stage'    => 'pre',
            'hook'     => 'Cpanel::ProxyRestoreHook::pre_restore',
            'exectype' => 'module',
        },
        {
            'category' => 'System',
            'event'    => 'restorepkg::post',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxyRestoreHook::post_restore',
            'exectype' => 'module',
        }
    ];
}

sub switch_to_mysql {
    # Fix Permissions for Socket ownership to mysql
    system("sudo chown mysql:mysql /var/lib/mysql/mysql.sock");
    # Fix Socket Permission
    system("sudo chmod +777 /var/lib/mysql/mysql.sock");
    # Temporarily redirect MySQL socket to active Mysql Socket location
    system("sudo ln -sf /var/lib/mysql/mysql2.sock /var/lib/mysql/mysql.sock");    
    # Redirect external incoming traffic port 3306 to 3307
    system("sudo iptables -t nat -A PREROUTING -p tcp --dport 3306 -j REDIRECT --to-ports 3307");
    # Redirect internal incoming traffic as well from 3306 to 3307
    system("sudo iptables -t nat -A OUTPUT -p tcp --dport 3306 -j REDIRECT --to-ports 3307");
}

sub revert_to_proxysql {
    # Fix Permissions for Socket ownership ProxySQL 
    system("sudo chown proxysql:proxysql /var/lib/mysql/mysql.sock");
    # Point the link to mysql socket if it exists
    system("sudo systemctl restart proxysql");
    # Unlink the old symlink
    system("sudo unlink /var/lib/mysql/mysql.sock");
    # Remove port redirection
    system("sudo iptables -t nat -D PREROUTING -p tcp --dport 3306 -j REDIRECT --to-ports 3307");
    # Remove internal redirection
    system("sudo iptables -t nat -D OUTPUT -p tcp --dport 3306 -j REDIRECT --to-ports 3307");
}

# Restore hook for post-restore actions
sub pre_restore {
    my ($context, $data) = @_;
    $logger->info("Starting pre-restore actions for restorepkg");
    switch_to_mysql();    
    $logger->info("Switch to mysql complete");
}

# Restore proxysql for post-restore actions
sub post_restore {
    my ($context, $data) = @_;
    $logger->info("Starting post-restore actions for restorepkg");
    # Sync MySQL users to ProxySQL
    _sync_all_mysql_users();
    $logger->info("ProxySQL user sync complete");
    revert_to_proxysql();
    $logger->info("ProxySQL operation restored");
}

sub _sync_all_mysql_users {    
    # Connect to MySQL (port 3307) and ProxySQL admin interface (port 6032)
    my $mysql_dbh = DBI->connect("DBI:mysql:database=mysql;host=127.0.0.1;port=3307", "stnduser", "stnduser")
        or die "Cannot connect to MySQL: $DBI::errstr";
    my $proxysql_dbh = DBI->connect("DBI:mysql:database=main;host=127.0.0.1;port=6032", "admin", "admin")
        or die "Cannot connect to ProxySQL: $DBI::errstr";

    # Get all MySQL users with their hashed passwords
    my $sth = $mysql_dbh->prepare("SELECT User, authentication_string FROM mysql.user WHERE Host = 'localhost'");
    $sth->execute();

    while (my ($username, $password_hash) = $sth->fetchrow_array) {
        # Skip empty or invalid entries
        next unless $username && $password_hash;

        # Insert or update ProxySQL's mysql_users table
        $proxysql_dbh->do(
            "REPLACE INTO mysql_users (username, password, default_hostgroup) VALUES (?, ?, ?)",
            undef, $username, $password_hash, 1
        );
    }

    # Apply changes in ProxySQL
    $proxysql_dbh->do("LOAD MYSQL USERS TO RUNTIME");
    $proxysql_dbh->do("SAVE MYSQL USERS TO DISK");

    # Clean up connections
    $mysql_dbh->disconnect();
    $proxysql_dbh->disconnect();
}

1;