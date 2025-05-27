#!/bin/bash
# Remove proxysql  setup
# This script removes the ProxySQL setup and reverts to the original MySQL configuration.
# It stops ProxySQL, removes the configuration files, and reverts MySQL to its original state.
set -e
echo "Removing ProxySQL setup and files..."
# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi

# Revert MySQL configuration
echo "Reverting MySQL configuration..."
sudo chmod +x revert.sh
sudo ./revert.sh

#REMOVE cPanel hook
echo "Removing cPanel hook..."
sudo chmod +x del_hook.sh
sudo ./del_hook.sh

# Check if ProxySQL is running
if systemctl is-active --quiet proxysql; then
    echo "Stopping ProxySQL..."
    sudo systemctl stop proxysql
fi

# Remove ProxySQL service
echo "Removing ProxySQL service..."
sudo systemctl disable proxysql
sudo rm -f /etc/systemd/system/proxysql.service
sudo systemctl daemon-reload

# Uninstall ProxySQL
echo "Uninstalling ProxySQL..."
sudo yum remove -y proxysql

# Remove ProxySQL configuration files
echo "Removing ProxySQL configuration files..."
sudo rm -rf /var/lib/proxysql
sudo rm -rf /var/log/proxysql

echo "ProxySQL setup removed successfully."