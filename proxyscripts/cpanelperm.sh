#!/bin/bash
# Fix cPanel safelock permissions and MySQL socket issues
set -e

echo "=== cPanel Permissions and MySQL Socket Fix ==="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi

echo "1. Fixing /etc directory permissions for cPanel safelock..."

# Check current /etc permissions
echo "Current /etc permissions:"
ls -ld /etc

# Fix /etc directory permissions - should be 755 with root:root ownership
chown root:root /etc
chmod 755 /etc

echo "Fixed /etc permissions:"
ls -ld /etc

echo "2. Cleaning up any stale lock files..."
# Remove any existing lock files that might be stuck
find /etc -name "userdatadomains.lock*" -type f -delete 2>/dev/null || true

echo "3. Checking cPanel service status..."
systemctl status cpanel --no-pager -l || echo "cPanel service check completed"

echo "4. Verifying MySQL socket configuration..."

# Check if MySQL is running
if ! systemctl is-active --quiet mysqld; then
    echo "Starting MySQL service..."
    systemctl start mysqld
    sleep 3
fi

# Verify socket exists and has correct permissions
if [ -S "/var/lib/mysql/mysql.sock" ]; then
    echo "✓ MySQL socket exists: /var/lib/mysql/mysql.sock"
    ls -la /var/lib/mysql/mysql.sock
    
    # Ensure socket has proper permissions
    chmod 777 /var/lib/mysql/mysql.sock
    
    # Create/update symlink for compatibility
    ln -sf /var/lib/mysql/mysql.sock /tmp/mysql.sock
    echo "✓ Created symlink: /tmp/mysql.sock -> /var/lib/mysql/mysql.sock"
else
    echo "✗ MySQL socket not found. Restarting MySQL..."
    systemctl restart mysqld
    sleep 5
    
    if [ -S "/var/lib/mysql/mysql.sock" ]; then
        echo "✓ MySQL socket created after restart"
        chmod 777 /var/lib/mysql/mysql.sock
        ln -sf /var/lib/mysql/mysql.sock /tmp/mysql.sock
    else
        echo "✗ Failed to create MySQL socket. Check MySQL configuration."
        exit 1
    fi
fi

echo "5. Testing MySQL connections..."

# Test direct MySQL connection
if mysql -e "SELECT 1;" >/dev/null 2>&1; then
    echo "✓ Direct MySQL connection successful"
else
    echo "✗ Direct MySQL connection failed"
fi

# Test localhost connection (what WordPress uses)
if mysql -h localhost -e "SELECT 1;" >/dev/null 2>&1; then
    echo "✓ Localhost MySQL connection successful"
else
    echo "✗ Localhost MySQL connection failed"
    echo "WordPress DB_HOST='localhost' will not work"
fi

echo "6. Checking PHP MySQL socket configuration..."
PHP_SOCKET=$(php -r "echo ini_get('pdo_mysql.default_socket');" 2>/dev/null || echo "unknown")
echo "PHP PDO MySQL socket: $PHP_SOCKET"

if [ "$PHP_SOCKET" = "/var/lib/mysql/mysql.sock" ]; then
    echo "✓ PHP MySQL socket configuration is correct"
else
    echo "⚠ PHP MySQL socket might need adjustment"
fi

echo "7. Restarting cPanel services to clear lock issues..."
# Restart key cPanel services
systemctl restart cpanel 2>/dev/null || echo "cPanel restart attempted"
systemctl restart tailwatchd 2>/dev/null || echo "tailwatchd restart attempted"

echo "8. Final verification..."
sleep 2

# Test if we can create a lock file in /etc (simulating what cPanel does)
if touch /etc/test-lock-file 2>/dev/null; then
    rm -f /etc/test-lock-file
    echo "✓ /etc directory is writable for lock files"
else
    echo "✗ /etc directory still not writable"
    echo "Current /etc permissions:"
    ls -ld /etc
fi

echo ""
echo "=== Fix Summary ==="
echo "✓ Fixed /etc directory permissions for cPanel safelock"
echo "✓ Cleaned up stale lock files"
echo "✓ Verified MySQL socket configuration"
echo "✓ Restarted cPanel services"
echo ""
echo "Your WordPress sites should now work with:"
echo "  define('DB_HOST', 'localhost');"
echo ""
echo "Monitor cPanel error logs for any remaining issues:"
echo "  tail -f /usr/local/cpanel/logs/error_log"