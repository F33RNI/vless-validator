#!/usr/bin/env bash

# This file is part of the vless-validator distribution.
# See <https://github.com/F33RNI/vless-validator> for more info.
#
# Copyright (c) 2026 Fern Lane.
#
# This program is free software: you can redistribute it and/or modify it under the terms of the
# GNU General Public License as published by the Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this program.
# If not, see <http://www.gnu.org/licenses/>.

_VERSION="1.0.dev0"

# URL to test
if [ -f ".env" ]; then source .env; fi
TEST_URL=${TEST_URL:-http://example.com}
CONN_TIMEOUT=${CONN_TIMEOUT:-3}
MAX_TIME=${MAX_TIME:-6}
RETRIES=${RETRIES:-1}

_MAIN_LOG_PREFIX="vless-validator"
_TMP_LOG=".vless-validator_log_tmp.log"
_TMP_CONFIG=".vless-validator_config_tmp.json"

# Pre-defined sing-box config
# NOTE: Uses Google DNS over UDP because Cloudflare and/or DoH could be banned
CONFIG_LOG='"log": { "disabled": false, "level": "info", "output": "'"$_TMP_LOG"'", "timestamp": false }'
CONFIG_DNS='"dns": { "servers": [{ "type": "local", "tag": "local", "detour": "direct" }'
CONFIG_DNS+=', { "type": "udp", "tag": "google-udp", "server": "8.8.8.8", "server_port": 53, "detour": "vless-out" }]'
CONFIG_DNS+=', "strategy": "prefer_ipv4", "final": "google-udp" }'
CONFIG_ROUTE='"route": { "rules": [{ "action": "sniff" }, { "protocol": "dns", "action": "hijack-dns" }]'
CONFIG_ROUTE+=', "final": "vless-out", "default_domain_resolver": "google-udp" }'
CONFIG_OUTBOUND_DIRECT='{ "type": "direct", "tag": "direct"'
CONFIG_OUTBOUND_DIRECT+=', "domain_resolver": { "server": "local", "strategy": "prefer_ipv4" }}'

# Prints log into terminal and log file
# Args:
#   1: Text to log
LOGGER() {
    echo -e "$1"
    echo -e "$1" >>"${_MAIN_LOG_PREFIX}_${log_datetime}.log"
}

# Converts VLESS link to sing-box's outbound JSON config
# Args:
#   1: VLESS link (must start with vless://)
# Returns:
#   Parsed link in JSON format or nothing in case of error
vless_to_json() {
    local _link="$1"
    if [[ ! "$_link" == vless://* ]]; then return; fi

    # Remove scheme
    local _uri="${_link#vless://}"

    # Split profile name
    local _main="${_uri%%#*}"

    # Split query
    local _base="${_main%%\?*}"
    local _query="${_main#*\?}"

    # Parse uuid + server
    local _uuid="${_base%@*}"
    local _host_port="${_base#*@}"
    local _server="${_host_port%%:*}"
    local _port="${_host_port##*:}"

    # Check required fields
    if [ -z "$_uuid" ] || [ -z "$_server" ] || [ -z "$_port" ]; then return; fi

    # Start building config
    local _config='"type": "vless", "tag": "vless-out"'
    _config+=', "server": "'"$_server"'", "server_port": '"$_port"', "uuid": "'"$_uuid"'"'

    # Parse query parameters
    declare -A _params

    IFS='&' read -ra _pairs <<<"$_query"
    for __pair in "${_pairs[@]}"; do
        local __key="${__pair%%=*}"
        local __value="${__pair#*=}"
        _params[$__key]="$__value"
    done

    # Flow
    if [ ! -z "${_params[flow]}" ]; then _config+=', "flow": "'"${_params[flow]}"'"'; fi

    # TCP or UDP network type
    if [[ "${_params[type]}" == "tcp" ]] || [[ "${_params[type]}" == "udp" ]]; then
        _config+=', "network": "'"${_params[type]}"'"'
    fi

    # WebSocket transport
    if [[ "${_params[type]}" == "ws" ]] && [ ! -z "${_params[path]}" ]; then
        _config+=', "transport": { "type": "ws", "path": "'"${_params[path]#/}"'"'
        if [ ! -z "${_params[host]}" ]; then _config+=', "headers": { "Host": "'"${_params[host]}"'" }'; fi
        # _config+=', "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"'
        _config+=" }"
    fi

    # TLS
    if [ ! -z "${_params[sni]}" ]; then
        _config+=', "tls": { "enabled": true, "server_name": "'"${_params[sni]}"'"'

        # Application-Layer Protocol Negotiation
        if [ ! -z "${_params[alpn]}" ]; then _config+=', "alpn": ["'"${_params[alpn]//,/\", \"}"'"]'; fi

        # Reality
        if [[ "${_params[security]}" == "reality" ]] && [ ! -z "${_params[pbk]}" ] && [ ! -z "${_params[sid]}" ]; then
            _config+=', "reality": { "enabled": true'
            _config+=', "public_key": "'"${_params[pbk]}"'", "short_id": "'"${_params[sid]}"'" }'
        fi

        # uTLS
        if [ ! -z "${_params[fp]}" ]; then
            _config+=', "utls": { "enabled": true, "fingerprint": "'"${_params[fp]}"'" }'
        elif [[ "${_params[security]}" == "reality" ]]; then
            # Fix "create service: initialize outbound[0]: uTLS is required by reality client"
            _config+=', "utls": { "enabled": true, "fingerprint": "firefox" }'
        fi

        _config+=" }"
    fi

    _config+=', "domain_resolver": { "server": "local", "strategy": "prefer_ipv4" }'

    echo "{ $_config }"
}

# Builds sing-box JSON config
# Args:
#   1: VLESS outbound (output of vless_to_json function)
# Returns:
#   Full JSON config for sing-box
build_sing_box_config() {
    local _vless_outbound=$1

    local _config="$CONFIG_LOG, $CONFIG_DNS"
    _config+=', "inbounds": [{ "type": "socks", "tag": "socks-in"'
    _config+=', "listen": "127.0.0.1", "listen_port": '"$inbound_port"' }]'
    _config+=', "outbounds": ['"$_vless_outbound"', '"$CONFIG_OUTBOUND_DIRECT"']'
    _config+=", ${CONFIG_ROUTE}"
    echo "{ $_config }"
}

# Checks if port is in use
# TODO: Test and improve this function
# Args:
#   1: Port number
# Returns (code):
#   0 if in use
is_port_in_use() {
    local _port=$1

    # Try ss
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "[.:]$_port$" >/dev/null 2>&1
        return $?
    fi

    # Fallback to netstat
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E "[.:]$_port$" >/dev/null 2>&1
        return $?
    fi

    # Fallback to lsof
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$_port" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi

    # Fallback to nc
    if command -v nc >/dev/null 2>&1; then
        nc -z localhost "$_port" >/dev/null 2>&1
        return $?
    fi

    # Safe fallback (port in use)
    return 0
}

# Generates unused port
# TODO: Improve this function
# Returns:
#   Unused port in 2000-65000 range
get_unused_port() {
    local _port=$(shuf -i 2000-65000 -n 1)
    if ! is_port_in_use "$_port"; then
        echo "$_port"
    else
        get_unused_port
    fi
}

# Checks for existing sing-box binary or downloads one and sets SING_BOX_PATH env variable
find_or_download_sing_box() {
    SING_BOX_PATH=${SING_BOX_PATH:-./sing-box/sing-box}
    if [ -f "$SING_BOX_PATH" ]; then
        export SING_BOX_PATH
        return
    fi
    SING_BOX_PATH="./sing-box"
    if [ -f "$SING_BOX_PATH" ]; then
        export SING_BOX_PATH
        return
    fi

    unset SING_BOX_PATH
    echo "No sing-box found!"

    # Determine platform
    if [[ -n "$ANDROID_ROOT" ]] || [[ -n "$ANDROID_DATA" ]] || grep -qi android /proc/version 2>/dev/null; then
        local _sing_box_platform="android"
    else
        local _uname_s
        local _uname_s="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        case "$_uname_s" in
        darwin)
            local _sing_box_platform="darwin"
            ;;
        linux)
            if [[ -f /etc/openwrt_release ]] || grep -qi openwrt /etc/os-release 2>/dev/null; then
                local _sing_box_platform="openwrt"
            else
                local _sing_box_platform="linux"
            fi
            ;;
        *)
            echo "ERROR: Unknown platform $_uname_s"
            exit 1
            ;;
        esac
    fi

    # Determine architecture
    local _uname_m=$(uname -m)
    case "$_uname_m" in
    x86_64)
        local _sing_box_arch="amd64"
        ;;
    i686 | i386)
        local _sing_box_arch="386"
        ;;
    aarch64 | arm64 | armv8*)
        local _sing_box_arch="arm64"
        ;;
    arm* | sa110*)
        local _sing_box_arch="armv7"
        ;;
    *)
        echo "ERROR: Unknown architecture $_uname_m"
        exit 1
        ;;
    esac

    # Download latest sing-box release
    echo "Downloading sing-box for $_sing_box_platform $_sing_box_arch"
    local _release_json=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest)
    local _download_url=$(echo "$_release_json" | grep -oP '"browser_download_url": "\K.*?\.tar\.gz(?=")' |
        grep -oE ".*sing-box-.*-${_sing_box_platform}-${_sing_box_arch}\.tar\.gz")

    local _download_filename=$(basename "$_download_url")
    curl --output "$_download_filename" --location "$_download_url"
    if [ ! -f "$_download_filename" ]; then
        echo "ERROR: Unable to download $_download_filename"
        exit 1
    fi

    # Extract, check and delete archive
    echo "Extracting"
    mkdir -p "sing-box"
    if ! tar -xvzf "$_download_filename" -C "sing-box" --strip-components 1; then
        tar xvzf "$_download_filename" -C "sing-box" --strip-components 1
    fi
    if [ -z "$(ls -A sing-box)" ]; then
        echo "ERROR: Unable to extract $_download_filename"
        exit 1
    fi
    echo "Deleting archive $_download_filename"
    rm "$_download_filename"

    # Search again
    find_or_download_sing_box
}

# Tests single VLESS link
# Args:
#   1: VLESS link (must start with vless://)
# Returns (code):
#   0 if working
test_link() {
    local _link=$1
    if [[ ! "$_link" == vless://* ]]; then return -1; fi

    # Decode URL symbols
    local LC_ALL=C
    local _link_decoded=$(echo "$_link" | sed "s@+@ @g;s@%@\\\\x@g" | xargs -0 printf "%b")

    # Split profile name
    local _profile_name="${_link_decoded#*#}"
    if [ -z "$_profile_name" ]; then
        _profile_name="$_link_decoded"
    fi

    local _outbound=$(vless_to_json "$_link_decoded")
    local _config=$(build_sing_box_config "$_outbound")

    LOGGER '\nTesting "'"$_profile_name"'"...'

    # Remove old temp files (just in case)
    rm -f "$_TMP_CONFIG"
    rm -f "$_TMP_LOG"

    # Start sing-box
    echo "$_config" >|"$_TMP_CONFIG"
    $SING_BOX_PATH run -c "$_TMP_CONFIG" &
    sing_box_pid=$!

    # Ensure cleanup on exit
    _stop_sing_box() {
        kill "$sing_box_pid" 2>/dev/null
        rm -f "$_TMP_CONFIG"
        rm -f "$_TMP_LOG"
    }
    trap _stop_sing_box EXIT

    # Wait for sing-box to start
    local _sing_box_start_time=$(date +%s)
    until grep -q "sing-box started" "$_TMP_LOG" 2>/dev/null; do
        local _now=$(date +%s)
        if ((_now - _sing_box_start_time >= 3)); then
            LOGGER "Timeout waiting for sing-box to start!"
            _stop_sing_box
            return 1
        fi
        sleep 0.1
    done

    # Test
    # NOTE: -s - silent, -S - show error, -f - exit code on error
    if curl --http0.9 --socks5-hostname "127.0.0.1:$inbound_port" -sSf \
        --connect-timeout $CONN_TIMEOUT --max-time $MAX_TIME --retry $RETRIES --retry-delay 1 \
        --retry-all-errors --retry-connrefused \
        -L $TEST_URL >/dev/null; then
        LOGGER "WORKING! WORKING! WORKING! ^-^"
        LOGGER "Link: $_link"
        LOGGER "Outbound config: $_outbound"
        _stop_sing_box
        return 0
    fi
    LOGGER "Not working T_T"
    _stop_sing_box
    return 1
}

# Tests lines from a local file
# Args:
#   1: Path to file
#   2: NUMBER_OF_LINKS_TO_TEST CLI argument
test_file() {
    local _file_path=$1
    local _lines_n=$2

    if [ ! -f "$_file_path" ]; then
        LOGGER "ERROR: File $_file_path doesn't exist"
        exit 1
    fi

    # Read lines into array based on N
    local _links=()

    # Entire file
    if [ -z "$_lines_n" ] || [[ "$_lines_n" == "0" ]]; then
        LOGGER "Testing entire file: $_file_path"
        mapfile -t _links <"$_file_path"

    # Random lines
    elif [[ "$_lines_n" =~ ^r([0-9]+)$ ]]; then
        local _count="${BASH_REMATCH[1]}"
        LOGGER "Testing $_count random lines from: $_file_path"
        mapfile -t _links < <(shuf -n "$_count" "$_file_path")

    # Last N lines
    elif [[ "$_lines_n" =~ ^-([0-9]+)$ ]]; then
        local _count="${BASH_REMATCH[1]}"
        LOGGER "Testing last $_count lines from: $_file_path"
        mapfile -t _links < <(tail -n "$_count" "$_file_path")

    # First N lines
    elif [[ "$_lines_n" =~ ^[0-9]+$ ]]; then
        local _count="$_lines_n"
        LOGGER "Testing first $_count lines from: $_file_path"
        mapfile -t _links < <(head -n "$_count" "$_file_path")
    else
        LOGGER "ERROR: Unknown NUMBER_OF_LINKS_TO_TEST format: $_lines_n"
        exit 1
    fi

    # Process each line
    for _link in "${_links[@]}"; do
        if [[ ! "$_link" == vless://* ]]; then continue; fi
        test_link "$_link"
    done
}

# Downloads sing-box (if needed) and finds free unused port
prepare() {
    # Download sing-box
    find_or_download_sing_box
    LOGGER "sing-box path: $SING_BOX_PATH"

    # Find free port for proxy
    inbound_port=$(get_unused_port)
    LOGGER "Inbound proxy port: $inbound_port"

    # Log test URL
    LOGGER "Test URL: $TEST_URL"
}

# ####################### #
# SCRIPT MAIN ENTRY POINT #
# ####################### #

# Trying to make this script a bit safer :)
set -o pipefail -o noclobber

# Timestamp for log file
log_datetime=$(date +"%Y_%m_%d__%H_%M_%S")

# Script name and version
echo "vless-validator"
echo "                by F3RNI"
echo -e "version: $_VERSION\n"

# CLI arguments
link_or_file="$1"
lines_n="$2"

# Single VLESS link provided
if [[ "$link_or_file" == vless://* ]]; then
    prepare
    test_link "$link_or_file"
    exit $?

# Link to download
elif [[ "$link_or_file" == http* ]]; then
    prepare
    download_filename=$(basename "$link_or_file")
    LOGGER "Downloading $link_or_file -> $download_filename"
    curl -k --output "$download_filename" --location "$link_or_file"
    if [ ! -f "$download_filename" ]; then
        echo "ERROR: Unable to download $download_filename"
        exit 1
    fi
    test_file "$download_filename" "$lines_n"
    exit $?

# Local file
elif [ -f "$link_or_file" ]; then
    prepare
    test_file "$link_or_file" "$lines_n"
    exit $?

# No / wrong argument provided
else
    echo "Usage: $0 LINK_OR_FILE [NUMBER_OF_LINKS_TO_TEST]"
    echo -e "\nNote:"
    echo '  Add "r" before NUMBER_OF_LINKS_TO_TEST to select N random lines;'
    echo '  add "-" before NUMBER_OF_LINKS_TO_TEST to select N lines from the bottom.'
    echo "  If needed, you can define environment variables in a .env file."
    echo -e "\nEnvironment variables:"
    echo "  TEST_URL - URL to test via VLESS. Current: $TEST_URL"
    echo "  SING_BOX_PATH - Path to sing-box binary (can be auto-downloaded)"
    echo "  CONN_TIMEOUT - --connect-timeout for curl. Current: $CONN_TIMEOUT"
    echo "  MAX_TIME - --max-time for curl. Current: $MAX_TIME"
    echo "  RETRIES - --retry for curl. Current: $RETRIES"
    echo -e "\nExamples:"
    echo "  $0 vless://UUID@IP:PORT?flow=xtls-rpr..."
    echo "  $0 path/to/file_with_links_to_test.txt"
    echo "  $0 path/to/file_with_links_to_test.txt 20"
    echo "  $0 path/to/file_with_links_to_test.txt -10"
    echo "  $0 https://web/path/to/file_to_download_and_test.txt r5"
    exit 1
fi
