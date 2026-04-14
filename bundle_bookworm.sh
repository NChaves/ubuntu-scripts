#!/bin/bash

set -euo pipefail

# ===== Colours =====
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'

INFO_LABEL="[INFO]"
OK_LABEL="[OK]"
WARN_LABEL="[WARN]"

# ===== User Detection =====
REAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
HOME_DIR=$(eval echo "~$REAL_USER")

# ===== Dependency Install =====
echo -e "$INFO_LABEL ${CYAN}Installing required dependencies...${RESET}"
apt update -y
apt install -y curl openssh-client ca-certificates lsb-release

# ===== Detect Network =====
DEFAULT_IF=$(ip route | awk '/default/ {print $5; exit}')
LOCAL_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
SUBNET=$(ip -o -f inet addr show "$DEFAULT_IF" | awk '{print $4}')

echo -e "$INFO_LABEL ${CYAN}Interface: $DEFAULT_IF${RESET}"
echo -e "$INFO_LABEL ${CYAN}Local IP: $LOCAL_IP${RESET}"
echo -e "$INFO_LABEL ${CYAN}Subnet: $SUBNET${RESET}"

# ===== Detect Container =====
if systemd-detect-virt -c | grep -q lxc; then
    echo -e "$WARN_LABEL ${YELLOW}Running inside LXC container - firewall rules may not apply as expected.${RESET}"
fi

# ===== Options =====
declare -A options=(
    [1]="nano"
    [2]="ufw"
    [3]="rsync"
    [4]="filebrowser"
    [5]="ssh-key"
)

echo -e "\n${CYAN}Select what to install:${RESET}"
for i in "${!options[@]}"; do
    echo "  $i) ${options[$i]}"
done
echo "  All) Install all"

read -rp "Enter option: " selection

install_selection=()

if [[ "$selection" =~ ^[Aa]ll$ ]]; then
    install_selection=("${options[@]}")
elif [[ "${options[$selection]+exists}" ]]; then
    install_selection+=("${options[$selection]}")
else
    echo -e "$WARN_LABEL ${YELLOW}Invalid selection${RESET}"
    exit 1
fi

# ===== Package helper =====
install_or_update() {
    local pkg=$1
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo -e "$INFO_LABEL ${CYAN}$pkg already installed, upgrading...${RESET}"
        apt install --only-upgrade -y "$pkg"
    else
        echo -e "$INFO_LABEL ${CYAN}Installing $pkg...${RESET}"
        apt install -y "$pkg"
    fi
}

# ===== Filebrowser Setup =====
setup_filebrowser() {
    FILEBROWSER_DIR="/home/filebrowser"
    FILEBROWSER_CONFIG="/etc/filebrowser.json"
    FILEBROWSER_DB="/etc/filebrowser.db"

    echo -e "$INFO_LABEL ${CYAN}Setting up Filebrowser...${RESET}"

    mkdir -p "$FILEBROWSER_DIR"
    chown "$REAL_USER":"$REAL_USER" "$FILEBROWSER_DIR"

    # Install binary if needed
    FILEBROWSER_BIN=$(command -v filebrowser || true)
    if [ -z "$FILEBROWSER_BIN" ]; then
        curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
        FILEBROWSER_BIN=$(command -v filebrowser)
    fi

    # Create config
    tee "$FILEBROWSER_CONFIG" >/dev/null <<EOF
{
  "port": 8080,
  "baseURL": "",
  "address": "$LOCAL_IP",
  "log": "stdout",
  "database": "$FILEBROWSER_DB",
  "root": "$FILEBROWSER_DIR"
}
EOF

    # Initialise DB with known credentials
    if [ ! -f "$FILEBROWSER_DB" ]; then
        "$FILEBROWSER_BIN" -c "$FILEBROWSER_CONFIG" config init
        "$FILEBROWSER_BIN" -c "$FILEBROWSER_CONFIG" users add admin admin --perm.admin
    fi

    # systemd service
    tee /etc/systemd/system/filebrowser.service >/dev/null <<EOF
[Unit]
Description=File Browser
After=network.target

[Service]
User=root
Group=root
ExecStart=$FILEBROWSER_BIN -c $FILEBROWSER_CONFIG
Restart=always
RestartSec=5
WorkingDirectory=/etc
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable filebrowser
    systemctl restart filebrowser

    echo -e "$OK_LABEL ${GREEN}Filebrowser running at http://$LOCAL_IP:8080${RESET}"
    echo -e "$INFO_LABEL ${CYAN}Login: admin / admin${RESET}"
}

# ===== Main Install Loop =====
for app in "${install_selection[@]}"; do
    case "$app" in
        nano)
            install_or_update nano
            ;;
        ufw)
            install_or_update ufw
            ufw allow from "$SUBNET" to any port 22 proto tcp
            echo -e "$OK_LABEL ${GREEN}SSH rule added${RESET}"
            ;;
        rsync)
            install_or_update rsync
            ;;
        filebrowser)
            setup_filebrowser
            ;;
        ssh-key)
            read -rp "Enter email: " user_email
            ssh_key_path="$HOME_DIR/.ssh/id_ed25519"

            if [ -f "$ssh_key_path" ]; then
                echo -e "$WARN_LABEL ${YELLOW}SSH key exists${RESET}"
            else
                sudo -u "$REAL_USER" ssh-keygen -t ed25519 -C "$user_email" -f "$ssh_key_path" -N ""
                echo -e "$OK_LABEL ${GREEN}SSH key created${RESET}"
                cat "$ssh_key_path.pub"
            fi
            ;;
    esac
done

# ===== UFW Post Config =====
if command -v ufw >/dev/null 2>&1 && command -v filebrowser >/dev/null 2>&1; then
    ufw allow from "$SUBNET" to any port 8080 proto tcp
fi

if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
    read -rp "Enable UFW? (y/n): " enable_ufw
    if [[ "$enable_ufw" =~ ^[Yy]$ ]]; then
        ufw enable
    fi
fi

# ===== Symlink Option =====
if [[ " ${install_selection[*]} " =~ " filebrowser " ]]; then
    read -rp "Create symlink into /home/filebrowser? (y/n): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        read -rp "Source path: " src
        read -rp "Destination name: " dest
        ln -s "$src" "/home/filebrowser/$dest" 2>/dev/null || \
        echo -e "$WARN_LABEL ${YELLOW}Failed or already exists${RESET}"
    fi
fi

# ===== Git Self Update =====
if [ -d .git ]; then
    git fetch origin
    git checkout origin/$(git rev-parse --abbrev-ref HEAD) -- bundle.sh || true
fi

echo -e "\n$OK_LABEL ${GREEN}Completed${RESET}"
