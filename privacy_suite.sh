#!/bin/bash
# Ultimate Privacy Suite v5.4
# Fixed Tor, VPN, and Dependency Handling
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
readonly REQUIRED_PKGS=(tor proxychains4 wireguard tcpdump wireshark git resolvconf)

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
    [[ -z "$latest" ]] && log "${RED}No backups available!${NC}" && exit 1
    log "Restoring from ${latest}..."
    rsync -av "$latest/" /
    dpkg --clear-selections
    dpkg --set-selections < "$latest/pkg-list.txt"
    apt-get dselect-upgrade -y
    systemctl daemon-reload
}

# VPN Configuration
validate_vpn_config() {
    local config_file="$1"
    [[ ! -s "$config_file" ]] && log "${RED}Empty/missing VPN config!${NC}" && exit 1
    
    if ! grep -q "^\[Interface\]" "$config_file" || \
       ! grep -q "^PrivateKey" "$config_file" || \
       ! grep -q "^\[Peer\]" "$config_file" || \
       ! grep -q "^PublicKey" "$config_file"; then
        log "${RED}Invalid WireGuard config!${NC}"
        exit 1
    fi
}

configure_vpn() {
    log "${GREEN}VPN Setup${NC}"
    local vpn_file=""
    
    while true; do
        read -p "Enter path to WireGuard config: " vpn_file
        [[ -f "$vpn_file" && "$vpn_file" =~ \.conf$ ]] && validate_vpn_config "$vpn_file" && break
        log "${RED}Invalid config! Must be .conf file${NC}"
    done

    sudo rm -f /etc/wireguard/wg*
    local config_name=$(basename "$vpn_file")
    sudo cp "$vpn_file" "/etc/wireguard/$config_name"
    sudo chmod 600 "/etc/wireguard/$config_name"
    
    local interface_name=$(basename "$config_name" .conf)
    sudo wg-quick up "/etc/wireguard/$config_name" || {
        log "${RED}VPN connection failed!${NC}"; exit 1
    }

    echo "nameserver 10.2.0.1" | sudo tee /etc/resolv.conf
    sudo chattr +i /etc/resolv.conf
    
    sudo nft flush ruleset
    sudo nft add table ip killswitch
    sudo nft add chain ip killswitch output { type filter hook output priority 0 \; }
    sudo nft add rule ip killswitch output meta skuid != 0 drop
    sudo nft add rule ip killswitch output oifname != "$interface_name" drop
    
    log "${GREEN}VPN active on $interface_name${NC}"
}

# Tor Configuration
configure_tor() {
    log "${GREEN}Tor Bridge Setup${NC}"
    sudo systemctl stop tor
    
    if [[ "$ADD_BRIDGES" =~ ^[Yy] ]]; then
        while true; do
            read -p "Enter Tor bridge line: " bridge_line
            [[ "$bridge_line" =~ ^obfs4.+cert=.+ ]] && break
            log "${RED}Invalid bridge format! Example: obfs4 1.2.3.4:1234 cert=...${NC}"
        done
        echo "Bridge $bridge_line" | sudo tee -a /etc/tor/torrc
    fi
    
    echo "UseBridges 1" | sudo tee -a /etc/tor/torrc
    echo "ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy" | sudo tee -a /etc/tor/torrc
    sudo systemctl start tor
    log "${GREEN}Tor configured successfully${NC}"
}

# Proxychains Setup
configure_proxychains() {
    log "${GREEN}Configuring Proxychains${NC}"
    sudo sed -i '/^strict_chain\|^random_chain\|^dynamic_chain\|^proxy_dns/d' "$PROXYCHAINS_CONFIG"
    echo "random_chain" | sudo tee -a "$PROXYCHAINS_CONFIG"
    echo "[ProxyList]" | sudo tee -a "$PROXYCHAINS_CONFIG"
    echo "socks5 127.0.0.1 9050" | sudo tee -a "$PROXYCHAINS_CONFIG"
    sudo sed -i 's/^#proxy_dns/proxy_dns/' "$PROXYCHAINS_CONFIG"
}

# Main Installation
main() {
    log "${GREEN}Starting Installation${NC}"
    backup_system

    # Clean system state
    sudo apt autoremove -y firebird3.0-common libcapstone4 libgdal35 libhdf5-103-1t64
    
    log "Installing packages..."
    sudo apt update && sudo apt install -y "${REQUIRED_PKGS[@]}"
    
    read -p "Configure VPN? [y/N]: " vpn_choice
    [[ "$vpn_choice" =~ ^[Yy] ]] && configure_vpn
    
    read -p "Add Tor Bridges? [y/N]: " ADD_BRIDGES
    configure_tor
    configure_proxychains

    log "${GREEN}Installation Complete!${NC}"
    log "${YELLOW}Reboot recommended for full isolation${NC}"
}

# Execution
[[ $EUID -ne 0 ]] && log "${RED}Run as root: sudo $0${NC}" && exit 1
main "$@"
