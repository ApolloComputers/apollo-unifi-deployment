#!/usr/bin/env bash
# Apollo Computers - UniFi OS Server Deployment
# Version 2.4: use Ubuntu's preconfigured network; never modify Netplan.
# Target: Ubuntu Server 24.04 LTS x86_64
set -Eeuo pipefail

VERSION="2.4"
UNIFI_VERSION="5.1.42"
UNIFI_URL="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"
SESSION="apollo-deploy"
WORKDIR="/opt/apollo-unifi"
LOG="/var/log/apollo-unifi-deployment.log"

info() { printf '\n[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Keep the tmux server owned by the technician, not root.
if [[ "${1:-}" != "--inside-tmux" ]]; then
    (( EUID == 0 )) || fail "Start with: sudo bash install.sh"
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || fail "Use sudo from a technician account."
    [[ -t 0 ]] || fail "An interactive terminal is required. Download the script, then run it with sudo."
    if ! command -v tmux >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
    fi
    SCRIPT="$(realpath "$0")"
    printf -v SCRIPT_Q '%q' "$SCRIPT"
    printf 'Persistent session: %s\nAfter reconnecting: tmux attach -t %s\n' "$SESSION" "$SESSION"
    exec runuser -u "$SUDO_USER" -- tmux new-session -A -s "$SESSION" \
        "sudo env TMUX=\"\$TMUX\" bash $SCRIPT_Q --inside-tmux"
fi

(( EUID == 0 )) || fail "Root permissions required."
[[ -n "${TMUX:-}" && -t 0 ]] || fail "Run inside the managed tmux session."
install -d -m 700 "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'printf "[ERROR] Command failed at line %s. Review %s\n" "$LINENO" "$LOG" >&2' ERR

printf '\n==================================================\n'
printf ' APOLLO COMPUTERS - UNIFI SERVER DEPLOYMENT\n'
printf ' Version %s | UniFi OS Server %s\n' "$VERSION" "$UNIFI_VERSION"
printf '==================================================\n\n'

source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || fail "Ubuntu 24.04 is required."
[[ "$(uname -m)" == x86_64 ]] || fail "x86_64 is required."
pass "Supported operating system and architecture."

read -r -p "Client Name: " CLIENT
[[ -n "${CLIENT//[[:space:]]/}" ]] || fail "Client name required."
CURRENT_HOST="$(hostnamectl --static 2>/dev/null || hostname)"
read -r -p "Server Hostname [$CURRENT_HOST]: " HOST
HOST="${HOST:-$CURRENT_HOST}"
[[ ${#HOST} -le 63 && "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || fail "Invalid hostname."

# Detect the interface used for outbound traffic, without changing networking.
IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
[[ -n "$IFACE" ]] || fail "No IPv4 route detected. Configure networking in Ubuntu before deployment."
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
if [[ -z "$IP" ]]; then
    IP="$(ip -4 -o addr show dev "$IFACE" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
fi
[[ -n "$IP" ]] || fail "No IPv4 address found on $IFACE."

printf '\nClient: %s\nHostname: %s\nInterface: %s\nCurrent IP: %s\n' "$CLIENT" "$HOST" "$IFACE" "$IP"
printf 'Network: existing Ubuntu configuration (will not be modified)\n'
read -r -p "Proceed? (Y/N): " OK
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

info "Checking internet and installer connectivity..."
command -v curl >/dev/null 2>&1 || fail "curl is required. Install it with: sudo apt-get install -y curl"
curl -fsSI --connect-timeout 15 --max-time 30 https://archive.ubuntu.com/ubuntu/ >/dev/null || fail "Ubuntu repository is unreachable. Check DNS and internet connectivity."
pass "Network connectivity available; existing configuration unchanged."

if [[ "$(hostnamectl --static 2>/dev/null || hostname)" != "$HOST" ]]; then
    info "Setting hostname to $HOST..."
    hostnamectl set-hostname "$HOST"
else
    pass "Keeping existing hostname $HOST."
fi

info "Installing UniFi dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl wget ca-certificates gnupg podman slirp4netns uidmap dbus-user-session
install -d -m 755 "$WORKDIR"
INSTALLER="$WORKDIR/unifi-os-server-installer"
info "Downloading UniFi OS Server $UNIFI_VERSION..."
curl -fL --retry 3 --connect-timeout 30 "$UNIFI_URL" -o "$INSTALLER"
[[ -s "$INSTALLER" ]] || fail "UniFi installer download was empty."
chmod 755 "$INSTALLER"
info "Running Ubiquiti installer (vendor confirmation may be required)..."
"$INSTALLER"

info "Checking UniFi services..."
STATUS=0
for SERVICE in uosserver.service uosserver-updater.service; do
    if systemctl list-unit-files "$SERVICE" --no-legend | grep -Fq "$SERVICE"; then
        systemctl enable "$SERVICE"
        systemctl start "$SERVICE"
        if systemctl is-active --quiet "$SERVICE"; then
            pass "$SERVICE is running"
        else
            STATUS=1
            echo "[ERROR] $SERVICE not active"
        fi
    else
        STATUS=1
        echo "[ERROR] $SERVICE not installed"
    fi
done
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
printf '\n==================================================\n'
printf ' APOLLO DEPLOYMENT SUMMARY\n'
printf ' Client: %s\n Hostname: %s\n IP: %s\n' "$CLIENT" "$HOST" "${IP:-not detected}"
[[ -z "$IP" ]] || printf ' UniFi UI: https://%s:11443/\n' "$IP"
printf ' Log: %s\n' "$LOG"
printf '==================================================\n'
printf 'Remaining: complete UniFi registration, install Datto RMM, verify reboot, adopt devices.\n'
if (( STATUS != 0 )); then fail "UniFi service verification failed."; fi
pass "UniFi deployment finished."
