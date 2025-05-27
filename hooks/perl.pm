#!/usr/bin/perl

# Written by Ashraf Sharif (ashraf@severalnines.com)
# Automatically manages ProxySQL mysql_users table for cPanel events

package Cpanel::ProxysqlHook;

use strict;
use warnings;

use Cpanel::Logger;
use JSON;
use DBI;

## ProxySQL admin login credentials
my $proxysql_admin_host = '127.0.0.1';
my $proxysql_admin_port = '6032';
my $proxysql_admin_user = 'admin';
my $proxysql_admin_pass = 'admin';

my $proxysql_admin_db   = 'admin'; # do not change
my $proxysql_default_hostgroup = 1;

my $logger = Cpanel::Logger->new();

sub describe {
  my $hooks = [
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
  return $hooks;
};

$logger->info("**** Reading ProxySQL information: Host: $proxysql_admin_host, Port: $proxysql_admin_port, User: $proxysql_admin_user *****");

# Connect to the ProxySQL admin database.
my $dsn = "DBI:mysql:database=$proxysql_admin_db;host=$proxysql_admin_host;port=$proxysql_admin_port";
my $dbh = DBI->connect($dsn,
            $proxysql_admin_user,
            $proxysql_admin_pass,
            {'RaiseError' => 1});

sub create_proxysql_user {
  my ( $context, $data ) = @_;

  my $dbuser = $data->{args}->{name};
  my $dbpass = $data->{args}->{password};

  if (check_mysql_users_table($dbuser) == 0) {
    $logger->info("**** Inserting $dbuser into ProxySQL mysql_users table *****");
    eval { $dbh->do("INSERT INTO mysql_users(username,password,default_hostgroup) VALUES (?, ?, ?)", undef, $dbuser, $dbpass, $proxysql_default_hostgroup) };
    print "Adding user $dbuser failed: $@\n" if $@;

    load_mysql_users_table();
  }
};

sub create_proxysql_user2 {
  my ( $context, $data ) = @_;

  my $dbuser = $data->{args}->{dbuser};
  my $dbpass = $data->{args}->{password};

  if (check_mysql_users_table($dbuser) == 0) {
    $logger->info("**** Inserting $dbuser into ProxySQL mysql_users table *****");
    eval { $dbh->do("INSERT INTO mysql_users(username,password,default_hostgroup) VALUES (?, ?, ?)", undef, $dbuser, $dbpass, $proxysql_default_hostgroup) };
    print "Adding user $dbuser failed: $@\n" if $@;

    load_mysql_users_table();
  }
};

sub delete_proxysql_user {
  my ( $context, $data ) = @_;

  my $dbuser = $data->{args}->{name};

  if (check_mysql_users_table($dbuser) != 0) {
    $logger->info("**** Deleting $dbuser from ProxySQL mysql_users table *****");
    eval { $dbh->do("DELETE FROM mysql_users WHERE username = ?", undef, $dbuser) };
    print "Deleting user $dbuser failed: $@\n" if $@;

    load_mysql_users_table();
  }
};

sub delete_proxysql_user2 {
  my ( $context, $data ) = @_;

  my $dbuser = $data->{args}->{dbuser};

  if (check_mysql_users_table($dbuser) != 0) {
    $logger->info("**** Deleting $dbuser from ProxySQL mysql_users table *****");
    eval { $dbh->do("DELETE FROM mysql_users WHERE username = ?", undef, $dbuser) };
    print "Deleting user $dbuser failed: $@\n" if $@;

    load_mysql_users_table();
  }
};

sub rename_proxysql_user {
  my ( $context, $data ) = @_;

  my $dbolduser = $data->{args}->{oldname};
  my $dbnewuser = $data->{args}->{newname};

  if (check_mysql_users_table($dbolduser) != 0) {
    $logger->info("**** Updating $dbolduser to $dbnewuser inside ProxySQL mysql_users table *****");
    eval { $dbh->do("UPDATE mysql_users SET username = ? WHERE username = ?", undef, $dbnewuser, $dbolduser) };
    print "Updating user $dbolduser failed: $@\n" if $@;

    load_mysql_users_table();
  }
};

sub set_default_schema {
  my ( $context, $data ) = @_;

  my $dbuser = $data->{args}->{user};
  my $dbname = $data->{args}->{database};

  $logger->info("**** Updating $dbuser default schema in ProxySQL mysql_users table *****");
  eval { $dbh->do("UPDATE mysql_users SET default_schema = ? WHERE username = ?", undef, $dbname, $dbuser) };
  print "Updating default schema for $dbuser failed: $@\n" if $@;

  load_mysql_users_table();
};

sub set_default_schema2 {
  my ( $context, $data ) = @_;

  my $dbuser = $data->{args}->{dbuser};
  my $dbname = $data->{args}->{db};

  $logger->info("**** Updating $dbuser default schema in ProxySQL mysql_users table *****");
  eval { $dbh->do("UPDATE mysql_users SET default_schema = ? WHERE username = ?", undef, $dbname, $dbuser) };
  print "Updating default schema for $dbuser failed: $@\n" if $@;

  load_mysql_users_table();
};

sub set_mysql_user_password {
  my ( $context, $data ) = @_;

  my $dbuser = $data->{args}->{user};
  my $dbpass = $data->{args}->{password};

  $logger->info("**** Updating $dbuser password in ProxySQL mysql_users table *****");
  eval { $dbh->do("UPDATE mysql_users SET password = ? WHERE username = ?", undef, $dbpass, $dbuser) };
  print "Updating password for user $dbuser failed: $@\n" if $@;

  load_mysql_users_table();
};

sub create_proxysql_default_user {
  my ( $context, $data ) = @_;

  my $default_dbuser = $data->{user};
  my $default_dbpass = $data->{pass};

  if (check_mysql_users_table($default_dbuser) == 0) {
    $logger->info("**** Inserting $default_dbuser into ProxySQL mysql_users table *****");
    eval { $dbh->do("INSERT INTO mysql_users(username,password,default_hostgroup) VALUES (?, ?, ?)", undef, $default_dbuser, $default_dbpass, $proxysql_default_hostgroup) };
    print "Adding user $default_dbuser failed: $@\n" if $@;

    load_mysql_users_table();
  }
}

sub remove_proxysql_default_user {
  my ( $context, $data ) = @_;

  my $default_dbuser = $data->{user};

  if (check_mysql_users_table($default_dbuser) != 0) {
    $logger->info("**** Deleting $default_dbuser from ProxySQL mysql_users table *****");
    eval { $dbh->do("DELETE FROM mysql_users WHERE username = ?", undef, $default_dbuser) };
    print "Deleting user $default_dbuser failed: $@\n" if $@;

    load_mysql_users_table();
  }
};

sub check_mysql_users_table {
  my ($dbuser) = @_;

  $logger->info("**** Checking if $dbuser exists inside ProxySQL mysql_users table *****");
  my $sth = $dbh->prepare(
    'SELECT username FROM mysql_users WHERE username = ?')
    or die "prepare statement failed: $dbh->errstr()";

  $sth->execute($dbuser) or die "execution failed: $dbh->errstr()";
  my $rows = $sth->rows;
  $sth->finish;

  return $rows;
}

sub load_mysql_users_table {
  $logger->info("**** Save and load user into ProxySQL runtime *****");

  $dbh->do("LOAD MYSQL USERS TO RUNTIME");
  $dbh->do("SAVE MYSQL USERS TO DISK");

  # $dbh->disconnect();
}

1;