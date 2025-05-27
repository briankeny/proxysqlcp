#!/bin/bash
# Proxysql Configuration
# This script configures ProxySQL to use MySQL as the backend database.
# It sets up the necessary configurations and ensures that ProxySQL is running.
set -e

echo "Starting ProxySQL configuration..."
# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi

echo "Checking if ProxySQL is installed..."
# Check if ProxySQL is installed
if ! command -v proxysql &> /dev/null
then
    echo "ProxySQL could not be found. Please install it first."
    PROXY_installed=0
else
    PROXY_installed=1
fi

# Check if ProxySQL is installed
if ! command -v proxysql >/dev/null 2>&1; then
    echo "ProxySQL is not installed. Installing..."
    # Write the repo file cleanly (no leading whitespace!)
    sudo tee /etc/yum.repos.d/proxysql.repo > /dev/null <<EOF
[proxysql_repo]
name=ProxySQL repository
baseurl=https://repo.proxysql.com/ProxySQL/proxysql-2.7.x/almalinux/\$releasever
gpgcheck=1
gpgkey=https://repo.proxysql.com/ProxySQL/proxysql-2.7.x/repo_pub_key
EOF
    # Install ProxySQL
    sudo yum install -y proxysql
else
    echo "ProxySQL is already installed."
fi


# Check if ProxySQL is running
if ! systemctl is-active --quiet proxysql; then
    echo "ProxySQL is not running. Starting ProxySQL..."
    sudo systemctl start proxysql
fi

# Check if ProxySQL is enabled to start on boot
if ! systemctl is-enabled --quiet proxysql; then
    echo "ProxySQL is not enabled to start on boot. Enabling ProxySQL..."
    sudo systemctl enable proxysql
fi

echo "Extracting MySQL credentials from /root/.my.cnf..."
# Read user and password from .my.cnf
MYSQL_USER=$(sudo grep -i '^user' /root/.my.cnf | awk -F= '{gsub(/ /,"",$2); print $2}')
MYSQL_PASSWORD=$(sudo grep -i '^password' /root/.my.cnf | awk -F= '{gsub(/"/,"",$2); gsub(/ /,"",$2); print $2}')

# Optional: Validate values were extracted
if [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ]; then
    echo "Failed to extract MySQL credentials from /root/.my.cnf"
    exit 1
fi

# Create MySQL users for ProxySQL
echo "Creating MySQL users for ProxySQL..."
mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -h 127.0.0.1 -P3306 <<EOF
-- Create 'monitor' user if it doesn't exist
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'monitor'@'%';
FLUSH PRIVILEGES;
-- Create 'stnduser' user if it doesn't exist
CREATE USER IF NOT EXISTS 'stnduser'@'%' IDENTIFIED BY 'stnduser';
GRANT ALL PRIVILEGES ON *.* TO 'stnduser'@'%';
FLUSH PRIVILEGES;
EOF


# Load mysql users to proxysql
echo "Loading MySQL users to ProxySQL..."
sudo chmod +x sync.sh
sudo ./sync.sh
# Check if sync.sh executed successfully
if [ $? -ne 0 ]; then
    echo "Error: sync.sh failed to execute."
    exit 1
fi

# Configure mysql my.cnf
MY_CNF="/etc/my.cnf"
SOCKET_VAL="/var/lib/mysql/mysql2.sock"
PORT_VAL="3307"
BIND_VAL="127.0.0.1"

echo "Configuring MySQL in $MY_CNF..."
# Ensure [mysqld] section exists
if ! grep -q "^\[mysqld\]" "$MY_CNF"; then
    echo "Adding [mysqld] section..."
    echo -e "\n[mysqld]" | sudo tee -a "$MY_CNF"
fi

# Function to replace or append a setting in [mysqld]
update_or_append() {
    local key="$1"
    local value="$2"
    if grep -q "^\s*$key\s*=" "$MY_CNF"; then
        echo "Updating $key..."
        sudo sed -i "s|^\s*$key\s*=.*|$key=$value|" "$MY_CNF"
    else
        echo "Adding $key..."
        # Append below [mysqld] section
        sudo awk -v key="$key" -v val="$value" '
            BEGIN {added=0}
            /^\[mysqld\]/ {
                print
                print key"="val
                added=1
                next
            }
            {print}
            END {
                if (!added) print key"="val
            }
        ' "$MY_CNF" | sudo tee "$MY_CNF.tmp" > /dev/null && sudo mv "$MY_CNF.tmp" "$MY_CNF"
    fi
}

# Update or append each setting
update_or_append "socket" "$SOCKET_VAL"
update_or_append "port" "$PORT_VAL"
update_or_append "bind-address" "$BIND_VAL"
echo "MySQL configuration updated."

# Restart mysql
echo "Restarting MySQL..."
sudo systemctl daemon-reload
sudo systemctl restart mysql

# Configure cpanel hook
echo "Configuring cPanel hook..."
chmod +x add_hook.sh
sudo ./add_hook.sh
# Check if add_hook.sh executed successfully
if [ $? -ne 0 ]; then
    echo "Error: add_hook.sh failed to execute."
    exit 1
fi

# Configure proxysql to use socket and port 3306
echo "Configuring ProxySQL to use socket & port 3306..."
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
SET mysql-interfaces='127.0.0.1:3306;/tmp/proxysql.sock';
SAVE MYSQL VARIABLES TO DISK;
EOF

# Restart proxysql
echo "Restarting ProxySQL..."
sudo systemctl restart proxysql

# Check if ProxySQL is running
if ! systemctl is-active --quiet proxysql; then
    echo "ProxySQL is not running. Please check the logs for more information."
    exit 1
fi

sleep 2 
echo "2 seconds delay..."

# Check mysql version
echo "Checking MySQL version..."
MYSQL_VERSION=$(mysql -h127.0.0.1 -P3306 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -Nse "SELECT VERSION();" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')

# Configure proxy ADMIN settings
echo "Configuring ProxySQL ADMIN settings..."
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
-- Set the MySQL server hostgroup
-- This is the group of MySQL servers that ProxySQL will use
INSERT INTO mysql_servers(hostgroup_id,hostname,port) VALUES (1,'127.0.0.1',3307);
INSERT INTO mysql_servers(hostgroup_id,hostname,port) VALUES (2,'127.0.0.1',3307);
LOAD MYSQL SERVERS TO RUNTIME; 
SAVE MYSQL SERVERS  TO DISK;
SET mysql-server_version = '$MYSQL_VERSION';
UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_password';
UPDATE global_variables SET variable_value='2000' WHERE variable_name IN ('mysql-monitor_connect_interval','mysql-monitor_ping_interval','mysql-monitor_read_only_interval');
-- Disable Monitoring
UPDATE global_variables SET variable_value='false' WHERE variable_name='mysql-monitor_enabled';
INSERT INTO mysql_replication_hostgroups (writer_hostgroup,reader_hostgroup,comment) VALUES (1,2,'cluster1');
-- Apply mysql variables
LOAD MYSQL VARIABLES TO RUNTIME; 
SAVE MYSQL VARIABLES TO DISK;
LOAD MYSQL SERVERS TO RUNTIME; 
SAVE MYSQL SERVERS TO DISK;
EOF

# Switch the unix socket
echo "Switching the unix socket..."
sudo rm -f /var/lib/mysql/mysql.sock
sudo touch /var/lib/mysql/mysql.sock
sudo ln -sf /tmp/proxysql.sock /var/lib/mysql/mysql.sock

# Load Caching Rules To ProxySQL
echo "Loading Caching Rules to ProxySQL..."
# Caching
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
SET mysql-have_ssl = 0;
-- Load the caching rules
-- Configure settings
--SSL & Security mysql-have_ssl :Disabled SSL to reduced overhead:
--Improves resilience to backend failures  mysql-connect_timeout_server Default: 10,000 ms
SET mysql-connect_timeout_server = 2000; -- 2 second
-- multiplexing
SET mysql-multiplexing = 1;
-- Optimize connection
SET mysql-max_transaction_time = 2000;
-- Cache ttl
SET mysql-query_cache_ttl=60000;
-- Default Cache Size 128 MB
SET mysql-query_cache_size_MB = 500;
-- Enable storing empty results
SET mysql-query_cache_stores_empty_result=1;
-- Adjust max connections
SET mysql-max_connections = 2048;
-- mysql-poll_timeout: Default: 1000 µs, Lower timeout for faster I/O polling: Helps in high-load scenarios 
SET mysql-poll_timeout = 500; -- Microseconds
-- Adjusted based on CPU cores
SET mysql-threads = 4;
-- Configure connection free timeout to free up idle connections
SET mysql-free_connections_pct = 90;
-- Disable group monitoring
SET mysql-monitor_enabled = 0;
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
EOF

# Check if the caching rules were loaded successfully
if [ $? -ne 0 ]; then
    echo "Error: Failed to load caching rules to ProxySQL."
    exit 1
fi

# # Disable Root Password Whm
# echo "Disabling root password for WHM MySQL..."
# # Backup the original file
# sudo cp /root/.my.cnf /root/.my.cnf.bak
# # Comment out the password line (only if it's not already commented)
# sudo sed -i '/^\s*password\s*=/s/^/#/' /root/.my.cnf

# Sync users
sudo ./sync.sh
echo "ReSyncing users..."
# Check if sync.sh executed successfully
if [ $? -ne 0 ]; then
    echo "Error: sync.sh failed to execute."
    exit 1
fi

# Check if the script executed successfully
if [ $? -eq 0 ]; then
    echo "ProxySQL configuration completed successfully."
else
    echo "Error: ProxySQL configuration failed."
    exit 1
fi