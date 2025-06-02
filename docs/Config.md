-- Reduce ssl overhead
SET mysql-have_ssl = 0;
-- multiplexing true
SET mysql-multiplexing = 1;
-- Global Variable Settings
SET mysql-threads = 12;
-- Optimize connection
SET mysql-connection_max_age_ms = 300000;
-- mysql-poll_timeout: Default: 1000 µs, Lower timeout for faster I/O polling: 
SET mysql-poll_timeout = 2000;
-- Disconnect early when server is unreachable
SET mysql-connect_timeout_server = 5000;
-- Optimize connection. No long running sess past 1 min
SET mysql-max_transaction_time = 50000;
-- Default Cache TTl to 30 seconds
SET mysql-query_cache_ttl = 30000;
-- Default Cache Size 128 MB. Set To 1GB
SET mysql-query_cache_size_MB = 1000;
-- Set timeout for idle conversations between MySQL client and a ProxySQL
SET mysql-wait_timeout = 3600000;
-- Enable storing empty results
SET mysql-query_cache_stores_empty_result=1;
-- Disable web interface
SET admin-web_enabled = false;
-- Adjust max connections
SET mysql-max_connections = 2048; 
-- Configure connection free timeout to free up idle connections
SET mysql-free_connections_pct = 90;
-- Increase TTL for rule 8 (high-frequency query)
UPDATE mysql_query_rules SET cache_ttl = 300000 WHERE rule_id = 8;
-- Reduce write HG connections to prevent overload
UPDATE mysql_servers SET max_connections = 500 WHERE hostgroup_id = 1;
-- Increase read HG connections for better scaling
UPDATE mysql_servers SET max_connections = 1500 WHERE hostgroup_id = 2;

-- APPLY CHANGES 
SAVE MYSQL VARIABLES TO DISK;
SAVE MYSQL QUERY RULES TO DISK;
SAVE MYSQL SERVERS TO DISK;

LOAD MYSQL VARIABLES TO RUNTIME;
LOAD MYSQL QUERY RULES TO RUNTIME;
LOAD MYSQL SERVERS TO RUNTIME;