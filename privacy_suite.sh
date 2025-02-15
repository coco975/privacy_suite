#!/bin/bash
# Ultimate Privacy Suite v5.0
# Complete Anonymous Computing Environment
# License: AGPL-3.0

set -eo pipefail
shopt -s inherit_errexit nullglob

# Configuration
readonly TOR_CONFIG="/etc/tor/torrc"
readonly PROXYCHAINS_CONFIG="/etc/proxychains4.conf"
readonly BACKUP_DIR="/var/lib/privacy-suite/backups"
readonly LOG_FILE="/var/log/privacy-suite.log"
readonly FIREJAIL_PROFILES="$HOME/.config/firejail"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly REQUIRED_PKGS=(tor proxychains4 firejail wireguard tcpdump wireshark)
readonly REQUIRED_PKGS=(tor proxychains4 wireguard tcpdump wireshark git build-essential)

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

# Error Handler
error_handler() {
    local lineno=$1
    local msg=$2
    log "${RED}Error on line $lineno: $msg${NC}"
    log "${YELLOW}Attempting rollback...${NC}"
    restore_backup
    exit 1
}

trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

# Backup System
backup_system() {
    log "Creating system backup..."
    local backup_path="$BACKUP_DIR/$TIMESTAMP"
    mkdir -p "$backup_path"
    
    cp --parents "$TOR_CONFIG" "$PROXYCHAINS_CONFIG" "$backup_path"
    dpkg --get-selections > "$backup_path/pkg-list.txt"
    log "Backup created: ${backup_path}"
}

restore_backup() {
    local latest=$(ls -td "$BACKUP_DIR"/*/ | head -1)
    log "Restoring from ${latest}..."
    rsync -av "$latest/" /
    dpkg --clear-selections
    dpkg --set-selections < "$latest/pkg-list.txt"
    apt-get dselect-upgrade -y
    systemctl daemon-reload
}

# VPN Configuration
configure_vpn() {
    log "${GREEN}VPN Setup${NC}"
    local vpn_file=""
    
    while true; do
        read -p "Enter path to WireGuard config: " vpn_file
        if [[ -f "$vpn_file" && "$vpn_file" =~ \.conf$ ]]; then
            break
        fi
        log "${RED}Invalid config. Must be .conf file${NC}"
    done

    local config_name=$(basename "$vpn_file")
    cp "$vpn_file" "/etc/wireguard/"
    systemctl enable "wg-quick@${config_name%.*}"
    systemctl start "wg-quick@${config_name%.*}"
    
    # VPN Killswitch
    iptables -A OUTPUT -o "$(ip link show | awk -F': ' '/^[0-9]+: wg/ {print $2}')" -j ACCEPT
    iptables -A OUTPUT -j DROP
}

# Tor Network Setup
configure_tor() {
    log "${GREEN}Configuring Tor${NC}"
    cat > "$TOR_CONFIG" <<EOF
SocksPort 9050
ControlPort 9051
TransPort 9040
DNSPort 5353
AvoidDiskWrites 1
HardwareAccel 1
EOF

    if [[ "$ADD_BRIDGES" == "y" ]]; then
        log "Adding Tor bridges..."
        cat >> "$TOR_CONFIG" <<EOF
UseBridges 1
Bridge obfs4 193.11.166.194:27015 2B280B23E1107BB62ABFC40DDCC8824814F80A72
Bridge obfs4 109.105.109.162:10527 D9B3ECEE9C1C7B857C9A4C44E8A39173A6B9A1A5
EOF
    fi
    systemctl restart tor@default
}

# Proxychains Setup
configure_proxychains() {
    log "${GREEN}Configuring Proxychains${NC}"
    sed -i '/^strict_chain\|^random_chain/d' "$PROXYCHAINS_CONFIG"
    echo "dynamic_chain" >> "$PROXYCHAINS_CONFIG"
    echo "proxy_dns" >> "$PROXYCHAINS_CONFIG"
    sed -i '/^socks4\|^socks5/d' "$PROXYCHAINS_CONFIG"
    echo "socks5 127.0.0.1 9050" >> "$PROXYCHAINS_CONFIG"
}

# Firejail Sandboxing
create_sandbox_profile() {
    local app=$1
    log "Creating sandbox profile for ${app}..."
    mkdir -p "$FIREJAIL_PROFILES"
    cat > "$FIREJAIL_PROFILES/${app}.profile" <<EOF
include /etc/firejail/${app}.profile

noblacklist ~/.config
netfilter
noexec=~/Downloads
seccomp
caps.drop all
private-dev
private-tmp
EOF
}

# Validation System
validate_network() {
    log "${GREEN}Starting Network Validation${NC}"
    local capture_file="/tmp/leaktest_${TIMESTAMP}.pcap"
    local report_file="/tmp/leakreport_${TIMESTAMP}.txt"

    log "Capturing network traffic for 300 seconds..."
    timeout 300 tcpdump -ni any -w "$capture_file" &
    
    log "Testing Tor connectivity..."
    if ! torsocks curl -s https://check.torproject.org | grep -q "Congratulations"; then
        log "${RED}Tor Connection Failed!${NC}"
        return 1
    fi

    log "Testing Proxychains..."
    if ! proxychains curl -s https://ifconfig.me >/dev/null; then
        log "${RED}Proxychains Failure!${NC}"
        return 1
    fi

    log "Analyzing traffic..."
    tshark -r "$capture_file" -Y "tcp.port != 9050" > "$report_file"
    log "Validation Report: ${YELLOW}${report_file}${NC}"
}

# Main Installation
main() {
    log "${GREEN}Starting Privacy Suite Installation${NC}"
    backup_system

    # ===== 1. Install Build Dependencies First =====
    log "Installing build essentials..."
    apt update && apt install -y git build-essential

    # ===== 2. Install Firejail from Source =====
    if ! command -v firejail &>/dev/null; then
        log "${YELLOW}Installing Firejail from source...${NC}"
        temp_dir=$(mktemp -d)
        git clone https://github.com/netblue30/firejail.git "$temp_dir"
        pushd "$temp_dir" >/dev/null
        ./configure
        make
        sudo make install-strip
        popd >/dev/null
        rm -rf "$temp_dir"
        
        # Verify installation
        if ! command -v firejail &>/dev/null; then
            log "${RED}Firejail installation failed!${NC}"
            exit 1
        fi
        log "${GREEN}Firejail installed successfully${NC}"
    fi

    # ===== 3. Install Remaining Packages =====
    log "Installing system packages..."
    apt install -y "${REQUIRED_PKGS[@]}"

    # ... [rest of the original main function] ...
}
# Execution
if [[ $EUID -ne 0 ]]; then
    log "${RED}Run as root: sudo $0${NC}"
    exit 1
fi

main "$@"
