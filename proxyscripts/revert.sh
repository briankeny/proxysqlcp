#!/bin/bash
# Revert to Mysql Configuration
set +e
echo "Starting Revert configuration..."
# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi
#Switch Port
echo "Configuring ProxySQL client on Admin to use default socket 6032..."
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt='Admin> ' <<EOF
SET mysql-interfaces='127.0.0.1:6033;/tmp/proxysql.sock';
SAVE MYSQL VARIABLES TO DISK;
EOF
# Remove default ACL from the directory
sudo setfacl -d -x u:proxysql /var/lib/mysql
# Remove proxysql ownership from the directory
sudo gpasswd -d proxysql mysql
# Restart Proxysql
echo "Restarting Proxysql..."
sudo systemctl restart proxysql.service
# mysql
echo "Configuring my.cnf to use default port 3306..."
sudo sed -i 's/port=3307/port=3306/g' /etc/my.cnf
sudo sed -i 's/socket=\/var\/lib\/mysql\/mysql2.sock/socket=\/var\/lib\/mysql\/mysql.sock/g' /etc/my.cnf
# Remove the old socket mysql will create a new one
echo "Removing the old mysql unix socket..."
sudo rm -f /var/lib/mysql/mysql.sock
sudo rm -f /var/lib/mysql/mysql2.sock
# Revert ownership and permissions
sudo chown mysql:mysql /var/lib/mysql
sudo chmod 755 /var/lib/mysql
# Restart mysql
echo "Restarting mysql ..."
sudo systemctl daemon-reload
sudo systemctl restart mysqld.service
# Wait for MySQL to fully start
echo "Waiting for MySQL to start..."
sleep 4
# Check if MySQL socket was created
if [ -S "/var/lib/mysql/mysql.sock" ]; then
    echo "MySQL socket created successfully at /var/lib/mysql/mysql.sock"  
    # Set proper permissions on the socket
    sudo chmod 777 /var/lib/mysql/mysql.sock
else
    echo "ERROR: MySQL socket was not created!"
    exit 1
fi
echo "Revert Successful!"