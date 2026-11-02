#!/usr/bin/env bash

# ==========================================================
# APOLLO COMPUTERS
# UNIFI OS SERVER AUTOMATED DEPLOYMENT
# Version: 2.0 - Network Configuration Testing
#
# Supported OS: Ubuntu Server 24.04 LTS
# Architecture: x86_64
#
# SECURITY:
# Never store Datto enrollment URLs or passwords here.
# ==========================================================

set -Eeuo pipefail

UNIFI_VERSION="5.1.42"
UNIFI_URL="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"

INSTALL_DIR="/opt/apollo-unifi"
LOG_FILE="/var/log/apollo-unifi-deployment.log"

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

fail() {
    error "$1"
    exit 1
}

on_error() {
    error "Deployment failed near line $1."
    error "Review $LOG_FILE for details."
}

trap 'on_error "$LINENO"' ERR

if [[ "$EUID" -ne 0 ]]; then
    fail "Run this script using sudo."
fi

# Interactive deployment requires a terminal.
if [[ ! -t 0 ]]; then
    fail "An interactive terminal is required."
fi

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "=================================================="
echo "           APOLLO COMPUTERS"
echo "         UNIFI SERVER DEPLOYMENT"
echo "=================================================="
echo
echo "Deployment Version: 2.0"
echo "UniFi OS Server: $UNIFI_VERSION"
echo

# ----------------------------------------------------------
# Verify operating system
# ----------------------------------------------------------

info "Checking operating system..."

source /etc/os-release

if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
    fail "Ubuntu Server 24.04 LTS is required."
fi

success "Ubuntu $VERSION_ID detected."

if [[ "$(uname -m)" != "x86_64" ]]; then
    fail "An x86_64 processor is required."
fi

success "x86_64 architecture detected."

# ----------------------------------------------------------
# Collect deployment information
# ----------------------------------------------------------

echo
read -r -p "Client Name: " CLIENT_NAME
read -r -p "Server Hostname: " SERVER_HOSTNAME

[[ -n "$CLIENT_NAME" ]] || fail "Client name is required."

if [[ ! "$SERVER_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    fail "Invalid hostname."
fi

# ----------------------------------------------------------
# Network interface selection
# ----------------------------------------------------------

echo
info "Detecting network interfaces..."

mapfile -t INTERFACES < <(
    find /sys/class/net -mindepth 1 -maxdepth 1 \
        -printf '%f\n' | grep -v '^lo$' | sort
)

if [[ "${#INTERFACES[@]}" -eq 0 ]]; then
    fail "No network interfaces detected."
fi

echo
echo "Available network interfaces:"
echo

for i in "${!INTERFACES[@]}"; do
    printf "%d) %s\n" "$((i + 1))" "${INTERFACES[$i]}"
done

echo

while true; do
    read -r -p "Select network interface number: " SELECTION

    if [[ "$SELECTION" =~ ^[0-9]+$ ]] &&
       (( 10#$SELECTION >= 1 && 10#$SELECTION <= ${#INTERFACES[@]} )); then
        NETWORK_INTERFACE="${INTERFACES[$((10#$SELECTION - 1))]}"
        break
    fi

    echo "Invalid selection."
done

success "Selected interface: $NETWORK_INTERFACE"

# ----------------------------------------------------------
# Network configuration selection
# ----------------------------------------------------------

echo
echo "NETWORK CONFIGURATION"
echo "--------------------------------------------------"
echo "1) DHCP"
echo "2) Static IP"
echo

while true; do
    read -r -p "Select network configuration (1/2): " NETWORK_CHOICE

    case "$NETWORK_CHOICE" in
        1)
            NETWORK_MODE="DHCP"
            break
            ;;
        2)
            NETWORK_MODE="STATIC"
            break
            ;;
        *)
            echo "Enter 1 or 2."
            ;;
    esac
done

# ----------------------------------------------------------
# Static IP validation
# ----------------------------------------------------------

valid_ipv4() {
    local ip="$1"
    local octet

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    read -r -a octets <<< "$ip"

    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

read_ipv4() {
    local prompt="$1"
    local value

    while true; do
        read -r -p "$prompt" value

        if valid_ipv4 "$value"; then
            printf -v "$2" '%s' "$value"
            return
        fi

        echo "Invalid IPv4 address."
    done
}

if [[ "$NETWORK_MODE" == "STATIC" ]]; then

    echo
    echo "STATIC IP CONFIGURATION"
    echo "--------------------------------------------------"

    read_ipv4 "Static IP Address: " STATIC_IP

    while true; do
        read -r -p "Subnet Prefix (example 24): " PREFIX

        if [[ "$PREFIX" =~ ^[0-9]+$ ]] &&
           (( 10#$PREFIX >= 1 && 10#$PREFIX <= 32 )); then
            PREFIX="$((10#$PREFIX))"
            break
        fi

        echo "Enter a prefix between 1 and 32."
    done

    read_ipv4 "Default Gateway: " GATEWAY
    read_ipv4 "Primary DNS: " DNS1
    read_ipv4 "Secondary DNS: " DNS2

fi

# ----------------------------------------------------------
# Display configuration
# ----------------------------------------------------------

echo
echo "=================================================="
echo "         DEPLOYMENT CONFIGURATION"
echo "=================================================="
echo
echo "Client:    $CLIENT_NAME"
echo "Hostname:  $SERVER_HOSTNAME"
echo "Interface: $NETWORK_INTERFACE"
echo "Network:   $NETWORK_MODE"

if [[ "$NETWORK_MODE" == "STATIC" ]]; then
    echo
    echo "Static IP: $STATIC_IP/$PREFIX"
    echo "Gateway:   $GATEWAY"
    echo "DNS 1:     $DNS1"
    echo "DNS 2:     $DNS2"
fi

echo
echo "UniFi OS Server: $UNIFI_VERSION"
echo "=================================================="
echo

read -r -p "Is this configuration correct? (Y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

# ----------------------------------------------------------
# Configure static networking
# ----------------------------------------------------------

if [[ "$NETWORK_MODE" == "STATIC" ]]; then

    echo
    echo "WARNING:"
    echo "Changing the IP address may disconnect SSH."
    echo "Use the physical or Hyper-V console for this step."
    echo

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        fail "Static IP changes must be performed from the local console."
    fi

    if ! command -v netplan >/dev/null 2>&1; then
        fail "Netplan is not installed."
    fi

    # This version supports Ubuntu installations where
    # cloud-init networking is disabled.
    if command -v cloud-init >/dev/null 2>&1; then
        CLOUD_STATUS="$(cloud-init status 2>/dev/null || true)"

        if [[ "$CLOUD_STATUS" != *"disabled"* ]]; then
            fail "Cloud-init is not confirmed disabled. Network configuration requires review."
        fi
    fi

    # Avoid changing complex or multi-interface configurations.
    mapfile -t NETPLAN_FILES < <(
        find /etc/netplan -maxdepth 1 \
            -type f -name '*.yaml' -print
    )

    if [[ "${#NETPLAN_FILES[@]}" -ne 1 ]]; then
        fail "Expected one Netplan YAML file. Manual review required."
    fi

    NETPLAN_FILE="${NETPLAN_FILES[0]}"

    if ! grep -Eq "^[[:space:]]+$NETWORK_INTERFACE:" "$NETPLAN_FILE"; then
        fail "Selected interface was not found in Netplan configuration."
    fi

    # Preserve the original configuration outside /etc/netplan.
    BACKUP_DIR="$(mktemp -d /root/apollo-netplan-backup.XXXXXX)"

    cp -a "$NETPLAN_FILE" "$BACKUP_DIR/original.yaml"

    # This initial version intentionally refuses configurations
    # containing advanced networking features.
    if grep -Eq '^[[:space:]]*(bridges|bonds|vlans|wifis):' "$NETPLAN_FILE"; then
        fail "Advanced Netplan configuration detected. Manual review required."
    fi

    info "Writing static network configuration..."

    # Create a new Netplan configuration for the selected interface.
    # The original file remains available in the backup directory.
    NEW_NETPLAN="/etc/netplan/99-apollo-unifi.yaml"

    if [[ -e "$NEW_NETPLAN" ]]; then
        fail "$NEW_NETPLAN already exists. Manual review required."
    fi

    cat > "$NEW_NETPLAN" <<EOF
network:
  version: 2
  ethernets:
    $NETWORK_INTERFACE:
      dhcp4: false
      addresses:
        - $STATIC_IP/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF

    chmod 600 "$NEW_NETPLAN"

    # Prevent the original DHCP definition from conflicting.
    mv "$NETPLAN_FILE" "$BACKUP_DIR/active-original.yaml"

    info "Validating Netplan configuration..."

    if ! netplan generate; then
        cp -a "$BACKUP_DIR/active-original.yaml" "$NETPLAN_FILE"
        rm -f "$NEW_NETPLAN"
        fail "Netplan validation failed. Original configuration restored."
    fi

    echo
    echo "Netplan will apply the new settings."
    echo "You have 120 seconds to confirm connectivity."
    echo "If you do not confirm, Netplan will attempt rollback."
    echo

    if netplan try --timeout 120; then
        success "Network configuration confirmed."
    else
        error "Network configuration was not confirmed."

        cp -a "$BACKUP_DIR/active-original.yaml" "$NETPLAN_FILE"
        rm -f "$NEW_NETPLAN"

        netplan apply || true

        fail "Original network configuration restored."
    fi

    # Keep a copy of the original file for troubleshooting.
    success "Network configuration completed."

else

    info "DHCP selected. Existing network configuration unchanged."

fi

# ----------------------------------------------------------
# Set hostname
# ----------------------------------------------------------

info "Configuring hostname..."

hostnamectl set-hostname "$SERVER_HOSTNAME"

success "Hostname configured."

# ----------------------------------------------------------
# Install dependencies
# ----------------------------------------------------------

info "Updating Ubuntu packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

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

success "Dependencies installed."

# ----------------------------------------------------------
# Download UniFi OS Server
# ----------------------------------------------------------

info "Preparing UniFi installation..."

mkdir -p "$INSTALL_DIR"

UNIFI_INSTALLER="$INSTALL_DIR/unifi-os-server-installer"

info "Downloading UniFi OS Server $UNIFI_VERSION..."

curl -fL \
    --retry 3 \
    --connect-timeout 30 \
    "$UNIFI_URL" \
    -o "$UNIFI_INSTALLER"

chmod 755 "$UNIFI_INSTALLER"

success "UniFi installer downloaded."

# ----------------------------------------------------------
# Install UniFi OS Server
# ----------------------------------------------------------

info "Starting UniFi OS Server installation..."

echo
echo "NOTE: Ubiquiti's installer may request confirmation."
echo

"$UNIFI_INSTALLER"

success "UniFi installer completed."

# ----------------------------------------------------------
# Verify services
# ----------------------------------------------------------

info "Verifying UniFi services..."

systemctl daemon-reload

INSTALL_OK=true

for SERVICE in uosserver.service uosserver-updater.service; do

    if ! systemctl list-unit-files "$SERVICE" \
        --no-legend | grep -q "^$SERVICE"; then

        error "$SERVICE was not found."
        INSTALL_OK=false
        continue
    fi

    systemctl enable "$SERVICE"
    systemctl start "$SERVICE"

    if systemctl is-active --quiet "$SERVICE"; then
        success "$SERVICE is running."
    else
        error "$SERVICE is not running."
        INSTALL_OK=false
    fi

done

# ----------------------------------------------------------
# Deployment summary
# ----------------------------------------------------------

SERVER_IP="$(ip -4 -o addr show dev "$NETWORK_INTERFACE" \
    | awk '{print $4}' | cut -d/ -f1 | head -n1)"

echo
echo "=================================================="
echo "          APOLLO DEPLOYMENT SUMMARY"
echo "=================================================="
echo
echo "Client:    $CLIENT_NAME"
echo "Hostname:  $SERVER_HOSTNAME"
echo "Interface: $NETWORK_INTERFACE"
echo "Network:   $NETWORK_MODE"
echo "IP:        ${SERVER_IP:-Not detected}"
echo "Ubuntu:    $VERSION_ID"
echo "UniFi:     $UNIFI_VERSION"
echo

if [[ -n "$SERVER_IP" ]]; then
    echo "UniFi Management URL:"
    echo "https://${SERVER_IP}:11443/"
fi

echo
echo "--------------------------------------------------"
echo "REMAINING TASKS"
echo "--------------------------------------------------"
echo
echo "[ ] Complete UniFi Site Manager registration"
echo "[ ] Install Apollo Datto RMM agent"
echo "[ ] Verify Datto agent and client assignment"
echo "[ ] Verify UniFi after reboot"
echo "[ ] Adopt client access points"
echo
echo "Deployment log: $LOG_FILE"
echo

if [[ "$INSTALL_OK" == true ]]; then
    echo "DEPLOYMENT STATUS: SUCCESS"
else
    echo "DEPLOYMENT STATUS: SERVICE VERIFICATION FAILED"
    exit 1
fi

echo "=================================================="
