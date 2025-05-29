#!/bin/bash
set -e
echo "Starting cpanel hook script..."
# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi
echo "Removing cpanel hook..."
# Removing the hook
sudo /usr/local/cpanel/bin/manage_hooks delete module Cpanel::ProxyRestoreHook
echo "Cpanel hook removal complete..."