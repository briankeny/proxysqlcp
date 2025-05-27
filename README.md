# Proxsyqlcp
This is a step by step guide on how to setup proxysql

## Installation
```sh
cat <<EOF | tee /etc/yum.repos.d/proxysql.repo
[proxysql_repo]
name=ProxySQL repository
baseurl=https://repo.proxysql.com/ProxySQL/proxysql-2.7.x/almalinux/\$releasever
gpgcheck=1
gpgkey=https://repo.proxysql.com/ProxySQL/proxysql-2.7.x/repo_pub_key
EOF
```
```sh
yum install proxysql
```
```sh
clear
```
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> '
```
ProxySQL Admin>
```sh
SELECT * FROM mysql_servers;
```
```sh
SELECT * from mysql_replication_hostgroups;
```
```sh
SELECT * from mysql_query_rules;
```
```sh
INSERT INTO mysql_servers(hostgroup_id,hostname,port) VALUES (1,'127.0.0.1',3306);
```
```sh
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS  TO DISK;
```
Create proxy monitoring user mysql
<!-- Mariadb -->
```sh
sudo mariadb
```
mysql

```sh
CREATE USER 'monitor'@'%' IDENTIFIED BY 'monitor';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'monitor'@'%';
FLUSH PRIVILEGES;
```
Then add the credentials of the monitor user to ProxySQL:
ProxySQL Admin>
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> '
```
```sh
 UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
 UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_password';
 UPDATE global_variables SET variable_value='2000' WHERE variable_name IN ('mysql-monitor_connect_interval','mysql-monitor_ping_interval','mysql-monitor_read_only_interval');
```
```sh
SELECT * FROM global_variables WHERE variable_name LIKE 'mysql-monitor_%';
```
ProxySQL Admin>
```sh
 LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
```
# Backend’s health check
Once the previous configuration is active, it’s time to promote the servers to runtime to enable monitoring:
ProxySQL Admin>
```sh
LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
```
```sh
SELECT * FROM mysql_servers;
```
Once the configuration is active, it’s possible to verify the status of the MySQL backends in the monitor database tables in ProxySQL Admin:

ProxySQL Admin>
```sh
 SHOW TABLES FROM monitor;
```
```
+----------------------------------+
| tables                           |
+----------------------------------+
| mysql_server_connect             |
| mysql_server_connect_log         |
| mysql_server_ping                |
| mysql_server_ping_log            |
| mysql_server_read_only_log       |
| mysql_server_replication_lag_log |
+----------------------------------+
6 rows in set (0.00 sec)
```
Each check type has a dedicated logging table, each should be checked individually:

ProxySQL Admin>
```sh
SELECT * FROM monitor.mysql_server_connect_log ORDER BY time_start_us DESC LIMIT 3;
```
```
+-----------+------+------------------+----------------------+---------------+
| hostname  | port | time_start_us    | connect_success_time | connect_error |
+-----------+------+------------------+----------------------+---------------+
| 10.10.0.1 | 3306 | 1456968814253432 | 562                  | NULL          |
| 10.10.0.2 | 3306 | 1456968814253432 | 309                  | NULL          |
| 10.10.0.3 | 3306 | 1456968814253432 | 154                  | NULL          |
+-----------+------+------------------+----------------------+---------------+
3 rows in set (0.00 sec)
```
```sh
SELECT * FROM monitor.mysql_server_ping_log ORDER BY time_start_us DESC LIMIT 3;
```
```
+-----------+------+------------------+-------------------+------------+
| hostname  | port | time_start_us    | ping_success_time | ping_error |
+-----------+------+------------------+-------------------+------------+
| 10.10.0.1 | 3306 | 1456968828686787 | 124               | NULL       |
| 10.10.0.2 | 3306 | 1456968828686787 | 62                | NULL       |
| 10.10.0.3 | 3306 | 1456968828686787 | 57                | NULL       |
+-----------+------+------------------+-------------------+------------+
3 rows in set (0.01 sec)
```
This way we can verify that the servers are being monitored correctly and are healthy.

# MySQL replication hostgroups
Cluster topology changes are monitored based on MySQL replication hostgroups configured in ProxySQL. ProxySQL understands the replication topology by monitoring the value of read_only on servers configured in hostgroups that are configured in mysql_replication_hostgroups.

This table is empty by default and should be configured by specifying a pair of READER and WRITER hostgroups, although the MySQL backends might all be right now in a single hostgroup.

For example:
```sh
INSERT INTO mysql_replication_hostgroups (writer_hostgroup,reader_hostgroup,comment) VALUES (1,2,'cluster1');
```
Now, all the MySQL backend servers that are either configured in hostgroup 1 or 2 will be placed into their respective hostgroup based on their read_only value:

If they have read_only=0 , they will be moved to hostgroup 1
If they have read_only=1 , they will be moved to hostgroup 2

To enable the replication hostgroup load mysql_replication_hostgroups to runtime using the same LOAD command used for MySQL servers since LOAD MYSQL SERVERS TO RUNTIME processes both mysql_servers and mysql_replication_hostgroups tables.

ProxySQL Admin>

```sh
LOAD MYSQL SERVERS TO RUNTIME;
```
The read_only check results are logged to the mysql_servers_read_only_log table in the monitor database:

```sh
SELECT * FROM monitor.mysql_server_read_only_log ORDER BY time_start_us DESC LIMIT 3;
```

```
+-----------+-------+------------------+--------------+-----------+-------+
| hostname  | port  | time_start_us    | success_time | read_only | error |
+-----------+-------+------------------+--------------+-----------+-------+
| 10.10.0.1 | 3306  | 1456969634783579 | 762          | 0         | NULL  |
| 10.10.0.2 | 3306  | 1456969634783579 | 378          | 1         | NULL  |
| 10.10.0.3 | 3306  | 1456969634783579 | 317          | 1         | NULL  |
+-----------+-------+------------------+--------------+-----------+-------+
3 rows in set (0.01 sec)
```

As a final step, persist the configuration to disk.

```sh
SAVE MYSQL SERVERS TO DISK;
```
```sh
SAVE MYSQL VARIABLES TO DISK;
```

# MySQL Users
After configuring the MySQL server backends in mysql_servers the next step is to configure mysql users.
We are creating a MySQL user with no particular restrictions: this is not a good practice the user should be configured with proper connection restrictions and privileges according to the setup and the application needs. To create the user in MySQL connect to the PRIMARY and execute:
mysql>
```sh
CREATE USER 'stnduser'@'%' IDENTIFIED BY 'stnduser';
```
```sh
GRANT ALL PRIVILEGES ON *.* TO 'stnduser'@'%';
```
Time to configure the user into ProxySQL: this is performed by adding entries to the mysql_users table:
```sh
INSERT INTO mysql_users(username,password,default_hostgroup) VALUES ('stnduser','stnduser',1);
SELECT * FROM mysql_users;
```
By defining the default_hostgroup we are specifying which backend servers a user should connect to BY DEFAULT (i.e. this will be the default route for traffic coming from the specific user, additional rules can be configured to re-route however in their absence all queries will go to the specific hostgroup).

ProxySQL Admin>
```sh
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
```
ProxySQL is now ready to serve traffic on port 6033 (by default):
```sh
sudo mysql -u stnduser -pstnduser -h 127.0.0.1 -P6033 -e "SELECT @@port;"
```
Warning: Using a password on the command line interface can be insecure.
```
+--------+
| @@port |
+--------+
|&nbsp; 3306&nbsp; |
+--------+
```
This query was sent to the server listening on port 3306 , the primary, as this is the server configured on hostgroup1 and is the default for user stnduser.

# Sysbench
Sysbench is a useful tool to verify that ProxySQL is functional and benchmark system performance.

# Installation

# RHEL/CentOS:
Run
```sh
curl -s https://packagecloud.io/install/repositories/akopytov/sysbench/script.rpm.sh | sudo bash
sudo yum -y install sysbench
```

# Mysql Config
In mysql my.cnf add
```sh
sudo vi /etc/my.cnf
```
```ini
innodb_data_home_dir = /data/mysql/
innodb_data_file_path = ibdata1:128M:autoextend
innodb_log_group_home_dir = /data/mysql/
innodb_buffer_pool_size = 1024M
innodb_additional_mem_pool_size = 32M
innodb_log_file_size = 256M
innodb_log_buffer_size = 16M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50
innodb_doublewrite = 0
innodb_flush_method = O_DIRECT
innodb_thread_concurrency = 0
innodb_max_dirty_pages_pct = 80

table_open_cache = 512
thread_cache = 512
query_cache_size = 0
query_cache_type = 0
```

Then

```sh
sudo systemctl stop mysql
sudo systemctl start mysql
```

Start and prepare database to use

```sh
mysqladmin -uroot drop sbtest
mysqladmin -uroot create sbtest
```

# Introduction
We use the latest sysbench with Lua scripting support. Therefore the test names differ from sysbench <= 0.4.
To get reasonable results we use a run time of 5 minutes.

# Setup
To simulate load on mysqldb directly

1. Set Test Dir
```sh
TEST_DIR="/usr/share/sysbench"
```
2. Preparation
```sh
sysbench  ${TEST_DIR}/oltp_read_write.lua   --db-driver=mysql   --mysql-user=stnduser   --mysql-password=stnduser  --mysql-host=127.0.0.1   --mysql-port=3306   --mysql-db=sbtest   --tables=1   --table-size=2000000   prepare
```
3. Running
```sh
NUM_THREADS="1 4 8 16 32 64 128"
for THREAD in $NUM_THREADS; do
  echo "=== Running oltp_read_write.lua with $THREAD threads ==="
  sysbench \
    ${TEST_DIR}/oltp_read_write.lua \
    --db-driver=mysql \
    --mysql-user=stnduser \
    --mysql-password=stnduser \
    --mysql-host=127.0.0.1 \
    --mysql-port=3306 \
    --mysql-db=sbtest \
    --tables=1 \
    --table-size=2000000 \
    --threads=$THREAD \
    --time=300 \
    --events=0 \
    run
  echo ""
done
```
4. cleanup
```sh
sysbench \
  ${TEST_DIR}/oltp_read_write.lua \
  --db-driver=mysql \
  --mysql-user=stnduser \
  --mysql-password=stnduser \
  --mysql-host=127.0.0.1 \
  --mysql-port=3306 \
  --mysql-db=sbtest \
  --tables=1 \
  --table-size=2000000 \
  cleanup
```

# Functional Test With Sysbench
You can run a load test against ProxySQL locally using the following command:

1. Set Test Dir
```sh
TEST_DIR="/usr/share/sysbench"
```
2. Simulate the load
```sh
sysbench ${TEST_DIR}/oltp_read_write.lua  \
  --threads=4 \
  --time=20 \
  --report-interval=5 \
  --events=0 \
  run \
  --mysql-user=stnduser \
  --mysql-password=stnduser \
  --mysql-host=127.0.0.1 \
  --mysql-port=6033 \
   --mysql-db=sbtest \
  --table-size=10000
```
# ProxySQL Statistics
ProxySQL collects a lot of real time statistics in the stats schema, each table provides specific information about the behavior of ProxySQL and the workload being processed:
1. Run
```sh
SHOW TABLES FROM stats;
```
2. stats_mysql_connection_pool
```sh
 SELECT * FROM stats.stats_mysql_connection_pool;
 ```
3. stats_mysql_commands_counters
The stats_mysql_commands_counters table returns detailed information about the type of statements executed, and the distribution of execution time:
```sh
SELECT * FROM stats_mysql_commands_counters WHERE Total_cnt;
```
4. stats_mysql_query_digest
Query information is tracked in the stats_mysql_query_digest which provides query counts per backend, reponse times per query as well as the actual query text as well as the query digest which is a unique identifier for every query type:
ProxySQL Admin>
```sh
SELECT * FROM stats_mysql_query_digest ORDER BY sum_time DESC;
```
5. Key query information can be filtered out to analyze the core traffic workload with a simple query:
```sh
SELECT hostgroup hg, sum_time, count_star, digest_text FROM stats_mysql_query_digest ORDER BY sum_time DESC;
```
In the information provided it is clear that all traffic is sent to the primary instance on hostgroup1, in order to re-route this workload to a replica in hostgroup2 query rules are required.
6. MySQL Query Rules
To configure ProxySQL to send the top 2 queries to the replica hostgroup2, and everything else to the primary the following rules would be required:
ProxySQL Admin>
```sh
INSERT INTO mysql_query_rules (rule_id,active,username,match_digest,destination_hostgroup,apply) VALUES (10,1,'stnduser','^SELECT c FROM sbtest1 WHERE id=?',2,1);
```
```sh
INSERT INTO mysql_query_rules (rule_id,active,username,match_digest,destination_hostgroup,apply) VALUES (20,1,'stnduser','DISTINCT c FROM sbtest1',2,1);
```
Key points about these query rules (and query rules in general):
Query rules are processed as ordered by rule_id
Only rules that have active=1 are processed
The first rule example uses caret (^) and dollar ($) : these are special regex characters that mark the beginning and the end of a pattern i.e. in this case match_digestormatch_pattern should completely match the query
The second rule in the example doesn’t use caret or dollar : the match could be anywhere in the query
The question mark is escaped as it has a special meaning in regex
apply=1 means that no further rules should be evaluated if the current rule was matched
The current rule configuration can be checked in the mysql_query_rules, note: this configuration is not yet active:

ProxySQL Admin>
```sh
SELECT match_digest,destination_hostgroup FROM mysql_query_rules WHERE active=1 AND username='stnduser' ORDER BY rule_id;
```
```
+-------------------------------------+-----------------------+
| match_digest                        | destination_hostgroup |
+-------------------------------------+-----------------------+
| ^SELECT c FROM sbtest1 WHERE id=?$ | 2                     |
| DISTINCT c FROM sbtest1             | 2                     |
+-------------------------------------+-----------------------+
```
2 rows in set (0.00 sec)
For these 2 specific rules, queries will be sent to slaves. If no rules match the query, the default_hostgroup configured for the user applies (that is 1 for user stnduser). The stats_mysql_query_digest_reset can be queried to retrieve the previous workload and clear the contents of the stats_mysql_query_digest table , and truncate it, this is recommended before activating query rules to easily review the changes.

Load the query rules to runtime to activate changes :
ProxySQL Admin>
```sh
LOAD MYSQL QUERY RULES TO RUNTIME;
```
After traffic passes through the new configuration the stats_mysql_query_digest will reflect the changes in routing per query:
ProxySQL Admin>
```sh
SELECT hostgroup hg, sum_time, count_star, digest_text FROM stats_mysql_query_digest ORDER BY sum_time DESC;
```
```
+----+----------+------------+----------------------------------------------------------------------+
| hg | sum_time | count_star | digest_text                                                          |
+----+----------+------------+----------------------------------------------------------------------+
<strong>| 2  | 14520738 | 50041      | SELECT c FROM sbtest1 WHERE id=?                                     |
| 2  | 3203582  | 5001       | SELECT DISTINCT c FROM sbtest1 WHERE id BETWEEN ? AND ?+? ORDER BY c |</strong>
| 1  | 3142041  | 5001       | COMMIT                                                               |
| 1  | 2270931  | 5001       | SELECT c FROM sbtest1 WHERE id BETWEEN ? AND ?+? ORDER BY c          |
| 1  | 2021320  | 5003       | SELECT c FROM sbtest1 WHERE id BETWEEN ? AND ?+?                     |
| 1  | 1768748  | 5001       | UPDATE sbtest1 SET k=k+? WHERE id=?                                  |
| 1  | 1697175  | 5003       | SELECT SUM(K) FROM sbtest1 WHERE id BETWEEN ? AND ?+?                |
| 1  | 1346791  | 5001       | UPDATE sbtest1 SET c=? WHERE id=?                                    |
| 1  | 1263259  | 5001       | DELETE FROM sbtest1 WHERE id=?                                       |
| 1  | 1191760  | 5001       | INSERT INTO sbtest1 (id, k, c, pad) VALUES (?, ?, ?, ?)              |
| 1  | 875343   | 5005       | BEGIN                                                                |
+----+----------+------------+----------------------------------------------------------------------+
11 rows in set (0.00 sec)
```
The top 2 queries identified are sent to the hostgroup2 replicas. Aggregated results can also be viewed in the stats_mysql_query_digest table, for example:
ProxySQL Admin>
```sh
SELECT hostgroup hg, SUM(sum_time), SUM(count_star) FROM stats_mysql_query_digest GROUP BY hostgroup;
```
```
+----+---------------+-----------------+
| hg | SUM(sum_time) | SUM(count_star) |
+----+---------------+-----------------+
| 1  | 21523008      | 59256           |
| 2  | 23915965      | 72424           |
+----+---------------+-----------------+
2 rows in set (0.00 sec)
```
# Query Caching
A popular use-case for ProxySQL is to act as a query cache. By default, queries aren’t cached, this is enabled by setting cache_ttl (in milliseconds) on a rule defined in mysql_query_rules . To cache all the queries sent to replicas for 5 seconds update the cache_ttl on the query rules defined in the previous example:

ProxySQL Admin>
```sh
UPDATE mysql_query_rules set cache_ttl=5000 WHERE active=1 AND destination_hostgroup=2;
```
```sh
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```
```sh
SELECT 1 FROM stats_mysql_query_digest_reset LIMIT 1;
```
-- we reset the counters
```
+---+
| 1 |
+---+
| 1 |
+---+
1 row in set (0.00 sec)
```
After traffic passes through the new configuration the stats_mysql_query_digest will show the cached queries with a hostgroup value of “-1”:

ProxySQL Admin>
```sh
SELECT hostgroup hg, sum_time, count_star, digest_text FROM stats_mysql_query_digest ORDER BY sum_time DESC;
```
```
+----+----------+------------+----------------------------------------------------------------------+
| hg | sum_time | count_star | digest_text                                                          |
+----+----------+------------+----------------------------------------------------------------------+
| 1  | 7457441  | 5963       | COMMIT                                                               |
| 1  | 6767681  | 5963       | SELECT c FROM sbtest1 WHERE id BETWEEN ? AND ?+? ORDER BY c          |
| 2  | 4891464  | 8369       | SELECT c FROM sbtest1 WHERE id=?                                     |
| 1  | 4573513  | 5963       | UPDATE sbtest1 SET k=k+? WHERE id=?                                  |
| 1  | 4531319  | 5963       | SELECT c FROM sbtest1 WHERE id BETWEEN ? AND ?+?                     |
| 1  | 3993283  | 5963       | SELECT SUM(K) FROM sbtest1 WHERE id BETWEEN ? AND ?+?                |
| 1  | 3482242  | 5963       | UPDATE sbtest1 SET c=? WHERE id=?                                    |
| 1  | 3209088  | 5963       | DELETE FROM sbtest1 WHERE id=?                                       |
| 1  | 2959358  | 5963       | INSERT INTO sbtest1 (id, k, c, pad) VALUES (?, ?, ?, ?)              |
| 1  | 2415318  | 5963       | BEGIN                                                                |
| 2  | 2266662  | 1881       | SELECT DISTINCT c FROM sbtest1 WHERE id BETWEEN ? AND ?+? ORDER BY c |
<strong>| -1 | 0        | 4082       | SELECT DISTINCT c FROM sbtest1 WHERE id BETWEEN ? AND ?+? ORDER BY c |
| -1 | 0        | 51261      | SELECT c FROM sbtest1 WHERE id=?                                     |</strong>
+----+----------+------------+----------------------------------------------------------------------+
13 rows in set (0.00 sec)
```

# Query Rewrite
To match the text of a query ProxySQL provides 2 mechanisms:

match_digest : match the regular expression against the digest of the query which strips SQL query data (e.g. `SELECT c FROM sbtest1 WHERE id=?` as represented in stats_mysql_query_digest.query_digest
match_pattern : match the regular expression against the actual text of the query e.g. `SELECT c FROM sbtest1 WHERE id=2`

The digest is always smaller than the query itself, running a regex against a smaller string is faster and it is recommended (for performance) to use
1. match_digest.
To rewrite queries or match against the query text itself use match_pattern. For example:
ProxySQL Admin>
```sh
INSERT INTO mysql_query_rules (rule_id,active,username,match_pattern,replace_pattern,apply) VALUES (30,1,'stnduser','DISTINCT(.*)ORDER BY c','DISTINCT1',1);
```
```sh
SELECT rule_id, match_digest, match_pattern, replace_pattern, cache_ttl, apply FROM mysql_query_rules ORDER BY rule_id;
```
```
+---------+-------------------------------------+------------------------+-----------------+-----------+-------+
| rule_id | match_digest                        | match_pattern          | replace_pattern | cache_ttl | apply |
+---------+-------------------------------------+------------------------+-----------------+-----------+-------+
| 10      | ^SELECT c FROM sbtest1 WHERE id=?$  | NULL                   | NULL            | 5000      | 1     |
| 20      | DISTINCT c FROM sbtest1             | NULL                   | NULL            | 5000      | 1     |
| 30      | NULL                                | DISTINCT(.*)ORDER BY c | DISTINCT1       | NULL      | 1     |
+---------+-------------------------------------+------------------------+-----------------+-----------+-------+
3 rows in set (0.00 sec)
```
ProxySQL Admin>
```sh
LOAD MYSQL QUERY RULES TO RUNTIME;
```
Query OK, 0 rows affected (0.00 sec)
This configuration would result in the following behavior:
ProxySQL Admin>
```sh
SELECT hits, mysql_query_rules.rule_id, match_digest, match_pattern, replace_pattern, cache_ttl, apply FROM mysql_query_rules NATURAL JOIN stats.stats_mysql_query_rules ORDER BY mysql_query_rules.rule_id;
```
```
+-------+---------+-------------------------------------+------------------------+-----------------+-----------+-------+
| hits  | rule_id | match_digest                        | match_pattern          | replace_pattern | cache_ttl | apply |
+-------+---------+-------------------------------------+------------------------+-----------------+-----------+-------+
| 48560 | 10      | ^SELECT c FROM sbtest1 WHERE id=?   | NULL                   | NULL            | 5000      | 1     |
| 4856  | 20      | DISTINCT c FROM sbtest1             | NULL                   | NULL            | 5000      | 0     |
| 4856  | 30      | NULL                                | DISTINCT(.*)ORDER BY c | DISTINCT1       | NULL      | 1     |
+-------+---------+-------------------------------------+------------------------+-----------------+-----------+-------+
3 rows in set (0.01 sec)
```
Feel confident to move on to more advanced configuration, here is a link on How to set up ProxySQL Read/Write Split


# Disable Monitoring

Delete the SHUNNED server from mysql_servers:

```sh
DELETE FROM mysql_servers
WHERE hostgroup_id = 2 AND hostname = '127.0.0.1' AND port = 3306;
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
```
# Disable monitoring
```sh
UPDATE global_variables SET variable_value='false' WHERE variable_name='mysql-monitor_enabled';
UPDATE global_variables SET variable_value='0' WHERE variable_name='mysql-monitor_groupreplication_healthcheck_interval';
UPDATE global_variables SET variable_value='0' WHERE variable_name='mysql-monitor_groupreplication_healthcheck_max_timeout_count';
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
```
```sh
SELECT variable_name, variable_value FROM global_variables WHERE variable_name LIKE 'mysql-monitor_groupreplication%';
```

# Enable Monitoring
```sh
UPDATE global_variables SET variable_value='true' WHERE variable_name='mysql-monitor_enabled';
UPDATE global_variables SET variable_value='5000' WHERE variable_name='mysql-monitor_groupreplication_healthcheck_interval';
UPDATE global_variables SET variable_value='4' WHERE variable_name='mysql-monitor_groupreplication_healthcheck_max_timeout_count';
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
```
# Deploying ProxySQL on WHM/cPanel
Since we want ProxySQL to take over the default MySQL port 3306, we have to firstly modify the existing MySQL server installed by WHM to listen to other port and other socket file.
In /etc/my.cnf, modify the following lines (add them if do not exist):
```sh
socket=/var/lib/mysql/mysql2.sock
port=3307
bind-address=127.0.0.1
```
Then, restart MySQL server on cPanel server:
```sh
systemctl restart mysqld
```

The server address is the WHM server, 127.0.0.1. The listening port is 3306 on the WHM server, taking over the local MySQL which is already running on port 3307. Further down, we specify the ProxySQL admin and monitoring users’ password. Then include MySQL server into the load balancing set and then choose “No” in the Implicit Transactions section.

Proxysql is already setup and configured on the server so we skip its installation and configuration.

The next step is to grant MySQL root user and import it into ProxySQL. Occasionally, WHM somehow connects to the database via TCP connection, bypassing the UNIX socket file. In this case, we have to allow MySQL root access from both root@localhost and root@127.0.0.1 (the IP address of WHM server) in our mysql database.

Thus, running the following statement on  server is necessary:
```sh
mysql -uroot -pmysql> GRANT ALL PRIVILEGES ON *.* TO whm_cpanel_usr@'127.0.0.1' IDENTIFIED BY 'zEw)7!sd+8Xf' WITH GRANT OPTION;
```
Then, import ‘root’@’localhost’ user from our MySQL server into ProxySQL
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> '
```
```sh
INSERT INTO mysql_users(username,password,default_hostgroup) VALUES ('root','zEw)7!sd+8Xf',1);
```
```sh
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
```
Next choose hostgroup 10 as the default hostgroup for the user.
<!-- No idea how to do this -->
Verify if ProxySQL is running correctly on the WHM/cPanel server.
```sh
sudo service proxysql status
```
Port 3306 is what ProxySQL should be listening to accept all MySQL connections. Port 6032 is the ProxySQL admin port, where we will connect to configure and monitor ProxySQL components like users, hostgroups, servers and variables.

# Configuring MySQL UNIX Socket
In Linux environment, if you define MySQL host as “localhost”, the client/application will try to connect via the UNIX socket file, which by default is located at /var/lib/mysql/mysql.sock on the cPanel server.
Using the socket file is the most recommended way to access MySQL server, because it has less overhead as compared to TCP connections. A socket file doesn’t actually contain data, it transports it. It is like a local pipe the server and the clients on the same machine can use to connect and exchange requests and data.

Having said that, if your application connects via “localhost” and port 3306 as the database host and port, it will connect via socket file. If you use “127.0.0.1” and port 3306, most likely the application will connect to the database via TCP. This behaviour is well explained in the MySQL documentation. In simple words, use socket file (or “localhost”) for local communication and use TCP if the application is connecting remotely.

In cPanel, the MySQL socket file is monitored by cpservd process and would be linked to another socket file if we configured a different path than the default one. For example, suppose we configured a non-default MySQL socket file as we configured in the previous section:

```sh
cat /etc/my.cnf | grep socket
```
```
socket=/var/lib/mysql/mysql2.sock
```
cPanel via cpservd process would correct this by creating a symlink to the default socket path:
```sh
ls -al /var/lib/mysql/mysql.sock
```
Output
```
lrwxrwxrwx. 1 root root 34 Jul  4 12:25 /var/lib/mysql/mysql.sock -> ../../../var/lib/mysql/mysql2.sock
```
To avoid cpservd to automatically re-correct this (cPanel has a term for this behaviour called “automagically”), we have to disable MySQL monitoring by going to WHM -> Service Manager (we are not going to use the local MySQL anyway) and uncheck “Monitor” checkbox for MySQL as shown in the screenshot below:
Save the changes in WHM. It’s now safe to remove the default socket file and create a symlink to ProxySQL socket file with the following command:
```sh
ln -s /tmp/proxysql.sock /var/lib/mysql/mysql.sock
```
Verify the socket MySQL socket file is now redirected to ProxySQL socket file:
```sh
ls -al /var/lib/mysql/mysql.sock
```
output
```
lrwxrwxrwx. 1 root root 18 Jul  3 12:47 /var/lib/mysql/mysql.sock -> /tmp/proxysql.sock
```
We also need to change the default login credentials inside /root/.my.cnf as follows:

```
cat ~/.my.cnf[client]#password="T<y4ar&cgjIu"user=whm_cpanel_usrpassword='zEw)7!sd+8Xf'socket=/var/lib/mysql/mysql.sock
```
A bit of explanation – The first line that we commented out is the MySQL root password generated by cPanel for the local MySQL server. We are not going to use that, therefore the ‘#’ is at the beginning of the line. Then, we added the MySQL root password for our MySQL replication setup and UNIX socket path, which is now symlink to ProxySQL socket file.

At this point, on the WHM server you should be able to access our MySQL as root user by simply typing “mysql”, for example:

```sh
mysql
```
```
Welcome to the MySQL monitor.  Commands end with ; or g.
Your MySQL connection id is 488605
Server version: 8.0.41 MySQL Community Server - GPL

Copyright (c) 2000, 2025, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql>
```
Notice the server version is 8.0.41 (ProxySQL). If you can connect as above, we can configure the integration part as described in the next section.

# WHM/cPanel Integration
WHM supports a number of database server, namely MySQL 8.0, 8.4, MariaDB 10.11 and MariaDB 11.4. Since WHM is now only seeing the ProxySQL and it is detected as version 5.5.30 (as stated above), WHM will complain about unsupported MySQL version. You can go to WHM -> SQL Services -> Manage MySQL Profiles and click on Validate button. You should get a red toaster notification on the top-right corner telling about this error.

Therefore, we have to change the MySQL version in ProxySQL to the same version as our MySQL db. You can get this information by running the following statement on the master server:
mysql>
```sh
select version();
```
```
+-----------+
| version() |
+-----------+
| 8.0.41 |
+-----------+
```
Then, login to the ProxySQL admin console to change the mysql-server_version variable:

```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> '
```
Use the SET statement as below:

```sh
SET mysql-server_version = '10.11.11';
```
Then load the variable into runtime and save it into disk to make it persistent:
```sh
LOAD MYSQL VARIABLES TO RUNTIME;
```
```sh
SAVE MYSQL VARIABLES TO DISK;
```
Finally verify the version that ProxySQL will represent:
```sh
SHOW VARIABLES LIKE 'mysql-server_version';
```
```
+----------------------+--------+| Variable_name | Value |+----------------------+--------+| mysql-server_version | 8.0.41 |+----------------------+--------+
```
If you try again to connect to MySQL by running the “mysql” command, you should now see “Server version: 8.0.41 (ProxySQL)” in the terminal.

Now we can update the MySQL root password under WHM -> SQL Services -> Manage MySQL Profiles. Edit the localhost profile by changing the Password field at the bottom with the MySQL root password of our mysql database. Click on the Save button once done. We can then click on “Validate” to verify if WHM can access our MySQL db via ProxySQL service correctly. You should get the following green toaster at the top right corner:

If you get the green toaster notification, we can proceed to integrate ProxySQL via cPanel hook.

# ProxySQL Integration via cPanel Hook
ProxySQL as the middle-man between WHM and MySQL replication needs to have a username and password for every MySQL user that will be passing through it. With the current architecture, if one creates a user via the control panel (WHM via account creation or cPanel via MySQL Database wizard), WHM will automatically create the user directly in our MySQL db using root@localhost (which has been imported into ProxySQL beforehand). However, the same database user would be not added into ProxySQL mysql_users table automatically.

From the end-user perspective, this would not work because all localhost connections at this point should be passed through ProxySQL. We need a way to integrate cPanel with ProxySQL, whereby for any MySQL user related operations performed by WHM and cPanel, ProxySQL must be notified and do the necessary actions to add/remove/update its internal mysql_users table.

The best way to automate and integrate these components is by using the cPanel standardized hook system. Standardized hooks trigger applications when cPanel & WHM performs an action. Use this system to execute custom code (hook action code) to customize how cPanel & WHM functions in specific scenarios (hookable events).

Firstly, create a Perl module file called ProxysqlHook.pm under /usr/local/cpanel directory:
```sh
touch /usr/local/cpanel/ProxysqlHook.pm
```
Then, copy and paste the lines from here. For more info, check out the Github repository at ProxySQL cPanel Hook.

Configure the ProxySQL admin interface from line 16 until 19:
```
my $proxysql_admin_host = '127.0.0.1';
my $proxysql_admin_port = '6032';
my $proxysql_admin_user = 'proxysql-admin';
my $proxysql_admin_pass = 'mys3cr3t';
```
Now that the hook is in place, we need to register it with the cPanel hook system:
```sh
sudo /usr/local/cpanel/bin/manage_hooks add module ProxysqlHook
```
output
```
info [manage_hooks] **** Reading ProxySQL information: Host: 127.0.0.1, Port: 6032, User: proxysql-admin *****
Added hook for Whostmgr::Accounts::Create to hooks registry
Added hook for Whostmgr::Accounts::Remove to hooks registry
Added hook for Cpanel::UAPI::Mysql::create_user to hooks registry
Added hook for Cpanel::Api2::MySQLFE::createdbuser to hooks registry
Added hook for Cpanel::UAPI::Mysql::delete_user to hooks registry
Added hook for Cpanel::Api2::MySQLFE::deletedbuser to hooks registry
Added hook for Cpanel::UAPI::Mysql::set_privileges_on_database to hooks registry
Added hook for Cpanel::Api2::MySQLFE::setdbuserprivileges to hooks registry
Added hook for Cpanel::UAPI::Mysql::rename_user to hooks registry
Added hook for Cpanel::UAPI::Mysql::set_password to hooks registry
```
# Removing the hook
```sh
sudo /usr/local/cpanel/bin/manage_hooks delete module ProxysqlHook
```

# Configure Unit Sock file for localhost connections
Tools using a socket, ProxySQL should listen on a UNIX socket too:
Make sure the file is owned/readable by the mysql

```sh
chown mysql:mysql /tmp/proxysql.sock
chmod 755 /tmp/proxysql.sock
```
Then restart ProxySQL:
```sh
systemctl restart proxysql
```
Then ensure /var/lib/mysql/mysql.sock symlink exists and points here:
```sh
  /var/lib/mysql/mysql.sock -> /tmp/proxysql.sock
```
This lets anything using the default MySQL socket (localhost) hit ProxySQL.

# Query Caching
Using ProxySQL to act as a query cache.

# Note
Rule order matters: lower rule_id = higher priority.
fast_forward = bypass full parse & speed routing.
cache_ttl only applies to SELECT rules.

# Hostgroups
We have two hostgroups already defined:
hostgroup 1 → Primary/MySQL (writes & fallback reads)
hostgroup 2 → Replica/MySQL (read-only)

1. Verify
```sh
SELECT * FROM mysql_servers;
```

# ProxySQL Admin>
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> '
```
```sql
UPDATE mysql_query_rules set cache_ttl=5000 WHERE active=1 AND destination_hostgroup=2;
LOAD MYSQL QUERY RULES TO RUNTIME;
```
```sql
SELECT 1 FROM stats_mysql_query_digest_reset LIMIT 1;
 --- After traffic passes through the new configuration the stats_mysql_query_digest will show the cached queries with a hostgroup value of “-1”:
SELECT hostgroup hg, sum_time, count_star, digest_text FROM stats_mysql_query_digest ORDER BY sum_time DESC;
```
Shell>
```sh
TEST_DIR="/usr/share/sysbench"
```
```sh
sysbench /usr/share/sysbench/oltp_read_write.lua  \
  --threads=4 \
  --time=20 \
  --report-interval=5 \
  --events=0 \
  run \
  --mysql-user=stnduser \
  --mysql-password=stnduser \
  --mysql-host=127.0.0.1 \
  --mysql-port=3306 \
   --mysql-db=sbtest \
  --table-size=10000
```

# View mysql query digest stats
```sh
SELECT hostgroup hg, sum_time, count_star, digest_text FROM stats_mysql_query_digest ORDER BY sum_time DESC;
```

# Cache Optimization Settings
```sql
  -- Delete existing rules
  DELETE FROM mysql_query_rules;
  -- Configure query cache rules for read/write split
  -- Rule 1: Direct all write operations to hostgroup 1 (your existing rule with a proper rule_id)
  INSERT INTO mysql_query_rules (rule_id, active, match_pattern, re_modifiers, destination_hostgroup, apply)
  VALUES (10, 1, '^(INSERT|UPDATE|DELETE|REPLACE|BEGIN|COMMIT|ROLLBACK)', 'CASELESS', 1, 1);
  -- Rule 2: Direct SELECT queries for single-row lookups with high cache value to read hostgroup with caching
  INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, cache_ttl, apply)
  VALUES (20, 1, '^SELECT c FROM sbtest1 WHERE id=\?$', 2, 600, 1);
  -- Rule 3: Cache the expensive range queries
  INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, cache_ttl, apply)
  VALUES (30, 1, '^SELECT .* FROM sbtest1 WHERE id BETWEEN \? AND \?', 2, 300, 1);
  -- Rule 4: Handle the single-row lookups (high frequency)
  INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, cache_ttl, apply)
  VALUES (40, 1, '^SELECT .* FROM sbtest1 WHERE id=\?', 2, 600, 1);
  -- Rule 5: Handle the SUM operation (analytical query)
  INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, cache_ttl, apply)
  VALUES (50, 1, '^SELECT SUM\(k\) FROM sbtest1 WHERE id BETWEEN \? AND \?', 2, 600, 1);
  -- Rule 6: Default rule to send remaining SELECT queries to read replica
  INSERT INTO mysql_query_rules (rule_id, active, match_pattern, re_modifiers, destination_hostgroup, apply)
  VALUES (100, 1, '^SELECT ', 'CASELESS', 2, 1);
  -- Load the new configuration into runtime
  LOAD MYSQL QUERY RULES TO RUNTIME;
  SAVE MYSQL QUERY RULES TO DISK;
  -- End of rules
  -- Configure settings
  --SSL & Security mysql-have_ssl :Disabled SSL to reduced overhead:
  SET mysql-have_ssl = 0;
  --Improves resilience to backend failures  mysql-connect_timeout_server Default: 10,000 ms
  SET mysql-connect_timeout_server = 1000; -- 1 second
  -- multiplexing
  SET mysql-multiplexing = 1;
  -- Optimize connection
  SET mysql-max_transaction_time = 2000;
  -- Cache ttl
  SET mysql-query_cache_ttl=60000;
  -- Default Cache Size 128 MB
  SET mysql-query_cache_size_MB = 300;
  -- Enable storing empty results
  SET mysql-query_cache_stores_empty_result=1;
  -- Adjust max connections
  SET mysql-max_connections = 2048;
  -- mysql-poll_timeout: Default: 1000 µs, Lower timeout for faster I/O polling: Helps in high-load scenarios
  SET mysql-poll_timeout = 500; -- Microseconds
  -- Adjusted based on CPU cores
  SET mysql-threads = 4;
  -- Configure connection free timeout to free up idle connections
  SET mysql-free_connections_pct = 120000;
  -- Apply and save
  SAVE MYSQL VARIABLES TO DISK;
  LOAD MYSQL VARIABLES TO RUNTIME;
  -- Adjust max connections per hostgroup for load balancing
  UPDATE mysql_servers SET max_connections=1000 WHERE hostgroup_id=1; -- Write hostgroup
  UPDATE mysql_servers SET max_connections=2000 WHERE hostgroup_id=2; -- Read hostgroup
  -- Improves write performance by skipping rules/cache [File ].
  UPDATE mysql_users SET fast_forward = 1 WHERE username = 'stnduser';
  LOAD MYSQL USERS TO RUNTIME;
  SAVE MYSQL USERS TO DISK;
```
