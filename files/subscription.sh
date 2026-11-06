# shellcheck shell=ash
# Subscription support: a section with proxy_config_type 'subscription' gets its
# proxy links from a subscription URL. The links are cached on flash, so podkop
# can start while the subscription server is unreachable.

# Result of subscription_resolve (space-separated links)
SUBSCRIPTION_LINKS=""
# Set to 1 by subscription_update: the cache is already fresh, do not download again
SUBSCRIPTION_NO_FETCH=0
# Set to 1 when a download changed the cached links
SUBSCRIPTION_CHANGED=0
# Section limiting subscription_update (all sections when empty)
SUBSCRIPTION_TARGET=""

# Returns the path of the links cache of the section
subscription_cache_file() {
    echo "$SUBSCRIPTION_CACHE_DIR/$1.links"
}

# Generates a stable HWID of this router
subscription_generate_hwid() {
    local mac

    mac="$(cat /sys/class/net/br-lan/address 2> /dev/null)"
    [ -z "$mac" ] && mac="$(cat /sys/class/net/eth0/address 2> /dev/null)"
    [ -z "$mac" ] && mac="$(cat /sys/class/net/*/address 2> /dev/null | grep -v '^00:00:00:00:00:00$' | head -n 1)"
    [ -z "$mac" ] && mac="$(cat /tmp/sysinfo/model 2> /dev/null)"

    printf 'podkop:%s' "$mac" | sha256sum | cut -c1-32
}

# Prints the HWID the section sends to the subscription server (nothing if disabled)
subscription_get_hwid() {
    local section="$1"
    local mode hwid

    config_get mode "$section" "subscription_hwid_mode" "auto"
    case "$mode" in
    off) ;;
    custom)
        config_get hwid "$section" "subscription_hwid"
        echo "$hwid"
        ;;
    *)
        subscription_generate_hwid
        ;;
    esac
}

# Downloads the subscription into a file; prints the first line of curl's error, if any
# Arguments: url, output file, hwid (may be empty), user agent, timeout, proxy address (may be empty)
_subscription_download() {
    local url="$1"
    local output="$2"
    local hwid="$3"
    local user_agent="$4"
    local timeout="$5"
    local proxy="$6"

    local os_version device_model error_file
    os_version="$(grep OPENWRT_RELEASE /etc/os-release 2> /dev/null | cut -d'"' -f2)"
    device_model="$(cat /tmp/sysinfo/model 2> /dev/null)"
    error_file="$output.err"

    set -- -fsSL --connect-timeout 8 --max-time "$timeout" -A "$user_agent" -o "$output"
    if [ -n "$hwid" ]; then
        set -- "$@" -H "x-hwid: $hwid" -H "x-device-os: OpenWrt" \
            -H "x-ver-os: ${os_version:-OpenWrt}" -H "x-device-model: ${device_model:-router}"
    fi
    [ -n "$proxy" ] && set -- "$@" -x "http://$proxy"

    curl "$@" "$url" 2> "$error_file"
    local status=$?
    head -n 1 "$error_file"
    rm -f "$error_file"

    return "$status"
}

# Prints the first non-whitespace character of a file
_subscription_first_char() {
    sed -n '/[^[:space:]]/{s/^[[:space:]]*\(.\).*/\1/p;q}' "$1"
}

# Prints the links found in a downloaded subscription, one per line.
# Understands plain text, base64 and JSON ("links" array) subscriptions.
_subscription_extract_links() {
    local file="$1"
    local first data pad

    first="$(_subscription_first_char "$file")"
    case "$first" in
    '{' | '[')
        jq -r 'if type == "object" then ((.links // []) + ((.ssConfLinks // {}) | to_entries | map(.value))) else . end
            | if type == "array" then .[] else empty end
            | select(type == "string")' "$file" 2> /dev/null
        ;;
    *)
        if grep -q '://' "$file"; then
            cat "$file"
        else
            data="$(tr -d ' \t\r\n' < "$file" | tr '_-' '/+')"
            pad=$(((4 - ${#data} % 4) % 4))
            while [ "$pad" -gt 0 ]; do
                data="${data}="
                pad=$((pad - 1))
            done
            printf '%s' "$data" | base64 -d 2> /dev/null
        fi
        ;;
    esac
}

# Reads links from stdin and prints the ones podkop can use, one per line
_subscription_filter_links() {
    local link scheme transport has_decode_link=0

    sing_box_has_feature "tools.decode-link" && has_decode_link=1

    tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]]/%20/g' | awk '!seen[$0]++' |
        while IFS= read -r link; do
            [ -z "$link" ] && continue

            scheme="$(url_get_scheme "$link")"
            case "$scheme" in
            vless | trojan | ss | hysteria2 | hy2) ;;
            *)
                log "Skipped a subscription link: unsupported protocol '$scheme'" "debug"
                continue
                ;;
            esac

            if ! echo "$link" | grep -Eq '^[a-z0-9]+://[^@/?#]+@[^/?#]+:[0-9]+'; then
                log "Skipped a subscription link: unsupported $scheme link format" "debug"
                continue
            fi

            if [ "$scheme" = "vless" ] || [ "$scheme" = "trojan" ]; then
                transport="$(url_get_query_param "$(url_strip_fragment "$link")" "type")"
                case "$transport" in
                "" | tcp | raw | ws | grpc) ;;
                xhttp | splithttp)
                    if [ "$has_decode_link" -ne 1 ]; then
                        log "Skipped a subscription link: the installed sing-box does not support the xhttp transport" "debug"
                        continue
                    fi
                    ;;
                *)
                    log "Skipped a subscription link: unsupported transport '$transport'" "debug"
                    continue
                    ;;
                esac
            fi

            echo "$link"
        done
}

# Downloads the subscription of the section and refreshes its links cache.
# Returns 0 when the subscription was downloaded and has usable links.
subscription_refresh() {
    local section="$1"
    local url user_agent timeout hwid proxy_address raw links cache cache_tmp count

    config_get url "$section" "subscription_url"
    config_get user_agent "$section" "subscription_user_agent" "$SUBSCRIPTION_DEFAULT_USER_AGENT"
    timeout="${2:-$SUBSCRIPTION_FETCH_TIMEOUT}"

    if [ -z "$url" ]; then
        log "Subscription URL of the $section section is not set" "error"
        return 1
    fi

    hwid="$(subscription_get_hwid "$section")"
    proxy_address="$(get_service_proxy_address)"
    raw="$(mktemp)"
    links="$(mktemp)"

    local attempt error downloaded=1
    for attempt in "$proxy_address" ""; do
        # without a proxy there is only one attempt
        [ -z "$attempt" ] && [ -n "$proxy_address" ] && log "Retrying the subscription of $section without proxy" "debug"
        : > "$raw"
        error="$(_subscription_download "$url" "$raw" "$hwid" "$user_agent" "$timeout" "$attempt")"
        if [ -s "$raw" ]; then
            downloaded=0
            break
        fi
        log "Cannot download the subscription of $section: ${error:-empty response}" "warn"
        [ -z "$proxy_address" ] && break
    done

    if [ "$downloaded" -ne 0 ]; then
        rm -f "$raw" "$links"
        return 1
    fi

    _subscription_extract_links "$raw" | _subscription_filter_links > "$links"

    # A JSON page of a panel may only point to the real subscription URL
    if [ ! -s "$links" ] && [ "$(_subscription_first_char "$raw")" = "{" ]; then
        local real_url
        real_url="$(jq -r '.subscriptionUrl // empty' "$raw" 2> /dev/null)"
        if [ -n "$real_url" ] && [ "$real_url" != "$url" ]; then
            : > "$raw"
            error="$(_subscription_download "$real_url" "$raw" "$hwid" "$user_agent" "$timeout" "$proxy_address")"
            [ -s "$raw" ] || error="$(_subscription_download "$real_url" "$raw" "$hwid" "$user_agent" "$timeout" "")"
            _subscription_extract_links "$raw" | _subscription_filter_links > "$links"
        fi
    fi

    count="$(grep -c '' "$links")"
    if [ "$count" -eq 0 ]; then
        log "The subscription of $section contains no supported links (vless, trojan, ss, hysteria2). Check the subscription URL, HWID and User-Agent settings" "error"
        rm -f "$raw" "$links"
        return 1
    fi

    cache="$(subscription_cache_file "$section")"
    if [ "$(md5sum < "$links")" != "$({ md5sum < "$cache"; } 2> /dev/null)" ]; then
        mkdir -p "$SUBSCRIPTION_CACHE_DIR"
        chmod 700 "$SUBSCRIPTION_CACHE_DIR"
        cache_tmp="$cache.tmp"
        cp "$links" "$cache_tmp" && chmod 600 "$cache_tmp" && mv "$cache_tmp" "$cache"
        SUBSCRIPTION_CHANGED=1
        log "Subscription of $section updated: $count links" "info"
    else
        log "Subscription of $section is up to date: $count links" "debug"
    fi

    rm -f "$raw" "$links"
    return 0
}

# Fills SUBSCRIPTION_LINKS with the links of the section.
# Downloads the subscription first; falls back to the cache when it is unreachable.
subscription_resolve() {
    local section="$1"
    local cache

    SUBSCRIPTION_LINKS=""

    cache="$(subscription_cache_file "$section")"

    if [ "$SUBSCRIPTION_NO_FETCH" -ne 1 ]; then
        if ! subscription_refresh "$section" 10 && [ -s "$cache" ]; then
            log "Using the cached links of the $section section subscription" "warn"
        fi
    fi

    [ -s "$cache" ] || return 1

    SUBSCRIPTION_LINKS="$(tr '\n' ' ' < "$cache")"
}

# Prints the cached links of the section as a JSON array (used by LuCI)
subscription_get_links_json() {
    local cache
    cache="$(subscription_cache_file "$1")"

    if [ -s "$cache" ]; then
        jq -R -s -c 'split("\n") | map(select(length > 0))' "$cache"
    else
        echo "[]"
    fi
}

_subscription_update_section() {
    local section="$1"
    local connection_type proxy_config_type

    [ -n "$SUBSCRIPTION_TARGET" ] && [ "$SUBSCRIPTION_TARGET" != "$section" ] && return 0

    config_get connection_type "$section" "connection_type"
    config_get proxy_config_type "$section" "proxy_config_type"
    [ "$connection_type" = "proxy" ] && [ "$proxy_config_type" = "subscription" ] || return 0

    echolog "🔄 Updating the subscription of the $section section..."
    if subscription_refresh "$section"; then
        echolog "✅ Subscription of $section downloaded"
    else
        echolog "❌ Subscription of $section was not updated" "error"
    fi
}

# Updates the subscriptions (of one section or of all) and reloads podkop if the links changed
subscription_update() {
    SUBSCRIPTION_TARGET="$1"
    SUBSCRIPTION_CHANGED=0

    config_foreach _subscription_update_section "section"

    if [ "$SUBSCRIPTION_CHANGED" -eq 1 ]; then
        echolog "Subscription links changed. Reloading podkop"
        SUBSCRIPTION_NO_FETCH=1
        reload
    else
        echolog "Subscription links are unchanged"
    fi
}

add_subscription_cron_job() {
    local section="$1"
    local connection_type proxy_config_type interval schedule

    config_get connection_type "$section" "connection_type"
    config_get proxy_config_type "$section" "proxy_config_type"
    [ "$connection_type" = "proxy" ] && [ "$proxy_config_type" = "subscription" ] || return 0

    config_get interval "$section" "subscription_update_interval" "12h"
    case "$interval" in
    "1h") schedule="23 * * * *" ;;
    "3h") schedule="23 */3 * * *" ;;
    "12h") schedule="23 */12 * * *" ;;
    "1d") schedule="23 9 * * *" ;;
    *)
        log "Invalid subscription_update_interval value of $section: $interval" "warn"
        return 0
        ;;
    esac

    (
        crontab -l 2> /dev/null
        echo "$schedule /usr/bin/podkop subscription_update $section"
    ) | crontab -
    log "The subscription cron job of $section has been created: $schedule" "info"
}

remove_subscription_cron_job() {
    (crontab -l 2> /dev/null | grep -v "/usr/bin/podkop subscription_update") | crontab -
}
