#!/bin/bash
set -e

echo "Adding cPanel ProxySQL Restore Sync hook..."
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

echo "Writing ProxySQL hook module..."
cat <<'EOF' > /usr/local/cpanel/Cpanel/ProxyRestoreHook.pm
#!/usr/bin/perl

package Cpanel::ProxyRestoreHook;

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
my $log_file = "$log_dir/proxy_restore.log";

# Ensure log directory exists
make_path($log_dir) unless -d $log_dir;

my $logger = Cpanel::Logger->new();

sub describe {
    return [
       {
            'category' => 'PkgAcct',
            'event'    => 'Restore',
            'stage'    => 'postExtract',
            'hook'     => 'Cpanel::ProxyRestoreHook::pre_restore',
            'exectype' => 'module',
        },
        {
            'category' => 'PkgAcct',
            'event'    => 'Restore',
            'stage'    => 'post',
            'hook'     => 'Cpanel::ProxyRestoreHook::post_restore',
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

sub switch_to_mysql {
    log_to_file("Switching to direct MySQL connection");

    # Fix socket permissions
    if (-e "/var/lib/mysql/mysql.sock") {
        system("sudo chown mysql:mysql /var/lib/mysql/mysql.sock") == 0
            or log_to_file("Failed to chown mysql.sock: $?");
        system("sudo chmod 777 /var/lib/mysql/mysql.sock") == 0
            or log_to_file("Failed to chmod mysql.sock: $?");
    } else {
        log_to_file("MySQL socket /var/lib/mysql/mysql.sock does not exist");
    }

    # Create symlink to MySQL socket
    if (-e "/var/lib/mysql/mysql2.sock") {
        system("sudo ln -sf /var/lib/mysql/mysql2.sock /var/lib/mysql/mysql.sock") == 0
            or log_to_file("Failed to create symlink for mysql.sock: $?");
    } else {
        log_to_file("MySQL socket /var/lib/mysql/mysql2.sock does not exist");
    }

    # Redirect traffic from port 3306 to 3307
    system("sudo iptables -t nat -A PREROUTING -p tcp --dport 3306 -j REDIRECT --to-ports 3307") == 0
        or log_to_file("Failed to redirect PREROUTING 3306 to 3307: $?");
    system("sudo iptables -t nat -A OUTPUT -p tcp --dport 3306 -j REDIRECT --to-ports 3307") == 0
        or log_to_file("Failed to redirect OUTPUT 3306 to 3307: $?");
}

sub revert_to_proxysql {
   log_to_file("Reverting to ProxySQL operation");

    # Restore socket ownership to Proxysql
    if (-e "/var/lib/mysql/mysql.sock") {
        system("sudo chown proxysql:proxysql /var/lib/mysql/mysql.sock") == 0
            or log_to_file("Failed to chown mysql.sock to proxysql: $?");
    }

    # Remove symlink
    if (-l "/var/lib/mysql/mysql.sock") {
        system("sudo unlink /var/lib/mysql/mysql.sock") == 0
            or log_to_file("Failed to unlink mysql.sock: $?");
    }

   # Restore socket ownership
    if (-e "/var/lib/mysql/mysql2.sock") {
        system("sudo chown mysql:mysql /var/lib/mysql/mysql2.sock") == 0
            or log_to_file("Failed to chown mysql2.sock to mysql: $?");
        system("sudo chmod 777 /var/lib/mysql/mysql2.sock") == 0
            or log_to_file("Failed to update permissions for mysql2.sock to 777 $?");
    }

    # Restart ProxySQL
    system("sudo systemctl restart proxysql") == 0
        or log_to_file("Failed to restart ProxySQL: $?");
    
    # Remove port redirections
    system("sudo iptables -t nat -D PREROUTING -p tcp --dport 3306 -j REDIRECT --to-ports 3307") == 0
        or log_to_file("Failed to remove PREROUTING redirection: $?");
    system("sudo iptables -t nat -D OUTPUT -p tcp --dport 3306 -j REDIRECT --to-ports 3307") == 0
        or log_to_file("Failed to remove OUTPUT redirection: $?");

}

sub pre_restore {
    my ($context, $data) = @_;
   log_to_file("Starting pre-restore actions for restorepkg");
    switch_to_mysql();
   log_to_file("Switch to MySQL complete");
}

sub post_restore {
    my ($context, $data) = @_;
   log_to_file("Starting post-restore actions for restorepkg");
    _sync_all_mysql_users();
   log_to_file("ProxySQL user sync complete");
    revert_to_proxysql();
   log_to_file("ProxySQL operation restored");
}

sub _sync_all_mysql_users {
    log_to_file("Starting MySQL to ProxySQL user synchronization");

    # Connect to MySQL
    my $mysql_dsn = "DBI:mysql:database=mysql;host=$mysql_host;port=$mysql_port";
    my $mysql_dbh = DBI->connect($mysql_dsn, $mysql_user, $mysql_pass, {
        RaiseError => 0,
        AutoCommit => 1,
        PrintError => 0
    }) or do {
        log_to_file("Cannot connect to MySQL: $DBI::errstr");
        return;
    };
    
    # Connect to ProxySQL
    my $proxysql_dsn = "DBI:mysql:database=$proxysql_admin_db;host=$proxysql_admin_host;port=$proxysql_admin_port";
    my $proxysql_dbh = DBI->connect($proxysql_dsn, $proxysql_admin_user, $proxysql_admin_pass, {
        RaiseError => 0,
        AutoCommit => 1,
        PrintError => 0
    }) or do {
        log_to_file("Cannot connect to ProxySQL: $DBI::errstr");
        return;
    };
    
    # Get MySQL users with hashed passwords
    my $sth = $mysql_dbh->prepare("SELECT User, authentication_string FROM mysql.user WHERE Host = 'localhost' AND authentication_string != ''");
    unless ($sth && $sth->execute()) {
        log_to_file("Failed to query MySQL users: " . ($mysql_dbh->errstr || "Unknown error"));
        $mysql_dbh->disconnect();
        $proxysql_dbh->disconnect();
        return;
    }

    while (my ($username, $password_hash) = $sth->fetchrow_array) {
        next unless $username && $password_hash;
        log_to_file("Syncing user: $username");
        
        # Update ProxySQL's mysql_users
        eval {
            $proxysql_dbh->do(
                "REPLACE INTO mysql_users (username, password, default_hostgroup, active) VALUES (?, ?, ?, 1)",
                undef, $username, $password_hash, $proxysql_default_hostgroup
            );
        };
        if ($@) {
            log_to_file("Failed to sync user $username to ProxySQL: $@");
            next;
        }
    }
    $sth->finish();
    
    # Apply ProxySQL changes
    eval {
        $proxysql_dbh->do("LOAD MYSQL USERS TO RUNTIME");
        $proxysql_dbh->do("SAVE MYSQL USERS TO DISK");
    };

    if ($@) {
        log_to_file("Failed to apply ProxySQL changes: $@");
    }
    
    $mysql_dbh->disconnect();
    $proxysql_dbh->disconnect();
    log_to_file("MySQL to ProxySQL user synchronization completed");
}

1;
EOF

echo "Validating syntax..."
/usr/local/cpanel/3rdparty/bin/perl -c /usr/local/cpanel/Cpanel/ProxyRestoreHook.pm || exit 1

echo "Registering hook..."
/usr/local/cpanel/bin/manage_hooks add module Cpanel::ProxyRestoreHook

echo "Verifying..."
/usr/local/cpanel/bin/manage_hooks list | grep -q ProxyRestoreHook && \
echo "Success!" || echo "Installation failed!"