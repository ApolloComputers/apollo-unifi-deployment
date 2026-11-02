#!/usr/bin/env bash

# ==========================================================
# APOLLO COMPUTERS
# UNIFI OS SERVER AUTOMATED DEPLOYMENT
# Version: 1.0 - Initial Testing
#
# Supported OS: Ubuntu Server 24.04 LTS
# Architecture: x86_64
#
# SECURITY:
# Do not place Datto enrollment URLs or passwords here.
# ==========================================================

set -Eeuo pipefail

UNIFI_VERSION="5.1.42"

UNIFI_URL="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"

INSTALL_DIR="/opt/apollo-unifi"
LOG_FILE="/var/log/apollo-unifi-deployment.log"

# ----------------------------------------------------------
# Display helpers
# ----------------------------------------------------------

info() {
    echo
    echo "[INFO] $1"
}

success() {
    echo "[PASS] $1"
}

error() {
    echo "[ERROR] $1" >&2
}

on_error() {
    error "Installation failed near line $1."
    error "Review the log: $LOG_FILE"
}

trap 'on_error "$LINENO"' ERR

# ----------------------------------------------------------
# Require root
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script using sudo."
    exit 1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

clear

echo "=================================================="
echo "         APOLLO COMPUTERS"
echo "       UNIFI SERVER DEPLOYMENT"
echo "=================================================="
echo
echo "Deployment Version: 1.0"
echo "UniFi OS Server: $UNIFI_VERSION"
echo

# ----------------------------------------------------------
# Collect client information
# ----------------------------------------------------------

read -r -p "Client Name: " CLIENT_NAME

read -r -p "Server Hostname: " SERVER_HOSTNAME

if [[ -z "$CLIENT_NAME" ]]; then
    error "Client name cannot be empty."
    exit 1
fi

if [[ ! "$SERVER_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    error "Invalid hostname."
    exit 1
fi

echo
echo "--------------------------------------------------"
echo "DEPLOYMENT CONFIGURATION"
echo "--------------------------------------------------"
echo "Client:   $CLIENT_NAME"
echo "Hostname: $SERVER_HOSTNAME"
echo "Network:  DHCP (testing mode)"
echo "UniFi:    $UNIFI_VERSION"
echo "--------------------------------------------------"
echo

read -r -p "Proceed with installation? (Y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# ----------------------------------------------------------
# Verify operating system
# ----------------------------------------------------------

info "Checking Ubuntu version..."

source /etc/os-release

if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
    error "Ubuntu Server 24.04 LTS is required."
    exit 1
fi

success "Ubuntu $VERSION_ID detected."

# ----------------------------------------------------------
# Verify architecture
# ----------------------------------------------------------

info "Checking system architecture..."

ARCH="$(uname -m)"

if [[ "$ARCH" != "x86_64" ]]; then
    error "Unsupported architecture: $ARCH"
    exit 1
fi

success "x86_64 architecture detected."

# ----------------------------------------------------------
# Verify network connectivity
# ----------------------------------------------------------

info "Checking Ubiquiti download availability..."

HTTP_CODE="$(curl -sIL --max-time 30 \
    -o /dev/null \
    -w '%{http_code}' \
    "$UNIFI_URL")"

if [[ "$HTTP_CODE" != "200" ]]; then
    error "UniFi download unavailable. HTTP $HTTP_CODE"
    exit 1
fi

success "UniFi download server accessible."

# ----------------------------------------------------------
# Update package information
# ----------------------------------------------------------

info "Updating Ubuntu package information..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

success "Package information updated."

# ----------------------------------------------------------
# Install required packages
# ----------------------------------------------------------

info "Installing UniFi dependencies..."

apt-get install -y \
    curl \
    wget \
    ca-certificates \
    gnupg \
    podman \
    slirp4netns \
    uidmap \
    dbus-user-session

success "UniFi dependencies installed."

# ----------------------------------------------------------
# Prepare installation directory
# ----------------------------------------------------------

info "Preparing installation directory..."

mkdir -p "$INSTALL_DIR"

chmod 755 "$INSTALL_DIR"

# ----------------------------------------------------------
# Download UniFi OS Server
# ----------------------------------------------------------

info "Downloading UniFi OS Server $UNIFI_VERSION..."
info "Download size: approximately 750 MiB."

UNIFI_INSTALLER="$INSTALL_DIR/unifi-os-server-installer"

curl -fL \
    --retry 3 \
    --connect-timeout 30 \
    --continue-at - \
    "$UNIFI_URL" \
    -o "$UNIFI_INSTALLER"

chmod 755 "$UNIFI_INSTALLER"

success "UniFi OS Server downloaded."

# ----------------------------------------------------------
# Install UniFi OS Server
# ----------------------------------------------------------

info "Installing UniFi OS Server..."

"$UNIFI_INSTALLER"

success "UniFi installer completed."

# ----------------------------------------------------------
# Enable and verify services
# ----------------------------------------------------------

info "Checking UniFi services..."

systemctl daemon-reload

for SERVICE in uosserver.service uosserver-updater.service; do

    if systemctl list-unit-files "$SERVICE" \
        --no-legend | grep -q "$SERVICE"; then

        systemctl enable "$SERVICE"

        systemctl start "$SERVICE"

        if systemctl is-active --quiet "$SERVICE"; then
            success "$SERVICE is running."
        else
            error "$SERVICE is not running."
        fi

    else
        error "$SERVICE was not found."
    fi

done

# ----------------------------------------------------------
# Configure hostname
# ----------------------------------------------------------

info "Configuring server hostname..."

hostnamectl set-hostname "$SERVER_HOSTNAME"

success "Hostname configured: $SERVER_HOSTNAME"

# ----------------------------------------------------------
# Display management address
# ----------------------------------------------------------

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo
echo "=================================================="
echo "        APOLLO DEPLOYMENT SUMMARY"
echo "=================================================="
echo
echo "Client:   $CLIENT_NAME"
echo "Hostname: $SERVER_HOSTNAME"
echo "Ubuntu:   $VERSION_ID"
echo "UniFi:    $UNIFI_VERSION"
echo
echo "UniFi Management URL:"
echo
echo "https://${SERVER_IP}:11443/"
echo
echo "--------------------------------------------------"
echo "REMAINING TASKS"
echo "--------------------------------------------------"
echo
echo "[ ] Complete UniFi Site Manager registration"
echo "[ ] Install and verify Apollo Datto RMM agent"
echo "[ ] Move Datto device to correct client site"
echo "[ ] Configure static IP when appropriate"
echo "[ ] Adopt client access points"
echo "[ ] Verify UniFi operation after reboot"
echo
echo "Deployment log: $LOG_FILE"
echo
echo "=================================================="
echo "        INSTALLATION SCRIPT FINISHED"
echo "=================================================="
