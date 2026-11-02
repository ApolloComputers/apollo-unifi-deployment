#!/usr/bin/env bash
# Apollo Computers - UniFi OS Server Deployment
# Version 2.2 (testing): persistent tmux and timed network recovery
# Target: Ubuntu 24.04 x86_64
set -Eeuo pipefail

VERSION="2.2"
UNIFI_VERSION="5.1.42"
UNIFI_URL="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"
SESSION="apollo-deploy"
WORKDIR="/opt/apollo-unifi"
LOG="/var/log/apollo-unifi-deployment.log"
BACKUP="/var/lib/apollo-unifi/network-backup"
ROLLBACK="$WORKDIR/network-rollback.sh"
UNIT="apollo-unifi-network-rollback"
NEW_CONFIG="/etc/netplan/99-apollo-unifi.yaml"
MARKER="/run/apollo-unifi-network-confirmed"

info() { printf '\n[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# The technician owns the tmux server; root runs only the deployment.
if [[ "${1:-}" != "--inside-tmux" ]]; then
    (( EUID == 0 )) || fail "Start with: sudo bash install.sh"
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || fail "Use sudo from a technician account."
    [[ -t 0 ]] || fail "An interactive terminal is required."
    if ! command -v tmux >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
    fi
    SCRIPT="$(realpath "$0")"
    printf -v SCRIPT_Q '%q' "$SCRIPT"
    echo "Persistent session: $SESSION"
    echo "After reconnecting: tmux attach -t $SESSION"
    exec runuser -u "$SUDO_USER" -- tmux new-session -A -s "$SESSION" \
        "sudo env TMUX=\"\$TMUX\" bash $SCRIPT_Q --inside-tmux"
fi

(( EUID == 0 )) || fail "Root permissions required."
[[ -n "${TMUX:-}" && -t 0 ]] || fail "Run inside the managed tmux session."
install -m 600 /dev/null "$LOG" 2>/dev/null || true
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
read -r -p "Server Hostname: " HOST
[[ "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || fail "Invalid hostname."

mapfile -t IFACES < <(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -v '^lo$' | sort)
(( ${#IFACES[@]} > 0 )) || fail "No network interfaces found."
printf '\nNetwork interfaces:\n'
for i in "${!IFACES[@]}"; do printf '%d) %s\n' "$((i+1))" "${IFACES[i]}"; done
while :; do
    read -r -p "Select interface number: " PICK
    if [[ "$PICK" =~ ^[1-9][0-9]*$ ]] && (( ${#PICK} <= 3 )) && (( 10#$PICK <= ${#IFACES[@]} )); then
        IFACE="${IFACES[$((10#$PICK-1))]}"
        break
    fi
    echo "Invalid selection."
done

printf '\n1) DHCP (leave existing network unchanged)\n2) Static IP\n'
while :; do
    read -r -p "Choose 1 or 2: " MODE
    [[ "$MODE" == 1 || "$MODE" == 2 ]] && break
    echo "Choose 1 or 2."
done

valid_ip() {
    local addr="$1" part
    local -a parts
    [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$addr"
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$part <= 255 )) || return 1
    done
}
ask_ip() {
    local prompt="$1" target="$2" value
    while :; do
        read -r -p "$prompt" value
        if valid_ip "$value"; then printf -v "$target" '%s' "$value"; return; fi
        echo "Invalid IPv4 address."
    done
}

if [[ "$MODE" == 2 ]]; then
    ask_ip "Static IP address: " STATIC_IP
    while :; do
        read -r -p "Subnet prefix (1-32): " PREFIX
        if [[ "$PREFIX" =~ ^[1-9][0-9]?$ ]] && (( 10#$PREFIX <= 32 )); then
            PREFIX="$((10#$PREFIX))"
            break
        fi
        echo "Enter a number from 1 to 32."
    done
    ask_ip "Default gateway: " GATEWAY
    ask_ip "Primary DNS: " DNS1
    ask_ip "Secondary DNS: " DNS2
fi

printf '\nClient: %s\nHostname: %s\nInterface: %s\n' "$CLIENT" "$HOST" "$IFACE"
if [[ "$MODE" == 2 ]]; then
    printf 'Static: %s/%s | Gateway: %s | DNS: %s, %s\n' "$STATIC_IP" "$PREFIX" "$GATEWAY" "$DNS1" "$DNS2"
else
    echo "Network: DHCP (unchanged)"
fi
read -r -p "Proceed? (Y/N): " OK
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

if [[ "$MODE" == 2 ]]; then
    info "Preparing independently timed network rollback."
    command -v netplan >/dev/null || fail "Netplan not installed."
    command -v systemd-run >/dev/null || fail "systemd-run not installed."
    [[ ! -e "$BACKUP" && ! -e "$NEW_CONFIG" ]] || fail "Previous network backup/config exists; manual review required."
    if command -v cloud-init >/dev/null 2>&1; then
        [[ "$(cloud-init status 2>/dev/null || true)" == *disabled* ]] || fail "Cloud-init networking is enabled; manual review required."
    fi
    mapfile -t CONFIGS < <(find /etc/netplan -maxdepth 1 -type f -name '*.yaml' -print)
    (( ${#CONFIGS[@]} == 1 )) || fail "Expected exactly one Netplan YAML file; manual review required."
    ORIGINAL="${CONFIGS[0]}"
    [[ "$ORIGINAL" != "$NEW_CONFIG" ]] || fail "Apollo configuration already exists."
    grep -Eq "^[[:space:]]+$IFACE:" "$ORIGINAL" || fail "Selected interface not present in Netplan."
    grep -Eq '^[[:space:]]+dhcp4:[[:space:]]+true([[:space:]]|$)' "$ORIGINAL" || fail "Expected a simple DHCP configuration."
    if grep -Eq '^[[:space:]]*(bridges|bonds|vlans|wifis|routes|addresses):' "$ORIGINAL"; then
        fail "Complex Netplan configuration requires manual review."
    fi
    systemctl is-active --quiet "$UNIT.timer" && fail "An existing rollback timer is active."
    mkdir -p "$WORKDIR" "$BACKUP"
    chmod 700 "$BACKUP"
    cp -a "$ORIGINAL" "$BACKUP/original.yaml"
    printf '%s\n' "$ORIGINAL" > "$BACKUP/original-path"
    chmod 600 "$BACKUP/original-path"
    rm -f "$MARKER"

    cat > "$ROLLBACK" <<'ROLLBACK_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP="/var/lib/apollo-unifi/network-backup"
NEW_CONFIG="/etc/netplan/99-apollo-unifi.yaml"
MARKER="/run/apollo-unifi-network-confirmed"
[[ ! -e "$MARKER" ]] || exit 0
[[ -f "$BACKUP/original.yaml" && -f "$BACKUP/original-path" ]] || { echo "Missing network backup" >&2; exit 1; }
ORIGINAL="$(cat "$BACKUP/original-path")"
case "$ORIGINAL" in /etc/netplan/*.yaml) ;; *) echo "Unsafe backup path" >&2; exit 1 ;; esac
echo "Network not confirmed: restoring prior Netplan settings."
rm -f "$NEW_CONFIG"
cp -a "$BACKUP/original.yaml" "$ORIGINAL"
netplan generate
netplan apply
echo "Rollback attempted; verify connectivity at console if needed."
ROLLBACK_SCRIPT
    chmod 700 "$ROLLBACK"
    bash -n "$ROLLBACK" || fail "Rollback helper syntax check failed."

    # Stage configuration outside /etc/netplan so validation cannot accidentally activate it.
    cat > "$BACKUP/new.yaml" <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
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
    chmod 600 "$BACKUP/new.yaml"
    printf '\nWARNING: Network connectivity may be interrupted.\n'
    printf 'Reconnect to %s, then run: tmux attach -t %s\n' "$STATIC_IP" "$SESSION"
    printf 'An independent rollback will run after 5 minutes unless confirmed.\n'
    printf 'Keep Hyper-V console access available during this test.\n\n'
    read -r -p "Apply static network configuration? (Y/N): " APPLY
    [[ "$APPLY" =~ ^[Yy]$ ]] || { echo "Cancelled without changing networking."; exit 0; }

    systemd-run --unit="$UNIT" --on-active=300s --timer-property=AccuracySec=1s "$ROLLBACK"
    systemctl is-active --quiet "$UNIT.timer" || fail "Rollback timer failed to start; network unchanged."
    pass "Independent rollback timer scheduled."

    # Once the timer exists, all failures leave recovery scheduled.
    mv "$ORIGINAL" "$BACKUP/active-original.yaml"
    cp -a "$BACKUP/new.yaml" "$NEW_CONFIG"
    if ! netplan generate; then
        echo "Netplan validation failed; restoring immediately."
        "$ROLLBACK"
        fail "Invalid Netplan configuration."
    fi
    info "Applying static network settings..."
    if ! netplan apply; then
        echo "Netplan apply failed. Rollback timer remains active."
        fail "Could not apply static network settings."
    fi

    printf '\nConnect to the NEW address from another SSH connection.\n'
    printf 'Then attach to this tmux session and type the new IP to confirm.\n'
    printf 'Expected address: %s\n' "$STATIC_IP"
    read -r -p "Enter the NEW IP after verifying SSH connectivity: " VERIFIED_IP
    [[ "$VERIFIED_IP" == "$STATIC_IP" ]] || fail "Not confirmed; automatic rollback remains scheduled."
    systemctl is-active --quiet "$UNIT.timer" || fail "Rollback timer expired or stopped; inspect network before proceeding."
    ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | grep -Fxq "$STATIC_IP/$PREFIX" || fail "Expected IP missing; rollback remains scheduled."
    touch "$MARKER"
    systemctl stop "$UNIT.timer"
    pass "Network confirmed; rollback timer canceled."
else
    info "DHCP selected; existing network configuration unchanged."
fi

info "Configuring hostname..."
hostnamectl set-hostname "$HOST"

info "Installing UniFi dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl wget ca-certificates gnupg podman slirp4netns uidmap dbus-user-session
mkdir -p "$WORKDIR"
INSTALLER="$WORKDIR/unifi-os-server-installer"
info "Downloading UniFi OS Server $UNIFI_VERSION..."
curl -fL --retry 3 --connect-timeout 30 "$UNIFI_URL" -o "$INSTALLER"
chmod 755 "$INSTALLER"
info "Running Ubiquiti installer (confirmation may be required)..."
"$INSTALLER"

info "Checking UniFi services..."
STATUS=0
for SERVICE in uosserver.service uosserver-updater.service; do
    if systemctl list-unit-files "$SERVICE" --no-legend | grep -Fq "$SERVICE"; then
        systemctl enable "$SERVICE"
        systemctl start "$SERVICE"
        if systemctl is-active --quiet "$SERVICE"; then pass "$SERVICE is running"; else STATUS=1; echo "[ERROR] $SERVICE not active"; fi
    else
        STATUS=1
        echo "[ERROR] $SERVICE not installed"
    fi
done
IP="$(ip -4 -o addr show dev "$IFACE" | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
printf '\n==================================================\n'
printf ' APOLLO DEPLOYMENT SUMMARY\n'
printf ' Client: %s\n Hostname: %s\n IP: %s\n' "$CLIENT" "$HOST" "${IP:-not detected}"
[[ -z "$IP" ]] || printf ' UniFi UI: https://%s:11443/\n' "$IP"
printf ' Log: %s\n' "$LOG"
printf '==================================================\n'
printf 'Remaining: complete UniFi registration, install Datto RMM, verify reboot, adopt devices.\n'
if (( STATUS != 0 )); then fail "UniFi service verification failed."; fi
pass "UniFi deployment finished."
