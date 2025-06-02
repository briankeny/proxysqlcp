## Introduction
In this guide we are going to setup caching rules for proxysql and test them

# Test Database Creation
```sh
sudo mysql <<EOF
-- Create a test database
CREATE DATABASE IF NOT EXISTS wordpress_test;
EOF
```

# Rule 001
This rule takes the following pattern
```sql
SELECT option_value FROM wpeudu_options WHERE option_name = ? LIMIT ?
```
Add to proxysql
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    5,
    1,
    '(?i)^SELECT\s+.*option_value.*\s+FROM\s+`?[a-zA-Z0-9_]*_options`?\s+WHERE\s+option_name\s*=\s*\?\s+LIMIT\s*\?(?:\s*,\s*\?)?\s*$',
    3600000,  -- 1 hour in milliseconds
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```

# Rule Testing  & Validation
1. Mysql insert data
```sh
sudo mysql <<EOF
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

2. Mysql Slap
Prepare Test SQL File 
```sh
cat <<EOF > test_queries.sql
SELECT option_value FROM wpa7_options WHERE option_name = 'siteurl' LIMIT 1;
SELECT option_value FROM wp_options WHERE option_name = 'active_plugins' LIMIT 0,1;
SELECT OPTION_VALUE FROM wpzy_options WHERE option_name = 'theme' LIMIT 1;
-- Non-matching queries (should NOT trigger caching)
SELECT * FROM unrelated_table WHERE id = 1;
SELECT option_name FROM wpa7_options WHERE option_value LIKE '%test%';
EOF
```
3. Run mysqlslap Through ProxySQL
Execute mysqlslap to simulate concurrent clients.
```sh
mysqlslap \
  --user=stnduser \
  --password=stnduser \
  --host=127.0.0.1 \
  --port=3306 \
  --concurrency=50 \
  --iterations=10 \
  --create-schema=wordpress_test \
  --query=test_queries.sql
```

4. Verify ProxySQL Stats
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
Proxysql Admin
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
    '^(?i)SELECT\s+post_id,\s*meta_key,\s*meta_value\s+FROM\s+`?[a-zA-Z0-9_]+_postmeta`?\s+WHERE\s+post_id\s+IN\s*\(\s*\?\s*\)\s+ORDER\s+BY\s+meta_id\s+ASC\s*$',
    3600000,  -- 1 hour in milliseconds
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
# Testing and Validation
1. Create Mysql Tables
```sh 
sudo mysql <<EOF
USE wordpress_test;
-- Create the table
CREATE TABLE IF NOT EXISTS wp0p_postmeta (
  meta_id BIGINT PRIMARY KEY,
  post_id BIGINT,
  meta_key VARCHAR(255),
  meta_value LONGTEXT
);
EOF
```

2.Insert sample Data
-- Insert sample data to mysql
```sh
sudo mysql <<EOF
USE wordpress_test;
INSERT INTO wp0p_postmeta (meta_id, post_id, meta_key, meta_value) VALUES
(1, 101, 'color', 'red'),
(2, 101, 'size', 'large'),
(3, 102, 'color', 'blue'),
(4, 103, 'weight', '5kg');
EOF
```

3. Test Queries
Create a test file postmeta_queries.sql
```sh
cat <<EOF > postmeta_queries.sql
-- Matching queries
SELECT post_id, meta_key, meta_value FROM wp0p_postmeta WHERE post_id IN (101) ORDER BY meta_id ASC;
SELECT post_id, meta_key, meta_value FROM wp0p_postmeta WHERE post_id IN (102) ORDER BY meta_id ASC;
-- Non-matching query
-- SELECT post_id, meta_key, meta_value FROM unrelated_postmeta WHERE post_id IN (103) ORDER BY meta_id ASC;
EOF
```

4. Simulate Load with mysqlslap
Run these queries through ProxySQL to validate the rule:
```bash
mysqlslap \
  --user=stnduser \
  --password=stnduser \
  --host=127.0.0.1 \
  --port=3306 \
  --concurrency=50 \
  --iterations=100 \
  --query=postmeta_queries.sql \
  --create-schema=wordpress_test
```

5. Verify ProxySQL Stats
Check query digest and caching:
```sql
-- Check matching queries
SELECT
  digest_text,
  cache_ttl,
  SUM(hits) AS total_hits,
  SUM(count_star) AS total_queries
FROM stats_mysql_query_digest
digest_text LIKE '%wp%postmeta%';
```
``` Expected Output:
digest_text	cache_ttl	total_hits	total_queries
SELECT post_id, meta_key, meta_value FROM wp0p_postmeta...	3600000	1000	1000
SELECT post_id, meta_key, meta_value FROM unrelated_post...	0	0	500
```

6. Final Validation
Only the target query (wp0p_postmeta) is cached.
The cache hit count (Query_Cache_count_GET_OK) increases.
Non-matching queries are ignored by the rule.


# Rule 003 & OO4
This rule takes the following pattern
```sql
SELECT t.*,tt.* FROM wprw_terms AS t INNER JOIN wprw_term_taxonomy AS tt ON t.term_id = tt.term_id WHERE t.term_id = ?
```
1. Create the rule 003
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    15,
    1,
    '(?i)^SELECT\s+t\.\*,tt\.\*\s+FROM\s+[a-zA-Z0-9]+_terms\s+AS\s+t\s+INNER\s+JOIN\s+`?[a-zA-Z0-9]+_term_taxonomy`?\s+AS\s+tt\s+ON\s+t\.term_id\s+=\s+tt\.term_id\s+WHERE\s+t\.term_id\s+=\s+\?$',
    30000,
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
2. This rule follows the following pattern 
```sql
SELECT t.*,tt.* FROM wprw_terms AS t INNER JOIN wprw_term_taxonomy AS tt ON t.term_id = tt.term_id WHERE t.term_id IN (?,?,?,...)
```
or
```sql
SELECT t.*,tt.* FROM wp6l_terms AS t INNER JOIN wp6l_term_taxonomy AS tt ON t.term_id = tt.term_id WHERE t.term_id IN (?)
```
Create the rule on proxysql
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    20,
    1,
    '(?i)^SELECT t\.\*,tt\.\* FROM [a-z0-9]+_terms AS t INNER JOIN [a-z0-9]+_term_taxonomy AS tt ON t\.term_id = tt\.term_id WHERE t\.term_id[ ]*IN[ ]*\([ ]*\?(?:[ ]*,[ ]*\?)*[ ]*\)$',
    3600000,
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
4. Create Test Table & Insert Data
Mysql
```sh
sudo mysql <<EOF
USE wordpress_test;
CREATE TABLE wp_terms (
    term_id INT PRIMARY KEY,
    name VARCHAR(100),
    slug VARCHAR(100),
    term_group INT
);
CREATE TABLE wp_term_taxonomy (
    term_taxonomy_id INT PRIMARY KEY,
    term_id INT,
    taxonomy VARCHAR(50),
    description TEXT,
    parent INT,
    count INT,
    FOREIGN KEY (term_id) REFERENCES wp_terms(term_id)
);
INSERT INTO wp_terms (term_id, name, slug, term_group) VALUES
(1, 'Technology', 'technology', 0),
(2, 'Science', 'science', 0),
(3, 'Health', 'health', 0),
(4, 'Education', 'education', 0);
INSERT INTO wp_term_taxonomy (term_taxonomy_id, term_id, taxonomy, description, parent, count) VALUES
(10, 1, 'category', 'Tech related content', 0, 5),
(11, 2, 'category', 'Science related content', 0, 3),
(12, 3, 'category', 'Health related content', 0, 4),
(13, 4, 'category', 'Education content', 0, 2);
EOF
```

4. Prepare and Query Data
Create term_queries.sql:
```sh
cat <<EOF > term_queries.sql
-- Matching IN queries (rule 9)
SELECT t.*,tt.* FROM wp_terms AS t INNER JOIN wp_term_taxonomy AS tt ON t.term_id = tt.term_id WHERE t.term_id IN (1);
SELECT t.*,tt.* FROM wp_terms AS t INNER JOIN wp_term_taxonomy AS tt ON t.term_id = tt.term_id WHERE t.term_id IN (2,3);
-- Matching = query (rule 8)
SELECT t.*,tt.* FROM wp_terms AS t INNER JOIN wp_term_taxonomy AS tt ON t.term_id = tt.term_id WHERE t.term_id = 4;
EOF
```
5. Simulate load with mysql slap
```sh
mysqlslap \
  --user=stnduser \
  --password=stnduser \
  --host=127.0.0.1 \
  --port=3306 \
  --concurrency=50 \
  --iterations=100 \
  --query=term_queries.sql \
  --create-schema=wordpress_test
```
6. Verification 
Run this to confirm match/caching behavior:

```sql
SELECT
  digest_text,
  cache_ttl,
  SUM(hits) AS total_hits,
  SUM(count_star) AS total_queries
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%term_taxonomy%' OR digest_text LIKE '%unrelated_table%'
GROUP BY digest_text;
```

## Rule 005:
This Query takes complex post query with JOINs Pattern
```sql
SELECT SQL_CALC_FOUND_ROWS wp6l_posts.ID 
FROM wp6l_posts 
LEFT JOIN wp6l_term_relationships 
ON (wp6l_posts.ID = wp6l_term_relationships.object_id) 
WHERE 1=1 
AND wp6l_posts.ID NOT IN (?) 
AND (wp6l_term_relationships.term_taxonomy_id IN (?)) 
AND wp6l_posts.post_type = ? 
AND ((wp6l_posts.post_status = ?)) 
GROUP BY wp6l_posts.ID 
ORDER BY RAND() 
LIMIT ?,?
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    25,
    1,
    '(?i)SELECT\s+SQL_CALC_FOUND_ROWS\s+[a-zA-Z0-9_]+\.ID\s+FROM\s+`?[a-zA-Z0-9_]+_posts`?\s+LEFT JOIN\s+`?[a-zA-Z0-9_]+_term_relationships`?\s+ON\s+\([a-zA-Z0-9_]+\.ID\s*=\s*[a-zA-Z0-9_]+\.object_id\)',
    600000,
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
1. Create tables and data:
```sh
sudo mysql <<EOF
USE wordpress_test;
CREATE TABLE wp6l_posts (ID INT PRIMARY KEY, post_type VARCHAR(50), post_status VARCHAR(50));
CREATE TABLE wp6l_term_relationships (object_id INT, term_taxonomy_id INT);
INSERT INTO wp6l_posts VALUES 
(1001,'post','publish'), (1002,'page','draft');
INSERT INTO wp6l_term_relationships VALUES (1001,5), (1001,7);
-- Create additional test tables
CREATE TABLE wp_other_posts (ID INT PRIMARY KEY, post_type VARCHAR(50));
CREATE TABLE wp_other_term_relationships (object_id INT, term_taxonomy_id INT);
-- Insert more diverse data
INSERT INTO wp6l_posts VALUES 
(1003, 'attachment', 'inherit'),
(1004, 'post', 'private'),
(1005, 'product', 'publish');
INSERT INTO wp6l_term_relationships VALUES 
(1003, 8),
(1004, 5),
(1005, 9);
INSERT INTO wp_other_posts VALUES (2001, 'post');
INSERT INTO wp_other_term_relationships VALUES (2001, 10);
EOF
```
2. Prepare Test Query:
```sh
cat <<EOF > rule005.sql
SELECT SQL_CALC_FOUND_ROWS wp6l_posts.ID FROM wp6l_posts LEFT JOIN wp6l_term_relationships ON (wp6l_posts.ID = wp6l_term_relationships.object_id) WHERE 1=1 AND wp6l_posts.ID NOT IN (1002) AND (wp6l_term_relationships.term_taxonomy_id IN (5)) AND wp6l_posts.post_type = 'post' AND ((wp6l_posts.post_status = 'publish')) GROUP BY wp6l_posts.ID ORDER BY RAND() LIMIT 0,10;
-- Should match
SELECT SQL_CALC_FOUND_ROWS wp6l_posts.ID FROM wp6l_posts LEFT JOIN wp6l_term_relationships ON (wp6l_posts.ID = wp6l_term_relationships.object_id);
-- Should match (different prefix)
SELECT SQL_CALC_FOUND_ROWS wp_other_posts.ID FROM wp_other_posts LEFT JOIN wp_other_term_relationships ON (wp_other_posts.ID = wp_other_term_relationships.object_id);
-- Should match (additional clauses)
SELECT SQL_CALC_FOUND_ROWS wp6l_posts.ID FROM wp6l_posts LEFT JOIN wp6l_term_relationships ON (wp6l_posts.ID = wp6l_term_relationships.object_id) WHERE post_status = 'publish';
-- Should NOT match (different structure)
SELECT * FROM wp6l_posts;
EOF
```
3. Test the query with mysql slap
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 --port=3306 \
  --concurrency=30 --iterations=100 --query=rule005.sql \
  --create-schema=wordpress_test
```
Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%SQL_CALC_FOUND_ROWS%';"
```
## Expected Results
Query shows cache_ttl=600000
Hit count matches iteration count (100 hits)


## Rule 006: Blogposts views query
Query Pattern
```sql
SELECT views, wkviews, hviews FROM blogposts where pash=?
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    30,
    1,
    '^(?i)SELECT\s+views,\s*wkviews,\s*hviews\s+FROM\s+blogposts\s+WHERE\s+pash\s*=\s*\?\s*$',
    1800000,
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
1. Create table and data:
```sh
sudo mysql <<EOF
USE wordpress_test;
CREATE TABLE blogposts (
  pash INT PRIMARY KEY, 
  views INT, 
  wkviews INT,
  hviews INT
);
INSERT INTO blogposts VALUES 
(101, 1500, 200, 15),
(102, 8500, 950, 82);
EOF
```
2. Run test queries:
```sh
cat <<EOF > rule006.sql
SELECT views, wkviews, hviews FROM blogposts where pash=101;
SELECT views, wkviews, hviews FROM blogposts where pash=102;
EOF
```
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 --port=3306 \
  --concurrency=40 --iterations=200 --query=rule006.sql \
  --create-schema=wordpress_test
```
3. Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%blogposts where pash=%';"
```
## Expected Results
Both queries show cache_ttl=1800000
Total hits = 400 (2 queries × 200 iterations)

## Rule 007: Blogposts lookup by pash
Query Pattern
```sql
SELECT * FROM blogposts WHERE pash=?
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    35,
    1,
    '^(?i)SELECT\s+\*\s+FROM\s+blogposts\s+WHERE\s+pash\s*=\s*\?\s*$',
    3600000,  -- 1 hour
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
1. Ensure data exists (using existing blogposts table):
```sh
sudo mysql <<EOF
USE wordpress_test;
INSERT INTO blogposts (pash, views, wkviews, hviews) VALUES 
(301, 2500, 300, 25),
(302, 3500, 400, 35);
EOF
```
2. Create test queries:
```sh
cat <<EOF > rule007.sql
SELECT * FROM blogposts WHERE pash=301;
SELECT * FROM blogposts WHERE pash=302;
EOF
```
3. Run test:
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 --port=3306 \
  --concurrency=40 --iterations=100 --query=rule007.sql \
  --create-schema=wordpress_test
```
4. Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%blogposts WHERE pash=%';"
```

## Expected Results
Queries show cache_ttl=3600000
Hit count = 200 (2 queries × 100 iterations)

## Rule 008: Blogposts lookup by pcat
Query Pattern
```sql
SELECT * FROM blogposts WHERE pcat=?
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    40,
    1,
    '^(?i)SELECT\s+\*\s+FROM\s+blogposts\s+WHERE\s+pcat\s*=\s*\?\s*$',
    1800000,  -- 30 minutes (shorter TTL since categories might change more frequently)
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
1. Add more category data:
```sh
sudo mysql <<EOF
USE wordpress_test;
ALTER TABLE blogposts ADD COLUMN pcat INT;
UPDATE blogposts SET pcat=7 WHERE pash=301;
UPDATE blogposts SET pcat=8 WHERE pash=302;
INSERT INTO blogposts (pash, pcat, views) VALUES 
(303, 7, 1500),
(304, 8, 2500);
EOF
```
2. Create test queries:
```sh
cat <<EOF > rule008.sql
SELECT * FROM blogposts WHERE pcat=7;
SELECT * FROM blogposts WHERE pcat=8;
EOF
```
Run test:
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 --port=3306 \
  --concurrency=30 --iterations=150 --query=rule008.sql \
  --create-schema=wordpress_test
```
Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%blogposts WHERE pcat=%';"
```
## Expected Results
Queries show cache_ttl=1800000
Hit count = 300 (2 queries × 150 iterations)

## Final Verification
Check all rules:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT rule_id, match_digest, cache_ttl 
FROM mysql_query_rules 
WHERE rule_id IN (100, 110);
SELECT 
  digest_text,
  cache_ttl,
  SUM(hits) AS hits
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%blogposts WHERE pash=%'
   OR digest_text LIKE '%blogposts WHERE pcat=%'
GROUP BY digest_text;"
```

## Rule 009: Blogposts by category
Query Pattern
```sql
SELECT * FROM blogposts 
WHERE pash!=? 
AND pcat=? OR pcat=? 
ORDER BY wkviews DESC, bblid DESC 
LIMIT ?
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    45,
    1,
    '^(?i)SELECT\s+\*\s+FROM\s+blogposts\s+WHERE\s+pash\s*!=\s*\?\s+AND\s+pcat\s*=\s*\?\s+OR\s+pcat\s*=\s*\?\s+ORDER BY\s+wkviews\s+DESC,\s*bblid\s+DESC\s+LIMIT\s*\?\s*$',
    300000,
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
1. Prepare data:
```sh
sudo mysql <<EOF
USE wordpress_test;
ALTER TABLE blogposts ADD COLUMN bblid INT;
UPDATE blogposts SET pcat=5, bblid=1001 WHERE pash=101;
UPDATE blogposts SET pcat=6, bblid=1002 WHERE pash=102;
INSERT INTO blogposts VALUES 
(201, 500, 50, 5, 5, 2001),
(202, 1500, 150, 15, 6, 2002);
EOF
```
2. Run test queries:
```sh
cat <<EOF > rule009.sql
SELECT * FROM blogposts WHERE pash!=0 AND pcat=5 OR pcat=6 ORDER BY wkviews DESC, bblid DESC LIMIT 10;
EOF
```
3. Mysqlslap
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 --port=3306 \
  --concurrency=35 --iterations=150 --query=rule009.sql \
  --create-schema=wordpress_test
```
4. Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%blogposts%' 
  AND digest_text LIKE '%ORDER BY wkviews DESC%';"
```

### Expected Results
Query shows cache_ttl=300000
Hit count = 150

# Rule 010: Latest posts by status and type
Query Pattern
```sql
SELECT post_date_gmt FROM wp6l_posts 
WHERE post_status = ? 
AND post_type IN (?,?,?) 
ORDER BY post_date_gmt DESC 
LIMIT ?
```
Create the proxysql rule
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    50,
    1,
    '^(?i)SELECT\s+post_date_gmt\s+FROM\s+\w+_posts\s+WHERE\s+post_status\s*=\s*\?\s+AND\s+post_type\s+IN\s*\((\s*\?,\s*){2,}\s*\?\)\s+ORDER\s+BY\s+post_date_gmt\s+DESC\s+LIMIT\s*\?\s*$',
    600000,
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
1. Prepare insertdata
```sh
sudo mysql -e "
USE wordpress_test;
-- Create a simplified but complete WordPress posts table with valid defaults
CREATE TABLE IF NOT EXISTS wp7l_posts (
    ID BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,
    post_author BIGINT(20) UNSIGNED NOT NULL DEFAULT 0,
    post_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    post_date_gmt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    post_content LONGTEXT NOT NULL,
    post_title TEXT NOT NULL,
    post_excerpt TEXT NOT NULL,
    post_status VARCHAR(20) NOT NULL DEFAULT 'publish',
    comment_status VARCHAR(20) NOT NULL DEFAULT 'open',
    ping_status VARCHAR(20) NOT NULL DEFAULT 'open',
    post_password VARCHAR(255) NOT NULL DEFAULT '',
    post_name VARCHAR(200) NOT NULL DEFAULT '',
    to_ping TEXT NOT NULL,
    pinged TEXT NOT NULL,
    post_modified DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    post_modified_gmt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    post_content_filtered LONGTEXT NOT NULL,
    post_parent BIGINT(20) UNSIGNED NOT NULL DEFAULT 0,
    guid VARCHAR(255) NOT NULL DEFAULT '',
    menu_order INT(11) NOT NULL DEFAULT 0,
    post_type VARCHAR(20) NOT NULL DEFAULT 'post',
    post_mime_type VARCHAR(100) NOT NULL DEFAULT '',
    comment_count BIGINT(20) NOT NULL DEFAULT 0,
    PRIMARY KEY (ID),
    KEY post_name (post_name(191)),
    KEY type_status_date (post_type,post_status,post_date,ID),
    KEY post_parent (post_parent),
    KEY post_author (post_author)
);
"
```
2. Prepare insert data
```sh
sudo mysql -e "
USE wordpress_test;
INSERT INTO wp7l_posts (
    ID, post_date_gmt, post_status, post_type, post_title, post_content, post_name, post_excerpt, to_ping, pinged, post_content_filtered
) VALUES 
(1, NOW(), 'publish', 'post', 'Test Post 1', 'Content 1', 'test-post-1', '', '', '', ''),
(2, NOW() - INTERVAL 1 DAY, 'publish', 'page', 'Test Page 1', 'Page Content 1', 'test-page-1', '', '', '', ''),
(3, NOW() - INTERVAL 2 DAY, 'draft', 'post', 'Draft Post', 'Draft Content', 'draft-post', '', '', '', ''),
(4, NOW() - INTERVAL 3 DAY, 'publish', 'attachment', 'Image 1', '', 'image-1', '', '', '', ''),
(5, NOW() - INTERVAL 4 DAY, 'publish', 'post', 'Old Post', 'Old Content', 'old-post', '', '', '', ''),
(6, NOW() - INTERVAL 5 DAY, 'publish', 'page', 'About Page', 'About Content', 'about', '', '', '', ''),
(7, NOW() - INTERVAL 6 DAY, 'private', 'post', 'Private Post', 'Private Content', 'private-post', '', '', '', '');
"
```
3. Prepare test data. Create test query file:
```sh
cat <<EOF > rule010.sql
SELECT post_date_gmt FROM wp7l_posts WHERE post_status = 'publish' AND post_type IN ('post','page','attachment') ORDER BY post_date_gmt DESC LIMIT 5;
SELECT ID, post_date_gmt, post_status, post_type, post_title FROM wp7l_posts ORDER BY post_date_gmt DESC;
SELECT post_date_gmt FROM wp7l_posts WHERE post_status = 'publish' AND post_type IN ('post','page','attachment') ORDER BY post_date_gmt DESC LIMIT 5;
EOF
```
4. Execute load test:
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 \
  --concurrency=25 --iterations=100 --query=rule010.sql \
  --create-schema=wordpress_test
```
### Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%post_date_gmt%' 
  AND digest_text LIKE '%post_type IN%';"
```
## Expected Results
cache_ttl = 600000
Hits = 100
Response time improvement in stats

## Rule 011: Blog lookup by UUID
Query Pattern
```sql
select * from `blogs` where `uuid` = ? limit ?
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    55,
    1,
    '^(?i)select \* from `blogs` where `uuid` = \? limit \?\s*$',
    86400000,  -- 24 hours (long TTL for static blog metadata)
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```

## Testing and Validation
1. Prepare test data:
```sh
sudo mysql -e "
USE wordpress_test;
CREATE TABLE IF NOT EXISTS blogs (
    id INT PRIMARY KEY,
    uuid CHAR(36),
    name VARCHAR(255)
);
INSERT INTO blogs VALUES 
(1, UUID(), 'Tech Blog'),
(2, UUID(), 'Travel Blog');
"
```
2. Create test queries:
```sh
cat <<EOF > rule011.sql
SELECT * FROM blogs WHERE uuid = '6ccd780c-baba-1026-9564-5b8c656024db' LIMIT 1;
SELECT * FROM blogs WHERE uuid = '7ddf780c-caca-1026-9564-6c9d767135ec' LIMIT 1;
EOF
```

3. Execute load test:
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 \
  --concurrency=20 --iterations=200 --query=rule011.sql \
  --create-schema=wordpress_test
```

4. Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%blogs%uuid%';"
```
## Expected Results
cache_ttl = 86400000
Hits = 400 (2 queries × 200 iterations)

# Rule 012: Posts lookup by ID
Query Pattern
```sql
SELECT * FROM wpy4_posts WHERE ID = ? LIMIT ?
SELECT * FROM wp0p_posts WHERE ID = ? LIMIT ?
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    140,
    1,
    '^(?i)SELECT \* FROM \w+_posts WHERE ID = \? LIMIT \?\s*$',
    1800000,  -- 30 minutes (shorter TTL for editable content)
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```
## Testing and Validation
1. Prepare test data:
```sh
sudo mysql -e "
USE wordpress_test;
CREATE TABLE IF NOT EXISTS wpy4_posts LIKE wp6l_posts;
CREATE TABLE IF NOT EXISTS wp0p_posts LIKE wp6l_posts;
INSERT INTO wpy4_posts VALUES (101, NOW(), 'publish', 'post');
INSERT INTO wp0p_posts VALUES (201, NOW(), 'draft', 'page');
"
```
2. Create test queries:
```sh
cat <<EOF > rule012.sql
SELECT * FROM wpy4_posts WHERE ID = 101 LIMIT 1;
SELECT * FROM wp0p_posts WHERE ID = 201 LIMIT 1;
EOF
```

3. Execute load test:
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 \
  --concurrency=30 --iterations=150 --query=rule012.sql \
  --create-schema=wordpress_test
```
4. Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%_posts WHERE ID = %';"
```
## Expected Results
cache_ttl = 1800000
Hits = 300 (2 queries × 150 iterations)
Both table patterns matched by single rule

## Complex Queries

## Rule 010: User meta search query
Query Pattern
```sql
SELECT wp0p_users.ID 
FROM wp0p_users 
INNER JOIN wp0p_usermeta 
ON (wp0p_users.ID = wp0p_usermeta.user_id) 
WHERE 1=1 
AND (((wp0p_usermeta.meta_key = ? 
AND wp0p_usermeta.meta_value LIKE ?) 
OR (wp0p_usermeta.meta_key = ? 
AND wp0p_usermeta.meta_value LIKE ?))) 
ORDER BY user_login ASC
```
Rule Creation
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
INSERT INTO mysql_query_rules (
    rule_id,
    active,
    match_digest,
    cache_ttl,
    apply
) VALUES (
    60,
    1,
    '^(?i)SELECT\s+[a-zA-Z0-9_]+\.ID\s+FROM\s+`?[a-zA-Z0-9_]+_users`?\s+INNER JOIN\s+`?[a-zA-Z0-9_]+_usermeta`?\s+ON\s+\([a-zA-Z0-9_]+\.ID\s*=\s*[a-zA-Z0-9_]+\.user_id\)\s+WHERE\s+\d=\d\s+AND\s+\(\(\([a-zA-Z0-9_]+\.meta_key\s*=\s*\?\s+AND\s+[a-zA-Z0-9_]+\.meta_value LIKE \?\)\s+OR\s+\([a-zA-Z0-9_]+\.meta_key\s*=\s*\?\s+AND\s+[a-zA-Z0-9_]+\.meta_value LIKE \?\)\)\)\s+ORDER BY\s+user_login\s+ASC\s*$',
    3600000,
    1
);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```

## Testing and Validation
1. Create tables and data:
```sh
sudo mysql <<EOF
USE wordpress_test;
CREATE TABLE wp0p_users (ID INT PRIMARY KEY, user_login VARCHAR(50));
CREATE TABLE wp0p_usermeta (user_id INT, meta_key VARCHAR(255), meta_value TEXT);
INSERT INTO wp0p_users VALUES (1, 'admin'), (2, 'editor');
INSERT INTO wp0p_usermeta VALUES 
(1, 'first_name', 'John'),
(1, 'last_name', 'Doe'),
(2, 'first_name', 'Jane');
EOF
```
2. Run test queries:
```sh
cat <<EOF > rule006.sql
SELECT wp0p_users.ID 
FROM wp0p_users 
INNER JOIN wp0p_usermeta 
ON (wp0p_users.ID = wp0p_usermeta.user_id) 
WHERE 1=1 
AND (((wp0p_usermeta.meta_key = 'first_name' 
AND wp0p_usermeta.meta_value LIKE '%Joh%') 
OR (wp0p_usermeta.meta_key = 'last_name' 
AND wp0p_usermeta.meta_value LIKE '%Do%'))) 
ORDER BY user_login ASC;
EOF
```
3. Mysqlslap
```sh
mysqlslap --user=stnduser --password=stnduser --host=127.0.0.1 --port=3306 \
  --concurrency=25 --iterations=75 --query=rule006.sql \
  --create-schema=wordpress_test
```
4. Verify caching:
```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT digest_text, cache_ttl, SUM(hits) hits 
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%usermeta%' AND digest_text LIKE '%LIKE%';"
```

## Expected Results
Query shows cache_ttl=3600000
Hit count = 75

# General Validation check commands
Check the query cache stats and results
```sql
SELECT * FROM stats_mysql_global WHERE Variable_Name LIKE  'Query_Cache%';
SELECT * FROM stats_mysql_query_rules;
```
Query_Cache_Memory_bytes --total size of stored result in query cache
Query_Cache_Count_GET -- total number of get requests executed against the Query cache
Query_Cache_count_GET_OK -- total number of succesful get requests against the Query Cache


## Final Verification
Check all rules and cache performance:

```sh
mysql -u admin -padmin -h 127.0.0.1 -P6032 -e "
SELECT rule_id, match_digest, cache_ttl 
FROM mysql_query_rules 
WHERE cache_ttl > 0;
SELECT 
  digest_text,
  cache_ttl,
  SUM(hits) AS hits,
  SUM(rows_sent) AS rows_sent
FROM stats_mysql_query_digest
WHERE digest_text LIKE '%posts%' 
   OR digest_text LIKE '%blog%'
GROUP BY digest_text
ORDER BY hits DESC;"
```
## Expected Outcome
All 5 rules (008,009,010,011,012) active with configured TTLs
High hit counts for all cached queries
Reduced load on backend MySQL servers
Consistent cache_ttl values in query digest stats