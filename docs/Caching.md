## Introduction
In this guide we are going to setup caching rules for proxysql and test them

# Rule 001
This rule takes the following pattern
```sql
SELECT option_value FROM wpeudu_options WHERE option_name = ? LIMIT ?
```
or 
```sql
SELECT option_value FROM zclk_options WHERE option_name = ? LIMIT ?
```
Let us add it to proxysql

```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    10,
    1,
    '(?i)^SELECT\s+.*option_value.*\s+FROM\s+`?[a-zA-Z0-9_]*_options`?\s+WHERE\s+option_name\s*=\s*\?\s+LIMIT\s*\?(?:\s*,\s*\?)?\s*$',
    3600000,  -- 1 hour in milliseconds
    1
);
EOF
```

# Rule Testing 
In mysql
```sh
sudo mysql <<EOF
-- Create a test database
CREATE DATABASE IF NOT EXISTS wordpress_test;
USE wordpress_test;
-- Create tables matching WordPress-like schemas
CREATE TABLE wp_options (
  option_name VARCHAR(255) PRIMARY KEY,
  option_value LONGTEXT
);
CREATE TABLE wpa7_options (
  option_name VARCHAR(255) PRIMARY KEY,
  option_value LONGTEXT
);
CREATE TABLE wpzy_options (
  option_name VARCHAR(255) PRIMARY KEY,
  option_value LONGTEXT
);
-- Create an unrelated table to test false positives
CREATE TABLE unrelated_table (
  id INT PRIMARY KEY,
  data VARCHAR(255)
);
-- Insert sample data
INSERT INTO wp_options (option_name, option_value) VALUES
('siteurl', 'http://test-site.com'),
('active_plugins', '["plugin1", "plugin2"]');
INSERT INTO wpa7_options (option_name, option_value) VALUES
('siteurl', 'http://wpa7-site.com'),
('theme', 'default');
INSERT INTO wpzy_options (option_name, option_value) VALUES
('siteurl', 'http://wpzy-site.com');
EOF
```

# Test Queries
Let us run these queries through ProxySQL 

## Test 1: Matching Query
```sql
SELECT option_value FROM wpa7_options WHERE option_name = 'siteurl' LIMIT 1;
```
Expected Result: This query should match the rule and be cached (check stats_mysql_query_digest).

## Test 2: Case-Insensitive Match
```sql
SELECT OPTION_VALUE FROM WPZY_OPTIONS WHERE OPTION_NAME = 'theme' LIMIT 1;
```
Expected Result: Should still match due to (?i) in the regex.

## Test 3: Non-Matching Query
```sql
SELECT * FROM unrelated_table WHERE id = 1;
```
Expected Result: Should not match the rule or be cached.

## Test 4: Edge Case (LIMIT with Two Parameters)
```sql
SELECT option_value FROM wp_options WHERE option_name = 'active_plugins' LIMIT 0,1;
```
Expected Result: Should match because the regex allows LIMIT ?,?.

## Verify Results
ProxySQL’s query digest to confirm caching:

```sql
-- Check which queries were matched/cached
SELECT digest, digest_text, cache_ttl, hits FROM stats_mysql_query_digest WHERE digest_text LIKE '%option_value%';
```
Look for:
cache_ttl = 3600000 on matching queries.
Increased hits for repeated identical queries.

# Mysql Slap
# Step 1: Prepare Test SQL File
Create a file
```sh
cat test_queries.sql  <<EOF
-- Matching queries (should trigger caching)
SELECT option_value FROM wpa7_options WHERE option_name = 'siteurl' LIMIT 1;
SELECT option_value FROM wp_options WHERE option_name = 'active_plugins' LIMIT 0,1;

-- Case sensitive
SELECT OPTION_VALUE FROM wpzy_options WHERE OPTION_NAME = 'theme' LIMIT 1;

-- Non-matching queries (should NOT trigger caching)
SELECT * FROM unrelated_table WHERE id = 1;
SELECT option_name FROM wpa7_options WHERE option_value LIKE '%test%';
EOF
```

## Step 2: Run mysqlslap Through ProxySQL
Execute mysqlslap to simulate concurrent clients.
```sh
mysqlslap \
  --user=stnduser \
  --password=stnduser \
  --host=127.0.0.1 \
  --port=3306 \
  --concurrency=50 \          
  --iterations=10 \          
  --query=test_queries.sql \  
  --create-schema=wordpress_test  
```

## Step 3: Verify ProxySQL Stats
After running mysqlslap,ProxySQL’s query digest to confirm caching behavior:

-- Connect to ProxySQL admin interface
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
SELECT
  digest_text,
  cache_ttl,
  SUM(hits) AS total_hits,
  SUM(count_star) AS total_queries
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%option_value%' OR digest_text LIKE '%unrelated_table%'
GROUP BY digest_text;
EOF
```

## Expected Results:
Queries matching your regex (e.g., SELECT option_value FROM wpa7_options...) should show cache_ttl = 3600000 and high total_hits.
Non-matching queries (e.g., SELECT * FROM unrelated_table...) should have cache_ttl = 0.

# Step 4: Validate Caching
All case variations (e.g., SELECT, select).
WordPress options tables (e.g., wp_options, wpa7_options).
Both LIMIT ? and LIMIT ?,?.
False Positives: If non-matching queries (e.g., SELECT * FROM unrelated_table) appear in stats_mysql_query_digest with cache_ttl > 0, 
Performance: High total_hits for matching queries indicate successful caching. If Query_Cache_count_GET_OK increases, the cache is working.


# Rule 002
This rule takes the following format 
```sql
SELECT post_id,meta_key,meta_value FROM wpgc_postmeta WHERE post_id IN (?) ORDER BY meta_id ASC
```
## 1. Create the Rule 
```sql
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    20,  -- new rule_id
    1,
    '^(?i)SELECT\s+post_id,\s*meta_key,\s*meta_value\s+FROM\s+`?[a-zA-Z0-9_]+_postmeta`?\s+WHERE\s+post_id\s+IN\s*\(\s*\?\s*\)\s+ORDER\s+BY\s+meta_id\s+ASC\s*$',
    3600000,  -- 1 hour in milliseconds
    1
);
```

```sql
USE wordpress_test;
```

```sql
-- Create the table
CREATE TABLE IF NOT EXISTS wp0p_postmeta (
  meta_id BIGINT PRIMARY KEY,
  post_id BIGINT,
  meta_key VARCHAR(255),
  meta_value LONGTEXT
);
```
## 2.Insert sample Data
-- Insert sample data
```sql
INSERT INTO wp0p_postmeta (meta_id, post_id, meta_key, meta_value) VALUES
(1, 101, 'color', 'red'),
(2, 101, 'size', 'large'),
(3, 102, 'color', 'blue'),
(4, 103, 'weight', '5kg');
```

# 3. Test Queries
Run these queries through ProxySQL to validate the rule:

1. Test 1: Matching Query
```sql
SELECT post_id, meta_key, meta_value FROM wp0p_postmeta WHERE post_id IN (101) ORDER BY meta_id ASC;
Expected Result: Rule matches, query is cached.
```

2. Test 2: Case-Insensitive Match
```sql
SELECT POST_ID, META_KEY, META_VALUE FROM WP0P_POSTMETA WHERE POST_ID IN (102) ORDER BY META_ID ASC;
Expected Result: Rule matches due to (?i).
```

3. Test 3: Non-Matching Query (Different Table)
```sql
SELECT post_id, meta_key, meta_value FROM other_postmeta WHERE post_id IN (103) ORDER BY meta_id ASC;
```
Expected Result: Rule does NOT match.

## 4. Simulate Load with mysqlslap
Create a test file postmeta_queries.sql:

```sql
-- Matching queries
SELECT post_id, meta_key, meta_value FROM wp0p_postmeta WHERE post_id IN (101) ORDER BY meta_id ASC;
SELECT post_id, meta_key, meta_value FROM wp0p_postmeta WHERE post_id IN (102) ORDER BY meta_id ASC;
-- Non-matching query
SELECT post_id, meta_key, meta_value FROM unrelated_postmeta WHERE post_id IN (103) ORDER BY meta_id ASC;
```
Run mysqlslap:
```bash
mysqlslap \
  --user=stnduser \
  --password=stnduser \
  --host=127.0.0.1 \
  --port=3306 \
  --concurrency=50 \
  --iterations=10 \
  --query=postmeta_queries.sql \
  --create-schema=wordpress_test
```
## 5. Verify ProxySQL Stats
Check query digest and caching:
```sql
-- Check matching queries
SELECT
  digest_text,
  cache_ttl,
  SUM(hits) AS total_hits,
  SUM(count_star) AS total_queries
FROM stats_mysql_query_digest
WHERE digest = '0xE705224D2739445A'  -- Digest from stats
OR digest_text LIKE '%wp%postmeta%';
```
``` Expected Output:
digest_text	cache_ttl	total_hits	total_queries
SELECT post_id, meta_key, meta_value FROM wp0p_postmeta...	3600000	1000	1000
SELECT post_id, meta_key, meta_value FROM unrelated_post...	0	0	500
```

## 6. Final Validation
Only the target query (wp0p_postmeta) is cached.
The cache hit count (Query_Cache_count_GET_OK) increases.
Non-matching queries are ignored by the rule.


# Validation check commands

Check the query cache status and results

```sql
SELECT * FROM stats_mysql_global WHERE Variable_Name LIKE  'Query_Cache%';
```

```sql
SELECT * FROM stats_mysql_query_rules;
```

Query_Cache_Memory_bytes --total size of stored result in query cache
Query_Cache_Count_GET -- total number of get requests executed against the Query cache
Query_Cache_count_GET_OK -- total number of succesful get requests against the Query Cache