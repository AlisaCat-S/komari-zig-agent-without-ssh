#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

readonly REPOSITORY="AlisaCat-S/komari-zig-agent-without-ssh"
readonly SERVICE_NAME="komari-agent"
readonly SERVICE_USER="komari"
readonly SERVICE_GROUP="komari"
VERSION="${KOMARI_VERSION:-latest}"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

group_exists() {
    grep -q "^${SERVICE_GROUP}:" /etc/group 2>/dev/null
}

download() {
    asset="$1"
    log "Downloading ${asset} from ${REPOSITORY} (${VERSION})"
    case "$DOWNLOADER" in
        curl)
            curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
                --output "${TEMP_DIR}/${asset}" "${RELEASE_BASE}/${asset}"
            ;;
        uclient-fetch)
            uclient-fetch -q -O "${TEMP_DIR}/${asset}" "${RELEASE_BASE}/${asset}"
            ;;
        wget)
            wget -q -O "${TEMP_DIR}/${asset}" "${RELEASE_BASE}/${asset}"
            ;;
        *) fail "internal error: unsupported downloader ${DOWNLOADER}" ;;
    esac
}

select_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER=curl
    elif command -v uclient-fetch >/dev/null 2>&1; then
        DOWNLOADER=uclient-fetch
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER=wget
    else
        fail "curl, uclient-fetch, or wget is required for HTTPS downloads"
    fi
}

hash_file() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{ print $1 }'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$file"
    else
        fail "sha256sum, shasum, or sha256 is required"
    fi
}

verify() {
    asset="$1"
    expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "${TEMP_DIR}/SHA256SUMS")"
    [ "${#expected}" -eq 64 ] || fail "SHA256SUMS does not contain a valid hash for ${asset}"
    actual="$(hash_file "${TEMP_DIR}/${asset}")"
    [ "$actual" = "$expected" ] || fail "SHA-256 verification failed for ${asset}"
}

detect_linux_init() {
    if command -v uci >/dev/null 2>&1 && [ -f /etc/rc.common ]; then
        printf '%s\n' procd
    elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        printf '%s\n' systemd
    elif command -v rc-service >/dev/null 2>&1; then
        printf '%s\n' openrc
    elif command -v initctl >/dev/null 2>&1; then
        printf '%s\n' upstart
    else
        printf '%s\n' unknown
    fi
}

ensure_linux_account() {
    if ! group_exists; then
        if command -v groupadd >/dev/null 2>&1; then
            groupadd --system "$SERVICE_GROUP"
        elif command -v addgroup >/dev/null 2>&1; then
            addgroup -S "$SERVICE_GROUP" 2>/dev/null || \
                addgroup --system "$SERVICE_GROUP" 2>/dev/null || \
                addgroup "$SERVICE_GROUP"
        else
            fail "cannot create the ${SERVICE_GROUP} group"
        fi
    fi

    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd --system --gid "$SERVICE_GROUP" --home-dir "$STATE_DIR" --shell /usr/sbin/nologin --no-create-home "$SERVICE_USER"
        elif command -v adduser >/dev/null 2>&1; then
            adduser --system --no-create-home --ingroup "$SERVICE_GROUP" "$SERVICE_USER" 2>/dev/null || \
                adduser -S -D -H -G "$SERVICE_GROUP" "$SERVICE_USER" 2>/dev/null || \
                adduser -D -H -G "$SERVICE_GROUP" "$SERVICE_USER" 2>/dev/null || \
                fail "cannot create the ${SERVICE_USER} user"
        else
            fail "cannot create the ${SERVICE_USER} user"
        fi
    fi
}

ensure_freebsd_account() {
    require_command pw
    if ! pw groupshow "$SERVICE_GROUP" >/dev/null 2>&1; then
        pw groupadd "$SERVICE_GROUP"
    fi
    if ! pw usershow "$SERVICE_USER" >/dev/null 2>&1; then
        pw useradd "$SERVICE_USER" -g "$SERVICE_GROUP" -d /nonexistent -s /usr/sbin/nologin
    fi
}

stop_existing_service() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true ;;
        openrc) rc-service "$SERVICE_NAME" stop 2>/dev/null || true ;;
        procd) [ -x "/etc/init.d/${SERVICE_NAME}" ] && "/etc/init.d/${SERVICE_NAME}" stop 2>/dev/null || true ;;
        upstart) initctl stop "$SERVICE_NAME" 2>/dev/null || true ;;
        freebsd) service "$SERVICE_NAME" stop 2>/dev/null || true ;;
        launchd) launchctl bootout "gui/$(id -u)" "$UNIT_PATH" 2>/dev/null || true ;;
    esac
}

prepare_directories_and_config() {
    CONFIG_EXISTED=false
    if [ -f "$CONFIG_PATH" ]; then
        CONFIG_EXISTED=true
    fi

    mkdir -p "$STATE_DIR" "$CONFIG_DIR"
    if [ "$OS_NAME" = darwin ]; then
        chmod 0700 "$STATE_DIR" "$CONFIG_DIR"
    else
        chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR"
        chmod 0750 "$STATE_DIR"
        chown root:"$SERVICE_GROUP" "$CONFIG_DIR"
        chmod 0750 "$CONFIG_DIR"
    fi

    if [ "$CONFIG_EXISTED" = false ]; then
        cp "${TEMP_DIR}/config.json.example" "$CONFIG_PATH"
    fi
    if [ "$OS_NAME" = darwin ]; then
        chmod 0600 "$CONFIG_PATH"
    else
        chown root:"$SERVICE_GROUP" "$CONFIG_PATH"
        chmod 0640 "$CONFIG_PATH"
    fi
}

install_binary() {
    mkdir -p "$(dirname "$BINARY_PATH")"
    cp "${TEMP_DIR}/${ASSET}" "${BINARY_PATH}.new"
    if [ "$OS_NAME" = darwin ]; then
        chmod 0755 "${BINARY_PATH}.new"
    else
        chown root:root "${BINARY_PATH}.new"
        chmod 0555 "${BINARY_PATH}.new"
    fi
    mv -f "${BINARY_PATH}.new" "$BINARY_PATH"
}

install_systemd_service() {
    cp "${TEMP_DIR}/komari-agent.service" "$UNIT_PATH"
    chown root:root "$UNIT_PATH"
    chmod 0644 "$UNIT_PATH"
    systemctl daemon-reload
    if [ "$CONFIG_EXISTED" = true ]; then
        systemctl enable --now "${SERVICE_NAME}.service"
    fi
}

install_openrc_service() {
    UNIT_PATH="/etc/init.d/${SERVICE_NAME}"
    cat > "$UNIT_PATH" <<EOF
#!/sbin/openrc-run
name="Komari monitoring agent"
description="Komari monitoring-only agent"
command="${BINARY_PATH}"
command_args="--config ${CONFIG_PATH}"
command_user="${SERVICE_USER}:${SERVICE_GROUP}"
directory="${STATE_DIR}"
pidfile="/run/${SERVICE_NAME}.pid"
retry="SIGTERM/30"
supervisor=supervise-daemon
depend() { need net; after network; }
EOF
    chmod 0755 "$UNIT_PATH"
    if [ "$CONFIG_EXISTED" = true ]; then
        rc-update add "$SERVICE_NAME" default
        rc-service "$SERVICE_NAME" restart
    fi
}

install_procd_service() {
    UNIT_PATH="/etc/init.d/${SERVICE_NAME}"
    cat > "$UNIT_PATH" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command "${BINARY_PATH}" --config "${CONFIG_PATH}"
    procd_set_param user "${SERVICE_USER}"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod 0755 "$UNIT_PATH"
    if [ "$CONFIG_EXISTED" = true ]; then
        "$UNIT_PATH" enable
        "$UNIT_PATH" restart
    fi
}

install_upstart_service() {
    UNIT_PATH="/etc/init/${SERVICE_NAME}.conf"
    cat > "$UNIT_PATH" <<EOF
description "Komari monitoring-only agent"
start on filesystem or runlevel [2345]
stop on runlevel [!2345]
respawn
respawn limit 10 5
setuid ${SERVICE_USER}
setgid ${SERVICE_GROUP}
chdir ${STATE_DIR}
exec ${BINARY_PATH} --config ${CONFIG_PATH}
EOF
    if [ "$CONFIG_EXISTED" = true ]; then
        initctl reload-configuration
        initctl restart "$SERVICE_NAME" || initctl start "$SERVICE_NAME"
    fi
}

install_freebsd_service() {
    UNIT_PATH="/usr/local/etc/rc.d/${SERVICE_NAME}"
    cat > "$UNIT_PATH" <<EOF
#!/bin/sh
# PROVIDE: komari_agent
# REQUIRE: NETWORKING
# KEYWORD: shutdown
. /etc/rc.subr

name="komari_agent"
rcvar="komari_agent_enable"
command="/usr/sbin/daemon"
pidfile="/var/run/komari-agent.pid"
procname="${BINARY_PATH}"
command_args="-f -u ${SERVICE_USER} -p \$pidfile ${BINARY_PATH} --config ${CONFIG_PATH}"
load_rc_config "\$name"
: \${komari_agent_enable:="NO"}
run_rc_command "\$1"
EOF
    chown root:wheel "$UNIT_PATH"
    chmod 0555 "$UNIT_PATH"
    if [ "$CONFIG_EXISTED" = true ]; then
        if command -v sysrc >/dev/null 2>&1; then
            sysrc komari_agent_enable=YES >/dev/null
        else
            mkdir -p /etc/rc.conf.d
            printf '%s\n' 'komari_agent_enable="YES"' > /etc/rc.conf.d/komari_agent
        fi
        service "$SERVICE_NAME" restart
    fi
}

install_launchd_service() {
    UNIT_PATH="$HOME/Library/LaunchAgents/com.komari.agent.plist"
    mkdir -p "$(dirname "$UNIT_PATH")"
    cat > "$UNIT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.komari.agent</string>
  <key>ProgramArguments</key><array>
    <string>${BINARY_PATH}</string>
    <string>--config</string>
    <string>${CONFIG_PATH}</string>
  </array>
  <key>WorkingDirectory</key><string>${STATE_DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF
    if [ "$CONFIG_EXISTED" = true ]; then
        launchctl bootstrap "gui/$(id -u)" "$UNIT_PATH"
    fi
}

require_command grep
select_downloader

case "$(uname -s)" in
    Linux)
        OS_NAME=linux
        INIT_SYSTEM="$(detect_linux_init)"
        [ "$INIT_SYSTEM" != unknown ] || fail "unsupported Linux init system"
        if [ "$INIT_SYSTEM" = procd ]; then
            BINARY_PATH="/usr/bin/${SERVICE_NAME}"
        else
            BINARY_PATH="/usr/local/bin/${SERVICE_NAME}"
        fi
        CONFIG_DIR="/etc/${SERVICE_NAME}"
        CONFIG_PATH="${CONFIG_DIR}/config.json"
        STATE_DIR="/var/lib/${SERVICE_NAME}"
        UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
        [ "$(id -u)" -eq 0 ] || fail "run this installer as root, for example: sudo ./install.sh"
        ensure_linux_account
        ;;
    FreeBSD)
        OS_NAME=freebsd
        INIT_SYSTEM=freebsd
        BINARY_PATH="/usr/local/bin/${SERVICE_NAME}"
        CONFIG_DIR="/usr/local/etc/${SERVICE_NAME}"
        CONFIG_PATH="${CONFIG_DIR}/config.json"
        STATE_DIR="/var/db/${SERVICE_NAME}"
        UNIT_PATH="/usr/local/etc/rc.d/${SERVICE_NAME}"
        [ "$(id -u)" -eq 0 ] || fail "run this installer as root"
        ensure_freebsd_account
        ;;
    Darwin)
        OS_NAME=darwin
        INIT_SYSTEM=launchd
        [ "$(id -u)" -ne 0 ] || fail "on macOS, run this installer as the login user, not root"
        BINARY_PATH="$HOME/.local/bin/${SERVICE_NAME}"
        CONFIG_DIR="$HOME/Library/Application Support/KomariAgent"
        CONFIG_PATH="${CONFIG_DIR}/config.json"
        STATE_DIR="$HOME/Library/Application Support/KomariAgent/state"
        UNIT_PATH="$HOME/Library/LaunchAgents/com.komari.agent.plist"
        ;;
    *) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    i386|i486|i586|i686) ARCH=386 ;;
    armv6*|armv7*) ARCH=arm ;;
    mips) ARCH=mips ;;
    mipsel) ARCH=mipsel ;;
    mips64) ARCH=mips64 ;;
    mips64el) ARCH=mips64el ;;
    riscv64) ARCH=riscv64 ;;
    s390x) ARCH=s390x ;;
    loongarch64|loong64) ARCH=loong64 ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
esac

case "$VERSION" in
    latest)
        RELEASE_BASE="https://github.com/${REPOSITORY}/releases/latest/download"
        ;;
    *)
        if ! printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
            fail "KOMARI_VERSION must be latest or a tag such as v0.1.42.1"
        fi
        RELEASE_BASE="https://github.com/${REPOSITORY}/releases/download/${VERSION}"
        ;;
esac

require_command awk
require_command mktemp
ASSET="komari-agent-${OS_NAME}-${ARCH}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

stop_existing_service
download "SHA256SUMS"
download "$ASSET"
download "config.json.example"
verify "$ASSET"
verify "config.json.example"
if [ "$INIT_SYSTEM" = systemd ]; then
    download "komari-agent.service"
    verify "komari-agent.service"
fi

prepare_directories_and_config
install_binary
case "$INIT_SYSTEM" in
    systemd) install_systemd_service ;;
    openrc) install_openrc_service ;;
    procd) install_procd_service ;;
    upstart) install_upstart_service ;;
    freebsd) install_freebsd_service ;;
    launchd) install_launchd_service ;;
esac

if [ "$CONFIG_EXISTED" = true ]; then
    log "Installed ${ASSET} from ${REPOSITORY} and started ${SERVICE_NAME}."
else
    log "Installed ${ASSET} from ${REPOSITORY}."
    log "Edit ${CONFIG_PATH} with the panel endpoint and token, then start ${SERVICE_NAME} using the platform service manager."
fi
