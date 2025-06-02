#!/bin/bash
set -e
echo "User Sync started..."
# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi
echo "Starting full user synchronization"
echo "Adding root to proxysql using .my.cnf"
# Extract user 
MYSQL_USER=$(sudo sed -n 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' /root/.my.cnf)
MYSQL_PASSWORD=$(sudo sed -n 's/^[[:space:]]*password[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' /root/.my.cnf)
set +e
# Add root to proxysql
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF >/dev/null 2>&1
INSERT INTO mysql_users(username,password,default_hostgroup) VALUES ('$MYSQL_USER','$MYSQL_PASSWORD',1);
SAVE MYSQL USERS TO DISK;
LOAD MYSQL USERS TO RUNTIME;
EOF
echo "Root is now on proxysql"
set -e
# Get all MySQL users with their default schema
USERS_QUERY="SELECT u.user, u.host, u.authentication_string, 
            IF(u.plugin='mysql_native_password',1,0) as active,
            MAX(IF(d.Select_priv = 'Y', 1, 0)) as use_ssl,
            MIN(d.Db) as default_schema
            FROM mysql.user u
            LEFT JOIN mysql.db d ON u.user = d.user AND u.host = d.host
            WHERE u.user != '' AND u.user NOT IN ('root', 'mysql.sys', 'mysql.session')
            GROUP BY u.user, u.host;"
# Temporary file to store user data
USERS_FILE=$(mktemp)
echo "Retrieving users from MySQL..."
# Get users from MySQL and save to temp file
sudo mysql -ANe "$USERS_QUERY" > "$USERS_FILE"
if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve users from MySQL"
    rm -f "$USERS_FILE"
    exit 1
fi
echo "Users retrieved from MySQL and saved to $USERS_FILE"
echo "Saving mysql users to proxysql..."
# Add users from temp file to ProxySQL
while IFS=$'\t' read -r user host password active use_ssl default_schema; do
    # Default to hostgroup 1
    default_hostgroup=1
    host=${host:-"%"}
    user=${user:-"stnduser"}
    password=${password:-""}
    active=${active:-1}
    use_ssl=0
    ssl_en=${use_ssl:-0}
    default_schema=${default_schema:-"NULL"} # Use NULL if no schema is found
    if [[ "$default_schema" != "NULL" ]]; then
        default_schema=${default_schema//\\}
    fi
    # Insert user into ProxySQL
    INSERT_QUERY="INSERT INTO mysql_users (username, password, active, default_hostgroup, default_schema, schema_locked, transaction_persistent, fast_forward, backend, frontend, max_connections, use_ssl) VALUES ('$user', '$password', $active, $default_hostgroup, '$default_schema', 0, 0, 0, 1, 1, 1000, $use_ssl)"
    # Execute the insert query
    mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' -e "$INSERT_QUERY" 2>/dev/null || true
    # Successfully continue the loop regardless of command success/failure
    echo "Processed user $user@$host in ProxySQL"
done < "$USERS_FILE"
echo "Saving mysql users to disk and runtime..."
# Apply changes to runtime and save to disk
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF 
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
EOF
# Clean up
rm -f "$USERS_FILE"
echo "Full user synchronization completed"