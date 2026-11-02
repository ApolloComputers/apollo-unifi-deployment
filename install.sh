#!/usr/bin/env bash

# ==========================================================
# APOLLO COMPUTERS
# UNIFI OS SERVER AUTOMATED DEPLOYMENT
# Version: 2.1 - Persistent Deployment Sessions
#
# Supported OS: Ubuntu Server 24.04 LTS
# Architecture: x86_64
#
# Do not store Datto enrollment URLs or passwords here.
# ==========================================================

set -Eeuo pipefail

VERSION="2.1"
UNIFI_VERSION="5.1.42"

UNIFI_URL="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"

INSTALL_DIR="/opt/apollo-unifi"
LOG_FILE="/var/log/apollo-unifi-deployment.log"
SESSION_NAME="apollo-deploy"

info() {
    echo
    echo "[INFO] $*"
}

success() {
    echo "[PASS] $*"
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

on_error() {
    echo "[ERROR] Deployment failed near line $1." >&2
    echo "Review $LOG_FILE for details." >&2
}

trap 'on_error "$LINENO"' ERR

# ----------------------------------------------------------
# Bootstrap persistent tmux session
# ----------------------------------------------------------

if [[ "${1:-}" != "--inside-tmux" ]]; then

    if [[ "$EUID" -ne 0 ]]; then
        echo "Run this script using sudo."
        exit 1
    fi

    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
        fail "Run from a technician account using sudo."
    fi

    TECH_USER="$SUDO_USER"

    info "Preparing persistent deployment session..."

    if ! command -v tmux >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
    fi

    success "tmux is available."

    SCRIPT_PATH="$(realpath "$0")"

    printf -v QUOTED_SCRIPT '%q' "$SCRIPT_PATH"

    echo
    echo "Starting persistent session: $SESSION_NAME"
    echo
    echo "If SSH disconnects, reconnect and run:"
    echo
    echo "tmux attach -t $SESSION_NAME"
    echo

    exec runuser -u "$TECH_USER" -- \
        tmux new-session -A -s "$SESSION_NAME" \
        "sudo bash $QUOTED_SCRIPT --inside-tmux"
fi

# ----------------------------------------------------------
# Require root inside tmux
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    fail "Administrative privileges are required."
fi

if [[ -z "${TMUX:-}" ]]; then
    fail "Deployment must run inside tmux."
fi

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
echo "Deployment Version: $VERSION"
echo "UniFi OS Server: $UNIFI_VERSION"
echo "Persistent Session: $SESSION_NAME"
echo

# ----------------------------------------------------------
# Verify operating system
# ----------------------------------------------------------

source /etc/os-release

[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
    || fail "Ubuntu Server 24.04 LTS is required."

[[ "$(uname -m)" == "x86_64" ]] \
    || fail "An x86_64 processor is required."

success "Ubuntu 24.04 x86_64 verified."

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
# Detect network interfaces
# ----------------------------------------------------------

info "Detecting network interfaces..."

mapfile -t INTERFACES < <(
    find /sys/class/net -mindepth 1 -maxdepth 1 \
        -printf '%f\n' | grep -v '^lo$' | sort
)

[[ "${#INTERFACES[@]}" -gt 0 ]] \
    || fail "No network interfaces detected."

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
       (( 10#$SELECTION >= 1 &&
          10#$SELECTION <= ${#INTERFACES[@]} )); then

        NETWORK_INTERFACE="${INTERFACES[$((10#$SELECTION - 1))]}"
        break
    fi

    echo "Invalid selection."
done

success "Selected interface: $NETWORK_INTERFACE"

# ----------------------------------------------------------
# Select DHCP or static IP
# ----------------------------------------------------------

echo
echo "NETWORK CONFIGURATION"
echo "--------------------------------------------------"
echo "1) DHCP"
echo "2) Static IP"
echo

while true; do
    read -r -p "Select network configuration (1/2): " CHOICE

    case "$CHOICE" in
        1) NETWORK_MODE="DHCP"; break ;;
        2) NETWORK_MODE="STATIC"; break ;;
        *) echo "Enter 1 or 2." ;;
    esac
done

# ----------------------------------------------------------
# IPv4 validation
# ----------------------------------------------------------

valid_ipv4() {
    local ip="$1"
    local octet
    local -a octets

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || return 1

    local IFS=.
    read -r -a octets <<< "$ip"

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] \
            || return 1

        (( octet <= 255 )) || return 1
    done
}

read_ipv4() {
    local prompt="$1"
    local result_var="$2"
    local value

    while true; do
        read -r -p "$prompt" value

        if valid_ipv4 "$value"; then
            printf -v "$result_var" '%s' "$value"
            return
        fi

        echo "Invalid IPv4 address."
    done
}

# ----------------------------------------------------------
# Collect static IP settings
# ----------------------------------------------------------

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
# Confirm deployment configuration
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

[[ "$CONFIRM" =~ ^[Yy]$ ]] || {
    echo "Deployment cancelled."
    exit 0
}

# ----------------------------------------------------------
# Static network configuration
# ----------------------------------------------------------

if [[ "$NETWORK_MODE" == "STATIC" ]]; then

    info "Preparing static network configuration..."

    command -v netplan >/dev/null 2>&1 \
        || fail "Netplan is required."

    # Only support simple, single-interface configurations
    # in this testing version.

    mapfile -t NETPLAN_FILES < <(
        find /etc/netplan -maxdepth 1 \
            -type f -name '*.yaml' -print
    )

    [[ "${#NETPLAN_FILES[@]}" -eq 1 ]] \
        || fail "Multiple Netplan files detected. Manual review required."

    NETPLAN_FILE="${NETPLAN_FILES[0]}"

    if command -v cloud-init >/dev/null 2>&1; then
        CLOUD_STATUS="$(cloud-init status 2>/dev/null || true)"

        [[ "$CLOUD_STATUS" == *"disabled"* ]] \
            || fail "Cloud-init networking requires manual review."
    fi

    # Only accept the simple DHCP configuration verified
    # on our Ubuntu test VM.
    if ! grep -Eq "^[[:space:]]+$NETWORK_INTERFACE:" "$NETPLAN_FILE" ||
       ! grep -Eq '^[[:space:]]+dhcp4:[[:space:]]+true' "$NETPLAN_FILE" ||
       grep -Eq '^[[:space:]]*(bridges|bonds|vlans|wifis|routes|addresses):' "$NETPLAN_FILE"; then

        fail "Existing network configuration requires manual review."
    fi

    BACKUP_DIR="$(mktemp -d /root/apollo-netplan-backup.XXXXXX)"

    cp -a "$NETPLAN_FILE" "$BACKUP_DIR/original.yaml"

    NEW_NETPLAN="/etc/netplan/99-apollo-unifi.yaml"

    [[ ! -e "$NEW_NETPLAN" ]] \
        || fail "Apollo Netplan configuration already exists."

    echo
    echo "=================================================="
    echo "           NETWORK CHANGE WARNING"
    echo "=================================================="
    echo
    echo "The server IP address may change."
    echo
    echo "Your SSH session may disconnect."
    echo
    echo "After reconnecting, run:"
    echo
    echo "tmux attach -t $SESSION_NAME"
    echo
    echo "Netplan will provide a 120-second confirmation"
    echo "window and attempt rollback if not confirmed."
    echo
    echo "Have console access available for recovery."
    echo

    read -r -p "Apply static network settings? (Y/N): " APPLY

    [[ "$APPLY" =~ ^[Yy]$ ]] \
        || fail "Static network change cancelled."

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

    mv "$NETPLAN_FILE" "$BACKUP_DIR/active-original.yaml"

    if ! netplan generate; then
        cp -a "$BACKUP_DIR/active-original.yaml" "$NETPLAN_FILE"
        rm -f "$NEW_NETPLAN"
        fail "Invalid network configuration. Original restored."
    fi

    info "Applying static network configuration..."

    if netplan try --timeout 120; then

        success "Network configuration confirmed."

    else

        echo "[WARN] Network change was not confirmed."

        cp -a "$BACKUP_DIR/active-original.yaml" "$NETPLAN_FILE"
        rm -f "$NEW_NETPLAN"

        netplan apply || true

        fail "Network change cancelled. Original configuration restored."
    fi

    # Netplan try is not a substitute for console recovery.
    # Verify connectivity before continuing.
    info "Checking network connectivity..."

    if ! ip -4 addr show dev "$NETWORK_INTERFACE" |
         grep -Fq "$STATIC_IP/$PREFIX"; then

        fail "Expected static IP was not detected."
    fi

    success "Static IP detected on $NETWORK_INTERFACE."

else

    info "DHCP selected. Existing network settings unchanged."

fi

# ----------------------------------------------------------
# Configure hostname
# ----------------------------------------------------------

info "Configuring hostname..."

hostnamectl set-hostname "$SERVER_HOSTNAME"

success "Hostname configured."

# ----------------------------------------------------------
# Install UniFi dependencies
# ----------------------------------------------------------

info "Updating package information..."

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

success "UniFi dependencies installed."

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

        echo "[ERROR] $SERVICE was not found."
        INSTALL_OK=false
        continue
    fi

    systemctl enable "$SERVICE"
    systemctl start "$SERVICE"

    if systemctl is-active --quiet "$SERVICE"; then
        success "$SERVICE is running."
    else
        echo "[ERROR] $SERVICE is not running."
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
