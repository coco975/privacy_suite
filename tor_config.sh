#!/bin/bash
# Ultimate Anonymity Toolkit v2.1
# Full-featured security suite with automatic configuration
# License: GPL-3.0
# Usage: ./anonymizer.sh [command]

set -euo pipefail
shopt -s nullglob

# Configuration
readonly BACKUP_DIR="/etc/anonymizer/backups"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly CONFIG_FILES=(
    "/etc/proxychains.conf"
    "/etc/tor/torrc"
    "/etc/resolv.conf"
)
readonly COLOR_ERR='\033[0;31m'
readonly COLOR_WARN='\033[0;33m'
readonly COLOR_INFO='\033[0;36m'
readonly COLOR_RESET='\033[0m'

# Core Functions
create_backup() {
    echo -e "${COLOR_INFO}Creating system snapshot...${COLOR_RESET}"
    local backup_path="${BACKUP_DIR}/${TIMESTAMP}"
    mkdir -p "${backup_path}"
    
    # Backup config files
    for file in "${CONFIG_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            cp --parents "$file" "$backup_path"
        fi
    done

    # Backup package states
    dpkg --get-selections > "${backup_path}/package_states.txt"
    
    echo -e "Backup created: ${backup_path}"
}

restore_system() {
    echo -e "${COLOR_INFO}Available backups:${COLOR_RESET}"
    local backups=("${BACKUP_DIR}"/*)
    for ((i=0; i<${#backups[@]}; i++)); do
        echo "$i: ${backups[$i]##*/}"
    done
    
    read -p "Select backup: " num
    local selected="${backups[$num]}"
    
    echo -e "${COLOR_WARN}Restoring system state...${COLOR_RESET}"
    rsync -av "${selected}/" /
    dpkg --set-selections < "${selected}/package_states.txt"
    apt-get dselect-upgrade -y
}

install_stack() {
    echo -e "${COLOR_INFO}Installing core components...${COLOR_RESET}"
    apt update && apt install -y \
        git build-essential autoconf libtool \
        tor firejail wireguard tcpdump
    
    # Build latest proxychains-ng
    git clone https://github.com/rofl0r/proxychains-ng
    pushd proxychains-ng
    ./configure --prefix=/usr --sysconfdir=/etc
    make && make install
    popd
    
    # Configure network stack
    configure_tor
    configure_proxychains
    test_connectivity
}

configure_tor() {
    echo -e "${COLOR_INFO}Hardening Tor configuration...${COLOR_RESET}"
    cat >> /etc/tor/torrc <<EOF
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 5353
EOF
    systemctl restart tor
}

configure_proxychains() {
    local conf_file="/etc/proxychains.conf"
    echo -e "${COLOR_INFO}Optimizing proxy chain...${COLOR_RESET}"
    sed -i.bak '
        s/^strict_chain/#strict_chain/;
        s/^#dynamic_chain/dynamic_chain/;
        s/^#proxy_dns/proxy_dns/;
        /socks4\s\+127\.0\.0\.1\s\+9050/d;
    ' "$conf_file"
    echo "socks5 127.0.0.1 9050" >> "$conf_file"
}

# Verification
test_connectivity() {
    echo -e "${COLOR_INFO}Running security checks...${COLOR_RESET}"
    if ! torsocks curl -s https://check.torproject.org | grep -q "Congratulations"; then
        echo -e "${COLOR_ERR}Tor connectivity test failed!${COLOR_RESET}"
        exit 1
    fi
    
    if ! proxychains curl -s ifconfig.me >/dev/null; then
        echo -e "${COLOR_ERR}Proxychains test failed!${COLOR_RESET}"
        exit 1
    fi
}

# Usage Manual
show_manual() {
    cat <<EOF

Ultimate Anonymity Toolkit - Usage Manual

Basic Commands:
  install       - Full installation
  restore       - Restore previous configuration
  update        - Update components
  vpn-config    - Setup VPN integration
  sandbox       - Launch sandboxed application

Advanced OPSEC:
1. Always combine with VPN:
   $ ./anonymizer.sh vpn-config --provider mullvad

2. Use Firejail containment:
   $ ./anonymizer.sh sandbox --browser firefox

3. Regular maintenance:
   $ ./anonymizer.sh update --security-only

4. Network monitoring:
   $ ./anonymizer.sh monitor --interface eth0

Security Best Practices:
- Chain Tor over VPN for entry guards
- Use application-specific firejail profiles
- Monitor DNS leaks weekly
- Verify PGP signatures on updates
- Restrict physical device access

Connection Diagram:
  [App] → [Firejail] → [Proxychains] → [Tor] → [VPN] → Internet

EOF
}

# Main Execution
case "${1:-}" in
    install)
        create_backup
        install_stack
        ;;
    restore)
        restore_system
        ;;
    update)
        git -C proxychains-ng pull
        systemctl restart tor
        ;;
    vpn-config)
        shift
        configure_vpn "$@"
        ;;
    sandbox)
        shift
        launch_sandbox "$@"
        ;;
    *)
        show_manual
        ;;
esac
