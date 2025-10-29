#!/bin/bash

set -e

# Colors and labels
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'
INFO_LABEL="[INFO]"
OK_LABEL="[OK]"
WARN_LABEL="[WARN]"

# Automatically detect subnet (e.g., 192.168.10.0/24)
SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {sub(/\/.*/, "", $4); split($4, a, "."); print a[1]"."a[2]"."a[3]".0/24"; exit}')
echo -e "$INFO_LABEL ${CYAN}Detected local subnet: $SUBNET${RESET}"

# Installable options
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
echo "  All) Install all of the above"

read -p "Enter option (number or 'All'): " selection

install_all=false
install_selection=()

if [[ "$selection" =~ ^[Aa]ll$ ]]; then
    install_all=true
    install_selection=("${options[@]}")
elif [[ "${options[$selection]+exists}" ]]; then
    install_selection+=("${options[$selection]}")
else
    echo -e "$WARN_LABEL ${YELLOW}Invalid selection. Exiting.${RESET}"
    exit 1
fi

echo -e "$INFO_LABEL ${CYAN}Updating package lists...${RESET}"
sudo apt update

install_or_update() {
    local pkg=$1
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo -e "$INFO_LABEL ${CYAN}$pkg already installed. Checking for updates...${RESET}"
        sudo apt install --only-upgrade -y "$pkg"
    else
        echo -e "$INFO_LABEL ${CYAN}Installing $pkg...${RESET}"
        sudo apt install -y "$pkg"
    fi
}

# Install selected apps
for app in "${install_selection[@]}"; do
    case "$app" in
        nano)
            install_or_update nano
            ;;
        ufw)
            install_or_update ufw
            echo -e "$INFO_LABEL ${CYAN}Allowing SSH (port 22) from $SUBNET...${RESET}"
            sudo ufw allow from "$SUBNET" to any port 22 proto tcp
            echo -e "$OK_LABEL ${GREEN}UFW rule for SSH added (not enabled).${RESET}"
            ;;
        rsync)
            install_or_update rsync
            ;;
        filebrowser)
            FILEBROWSER_DIR="/home/filebrowser"
            if [ ! -d "$FILEBROWSER_DIR" ]; then
                echo -e "$INFO_LABEL ${CYAN}Creating $FILEBROWSER_DIR...${RESET}"
                sudo mkdir -p "$FILEBROWSER_DIR"
                sudo chown "$USER":"$USER" "$FILEBROWSER_DIR"
            fi

            if ! command -v filebrowser >/dev/null 2>&1; then
                echo -e "$INFO_LABEL ${CYAN}Installing Filebrowser...${RESET}"
                curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
            else
                echo -e "$INFO_LABEL ${CYAN}Filebrowser already installed.${RESET}"
            fi

            LOCAL_IP=$(hostname -I | awk '{print $1}')
            FILEBROWSER_CONFIG="/etc/filebrowser.json"
            echo -e "$INFO_LABEL ${CYAN}Writing config to $FILEBROWSER_CONFIG...${RESET}"
            sudo tee "$FILEBROWSER_CONFIG" >/dev/null <<EOF
{
  "port": 8080,
  "baseURL": "",
  "address": "$LOCAL_IP",
  "log": "stdout",
  "database": "/etc/filebrowser.db",
  "root": "$FILEBROWSER_DIR"
}
EOF

            FILEBROWSER_SERVICE="/etc/systemd/system/filebrowser.service"
            echo -e "$INFO_LABEL ${CYAN}Creating Filebrowser service...${RESET}"
            sudo tee "$FILEBROWSER_SERVICE" >/dev/null <<EOF
[Unit]
Description=File Browser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser -c /etc/filebrowser.json

[Install]
WantedBy=multi-user.target
EOF

            echo -e "$INFO_LABEL ${CYAN}Starting Filebrowser service...${RESET}"
            sudo systemctl daemon-reexec
            sudo systemctl daemon-reload
            sudo systemctl enable filebrowser
            # Start File Browser
            sudo systemctl start filebrowser
            
            # Wait a few seconds for initialization
            sleep 5
            
            # Extract the randomly generated password from the logs
            PASSWORD=$(sudo journalctl -u filebrowser -n 20 --no-pager | grep "User 'admin' initialized with randomly generated password" | tail -n1 | awk -F': ' '{print $NF}')
            
            echo
            echo "File Browser admin password: $PASSWORD"
            echo "Access File Browser at http://$(hostname -I | awk '{print $1}'):8080"
            ;;
        ssh-key)
            read -p "Enter your GitHub email address: " user_email
            ssh_key_path="$HOME/.ssh/id_ed25519"

            if [ -f "$ssh_key_path" ]; then
                echo -e "$WARN_LABEL ${YELLOW}SSH key already exists at $ssh_key_path. Skipping creation.${RESET}"
            else
                echo -e "$INFO_LABEL ${CYAN}Creating SSH key...${RESET}"
                ssh-keygen -t ed25519 -C "$user_email" -f "$ssh_key_path" -N ""
                eval "$(ssh-agent -s)"
                ssh-add "$ssh_key_path"
                echo -e "\n✅ SSH key created and added to the SSH agent."
                echo -e "📋 Copy the following public key into your GitHub SSH settings:"
                echo -e "--------------------------------------------------------------"
                cat "$ssh_key_path.pub"
                echo -e "--------------------------------------------------------------"
            fi
            ;;
        *)
            echo -e "$WARN_LABEL ${YELLOW}Unknown option: $app${RESET}"
            ;;
    esac
done

# Add UFW rule for Filebrowser if both installed
if dpkg -s "ufw" >/dev/null 2>&1 && command -v filebrowser >/dev/null 2>&1; then
    echo -e "$INFO_LABEL ${CYAN}Adding UFW rule to allow port 8080 from $SUBNET...${RESET}"
    sudo ufw allow from "$SUBNET" to any port 8080 proto tcp
    echo -e "$OK_LABEL ${GREEN}UFW rule for Filebrowser added.${RESET}"
fi

# Symlink option for filebrowser
if [[ " ${install_selection[@]} " =~ " filebrowser " ]]; then
    read -p "Do you want to symlink a folder into /home/filebrowser/? (y/n): " want_symlink
    if [[ "$want_symlink" =~ ^[Yy]$ ]]; then
        read -p "Enter the source directory to symlink: " src
        read -p "Enter the name for the destination folder (relative to /home/filebrowser/): " dest
        dest_path="/home/filebrowser/$dest"

        if [ -e "$src" ]; then
            if [ ! -e "$dest_path" ]; then
                ln -s "$src" "$dest_path"
                echo -e "$OK_LABEL ${GREEN}Symlink created: $dest_path -> $src${RESET}"
            else
                echo -e "$WARN_LABEL ${YELLOW}Destination already exists. Skipping symlink.${RESET}"
            fi
        else
            echo -e "$WARN_LABEL ${YELLOW}Source does not exist. Skipping symlink.${RESET}"
        fi
    else
        echo -e "$INFO_LABEL ${CYAN}No symlink created.${RESET}"
    fi
fi

# Show UFW status
if command -v ufw >/dev/null 2>&1; then
    echo -e "\n$INFO_LABEL ${CYAN}Current UFW status:${RESET}"
    sudo ufw status verbose

    read -p "Do you want to enable UFW now? (y/n): " enable_ufw
    if [[ "$enable_ufw" =~ ^[Yy]$ ]]; then
        sudo ufw enable
        echo -e "$OK_LABEL ${GREEN}UFW enabled.${RESET}"
    else
        echo -e "$INFO_LABEL ${CYAN}UFW not enabled.${RESET}"
    fi
fi

# Notify about Filebrowser URL
if command -v filebrowser >/dev/null 2>&1; then
    echo -e "\n$INFO_LABEL ${CYAN}Filebrowser is running at: http://$LOCAL_IP:8080${RESET}"
    echo -e "$INFO_LABEL ${CYAN}Default Login: admin / admin${RESET}"
fi

# Git repo update (if inside git)
if [ -d .git ]; then
    echo -e "\n$INFO_LABEL ${CYAN}Updating bundle.sh from the latest repo version...${RESET}"
    git fetch origin
    git checkout origin/$(git rev-parse --abbrev-ref HEAD) -- bundle.sh
    echo -e "$OK_LABEL ${GREEN}bundle.sh updated from Git repo.${RESET}"
else
    echo -e "$WARN_LABEL ${YELLOW}Not a Git repo. Skipping auto-update.${RESET}"
fi

echo -e "\n$OK_LABEL ${GREEN}Setup complete.${RESET}"
