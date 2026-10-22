#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

readonly REPOSITORY="AlisaCat-S/komari-zig-agent-without-ssh"
readonly SERVICE_NAME="komari-agent"
readonly SERVICE_USER="komari"
readonly SERVICE_GROUP="komari"
VERSION="${KOMARI_VERSION:-latest}"
CONFIG_OVERRIDES=""
HAS_ENDPOINT=false
HAS_AUTH=false

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

usage() {
    cat <<'EOF'
Usage: install.sh [options]
  -e, --endpoint URL          Panel endpoint
  -t, --token TOKEN           Agent token
  -i, --interval SECONDS      Reporting interval (> 0)
  -r, --max-retries COUNT     Retry count (>= 0)
  -c, --reconnect-interval N  Reconnect delay in seconds (>= 0)
      --install-version TAG  latest or a fork release tag
      --help                 Show this help
Monitoring options: --info-report-interval, --protocol-version, --prefer-ip-version,
--include-nics, --exclude-nics, --include-mountpoint, --month-rotate,
--cf-access-client-id, --cf-access-client-secret, --custom-dns, --custom-ipv4,
--custom-ipv6, --memory-include-cache, --memory-exclude-bcf, --disable-compression,
--gpu, --debug-log, --get-ip-addr-from-nic. Boolean flags accept =true or =false.
Auto-discovery, remote-control, self-update, proxy, custom install-dir/service-name options are unsupported.
Without options, an existing config is preserved; a new install waits for manual config.
Replacing a detected legacy agent requires confirmation on /dev/tty (default: No).
EOF
}

json_string() {
    JSON_VALUE="$1" awk 'BEGIN {
        s = ENVIRON["JSON_VALUE"]; printf "\""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\"" || c == "\\") printf "\\%s", c
            else if (c == "\n") printf "\\n"
            else if (c == "\r") printf "\\r"
            else if (c == "\t") printf "\\t"
            else {
                control=0
                for (j=1; j<32; j++) if (c == sprintf("%c",j)) { printf "\\u%04x",j; control=1; break }
                if (!control) printf "%s", c
            }
        }
        printf "\""
    }'
}

parse_options() {
    while [ "$#" -gt 0 ]; do
        option=${1%%=*}
        case "$option" in
            -h|--help) usage; exit 0 ;;
            --install-version) key=version; kind=string ;;
            -e|--endpoint) key=endpoint; kind=string; HAS_ENDPOINT=true ;;
            -t|--token) key=token; kind=string; HAS_AUTH=true ;;
            -i|--interval) key=interval; kind=positive ;;
            -r|--max-retries) key=max_retries; kind=integer ;;
            -c|--reconnect-interval) key=reconnect_interval; kind=integer ;;
            --info-report-interval) key=info_report_interval; kind=integer ;;
            --protocol-version) key=protocol_version; kind=protocol ;;
            --prefer-ip-version) key=prefer_ip_version; kind=ip ;;
            --include-nics) key=include_nics; kind=string ;;
            --exclude-nics) key=exclude_nics; kind=string ;;
            --include-mountpoint) key=include_mountpoints; kind=string ;;
            --month-rotate) key=month_rotate; kind=month ;;
            --cf-access-client-id) key=cf_access_client_id; kind=string ;;
            --cf-access-client-secret) key=cf_access_client_secret; kind=string ;;
            --custom-dns) key=custom_dns; kind=string ;;
            --custom-ipv4) key=custom_ipv4; kind=string ;;
            --custom-ipv6) key=custom_ipv6; kind=string ;;
            --memory-include-cache) key=memory_include_cache; kind=bool ;;
            --memory-exclude-bcf) key=memory_report_raw_used; kind=bool ;;
            --disable-compression) key=disable_compression; kind=bool ;;
            --gpu) key=enable_gpu; kind=bool ;;
            --debug-log) key=debug_log; kind=bool ;;
            --get-ip-addr-from-nic) key=get_ip_addr_from_nic; kind=bool ;;
            *) fail "unsupported option: $option (see --help)" ;;
        esac
        case "$1" in
            *=*) value=${1#*=}; shift ;;
            *)
                shift
                if [ "$kind" = bool ]; then value=true
                else
                    [ "$#" -gt 0 ] || fail "missing value for $option"
                    case "$1" in -*) fail "missing value for $option" ;; esac
                    value=$1; shift
                fi ;;
        esac
        [ -n "$value" ] || fail "empty value for $option"
        case "$kind" in
            string|ip)
                if [ "$kind" = ip ]; then
                    case "$value" in 4|6) ;; *) fail "$option must be 4 or 6" ;; esac
                fi
                encoded=$(json_string "$value") ;;
            bool)
                case "$value" in true|false) encoded=$value ;; *) fail "$option must be true or false" ;; esac ;;
            *)
                case "$kind" in
                    positive) pattern='^(0|[1-9][0-9]*)(\.[0-9]+)?$' ;;
                    *) pattern='^(0|[1-9][0-9]*)$' ;;
                esac
                printf '%s' "$value" | grep -Eq "$pattern" || fail "invalid number for $option"
                case "$kind" in
                    positive) awk -v n="$value" 'BEGIN { exit !(n > 0 && n <= 2147483647) }' || fail "invalid interval" ;;
                    protocol) case "$value" in 1|2) ;; *) fail "protocol version must be 1 or 2" ;; esac ;;
                    month) [ "$value" -le 31 ] || fail "month rotation must be 0..31" ;;
                    *) [ "$value" -le 2147483647 ] || fail "number too large for $option" ;;
                esac
                encoded=$value ;;
        esac
        if [ "$key" = version ]; then VERSION=$value
        else
            CONFIG_OVERRIDES="${CONFIG_OVERRIDES}${CONFIG_OVERRIDES:+,}\"${key}\":${encoded}"
            # Explicit token authentication supersedes any old auto-discovery setting.
            if [ "$key" = token ]; then CONFIG_OVERRIDES="${CONFIG_OVERRIDES},\"auto_discovery_key\":\"\""; fi
        fi
    done
}

# Split JSON object members only at top-level commas, preserving strings and nested values.
# The config schema is flat, but unknown members are retained when options override it.
merge_config() {
    OVERRIDES="$CONFIG_OVERRIDES" awk '
    function member(s, p, k) {
        if (s ~ /^[[:space:]]*$/) return
        p = index(s, ":"); if (!p) exit 1
        k = substr(s, 1, p - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (!(k in values)) keys[++count] = k
        values[k] = substr(s, p + 1)
    }
    function object(s, i, c, quoted, escaped, depth, part) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        if (substr(s,1,1) != "{" || substr(s,length(s),1) != "}") exit 1
        s = substr(s, 2, length(s)-2)
        for (i=1; i<=length(s); i++) {
            c=substr(s,i,1)
            if (quoted) {
                if (escaped) escaped=0
                else if (c == "\\") escaped=1
                else if (c == "\"") quoted=0
            } else if (c == "\"") quoted=1
            else if (c == "{" || c == "[") depth++
            else if (c == "}" || c == "]") depth--
            else if (c == "," && depth == 0) { member(part); part=""; continue }
            part=part c
        }
        if (quoted || depth) exit 1
        member(part)
    }
    { input=input $0 "\n" }
    END {
        object(input); object("{" ENVIRON["OVERRIDES"] "}")
        print "{"
        for (i=1; i<=count; i++) printf "  %s:%s%s\n", keys[i], values[keys[i]], (i<count ? "," : "")
        print "}"
    }' "$1" > "$2" || fail "cannot merge config; existing config was not changed"
}

confirm_legacy_replacement() {
    LEGACY_BINARY=""
    case "$OS_NAME" in
        linux|freebsd) legacy_candidates="/opt/komari/agent /usr/local/komari/agent" ;;
        darwin) legacy_candidates="" # macOS user path may contain spaces.
            if [ -f "$HOME/.komari/agent" ]; then LEGACY_BINARY="$HOME/.komari/agent"; fi
            [ ! -f /Library/LaunchDaemons/com.komari.komari-agent.plist ] ||
                fail "uninstall the system-wide official launchd agent as root before installing the user agent"
            ;;
    esac
    for candidate in $legacy_candidates; do
        if [ -f "$candidate" ]; then
            [ -z "$LEGACY_BINARY" ] || fail "multiple legacy agents found; uninstall them manually first"
            LEGACY_BINARY=$candidate
        fi
    done
    LEGACY_UNIT=$UNIT_PATH
    if [ "$OS_NAME" = darwin ]; then LEGACY_UNIT="$HOME/Library/LaunchAgents/com.komari.komari-agent.plist"; fi
    if [ -z "$LEGACY_BINARY" ] && [ ! -f "$LEGACY_UNIT" ]; then return; fi
    # Our service always uses this config; an old same-name service is a replacement.
    if [ -z "$LEGACY_BINARY" ] && grep -Fq -- "$CONFIG_PATH" "$LEGACY_UNIT"; then return; fi
    log "Detected a legacy/official Komari agent. Replace it with the monitoring-only Zig agent? [y/N]"
    answer=""
    if ! { IFS= read -r answer </dev/tty; } 2>/dev/null; then
        fail "replacement requires an interactive terminal; rerun from a terminal"
    fi
    case "$answer" in y|Y|yes|YES) REPLACE_LEGACY=true ;;
        *) log "Cancelled; existing agent was not changed."; exit 0 ;;
    esac
}

backup_legacy() {
    [ "$REPLACE_LEGACY" = true ] || return 0
    BACKUP_DIR=$(mktemp -d "${CONFIG_DIR}/previous-agent.XXXXXX")
    [ ! -f "$LEGACY_UNIT" ] || cp -p "$LEGACY_UNIT" "$BACKUP_DIR/service"
    [ -z "$LEGACY_BINARY" ] || cp -p "$LEGACY_BINARY" "$BACKUP_DIR/agent"
    [ ! -f "$CONFIG_PATH" ] || cp -p "$CONFIG_PATH" "$BACKUP_DIR/config.json"
    printf 'service=%s\nagent=%s\nconfig=%s\n' "$LEGACY_UNIT" "$LEGACY_BINARY" "$CONFIG_PATH" > "$BACKUP_DIR/restore-paths.txt"
    log "Previous agent backup: $BACKUP_DIR (restore its service and binary to roll back)."
}

remove_legacy() {
    [ "$REPLACE_LEGACY" = true ] || return 0
    if [ -f "$LEGACY_UNIT" ]; then
        case "$INIT_SYSTEM" in
            systemd) systemctl disable "${SERVICE_NAME}.service" ;;
            openrc) rc-update del "$SERVICE_NAME" default ;;
            procd) "$UNIT_PATH" disable ;;
        esac
    fi
    [ ! -f "$LEGACY_UNIT" ] || rm -f "$LEGACY_UNIT"
    [ -z "$LEGACY_BINARY" ] || rm -f "$LEGACY_BINARY"
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
    if [ "$REPLACE_LEGACY" = true ] && [ -f "$LEGACY_UNIT" ]; then
        case "$INIT_SYSTEM" in
            systemd) systemctl stop "${SERVICE_NAME}.service" ;;
            openrc) rc-service "$SERVICE_NAME" stop ;;
            procd) "$UNIT_PATH" stop ;;
            upstart) initctl stop "$SERVICE_NAME" ;;
            freebsd) service "$SERVICE_NAME" stop ;;
            launchd) launchctl bootout "gui/$(id -u)" "$LEGACY_UNIT" ;;
        esac
        return
    fi
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

    cp "${TEMP_DIR}/config.json" "${CONFIG_PATH}.new"
    if [ "$OS_NAME" = darwin ]; then
        chmod 0600 "${CONFIG_PATH}.new"
    else
        chown root:"$SERVICE_GROUP" "${CONFIG_PATH}.new"
        chmod 0640 "${CONFIG_PATH}.new"
    fi
    mv -f "${CONFIG_PATH}.new" "$CONFIG_PATH"
    if [ "$HAS_ENDPOINT" = true ] && [ "$HAS_AUTH" = true ]; then CONFIG_EXISTED=true; fi
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

# Installer entrypoint.
require_command grep
require_command awk
parse_options "$@"
select_downloader
REPLACE_LEGACY=false

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
        case "$INIT_SYSTEM" in
            openrc|procd) UNIT_PATH="/etc/init.d/${SERVICE_NAME}" ;;
            upstart) UNIT_PATH="/etc/init/${SERVICE_NAME}.conf" ;;
        esac
        [ "$(id -u)" -eq 0 ] || fail "run this installer as root, for example: sudo ./install.sh"
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

confirm_legacy_replacement
if [ "$HAS_ENDPOINT" != "$HAS_AUTH" ]; then
    fail "supply --endpoint and --token together"
fi
if [ "$REPLACE_LEGACY" = true ] && { [ "$HAS_ENDPOINT" != true ] || [ "$HAS_AUTH" != true ]; }; then
    fail "replacing a legacy agent requires --endpoint and --token"
fi

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

download "SHA256SUMS"
download "$ASSET"
download "config.json.example"
verify "$ASSET"
verify "config.json.example"
if [ "$INIT_SYSTEM" = systemd ]; then
    download "komari-agent.service"
    verify "komari-agent.service"
fi

# Stage configuration before stopping anything. CLI options override only named fields.
CONFIG_SOURCE="${TEMP_DIR}/config.json.example"
if [ -f "$CONFIG_PATH" ]; then CONFIG_SOURCE=$CONFIG_PATH; fi
if [ -n "$CONFIG_OVERRIDES" ]; then
    merge_config "$CONFIG_SOURCE" "${TEMP_DIR}/config.json"
else
    cp "$CONFIG_SOURCE" "${TEMP_DIR}/config.json"
fi
case "$OS_NAME" in
    linux) ensure_linux_account ;;
    freebsd) ensure_freebsd_account ;;
esac
mkdir -p "$CONFIG_DIR"
backup_legacy
stop_existing_service
remove_legacy
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
