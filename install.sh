#!/usr/bin/env bash
# Apollo Computers - UniFi OS Server + Datto RMM Deployment
# Version 2.6 | Ubuntu Server 24.04 LTS x86_64

set -Eeuo pipefail

VERSION="2.6"
UNIFI_VERSION="5.1.42"
UNIFI_URL="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"

SESSION="apollo-deploy"
WORKDIR="/opt/apollo-unifi"
LOG="/var/log/apollo-unifi-deployment.log"

STEP="Startup"
UNIFI_STATUS="NOT RUN"
RMM_STATUS="NOT RUN"
FAILURES=0

info() {
    printf '\n[INFO] %s\n' "$*"
}

pass() {
    printf '[PASS] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*"
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

# ==================================================
# PERSISTENT SSH SESSION
# ==================================================

if [[ "${1:-}" != "--inside-tmux" ]]; then

    (( EUID == 0 )) || {
        error "Run with sudo."
        exit 1
    }

    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || {
        error "Run sudo from a technician account."
        exit 1
    }

    [[ -t 0 ]] || {
        error "An interactive SSH terminal is required."
        exit 1
    }

    if ! command -v tmux >/dev/null 2>&1; then
        apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y tmux || exit 1
    fi

    SCRIPT="$(realpath "$0")"
    printf -v SCRIPT_Q '%q' "$SCRIPT"

    printf 'Persistent session: %s\n' "$SESSION"
    printf 'After reconnecting: tmux attach -t %s\n' "$SESSION"

    exec runuser -u "$SUDO_USER" -- tmux new-session -A -s "$SESSION" \
        "sudo env TMUX=\"\$TMUX\" bash $SCRIPT_Q --inside-tmux"
fi

(( EUID == 0 )) || {
    error "Root required."
    exit 1
}

[[ -n "${TMUX:-}" && -t 0 ]] || {
    error "Managed tmux session required."
    exit 1
}

touch "$LOG"
chmod 600 "$LOG"

exec > >(tee -a "$LOG") 2>&1

# ==================================================
# ERROR HANDLING
# ==================================================

finish() {
    local rc=$?

    trap - EXIT

    if (( rc != 0 )); then
        printf '\n==================================================\n'
        printf ' APOLLO DEPLOYMENT - STOPPED WITH ERROR\n'
        printf ' Step: %s\n' "$STEP"
        printf ' Exit code: %s\n' "$rc"
        printf ' Log: %s\n' "$LOG"
        printf '==================================================\n'

        read -r -p 'Press Enter to close this session...' _ </dev/tty || true
    fi
}

trap finish EXIT

trap 'error "Step: $STEP | Line: $LINENO | Command: $BASH_COMMAND | Exit: $?"' ERR

fatal() {
    error "$*"
    exit 1
}

# ==================================================
# HEADER
# ==================================================

printf '\n==================================================\n'
printf ' APOLLO COMPUTERS - UNIFI + RMM DEPLOYMENT\n'
printf ' Version %s | UniFi OS Server %s\n' "$VERSION" "$UNIFI_VERSION"
printf '==================================================\n\n'

# ==================================================
# STAGE 0 - UBUNTU AND NETWORK VALIDATION
# ==================================================

STEP="Validating Ubuntu and network"

source /etc/os-release

[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] ||
    fatal "Ubuntu Server 24.04 is required."

[[ "$(uname -m)" == x86_64 ]] ||
    fatal "x86_64 is required."

pass "Supported operating system and architecture."

read -r -p 'Client Name: ' CLIENT

[[ -n "${CLIENT//[[:space:]]/}" ]] ||
    fatal "Client name required."

CURRENT_HOST="$(hostnamectl --static 2>/dev/null || hostname)"

read -r -p "Server Hostname [$CURRENT_HOST]: " HOST

HOST="${HOST:-$CURRENT_HOST}"

[[ ${#HOST} -le 63 && "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] ||
    fatal "Invalid hostname."

ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null)" ||
    fatal "No IPv4 route. Configure Ubuntu networking first."

IFACE="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$ROUTE")"

IP="$(awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' <<< "$ROUTE")"

[[ -n "$IFACE" && -n "$IP" ]] ||
    fatal "No usable IPv4 interface/address detected."

printf '\nClient: %s\n' "$CLIENT"
printf 'Hostname: %s\n' "$HOST"
printf 'Interface: %s\n' "$IFACE"
printf 'Current IP: %s\n' "$IP"
printf 'Network: existing Ubuntu configuration (will not be modified)\n'

# Automatically continue without asking for confirmation.

command -v curl >/dev/null 2>&1 ||
    fatal "curl is required."

curl -fsS \
    --connect-timeout 15 \
    --max-time 30 \
    -o /dev/null \
    https://archive.ubuntu.com/ubuntu/ ||
    fatal "Internet connectivity check failed."

pass "Network connectivity available."

if [[ "$CURRENT_HOST" != "$HOST" ]]; then

    hostnamectl set-hostname "$HOST"

    pass "Hostname set to $HOST."

else

    pass "Keeping existing hostname $HOST."

fi

# ==================================================
# STAGE 1 - UNIFI OS SERVER
# ==================================================

install_unifi() (
    set -Eeuo pipefail

    STEP="UniFi OS Server"

    local has_main=false
    local has_updater=false

    systemctl cat uosserver.service >/dev/null 2>&1 &&
        has_main=true

    systemctl cat uosserver-updater.service >/dev/null 2>&1 &&
        has_updater=true

    if [[ "$has_main" == true && "$has_updater" == true ]]; then

        pass "Existing UniFi installation detected; skipping installer."

        info "Installed version not independently verified; no upgrade attempted."

    elif [[ "$has_main" == true || "$has_updater" == true ]]; then

        error "Partial UniFi installation detected; not overwriting it."

        return 1

    else

        info "Installing UniFi dependencies..."

        export DEBIAN_FRONTEND=noninteractive

        apt-get update || return 1

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            gnupg \
            podman \
            slirp4netns \
            uidmap \
            dbus-user-session || return 1

        install -d -m 755 "$WORKDIR" || return 1

        local installer="$WORKDIR/unifi-os-server-installer"

        info "Downloading UniFi OS Server $UNIFI_VERSION..."

        curl -fL \
            --retry 3 \
            --connect-timeout 30 \
            "$UNIFI_URL" \
            -o "$installer" || return 1

        [[ -s "$installer" ]] || {
            error "UniFi installer is empty."
            return 1
        }

        chmod 755 "$installer" || return 1

        info "Running Ubiquiti installer (vendor prompts may appear)..."

        "$installer" || return 1

    fi

    local service

    for service in uosserver.service uosserver-updater.service; do

        systemctl cat "$service" >/dev/null 2>&1 || {
            error "$service missing."
            return 1
        }

        systemctl enable "$service" || return 1

        systemctl start "$service" || return 1

        systemctl is-active --quiet "$service" || {
            error "$service not running."
            return 1
        }

        pass "$service is active."

    done

    info "Waiting for UniFi container and HTTPS interface..."

    local state
    local code
    local attempt

    for (( attempt=1; attempt<=60; attempt++ )); do

        state="$(
            runuser -u uosserver -- sh -c \
                'cd / && podman inspect --format "{{.State.Running}}" uosserver' \
                2>/dev/null || true
        )"

        code="$(
            curl -k -sS \
                -o /dev/null \
                -w '%{http_code}' \
                --connect-timeout 2 \
                --max-time 3 \
                https://127.0.0.1:11443/ \
                2>/dev/null || true
        )"

        if [[ "$state" == true && "$code" =~ ^[23][0-9][0-9]$ ]]; then

            pass "UniFi container and HTTPS UI ready (HTTP $code)."

            return 0

        fi

        sleep 3

    done

    error "UniFi container/HTTPS UI did not become ready."

    error "Inspect: sudo journalctl -u uosserver.service -n 80 --no-pager"

    return 1
)

# ==================================================
# STAGE 2 - DATTO RMM
# ==================================================

install_rmm() (
    set -Eeuo pipefail

    STEP="Datto RMM"

    # Never embed site enrollment tokens in public GitHub.

    if systemctl is-active --quiet cag.service; then

        pass "Datto RMM agent service already active; not reinstalling."

        return 0

    fi

    if systemctl cat cag.service >/dev/null 2>&1; then

        info "Existing Datto RMM service detected; attempting to start it."

        systemctl enable cag.service || return 1

        systemctl start cag.service || return 1

        systemctl is-active --quiet cag.service || {
            error "cag.service is not active."
            return 1
        }

        pass "Datto RMM service active. Confirm device appears in RMM console."

        return 0

    fi

    printf '\nDatto RMM enrollment requires your approved, site-specific Linux installer.\n'
    printf 'Do not put the enrollment URL or token into public GitHub.\n'

    read -r -p \
        'Local path to approved Datto Linux installer (Enter to skip): ' \
        RMM_FILE

    if [[ -z "$RMM_FILE" ]]; then

        warn "Datto RMM not installed: no approved installer supplied."

        return 2

    fi

    if [[ ! -f "$RMM_FILE" ]]; then

        error "Datto installer file not found: $RMM_FILE"

        return 1

    fi

    info "Running approved local Datto installer..."

    bash "$RMM_FILE" || return 1

    systemctl is-active --quiet cag.service || {
        error "Datto agent service is not active after installation."
        return 1
    }

    pass "Datto RMM service active. Confirm enrollment in RMM console."
)

# ==================================================
# RUN INDEPENDENT INSTALLATION STAGES
# ==================================================

STEP="UniFi OS Server"

info "Stage 1/2: UniFi OS Server"

if install_unifi; then

    UNIFI_STATUS="PASS"

else

    UNIFI_STATUS="FAILED"

    (( FAILURES+=1 ))

    error "UniFi stage failed; proceeding to RMM."

fi

STEP="Datto RMM"

info "Stage 2/2: Datto RMM"

if install_rmm; then

    RMM_STATUS="PASS"

else

    rc=$?

    if (( rc == 2 )); then

        RMM_STATUS="SKIPPED (installer not supplied)"

    else

        RMM_STATUS="FAILED"

        (( FAILURES+=1 ))

    fi

fi

# ==================================================
# DEPLOYMENT SUMMARY
# ==================================================

STEP="Deployment summary"

printf '\n==================================================\n'
printf ' APOLLO DEPLOYMENT SUMMARY\n'
printf ' Client: %s\n' "$CLIENT"
printf ' Hostname: %s\n' "$HOST"
printf ' IP: %s\n' "$IP"
printf ' UniFi OS Server: %s\n' "$UNIFI_STATUS"
printf ' Datto RMM: %s\n' "$RMM_STATUS"

if [[ "$UNIFI_STATUS" == PASS ]]; then

    printf ' UniFi UI: https://%s:11443/\n' "$IP"

fi

printf ' Log: %s\n' "$LOG"
printf '==================================================\n'

printf 'Remaining: complete UniFi registration, confirm Datto enrollment, verify reboot, adopt devices.\n'

if (( FAILURES > 0 )); then

    error "Deployment completed with $FAILURES failed component(s)."

    read -r -p 'Press Enter to close this session...' _ </dev/tty || true

    exit 1

fi

if [[ "$RMM_STATUS" == SKIPPED* ]]; then

    warn "UniFi completed, but RMM installation was skipped."

else

    pass "UniFi and RMM stages completed."

fi
