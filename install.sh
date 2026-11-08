#!/bin/sh
# rtr-subs: unofficial add-on for Podkop 0.7.24 on OpenWrt
#   1. auto-installs Podkop 0.7.24 directly from GitHub releases if missing;
#   2. adds subscription support (URL, HWID, update interval) in the Podkop UI;
#   3. installs the podkop-engine sing-box core (REALITY compatible with modern Xray servers).
#
# Usage:
#   sh install.sh               install base Podkop 0.7.24 (if needed), add-on, and core
#   sh install.sh --no-core     add-on only (keep the current sing-box)
#   sh install.sh --core-only   core only
#   sh install.sh --uninstall   restore the files from the latest backup
#
# Variables: PE_VERSION (core version), PE_FLAVOR (podkop-engine | podkop-engine-full),
#            PE_ALLOW_UNVERIFIED=1 (default: 1, allow installing core when SHA256 isn't hardcoded)

set -eu

ADDON_VERSION="1.3.1"
RAW_BASE="${RTR_SUBS_RAW:-https://raw.githubusercontent.com/FoolTrigger/sub-podkop/main}"
PODKOP_REPO="itdoginfo/podkop"
PODKOP_TAG="${PODKOP_TAG:-0.7.24}"
PE_VERSION="${PE_VERSION:-1.13.21-r15}"
PE_FLAVOR="${PE_FLAVOR:-podkop-engine}"
PE_REPO="podkop-net/podkop-engine"
PE_ALLOW_UNVERIFIED="${PE_ALLOW_UNVERIFIED:-1}"
ROOT="${ROOT:-}"

BIN="$ROOT/usr/bin/podkop"
LIB="$ROOT/usr/lib/podkop"
VIEW="$ROOT/www/luci-static/resources/view/podkop"
I18N="$ROOT/usr/lib/lua/luci/i18n"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/root/rtr-subs-backup-$STAMP"
WORK="${TMPDIR:-/tmp}/rtr-subs.$$"

KNOWN_SHA256_1_13_21_R15_AARCH64_CORTEX_A53_IPK="c93ceb551f92e16a30e401c8d0211d5cf56e1561262e567f09964984b5625229"
KNOWN_SHA256_1_13_21_R15_AARCH64_CORTEX_A53_APK="03af1f6e0a661b7b09e2df087d655ae3a2091d98b66f48d72acf3f02c1508f1c"

say() { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

DO_ADDON=1
DO_CORE=1
DO_UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
    --no-core) DO_CORE=0 ;;
    --core-only) DO_ADDON=0 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "неизвестный параметр: $arg" ;;
    esac
done

mkdir -p "$WORK"

[ "$(id -u)" = "0" ] || die "нужны права root"
command -v wget > /dev/null 2>&1 || die "не найден wget"

if [ "$DO_UNINSTALL" = "1" ]; then
    last=""
    for d in $(ls -d "$ROOT"/root/rtr-subs-backup-* 2> /dev/null | sort -r); do
        if [ -f "$d/podkop" ]; then
            last="$d"
            break
        fi
    done
    [ -n "$last" ] || die "резервная копия не найдена в /root"
    say "Восстанавливаю файлы из $last"
    [ -f "$last/podkop" ] && cp "$last/podkop" "$BIN" && chmod 755 "$BIN"
    [ -f "$last/constants.sh" ] && cp "$last/constants.sh" "$LIB/constants.sh"
    [ -f "$last/main.js" ] && cp "$last/main.js" "$VIEW/main.js"
    [ -f "$last/section.js" ] && cp "$last/section.js" "$VIEW/section.js"
    [ -f "$last/podkop.ru.lmo" ] && cp "$last/podkop.ru.lmo" "$I18N/podkop.ru.lmo"

    rm -f "$LIB/subscription.sh"
    rm -rf "$ROOT/etc/podkop/subscriptions"

    if [ -f "$ROOT/etc/crontabs/root" ]; then
        sed -i '/subscription/d; /rtr-subs/d' "$ROOT/etc/crontabs/root" 2> /dev/null || true
        [ -x "$ROOT/etc/init.d/cron" ] && "$ROOT/etc/init.d/cron" restart > /dev/null 2>&1 || true
    fi

    rm -rf "$last"
    rm -f "$ROOT"/tmp/luci-indexcache* 2> /dev/null || true
    rm -rf "$ROOT"/tmp/luci-modulecache 2> /dev/null || true
    [ -x "$ROOT/etc/init.d/podkop" ] && "$ROOT/etc/init.d/podkop" restart || true
    say "Готово."
    exit 0
fi

detect_arch() {
    arch=""
    if [ -f "$ROOT/etc/openwrt_release" ]; then
        arch="$(sed -n "s/^DISTRIB_ARCH=['\"]\?\([^'\"]*\)['\"]\?/\1/p" "$ROOT/etc/openwrt_release" | head -n 1)"
    fi
    if [ -z "$arch" ] && [ -f "$ROOT/etc/os-release" ]; then
        arch="$(sed -n 's/^OPENWRT_ARCH=["'\'']\?\([^"'\'']*\)["'\'']\?/\1/p' "$ROOT/etc/os-release" | head -n 1)"
    fi
    if [ -z "$arch" ] && command -v opkg > /dev/null 2>&1; then
        arch="$(opkg print-architecture 2> /dev/null | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $3, $2}' | sort -n | tail -n 1 | cut -d' ' -f2)"
    fi
    if [ -z "$arch" ] && command -v apk > /dev/null 2>&1; then
        arch="$(apk --print-arch 2> /dev/null)"
    fi
    printf '%s' "$arch"
}

install_podkop_base() {
    say "Устанавливаю базовый Podkop ($PODKOP_TAG)..."
    PK_WORK="$WORK/pk_pkgs"
    mkdir -p "$PK_WORK"

    # В репозитории itdoginfo/podkop тег называется "0.7.24" (без "v")
    TAG_CLEAN="${PODKOP_TAG#v}"
    BASE_DL="https://github.com/$PODKOP_REPO/releases/download/$TAG_CLEAN"

    if command -v apk > /dev/null 2>&1; then
        PKG_EXT="apk"
        say "Обновляю списки пакетов (apk update)..."
        apk update || warn "apk update завершился с предупреждением"
        PKGS="
podkop-${TAG_CLEAN}-r1.apk
luci-app-podkop-${TAG_CLEAN}-r1.apk
luci-i18n-podkop-ru-${TAG_CLEAN}.apk
"
    elif command -v opkg > /dev/null 2>&1; then
        PKG_EXT="ipk"
        say "Обновляю списки пакетов (opkg update)..."
        opkg update || warn "opkg update завершился с предупреждением"
        PKGS="
podkop-v${TAG_CLEAN}-r1-all.ipk
luci-app-podkop-v${TAG_CLEAN}-r1-all.ipk
luci-i18n-podkop-ru-${TAG_CLEAN}.ipk
"
    else
        die "не найден ни opkg, ни apk"
    fi

    for fname in $PKGS; do
        url="$BASE_DL/$fname"
        say "Скачиваю $fname..."
        wget -qO "$PK_WORK/$fname" "$url" || die "не удалось скачать $url"
        [ -s "$PK_WORK/$fname" ] || die "скачанный файл $fname пуст"
    done

    say "Устанавливаю пакеты Podkop $TAG_CLEAN..."
    if [ "$PKG_EXT" = "apk" ]; then
        apk add --allow-untrusted \
            "$PK_WORK/podkop-${TAG_CLEAN}-r1.apk" \
            "$PK_WORK/luci-app-podkop-${TAG_CLEAN}-r1.apk" \
            "$PK_WORK/luci-i18n-podkop-ru-${TAG_CLEAN}.apk" \
            || die "ошибка установки пакетов Podkop через apk"
    else
        # В OpenWrt 23.05/24.10 с opkg пакет dnsmasq нужно заменить на dnsmasq-full, если этого требует podkop
        if opkg list-installed | grep -q '^dnsmasq '; then
            say "Заменяю стандартный dnsmasq на dnsmasq-full..."
            opkg install dnsmasq-full --download-only && opkg remove dnsmasq && opkg install dnsmasq-full --cache . && rm -f *.ipk || true
        fi
        opkg install \
            "$PK_WORK/podkop-v${TAG_CLEAN}-r1-all.ipk" \
            "$PK_WORK/luci-app-podkop-v${TAG_CLEAN}-r1-all.ipk" \
            "$PK_WORK/luci-i18n-podkop-ru-${TAG_CLEAN}.ipk" \
            || die "ошибка установки пакетов Podkop через opkg"
    fi
}

get_payload() {
    PAYLOAD="$WORK/payload"
    mkdir -p "$PAYLOAD"
    if [ -f "$0" ] && grep -q '^#PAYLOAD#$' "$0" 2> /dev/null; then
        sed '1,/^#PAYLOAD#$/d' "$0" | base64 -d | tar xzf - -C "$PAYLOAD" || die "не удалось распаковать встроенные файлы"
        return
    fi
    case "$RAW_BASE" in *OWNER/REPO*) die "RTR_SUBS_RAW не задан" ;; esac
    for f in podkop subscription.sh main.js section.js podkop.ru.lmo; do
        wget -qO "$PAYLOAD/$f" "$RAW_BASE/files/$f" || die "не удалось скачать $f из $RAW_BASE/files/$f"
        [ -s "$PAYLOAD/$f" ] || die "скачанный файл $f пуст"
    done
}

install_addon() {
    if [ ! -f "$LIB/constants.sh" ]; then
        warn "Podkop не найден на устройстве. Запускаю чистую установку $PODKOP_TAG..."
        install_podkop_base
    fi

    version="$(sed -n 's/^PODKOP_VERSION="\(.*\)"/\1/p' "$LIB/constants.sh" 2> /dev/null || true)"
    case "$version" in
    v0.7.24* | 0.7.24*) ;;
    *)
        warn "Обнаружен Podkop '$version', но требуется 0.7.24. Устанавливаю $PODKOP_TAG..."
        install_podkop_base
        version="$(sed -n 's/^PODKOP_VERSION="\(.*\)"/\1/p' "$LIB/constants.sh" 2> /dev/null || true)"
        case "$version" in
        v0.7.24* | 0.7.24*) ;;
        *) die "после установки версия Podkop '$version' всё ещё не совпадает с 0.7.24" ;;
        esac
        ;;
    esac

    get_payload

    if grep -q 'subscription.sh' "$BIN" 2> /dev/null; then
        say "Дополнение уже установлено, обновляю файлы"
    else
        mkdir -p "$BACKUP"
        for f in "$BIN" "$LIB/constants.sh" "$VIEW/main.js" "$VIEW/section.js" "$I18N/podkop.ru.lmo"; do
            [ -f "$f" ] && cp "$f" "$BACKUP/"
        done
        say "Резервная копия: $BACKUP"
    fi

    cp "$PAYLOAD/podkop" "$BIN" && chmod 755 "$BIN"
    cp "$PAYLOAD/subscription.sh" "$LIB/subscription.sh" && chmod 644 "$LIB/subscription.sh"

    if ! grep -q SUBSCRIPTION_CACHE_DIR "$LIB/constants.sh"; then
        cat >> "$LIB/constants.sh" << 'EOT'

## Subscriptions
SUBSCRIPTION_CACHE_DIR="/etc/podkop/subscriptions"
SUBSCRIPTION_DEFAULT_USER_AGENT="v2rayN/7.0"
SUBSCRIPTION_FETCH_TIMEOUT=20
EOT
    fi

    luci_version="$(sed -n 's/^var PODKOP_LUCI_APP_VERSION = "\(.*\)";/\1/p' "$VIEW/main.js" 2> /dev/null || true)"
    cp "$PAYLOAD/main.js" "$VIEW/main.js" && chmod 644 "$VIEW/main.js"
    cp "$PAYLOAD/section.js" "$VIEW/section.js" && chmod 644 "$VIEW/section.js"
    sed -i "s/__COMPILED_VERSION_VARIABLE__/${luci_version:-$version}/g" "$VIEW/main.js"

    if [ -f "$I18N/podkop.ru.lmo" ] || [ -d "$I18N" ]; then
        mkdir -p "$I18N"
        cp "$PAYLOAD/podkop.ru.lmo" "$I18N/podkop.ru.lmo"
    fi

    rm -f "$ROOT"/tmp/luci-indexcache* 2> /dev/null || true
    rm -rf "$ROOT"/tmp/luci-modulecache 2> /dev/null || true
    say "Дополнение подписок установлено"
}

expected_sha256() {
    key="KNOWN_SHA256_$(printf '%s_%s' "$PE_VERSION" "$ARCH_NAME" | tr 'a-z.-' 'A-Z__')_$(printf '%s' "$EXT" | tr 'a-z' 'A-Z')"
    eval "known=\${$key:-}"
    if [ -n "$known" ]; then
        printf '%s' "$known"
        return
    fi
    wget -qO "$WORK/release.json" "https://api.github.com/repos/$PE_REPO/releases/tags/v$PE_VERSION" 2> /dev/null || return 0
    if command -v jq > /dev/null 2>&1; then
        jq -r --arg n "$1" '.assets[]? | select(.name == $n) | .digest // empty' "$WORK/release.json" 2> /dev/null | sed 's/^sha256://'
    elif command -v jsonfilter > /dev/null 2>&1; then
        jsonfilter -i "$WORK/release.json" -e "@.assets[@.name='$1'].digest" 2> /dev/null | sed 's/^sha256://'
    fi
}

core_installed() {
    if command -v opkg > /dev/null 2>&1 && opkg list-installed 2> /dev/null | grep -q '^podkop-engine'; then
        return 0
    fi
    if command -v apk > /dev/null 2>&1 && apk info -e podkop-engine > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

install_core() {
    if core_installed; then
        say "Ядро podkop-engine уже установлено: $(sing-box version 2> /dev/null | head -n 1)"
        return
    fi

    if command -v apk > /dev/null 2>&1; then
        EXT="apk"
    elif command -v opkg > /dev/null 2>&1; then
        EXT="ipk"
    else
        die "не найден ни opkg, ни apk"
    fi

    ARCH_NAME="$(detect_arch)"
    [ -n "$ARCH_NAME" ] || die "не удалось определить архитектуру устройства"
    file="${PE_FLAVOR}_${PE_VERSION}_openwrt_${ARCH_NAME}.${EXT}"
    url="https://github.com/$PE_REPO/releases/download/v$PE_VERSION/$file"

    say "Архитектура: $ARCH_NAME. Скачиваю $file"
    if ! wget -qO "$WORK/$file" "$url"; then
        if [ "$EXT" = "apk" ]; then
            SHORT_ARCH="$(apk --print-arch 2> /dev/null || true)"
            if [ -n "$SHORT_ARCH" ] && [ "$SHORT_ARCH" != "$ARCH_NAME" ]; then
                warn "пакет для $ARCH_NAME не найден, пробую $SHORT_ARCH"
                ARCH_NAME="$SHORT_ARCH"
                file="${PE_FLAVOR}_${PE_VERSION}_openwrt_${ARCH_NAME}.${EXT}"
                url="https://github.com/$PE_REPO/releases/download/v$PE_VERSION/$file"
                wget -qO "$WORK/$file" "$url" || die "не удалось скачать $url"
            else
                die "не удалось скачать $url"
            fi
        else
            die "не удалось скачать $url"
        fi
    fi

    want="$(expected_sha256 "$file")"
    have="$(sha256sum "$WORK/$file" | cut -d' ' -f1)"
    if [ -n "$want" ]; then
        [ "$want" = "$have" ] || die "контрольная сумма не совпала: ожидалась $want, получена $have"
        say "Контрольная сумма совпала: $have"
    elif [ "$PE_ALLOW_UNVERIFIED" = "1" ]; then
        warn "контрольная сумма в базе не найдена ($have), продолжаю установку"
    else
        die "контрольная сумма $file неизвестна ($have). Запустите с PE_ALLOW_UNVERIFIED=1"
    fi

    mkdir -p "$BACKUP"
    [ -f "$ROOT/usr/bin/sing-box" ] && cp "$ROOT/usr/bin/sing-box" "$BACKUP/sing-box.orig"

    if [ "$EXT" = "ipk" ]; then
        opkg update > /dev/null 2>&1 || true
    fi

    [ -x "$ROOT/etc/init.d/podkop" ] && "$ROOT/etc/init.d/podkop" stop || true

    if [ "$EXT" = "ipk" ]; then
        opkg remove --force-depends sing-box sing-box-tiny > /dev/null 2>&1 || true
        opkg install "$WORK/$file" || die "установка ядра ($file) через opkg не удалась"
    else
        APK_SYS_ARCH="$(apk --print-arch 2> /dev/null || true)"
        if [ -n "$APK_SYS_ARCH" ] && [ "$APK_SYS_ARCH" != "$ARCH_NAME" ]; then
            mkdir -p "$ROOT/etc/apk"
            if [ ! -f "$ROOT/etc/apk/arch" ]; then
                printf '%s\n' "$APK_SYS_ARCH" > "$ROOT/etc/apk/arch"
            fi
            if ! grep -qx "$ARCH_NAME" "$ROOT/etc/apk/arch" 2> /dev/null; then
                printf '%s\n' "$ARCH_NAME" >> "$ROOT/etc/apk/arch"
            fi
        fi

        apk del --no-depend sing-box sing-box-tiny > /dev/null 2>&1 || true
        apk add --allow-untrusted --overwrite "$WORK/$file" 2> /dev/null \
            || apk add --allow-untrusted --arch "$ARCH_NAME" "$WORK/$file" 2> /dev/null \
            || apk add --allow-untrusted "$WORK/$file" \
            || die "установка ядра ($file) через apk не удалась"
    fi

    say "Ядро установлено: $(sing-box version 2> /dev/null | head -n 1)"
}

# RuTracker fix: resolve real destination IP locally before routing traffic
# through the proxy. This is a native Podkop 0.7.24 option.
enable_rutracker_resolve() {
    [ "$DO_ADDON" = "1" ] || return 0

    if [ -n "$ROOT" ]; then
        warn "ROOT задан ($ROOT): пропускаю изменение UCI хост-системы"
        return 0
    fi
    command -v uci > /dev/null 2>&1 || {
        warn "uci не найден; не удалось включить resolve_real_ip_for_routing"
        return 0
    }

    if ! uci -q get podkop.main > /dev/null 2>&1; then
        warn "секция podkop.main не найдена; настройка RuTracker не изменена"
        return 0
    fi

    current="$(uci -q get podkop.main.resolve_real_ip_for_routing 2>/dev/null || true)"
    if [ "$current" = "1" ]; then
        say "RuTracker fix уже включён (resolve_real_ip_for_routing=1)"
        return 0
    fi

    say "Включаю штатное разрешение реального IP для маршрутизации (RuTracker fix)..."
    uci set podkop.main.resolve_real_ip_for_routing='1' \
        || die "не удалось установить resolve_real_ip_for_routing"
    uci commit podkop \
        || die "не удалось сохранить настройку resolve_real_ip_for_routing"
    say "RuTracker fix включён: podkop.main.resolve_real_ip_for_routing=1"
}

[ "$DO_ADDON" = "1" ] && install_addon
[ "$DO_CORE" = "1" ] && install_core

enable_rutracker_resolve

if [ -x "$ROOT/etc/init.d/podkop" ]; then
    say "Перезапускаю Podkop"
    "$ROOT/etc/init.d/podkop" restart || warn "не удалось перезапустить Podkop"
fi

say ""
say "Готово (rtr-subs $ADDON_VERSION)."
exit 0
