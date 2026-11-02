#!/usr/bin/env bash
# ============================================================
# Apollo Computers - UniFi OS Server + Datto RMM Deployment
# Version 2.8
# Supported OS: Ubuntu Server 24.04 LTS (x86_64)
# ============================================================

set -Eeuo pipefail
umask 077

VERSION="2.8"
UNIFI_VERSION="5.1.42"

UNIFI_URL="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"

WORKDIR="/opt/apollo-unifi"
LOG="/var/log/apollo-unifi-deployment.log"

STEP="Startup"

UNIFI_STATUS="NOT RUN"
RMM_STATUS="NOT RUN"

FAILURES=0

CLIENT=""
HOST=""
IP=""

# ============================================================
# OUTPUT FUNCTIONS
# ============================================================

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

# ============================================================
# ROOT VALIDATION
# ============================================================

if (( EUID != 0 )); then
    error "Run this script using sudo."
    exit 1
fi

# ============================================================
# LOGGING
# ============================================================

touch "$LOG"
chmod 600 "$LOG"

exec > >(tee -a "$LOG") 2>&1

# ============================================================
# ERROR HANDLING
# ============================================================

trap 'rc=$?; error "Unexpected error at line $LINENO (exit code $rc). Step: $STEP"' ERR

fatal() {
    error "$*"
    error "Deployment stopped during: $STEP"
    error "Log: $LOG"
    exit 1
}

# ============================================================
# HEADER
# ============================================================

printf '\n==================================================\n'
printf ' APOLLO COMPUTERS - SERVER DEPLOYMENT\n'
printf ' Version: %s\n' "$VERSION"
printf ' UniFi OS Server: %s\n' "$UNIFI_VERSION"
printf '==================================================\n\n'

# ============================================================
# STAGE 0 - SYSTEM AND NETWORK VALIDATION
# ============================================================

STEP="System and network validation"

source /etc/os-release

[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] ||
    fatal "Ubuntu Server 24.04 LTS is required."

[[ "$(uname -m)" == x86_64 ]] ||
    fatal "This deployment requires x86_64 architecture."

pass "Supported operating system and architecture."

read -r -p "Client Name: " CLIENT

[[ -n "${CLIENT//[[:space:]]/}" ]] ||
    fatal "Client name cannot be empty."

CURRENT_HOST="$(hostnamectl --static 2>/dev/null || hostname)"

read -r -p "Server Hostname [$CURRENT_HOST]: " HOST

HOST="${HOST:-$CURRENT_HOST}"

[[ ${#HOST} -le 63 && "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] ||
    fatal "Invalid hostname."

ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null)" ||
    fatal "No IPv4 route detected. Configure networking first."

IFACE="$(
    awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' \
    <<< "$ROUTE"
)"

IP="$(
    awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' \
    <<< "$ROUTE"
)"

[[ -n "$IFACE" && -n "$IP" ]] ||
    fatal "No usable IPv4 address detected."

printf '\n'
printf 'Client: %s\n' "$CLIENT"
printf 'Hostname: %s\n' "$HOST"
printf 'Interface: %s\n' "$IFACE"
printf 'Current IP: %s\n' "$IP"
printf 'Network: Existing Ubuntu configuration\n'

# Networking was configured during Ubuntu installation.
# Do not modify it or request confirmation.

command -v curl >/dev/null 2>&1 ||
    fatal "curl is required."

info "Checking internet connectivity..."

curl -fsS \
    --connect-timeout 15 \
    --max-time 30 \
    -o /dev/null \
    https://archive.ubuntu.com/ubuntu/ ||
    fatal "Internet connectivity check failed."

pass "Network connectivity available."

if [[ "$CURRENT_HOST" != "$HOST" ]]; then

    hostnamectl set-hostname "$HOST" ||
        fatal "Failed to update hostname."

    pass "Hostname updated to $HOST."

else

    pass "Keeping existing hostname $HOST."

fi

# ============================================================
# STAGE 1 - UNIFI OS SERVER
# ============================================================

install_unifi() {

    local has_main=false
    local has_updater=false

    local service
    local state
    local code
    local attempt

    info "Checking UniFi OS Server installation..."

    if systemctl cat uosserver.service >/dev/null 2>&1; then
        has_main=true
    fi

    if systemctl cat uosserver-updater.service >/dev/null 2>&1; then
        has_updater=true
    fi

    if [[ "$has_main" == true && "$has_updater" == true ]]; then

        pass "Existing UniFi installation detected."
        info "Skipping UniFi installer."

    elif [[ "$has_main" == true || "$has_updater" == true ]]; then

        error "Partial UniFi installation detected."
        error "Manual repair is required before continuing."

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

        mkdir -p "$WORKDIR" || return 1

        local installer="$WORKDIR/unifi-os-server-installer"

        info "Downloading UniFi OS Server $UNIFI_VERSION..."

        curl -fL \
            --retry 3 \
            --connect-timeout 30 \
            "$UNIFI_URL" \
            -o "$installer" || return 1

        [[ -s "$installer" ]] || {
            error "Downloaded UniFi installer is empty."
            return 1
        }

        chmod 755 "$installer" || return 1

        info "Running UniFi OS Server installer..."

        "$installer" || return 1

    fi

    info "Checking UniFi services..."

    for service in \
        uosserver.service \
        uosserver-updater.service
    do

        systemctl cat "$service" >/dev/null 2>&1 || {
            error "$service is missing."
            return 1
        }

        systemctl enable "$service" || return 1

        systemctl start "$service" || return 1

        systemctl is-active --quiet "$service" || {
            error "$service is not active."
            return 1
        }

        pass "$service is active."

    done

    info "Waiting for UniFi container and HTTPS interface..."

    for ((attempt=1; attempt<=60; attempt++)); do

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

            pass "UniFi container running."
            pass "UniFi HTTPS interface responding (HTTP $code)."

            return 0

        fi

        sleep 3

    done

    error "UniFi container or HTTPS interface did not become ready."

    return 1
}

# ============================================================
# STAGE 2 - DATTO RMM
# ============================================================

install_rmm() {

    local rmm_url=""
    local rmm_installer=""
    local download_status=0
    local install_status=0
    local attempt=0

    info "Checking Datto RMM installation..."

    # --------------------------------------------------------
    # CHECK FOR EXISTING AGENT
    # --------------------------------------------------------

    if systemctl is-active --quiet cag.service; then

        pass "Datto RMM service already running."
        info "Skipping RMM installation."

        return 0

    fi

    if systemctl cat cag.service >/dev/null 2>&1; then

        info "Existing Datto RMM service detected."

        systemctl enable cag.service || return 1
        systemctl start cag.service || return 1

        if systemctl is-active --quiet cag.service; then

            pass "Datto RMM service started."
            info "Confirm device enrollment in Datto RMM console."

            return 0

        fi

        error "Datto RMM service failed to start."
        return 1

    fi

    # --------------------------------------------------------
    # REQUEST CLIENT-SPECIFIC INSTALLER URL
    # --------------------------------------------------------

    printf '\n'
    printf '==================================================\n'
    printf ' DATTO RMM INSTALLATION\n'
    printf '==================================================\n'
    printf '\n'
    printf 'Open the client site in Datto RMM.\n'
    printf 'Copy the Linux agent download URL.\n'
    printf '\n'
    printf 'Paste ONLY the URL, not the entire wget command.\n'
    printf '\n'
    printf 'Press Enter without a URL to skip installation.\n'
    printf '\n'

    # Read silently so the URL is not echoed into the log.
    # The URL may contain a site-specific enrollment identifier.

    read -r -s -p "Datto RMM URL (right-click to paste; input hidden): " rmm_url
    printf '\n'

    if [[ -z "$rmm_url" ]]; then

        warn "Datto RMM installation skipped."
        return 2

    fi

    # --------------------------------------------------------
    # VALIDATE URL
    # --------------------------------------------------------

    info "Validating Datto RMM installer URL..."

    # Accept HTTPS download-agent URLs from Datto RMM hosts.
    # Reject commands, spaces, query strings, and redirects
    # to unrelated domains.

    if [[ ! "$rmm_url" =~ ^https://[a-zA-Z0-9-]+\.rmm\.datto\.com/download-agent/linux/[a-zA-Z0-9-]+/?$ ]]; then

        error "Invalid Datto RMM installer URL."
        error "Copy only the Linux download URL from Datto RMM."

        unset rmm_url
        return 1

    fi

    pass "Datto RMM URL format validated."

    # --------------------------------------------------------
    # DOWNLOAD INSTALLER
    # --------------------------------------------------------

    rmm_installer="$(mktemp /tmp/apollo-datto-rmm.XXXXXXXX.sh)" || {
        error "Unable to create temporary installer file."
        return 1
    }

    chmod 600 "$rmm_installer"

    info "Downloading Datto RMM Linux installer..."

    # Avoid printing site-specific URLs in the deployment log.
    # Do not follow redirects to arbitrary destinations.

    curl \
        --fail \
        --silent \
        --show-error \
        --proto '=https' \
        --connect-timeout 30 \
        --max-time 180 \
        --retry 3 \
        --output "$rmm_installer" \
        "$rmm_url" >/dev/null 2>&1 || download_status=$?

    unset rmm_url

    if (( download_status != 0 )); then

        error "Datto RMM installer download failed."
        error "Curl exit code: $download_status"

        rm -f "$rmm_installer"
        return 1

    fi

    if [[ ! -s "$rmm_installer" ]]; then

        error "Downloaded Datto RMM installer is empty."

        rm -f "$rmm_installer"
        return 1

    fi

    pass "Datto RMM installer downloaded."

    # --------------------------------------------------------
    # INSTALL AGENT
    # --------------------------------------------------------

    info "Installing Datto RMM agent..."

    # Datto provides a shell installer.
    # Suppress installer output to avoid leaking enrollment
    # information into the public terminal or deployment log.

    sh "$rmm_installer" >/dev/null 2>&1 || install_status=$?

    # Remove the downloaded installer regardless of result.

    rm -f "$rmm_installer"

    if (( install_status != 0 )); then

        error "Datto RMM installer failed."
        error "Installer exit code: $install_status"

        return 1

    fi

    pass "Datto RMM installer completed."

    # --------------------------------------------------------
    # VERIFY AGENT SERVICE
    # --------------------------------------------------------

    info "Waiting for Datto RMM service..."

    for ((attempt=1; attempt<=30; attempt++)); do

        if systemctl is-active --quiet cag.service; then

            pass "Datto RMM service is running."
            info "Confirm the device appears in the Datto RMM console."

            return 0

        fi

        sleep 2

    done

    error "Datto RMM service did not become active."
    error "Check service status: sudo systemctl status cag.service"

    return 1
}

# ============================================================
# RUN DEPLOYMENT STAGES INDEPENDENTLY
# ============================================================

STEP="UniFi OS Server"

info "Stage 1/2: UniFi OS Server"

if install_unifi; then

    UNIFI_STATUS="PASS"

else

    UNIFI_STATUS="FAILED"

    ((FAILURES+=1))

    error "UniFi deployment failed."
    warn "Continuing to Datto RMM installation."

fi

STEP="Datto RMM"

info "Stage 2/2: Datto RMM"

if install_rmm; then

    RMM_STATUS="PASS"

else

    RC=$?

    if (( RC == 2 )); then

        RMM_STATUS="SKIPPED"

    else

        RMM_STATUS="FAILED"

        ((FAILURES+=1))

    fi

fi

# ============================================================
# DEPLOYMENT SUMMARY
# ============================================================

STEP="Deployment summary"

printf '\n'
printf '==================================================\n'
printf ' APOLLO COMPUTERS - DEPLOYMENT SUMMARY\n'
printf '==================================================\n'

printf 'Client:           %s\n' "$CLIENT"
printf 'Hostname:         %s\n' "$HOST"
printf 'IP Address:       %s\n' "$IP"

printf '\n'
printf 'UniFi OS Server:  %s\n' "$UNIFI_STATUS"
printf 'Datto RMM:        %s\n' "$RMM_STATUS"

if [[ "$UNIFI_STATUS" == PASS ]]; then

    printf '\n'
    printf 'UniFi Management:\n'
    printf 'https://%s:11443/\n' "$IP"

fi

printf '\n'
printf 'Deployment Log:\n'
printf '%s\n' "$LOG"

printf '\n'
printf '==================================================\n'

# ============================================================
# FINAL STATUS
# ============================================================

if (( FAILURES > 0 )); then

    error "DEPLOYMENT COMPLETED WITH $FAILURES ERROR(S)."

    printf '\n'
    printf 'Review the errors above or check the deployment log.\n'
    printf '\n'

    exit 1

fi

if [[ "$RMM_STATUS" == "SKIPPED" ]]; then

    warn "UniFi deployment completed. Datto RMM was skipped."

else

    pass "UniFi and Datto RMM deployment stages completed."

fi

printf '\n'
printf 'Remaining tasks:\n'
printf ' - Complete UniFi registration\n'
printf ' - Confirm Datto RMM enrollment\n'
printf ' - Verify services after reboot\n'
printf ' - Adopt UniFi devices\n'

printf '\n'
pass "Deployment script finished."

exit 0
