#!/bin/sh
# rtr-subs: unofficial add-on for Podkop 0.7.24 on OpenWrt
#   1. subscription support (URL, HWID, update interval) in the Podkop UI;
#   2. the podkop-engine sing-box core (REALITY compatible with modern Xray servers).
#
# Usage:
#   sh install.sh               install the add-on and the core
#   sh install.sh --no-core     add-on only (keep the current sing-box)
#   sh install.sh --core-only   core only
#   sh install.sh --uninstall   restore the files from the latest backup
#
# Variables: PE_VERSION (core version), PE_FLAVOR (podkop-engine | podkop-engine-full),
#            PE_ALLOW_UNVERIFIED=1 (install a core whose checksum is unknown)

set -eu

ADDON_VERSION="1.0.0"
RAW_BASE="${RTR_SUBS_RAW:-https://raw.githubusercontent.com/FoolTrigger/sub-podkop/main}"
PE_VERSION="${PE_VERSION:-1.13.21-r15}"
PE_FLAVOR="${PE_FLAVOR:-podkop-engine}"
PE_REPO="podkop-net/podkop-engine"
ROOT="${ROOT:-}"

BIN="$ROOT/usr/bin/podkop"
LIB="$ROOT/usr/lib/podkop"
VIEW="$ROOT/www/luci-static/resources/view/podkop"
I18N="$ROOT/usr/lib/lua/luci/i18n"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/root/rtr-subs-backup-$STAMP"
WORK="${TMPDIR:-/tmp}/rtr-subs.$$"

# Checksums of the core packages verified when this add-on was made
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
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "неизвестный параметр: $arg" ;;
    esac
done

mkdir -p "$WORK"

[ "$(id -u)" = "0" ] || die "нужны права root"
command -v wget > /dev/null 2>&1 || die "не найден wget"

# ---------------------------------------------------------------- uninstall
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

    # Очистка cron от задач обновления подписок
    if [ -f "$ROOT/etc/crontabs/root" ]; then
        sed -i '/subscription/d; /rtr-subs/d' "$ROOT/etc/crontabs/root" 2> /dev/null || true
        [ -x "$ROOT/etc/init.d/cron" ] && "$ROOT/etc/init.d/cron" restart > /dev/null 2>&1 || true
    fi

    # Удаляем использованный бэкап, чтобы при повторной установке создался свежий
    rm -rf "$last"

    rm -f "$ROOT"/tmp/luci-indexcache* 2> /dev/null || true
    rm -rf "$ROOT"/tmp/luci-modulecache 2> /dev/null || true
    [ -x "$ROOT/etc/init.d/podkop" ] && "$ROOT/etc/init.d/podkop" restart || true
    say "Готово. Ядро sing-box не менялось. Чтобы вернуть стандартное ядро:"
    say "  service podkop stop; opkg update; opkg remove --force-depends podkop-engine; opkg install sing-box; service podkop start"
    exit 0
fi

# ------------------------------------------------------------ payload files
# Embedded payload (standalone installer) or download from the repository
get_payload() {
    PAYLOAD="$WORK/payload"
    mkdir -p "$PAYLOAD"
    if [ -f "$0" ] && grep -q '^#PAYLOAD#$' "$0" 2> /dev/null; then
        sed '1,/^#PAYLOAD#$/d' "$0" | base64 -d | tar xzf - -C "$PAYLOAD" || die "не удалось распаковать встроенные файлы"
        return
    fi
    case "$RAW_BASE" in *OWNER/REPO*) die "RTR_SUBS_RAW не задан: укажите адрес репозитория" ;; esac
    for f in podkop subscription.sh main.js section.js podkop.ru.lmo; do
        wget -qO "$PAYLOAD/$f" "$RAW_BASE/files/$f" || die "не удалось скачать $f из $RAW_BASE/files/$f"
        [ -s "$PAYLOAD/$f" ] || die "скачанный файл $f пуст"
    done
}

# ---------------------------------------------------------------- the add-on
install_addon() {
    [ -f "$LIB/constants.sh" ] || die "Podkop не установлен ($LIB/constants.sh не найден). Сначала установите Podkop 0.7.24"
    version="$(sed -n 's/^PODKOP_VERSION="\(.*\)"/\1/p' "$LIB/constants.sh")"
    case "$version" in
    v0.7.24* | 0.7.24*) ;;
    *) die "установлен Podkop '$version', дополнение сделано для 0.7.24" ;;
    esac

    get_payload

    if grep -q 'subscription.sh' "$BIN" 2> /dev/null; then
        say "Дополнение уже установлено, обновляю файлы (исходная резервная копия сохранена)"
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

    # main.js carries the package version instead of the build placeholder
    luci_version="$(sed -n 's/^var PODKOP_LUCI_APP_VERSION = "\(.*\)";/\1/p' "$VIEW/main.js")"
    cp "$PAYLOAD/main.js" "$VIEW/main.js" && chmod 644 "$VIEW/main.js"
    cp "$PAYLOAD/section.js" "$VIEW/section.js" && chmod 644 "$VIEW/section.js"
    sed -i "s/__COMPILED_VERSION_VARIABLE__/${luci_version:-$version}/g" "$VIEW/main.js"

    if [ -f "$I18N/podkop.ru.lmo" ]; then
        cp "$PAYLOAD/podkop.ru.lmo" "$I18N/podkop.ru.lmo"
    else
        warn "русский перевод Podkop не установлен, новые поля будут на английском"
    fi

    rm -f "$ROOT"/tmp/luci-indexcache* 2> /dev/null || true
    rm -rf "$ROOT"/tmp/luci-modulecache 2> /dev/null || true
    say "Дополнение подписок установлено"
}

# ------------------------------------------------------------------ the core
detect_arch() {
    if command -v apk > /dev/null 2>&1; then
        apk --print-arch
    else
        opkg print-architecture | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $3, $2}' | sort -n | tail -n 1 | cut -d' ' -f2
    fi
}

expected_sha256() {
    # $1 package file name; prints the expected sha256 or nothing
    key="KNOWN_SHA256_$(printf '%s_%s' "$PE_VERSION" "$ARCH_NAME" | tr 'a-z.-' 'A-Z__')_$(printf '%s' "$EXT" | tr 'a-z' 'A-Z')"
    eval "known=\${$key:-}"
    if [ -n "$known" ]; then
        printf '%s' "$known"
        return
    fi
    # otherwise ask the release metadata
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
    [ -n "$ARCH_NAME" ] || die "не удалось определить архитектуру пакетов"
    file="${PE_FLAVOR}_${PE_VERSION}_openwrt_${ARCH_NAME}.${EXT}"
    url="https://github.com/$PE_REPO/releases/download/v$PE_VERSION/$file"

    say "Архитектура: $ARCH_NAME. Скачиваю $file"
    wget -qO "$WORK/$file" "$url" || die "не удалось скачать $url (проверьте архитектуру и версию)"

    want="$(expected_sha256 "$file")"
    have="$(sha256sum "$WORK/$file" | cut -d' ' -f1)"
    if [ -n "$want" ]; then
        [ "$want" = "$have" ] || die "контрольная сумма не совпала: ожидалась $want, получена $have"
        say "Контрольная сумма совпала: $have"
    elif [ "${PE_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        warn "контрольная сумма неизвестна ($have), продолжаю по PE_ALLOW_UNVERIFIED=1"
    else
        die "контрольная сумма $file неизвестна ($have). Сверьте её со страницей релиза https://github.com/$PE_REPO/releases/tag/v$PE_VERSION и запустите с PE_ALLOW_UNVERIFIED=1"
    fi

    mkdir -p "$BACKUP"
    [ -f "$ROOT/usr/bin/sing-box" ] && cp "$ROOT/usr/bin/sing-box" "$BACKUP/sing-box.orig"

    # Обновляем списки пакетов ДО остановки Podkop, пока работает DNS
    if [ "$EXT" = "ipk" ]; then
        opkg update > /dev/null 2>&1 || warn "opkg update не удался (продолжаю установку локального пакета)"
    fi

    # DNS goes through sing-box while Podkop runs, so stop it first
    [ -x "$ROOT/etc/init.d/podkop" ] && "$ROOT/etc/init.d/podkop" stop || true

    if [ "$EXT" = "ipk" ]; then
        opkg remove --force-depends sing-box sing-box-tiny > /dev/null 2>&1 || true
        opkg install "$WORK/$file" || die "установка ядра не удалась. Откат: opkg install sing-box"
    else
        apk add --allow-untrusted --overwrite "$WORK/$file" 2> /dev/null || \
            apk add --allow-untrusted "$WORK/$file" || \
            die "установка ядра не удалась. Откат: apk add sing-box"
    fi

    core_installed || warn "пакет podkop-engine не найден в списке установленных"
    say "Ядро установлено: $(sing-box version 2> /dev/null | head -n 1)"
}

# ---------------------------------------------------------------------- main
[ "$DO_ADDON" = "1" ] && install_addon
[ "$DO_CORE" = "1" ] && install_core

if [ -x "$ROOT/etc/init.d/podkop" ]; then
    say "Перезапускаю Podkop"
    "$ROOT/etc/init.d/podkop" restart || warn "не удалось перезапустить Podkop"
fi

say ""
say "Готово (rtr-subs $ADDON_VERSION). Обновите страницу LuCI (Ctrl+F5), выберите в секции тип «Подписка»,"
say "вставьте ссылку и нажмите Save & Apply. Удаление дополнения: sh install.sh --uninstall"
exit 0