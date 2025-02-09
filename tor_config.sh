#!/bin/bash
# tor_config.sh
# This script configures /etc/tor/torrc for enhanced Tor usage.
# It backs up the original file, sets:
#   - SocksPort 9050
#   - ControlPort 9051
#   - HashedControlPassword (generated from a user-supplied password)
#   - Optionally, transparent proxy settings (TransPort, DNSPort, AutomapHostsOnResolve)
#
# Usage:
#   sudo ./tor_config.sh         # Apply changes
#   sudo ./tor_config.sh undo    # Restore the most recent backup

TORRC="/etc/tor/torrc"
BACKUP="/etc/tor/torrc.bak_$(date +%Y%m%d_%H%M%S)"

# Function to ensure the script is run as root
function check_root {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (e.g. using sudo)."
        exit 1
    fi
}

# Function to back up the torrc file
function backup_torrc {
    echo "Creating backup of $TORRC at $BACKUP"
    cp "$TORRC" "$BACKUP"
}

# Function to restore the most recent backup
function restore_backup {
    LATEST_BACKUP=$(ls -t /etc/tor/torrc.bak_* 2>/dev/null | head -n 1)
    if [ -z "$LATEST_BACKUP" ]; then
        echo "No backup file found in /etc/tor/"
        exit 1
    fi
    echo "Restoring backup from $LATEST_BACKUP to $TORRC"
    cp "$LATEST_BACKUP" "$TORRC"
    echo "Restoration complete."
}

# Function to uncomment lines that start with a given pattern
function ensure_uncomment {
    # $1: Pattern (e.g., SocksPort)
    if grep -qE "^\s*#\s*$1" "$TORRC"; then
        sed -i "s/^\s*#\s*\($1.*\)/\1/" "$TORRC"
        echo "Uncommented line for: $1"
    fi
}

# Function to ensure a specific line exists in torrc (append if missing)
function ensure_line {
    # $1: Exact line to ensure exists
    if ! grep -Fxq "$1" "$TORRC"; then
        echo "$1" >> "$TORRC"
        echo "Added line: $1"
    else
        echo "Line already exists: $1"
    fi
}

# Main script

check_root

# If "undo" is passed as an argument, restore the backup and exit.
if [ "$1" == "undo" ]; then
    restore_backup
    exit 0
fi

echo "This script will modify $TORRC to configure Tor."
echo "A backup will be created first."

read -p "Proceed? (y/N): " proceed
if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

backup_torrc

# --- Configure basic Tor settings ---

# 1. Configure SocksPort 9050
ensure_uncomment "SocksPort"
ensure_line "SocksPort 9050"

# 2. Configure ControlPort 9051
ensure_uncomment "ControlPort"
ensure_line "ControlPort 9051"

# 3. Configure HashedControlPassword
# Remove any existing HashedControlPassword lines first:
sed -i '/^HashedControlPassword/d' "$TORRC"

echo "Enter the desired control password. This script will generate a hashed version."
read -sp "Control Password: " ctrl_pass
echo
# Generate the hashed password using Tor's built-in function.
hashed=$(tor --hash-password "$ctrl_pass" | tail -n 1)
if [ -z "$hashed" ]; then
    echo "Error: Could not generate hashed password. Ensure Tor is installed."
    exit 1
fi
ensure_line "HashedControlPassword $hashed"

# --- Optional: Transparent Proxy Settings ---
read -p "Enable Transparent Proxy settings? (TransPort 9040, DNSPort 53, AutomapHostsOnResolve 1) (y/N): " enable_trans
if [[ "$enable_trans" =~ ^[Yy]$ ]]; then
    ensure_uncomment "TransPort"
    ensure_line "TransPort 9040"
    ensure_uncomment "DNSPort"
    ensure_line "DNSPort 53"
    ensure_uncomment "AutomapHostsOnResolve"
    ensure_line "AutomapHostsOnResolve 1"
fi

echo "Tor configuration changes have been applied to $TORRC."
echo "A backup of the original file is stored at: $BACKUP"
echo "Restart Tor with: sudo systemctl restart tor"

