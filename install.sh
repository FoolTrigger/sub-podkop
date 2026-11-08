#!/bin/sh
# rtr-subs: unofficial add-on for Podkop 0.7.24 on OpenWrt
#   1. auto-installs Podkop 0.7.24 directly from GitHub releases if missing;
#   2. adds subscription support (URL, HWID, update interval) in the Podkop UI;
#   3. installs the podkop-engine sing-box core (REALITY compatible with modern Xray servers).
#
# Usage:
#   sh install.sh                 install/update add-on and core (asks about XHTTP filter and backup)
#   sh install.sh --no-core       add-on only
#   sh install.sh --core-only     core only
#   sh install.sh --xhttp-filter  enable XHTTP filter (skip XHTTP nodes)
#   sh install.sh --allow-xhttp   disable XHTTP filter (keep XHTTP nodes)
#   sh install.sh --backup        create backup without asking
#   sh install.sh --no-backup     skip backup without asking
#   sh install.sh --uninstall     restore files/configuration from the latest backup
#
# Variables: PE_VERSION (default 1.13.21-r18), PE_FLAVOR (podkop-engine | podkop-engine-full),
#            PE_ALLOW_UNVERIFIED=1 (not recommended; default: 0)
# Optional: --no-safe-defaults skips resolve/uTLS UCI defaults.
# Core packages are resolved through the GitHub API to avoid OpenWrt uclient-fetch
# redirect-header limitations; SHA256 is required unless PE_ALLOW_UNVERIFIED=1 is set.

set -eu

ADDON_VERSION="1.4.1"
RAW_BASE="${RTR_SUBS_RAW:-https://raw.githubusercontent.com/FoolTrigger/sub-podkop/main}"
PODKOP_REPO="itdoginfo/podkop"
PODKOP_TAG="${PODKOP_TAG:-0.7.24}"
PE_VERSION="${PE_VERSION:-1.13.21-r18}"
PE_FLAVOR="${PE_FLAVOR:-podkop-engine}"
PE_REPO="podkop-net/podkop-engine"
PE_ALLOW_UNVERIFIED="${PE_ALLOW_UNVERIFIED:-0}"
ROOT="${ROOT:-}"

BIN="$ROOT/usr/bin/podkop"
LIB="$ROOT/usr/lib/podkop"
VIEW="$ROOT/www/luci-static/resources/view/podkop"
I18N="$ROOT/usr/lib/lua/luci/i18n"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/root/rtr-subs-backup-$STAMP-$$"
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
DO_SAFE_DEFAULTS=1
XHTTP_FILTER_CHOICE=""   # 1 = filter XHTTP (default/safe); 0 = allow XHTTP
BACKUP_CHOICE=""        # 1 = create backup; 0 = skip backup
for arg in "$@"; do
    case "$arg" in
    --no-core) DO_CORE=0 ;;
    --core-only) DO_ADDON=0 ;;
    --no-safe-defaults) DO_SAFE_DEFAULTS=0 ;;
    --xhttp-filter | --filter-xhttp)
        [ "$XHTTP_FILTER_CHOICE" != "0" ] || die "нельзя одновременно использовать --xhttp-filter и --allow-xhttp"
        XHTTP_FILTER_CHOICE=1
        ;;
    --allow-xhttp | --no-xhttp-filter)
        [ "$XHTTP_FILTER_CHOICE" != "1" ] || die "нельзя одновременно использовать --xhttp-filter и --allow-xhttp"
        XHTTP_FILTER_CHOICE=0
        ;;
    --backup)
        [ "$BACKUP_CHOICE" != "0" ] || die "нельзя одновременно использовать --backup и --no-backup"
        BACKUP_CHOICE=1
        ;;
    --no-backup)
        [ "$BACKUP_CHOICE" != "1" ] || die "нельзя одновременно использовать --backup и --no-backup"
        BACKUP_CHOICE=0
        ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -h | --help)
        sed -n '2,22p' "$0"
        printf '%s\n' \
            "  --xhttp-filter  включить фильтр XHTTP (узлы XHTTP пропускаются)" \
            "  --allow-xhttp   выключить фильтр XHTTP (узлы XHTTP разрешены)" \
            "  --backup        создать резервную копию без запроса" \
            "  --no-backup     не создавать резервную копию" \
            "  --no-safe-defaults  не менять UCI-настройки resolve/uTLS fallback"
        exit 0
        ;;
    *) die "неизвестный параметр: $arg" ;;
    esac
done

mkdir -p "$WORK"

[ "$(id -u)" = "0" ] || die "нужны права root"
command -v wget > /dev/null 2>&1 || die "не найден wget"

if [ "$DO_UNINSTALL" = "1" ]; then
    last=""
    for d in $(ls -d "$ROOT"/root/rtr-subs-backup-* 2>/dev/null | sort -r); do
        if [ -f "$d/.rtr-subs-backup" ] || [ -f "$d/usr/bin/podkop" ] || [ -f "$d/podkop" ]; then
            last="$d"
            break
        fi
    done
    [ -n "$last" ] || die "резервная копия не найдена в /root"
    say "Восстанавливаю файлы из $last"

    # New backups contain a manifest. Remove the current parser first; if it existed
    # before installation, the snapshot is restored by the file-copy loop below.
    # Older flat backups did not save subscription.sh.
    new_backup=0
    [ -f "$last/.rtr-subs-backup" ] && new_backup=1
    rm -f "$LIB/subscription.sh"

    # Restore the directory-layout backups created by rtr-subs 1.4.1+.
    for rel in \
        usr/bin/podkop \
        usr/lib/podkop/constants.sh \
        usr/lib/podkop/subscription.sh \
        www/luci-static/resources/view/podkop/main.js \
        www/luci-static/resources/view/podkop/section.js \
        usr/lib/lua/luci/i18n/podkop.ru.lmo \
        etc/config/podkop \
        etc/crontabs/root \
        etc/init.d/podkop \
        usr/bin/sing-box
    do
        if [ -f "$last/$rel" ]; then
            mkdir -p "$ROOT/$(dirname "$rel")"
            cp -a "$last/$rel" "$ROOT/$rel" || die "не удалось восстановить $rel"
            case "$rel" in
                usr/bin/podkop|usr/bin/sing-box) chmod 755 "$ROOT/$rel" 2>/dev/null || true ;;
            esac
        fi
    done

    # Restore/remove the subscription cache according to the snapshot manifest.
    # A core-only backup marks this path as not included and leaves it untouched.
    if [ "$new_backup" = "1" ]; then
        subscriptions_state="$(sed -n 's/^SUBSCRIPTIONS_STATE=//p' "$last/.rtr-subs-backup" | head -n 1)"
        case "$subscriptions_state" in
            present)
                rm -rf "$ROOT/etc/podkop/subscriptions"
                mkdir -p "$ROOT/etc/podkop"
                cp -a "$last/etc/podkop/subscriptions" "$ROOT/etc/podkop/subscriptions"
                ;;
            absent)
                rm -rf "$ROOT/etc/podkop/subscriptions"
                ;;
            not_included) ;;
        esac
    elif [ ! -d "$last/usr" ]; then
        # Legacy flat backup created by rtr-subs <= 1.4.0.
        rm -rf "$ROOT/etc/podkop/subscriptions"
    fi

    # Backward compatibility with flat backups made by rtr-subs <= 1.4.0.
    [ -f "$last/podkop" ] && cp "$last/podkop" "$BIN" && chmod 755 "$BIN"
    [ -f "$last/constants.sh" ] && cp "$last/constants.sh" "$LIB/constants.sh"
    [ -f "$last/subscription.sh" ] && cp "$last/subscription.sh" "$LIB/subscription.sh"
    [ -f "$last/main.js" ] && cp "$last/main.js" "$VIEW/main.js"
    [ -f "$last/section.js" ] && cp "$last/section.js" "$VIEW/section.js"
    [ -f "$last/podkop.ru.lmo" ] && cp "$last/podkop.ru.lmo" "$I18N/podkop.ru.lmo"

    if [ ! -f "$last/etc/crontabs/root" ] && [ -f "$ROOT/etc/crontabs/root" ]; then
        sed -i '/subscription/d; /rtr-subs/d' "$ROOT/etc/crontabs/root" 2>/dev/null || true
    fi
    [ -x "$ROOT/etc/init.d/cron" ] && "$ROOT/etc/init.d/cron" restart >/dev/null 2>&1 || true

    # A copied sing-box executable restores the previous binary, but package-manager
    # metadata still belongs to the version installed by opkg/apk.
    if [ -f "$last/usr/bin/sing-box" ]; then
        warn "Бинарный файл sing-box восстановлен из копии; сведения opkg/apk о версии пакета не откатываются"
    fi

    rm -rf "$last"
    rm -f "$ROOT"/tmp/luci-indexcache* 2>/dev/null || true
    rm -rf "$ROOT"/tmp/luci-modulecache 2>/dev/null || true
    [ -x "$ROOT/etc/init.d/podkop" ] && "$ROOT/etc/init.d/podkop" restart || true
    say "Готово."
    exit 0
fi

# Read an interactive answer from the controlling terminal when available.
# When stdin is not a terminal (e.g. curl | sh), use documented safe defaults.
read_tty_answer() {
    prompt="$1"
    # Access checks alone are insufficient on BusyBox: /dev/tty may exist but
    # the process can have no controlling terminal (for example, during tests).
    if ( : </dev/tty >/dev/tty ) 2>/dev/null; then
        printf '%s' "$prompt" >/dev/tty || return 1
        IFS= read -r REPLY </dev/tty || REPLY=""
        return 0
    fi
    return 1
}

choose_xhttp_policy() {
    [ "$DO_ADDON" = "1" ] || return 0

    if [ -z "$XHTTP_FILTER_CHOICE" ]; then
        say ""
        say "Фильтр XHTTP защищает от известных проблем совместимости XHTTP с привязкой интерфейса в Podkop 0.7.24."
        say "При включённом фильтре XHTTP-узлы будут пропускаться; остальные узлы подписки останутся доступными."
        while :; do
            if read_tty_answer "Включить фильтр XHTTP? [Y/n]: "; then
                case "$(printf '%s' "$REPLY" | tr 'A-Z' 'a-z')" in
                    ''|y|yes|д|да) XHTTP_FILTER_CHOICE=1; break ;;
                    n|no|н|нет) XHTTP_FILTER_CHOICE=0; break ;;
                    *) printf '%s\n' "Введите y/д или n/н." >/dev/tty ;;
                esac
            else
                XHTTP_FILTER_CHOICE=1
                say "Нет интерактивного терминала: фильтр XHTTP включён по умолчанию. Используйте --allow-xhttp, чтобы разрешить XHTTP."
                break
            fi
        done
    fi

    if [ "$XHTTP_FILTER_CHOICE" = "1" ]; then
        say "Выбрано: фильтр XHTTP ВКЛЮЧЁН (XHTTP-узлы будут исключаться из подписки)."
    else
        say "Выбрано: фильтр XHTTP ВЫКЛЮЧЕН (XHTTP-узлы будут разрешены; возможны проблемы совместимости)."
    fi
}

backup_measure_path() {
    src="$1"
    if [ -e "$src" ] || [ -L "$src" ]; then
        kb="$(du -sk "$src" 2>/dev/null | awk '{print $1}')"
        case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
        backup_total_kb=$((backup_total_kb + kb))
    fi
}

backup_copy_path() {
    src="$1"
    if [ -e "$src" ] || [ -L "$src" ]; then
        case "$src" in
            "$ROOT"/*) rel="${src#"$ROOT"/}" ;;
            /*) rel="${src#/}" ;;
            *) rel="$src" ;;
        esac
        mkdir -p "$BACKUP/$(dirname "$rel")"
        cp -a "$src" "$BACKUP/$rel" || die "не удалось сохранить резервную копию: $src"
        backup_count=$((backup_count + 1))
    fi
}

backup_size_kb() {
    backup_total_kb=0
    backup_measure_path "$ROOT/etc/config/podkop"
    if [ "$DO_ADDON" = "1" ]; then
        for src in "$BIN" "$LIB/constants.sh" "$LIB/subscription.sh" \
            "$VIEW/main.js" "$VIEW/section.js" "$I18N/podkop.ru.lmo" \
            "$ROOT/etc/init.d/podkop" "$ROOT/etc/crontabs/root" \
            "$ROOT/etc/podkop/subscriptions"
        do
            backup_measure_path "$src"
        done
    fi
    if [ "$DO_CORE" = "1" ]; then
        backup_measure_path "$ROOT/usr/bin/sing-box"
    fi
    printf '%s' "$backup_total_kb"
}

format_kilobytes() {
    awk -v kb="$1" 'BEGIN {
        if (kb >= 1048576) printf "%.2f GiB", kb / 1048576
        else if (kb >= 1024) printf "%.1f MiB", kb / 1024
        else printf "%d KiB", kb
    }'
}

create_backup() {
    [ "$BACKUP_CHOICE" = "1" ] || {
        say "Резервная копия по выбору пользователя отключена."
        return 0
    }

    backup_count=0
    mkdir -p "$BACKUP"
    backup_copy_path "$ROOT/etc/config/podkop"
    if [ "$DO_ADDON" = "1" ]; then
        for src in "$BIN" "$LIB/constants.sh" "$LIB/subscription.sh" \
            "$VIEW/main.js" "$VIEW/section.js" "$I18N/podkop.ru.lmo" \
            "$ROOT/etc/init.d/podkop" "$ROOT/etc/crontabs/root" \
            "$ROOT/etc/podkop/subscriptions"
        do
            backup_copy_path "$src"
        done
    fi
    if [ "$DO_CORE" = "1" ]; then
        backup_copy_path "$ROOT/usr/bin/sing-box"
    fi

    if [ "$DO_ADDON" = "1" ]; then
        if [ -d "$ROOT/etc/podkop/subscriptions" ]; then
            subscriptions_state="present"
        else
            subscriptions_state="absent"
        fi
    else
        subscriptions_state="not_included"
    fi
    {
        printf 'ADDON_VERSION=%s\n' "$ADDON_VERSION"
        printf 'DO_ADDON=%s\n' "$DO_ADDON"
        printf 'DO_CORE=%s\n' "$DO_CORE"
        printf 'SUBSCRIPTIONS_STATE=%s\n' "$subscriptions_state"
    } > "$BACKUP/.rtr-subs-backup"

    backup_actual_kb="$(du -sk "$BACKUP" 2>/dev/null | awk '{print $1}')"
    say "Резервная копия создана: $BACKUP"
    say "Сохранено объектов: $backup_count; фактический размер: $(format_kilobytes "${backup_actual_kb:-0}")"
    [ "$backup_count" -gt 0 ] || say "В резервной копии сохранена информация о состоянии; исходных файлов для копирования не было."
}

choose_backup_policy() {
    estimated_kb="$(backup_size_kb)"
    estimated_size="$(format_kilobytes "$estimated_kb")"
    say ""
    say "Расчётный размер резервной копии: $estimated_size"
    say "В копию войдут только существующие файлы, относящиеся к выбранной операции: UCI-конфигурация."
    if [ "$DO_ADDON" = "1" ]; then
        say "Также: файлы Podkop/rtr-subs, кэш подписок и crontab."
    fi
    if [ "$DO_CORE" = "1" ]; then
        say "Также: текущий бинарный файл sing-box."
    fi
    say "Это не полный бэкап OpenWrt."

    if [ -n "$BACKUP_CHOICE" ]; then
        [ "$BACKUP_CHOICE" = "1" ] && say "Резервное копирование включено параметром --backup." \
            || say "Резервное копирование отключено параметром --no-backup."
        return 0
    fi

    while :; do
        if read_tty_answer "Создать резервную копию перед установкой? [Y/n]: "; then
            case "$(printf '%s' "$REPLY" | tr 'A-Z' 'a-z')" in
                ''|y|yes|д|да) BACKUP_CHOICE=1; break ;;
                n|no|н|нет) BACKUP_CHOICE=0; break ;;
                *) printf '%s\n' "Введите y/д или n/н." >/dev/tty ;;
            esac
        else
            BACKUP_CHOICE=1
            say "Нет интерактивного терминала: резервная копия будет создана по умолчанию. Используйте --no-backup, чтобы пропустить её."
            break
        fi
    done
}

apply_xhttp_filter_choice() {
    [ "$DO_ADDON" = "1" ] || return 0
    command -v uci >/dev/null 2>&1 || die "uci не найден; невозможно сохранить выбранный режим XHTTP"

    if [ "$XHTTP_FILTER_CHOICE" = "1" ]; then
        allow_xhttp=0
    else
        allow_xhttp=1
    fi

    # The parser reads this option from the named Podkop 'settings' section.
    if ! uci -q get podkop.settings >/dev/null 2>&1; then
        uci -q set podkop.settings='settings' || die "не удалось создать секцию podkop.settings"
    fi
    uci -q set "podkop.settings.rtr_subs_allow_xhttp=$allow_xhttp" \
        || die "не удалось сохранить выбор фильтра XHTTP"
    uci commit podkop || die "не удалось сохранить настройки фильтра XHTTP"

    if [ "$XHTTP_FILTER_CHOICE" = "1" ]; then
        say "Сохранено: podkop.settings.rtr_subs_allow_xhttp=0 (фильтр включён)"
    else
        say "Сохранено: podkop.settings.rtr_subs_allow_xhttp=1 (фильтр выключен)"
    fi
}

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

# Patch the downloaded subscription parser without changing the user's upstream UI files.
# The legacy parser remains responsible for protocol/transport allow-listing. This wrapper
# adds strict endpoint validation, decode-link validation and a safe XHTTP default.
patch_subscription_payload() {
    local file="$PAYLOAD/subscription.sh"
    local tmp="$PAYLOAD/subscription.sh.rtr-tmp"

    [ -s "$file" ] || die "subscription.sh отсутствует в payload"
    if grep -q 'RTR_SUBS_HARDENED_FILTER_V1' "$file"; then
        say "Проверки подписок уже присутствуют"
        return 0
    fi

    awk '
        BEGIN { renamed = 0 }
        !renamed && /^_subscription_filter_links\(\)[[:space:]]*\{/ {
            sub(/^_subscription_filter_links/, "_subscription_filter_links_legacy")
            renamed = 1
        }
        { print }
        END { if (!renamed) exit 42 }
    ' "$file" > "$tmp" || die "не удалось найти функцию _subscription_filter_links() в subscription.sh"

    cat >> "$tmp" << 'RTR_SUBS_HARDENED_FILTER_V1'

# RTR_SUBS_HARDENED_FILTER_V1
# rtr-subs 1.4.0: validate server/port and the complete URI before caching it.
_rtr_subs_valid_ipv4() {
    [ "$1" != "0.0.0.0" ] || return 1
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9][0-9]?[0-9]?$/ || ($i + 0) > 255) exit 1
            }
        }
    '
}

_rtr_subs_valid_host() {
    local host="$1" host6
    [ -n "$host" ] || return 1
    [ "$host" != "0.0.0.0" ] || return 1

    # IPv6 literal (url_get_host may return it with or without square brackets).
    case "$host" in
        \[*\])
            host6="${host#\[}"
            host6="${host6%\]}"
            ;;
        *) host6="$host" ;;
    esac
    case "$host6" in
        *:*)
            printf '%s\n' "$host6" | grep -Eq '^[0-9A-Fa-f:.]+$'
            return $?
            ;;
    esac

    # A host containing only digits and dots must be a valid IPv4 address.
    # This rejects broken single-label hosts such as "120" while preserving IPv4.
    case "$host" in
        *[!0-9.]*) ;;
        *) _rtr_subs_valid_ipv4 "$host"; return $? ;;
    esac

    # DNS hostname: at least two labels, no empty labels, no leading/trailing hyphens.
    printf '%s\n' "$host" | awk '
        BEGIN { FS = "." }
        {
            if (length($0) > 253 || $0 ~ /^\./ || $0 ~ /\.$/ || $0 ~ /\.\./) exit 1
            if (NF < 2) exit 1
            for (i = 1; i <= NF; i++) {
                if (length($i) < 1 || length($i) > 63) exit 1
                if ($i !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) exit 1
            }
        }
    '
}

_rtr_subs_valid_port() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

_subscription_filter_links() {
    local link scheme host port transport allow_xhttp
    config_get allow_xhttp "settings" "rtr_subs_allow_xhttp" "0"

    _subscription_filter_links_legacy |
        while IFS= read -r link; do
            [ -n "$link" ] || continue

            scheme="$(url_get_scheme "$link")"
            host="$(url_get_host "$link")"
            port="$(url_get_port "$link")"

            if ! _rtr_subs_valid_host "$host"; then
                log "Skipped subscription node: invalid server address '$host' (protocol: $scheme)" "warn"
                continue
            fi
            if ! _rtr_subs_valid_port "$port"; then
                log "Skipped subscription node: invalid server port '$port' (protocol: $scheme)" "warn"
                continue
            fi

            # Podkop 0.7.24 binds outgoing traffic to an interface (auto-detect or
            # default_interface). XHTTP has a known compatibility issue with this mode.
            # Keep XHTTP opt-in until the user explicitly accepts that risk.
            if [ "$scheme" = "vless" ] || [ "$scheme" = "trojan" ]; then
                transport="$(url_get_query_param "$(url_strip_fragment "$link")" "type" | tr 'A-Z' 'a-z')"
                case "$transport" in
                    xhttp | splithttp)
                        if [ "$allow_xhttp" != "1" ]; then
                            log "Skipped XHTTP subscription node ($host): disabled by rtr-subs safety policy; set podkop.settings.rtr_subs_allow_xhttp=1 to override" "warn"
                            continue
                        fi
                        log "XHTTP node explicitly allowed by podkop.settings.rtr_subs_allow_xhttp=1: $host" "warn"
                        ;;
                esac
            fi

            # The podkop-engine decoder builds and validates the outbound using the
            # same schema checks as sing-box. Read the URI through stdin so credentials
            # do not appear in the process list.
            if sing_box_has_feature "tools.decode-link"; then
                if ! printf '%s\n' "$link" | sing-box tools decode-link --compact >/dev/null 2>&1; then
                    log "Skipped subscription node: sing-box decode-link rejected $scheme server '$host:$port'" "warn"
                    continue
                fi
            fi

            echo "$link"
        done
}
RTR_SUBS_HARDENED_FILTER_V1

    chmod 644 "$tmp"
    mv "$tmp" "$file"
    say "Добавлены проверки адресов, портов, decode-link и XHTTP"
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
    patch_subscription_payload

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

load_release_metadata() {
    [ -s "$WORK/release.json" ] && return 0
    wget -qO "$WORK/release.json" \
        "https://api.github.com/repos/$PE_REPO/releases/tags/v$PE_VERSION" 2>/dev/null \
        || return 1
    [ -s "$WORK/release.json" ]
}

release_asset_field() {
    local asset_name="$1" field="$2"
    load_release_metadata || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg n "$asset_name" --arg f "$field" \
            '.assets[]? | select(.name == $n) | .[$f] // empty' \
            "$WORK/release.json" 2>/dev/null | head -n 1
    elif command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -i "$WORK/release.json" \
            -e "@.assets[@.name='$asset_name'].$field" 2>/dev/null | head -n 1
    fi
}

# OpenWrt 24.10's wget/uclient-fetch may stall on the long redirect header
# from github.com/releases/download. Resolve the asset through the GitHub API
# and request application/octet-stream from the API asset URL instead.
download_core_asset() {
    local asset_name="$1" output="$2" asset_url
    asset_url="$(release_asset_field "$asset_name" url)"
    [ -n "$asset_url" ] || {
        warn "GitHub API не вернул URL файла $asset_name"
        return 1
    }
    wget -q --header='Accept: application/octet-stream' \
        -O "$output" "$asset_url" || {
        warn "Не удалось скачать asset через GitHub API: $asset_name"
        rm -f "$output"
        return 1
    }
    [ -s "$output" ] || {
        warn "GitHub вернул пустой файл: $asset_name"
        rm -f "$output"
        return 1
    }
}

expected_sha256() {
    local asset_name="$1" key known
    key="KNOWN_SHA256_$(printf '%s_%s' "$PE_VERSION" "$ARCH_NAME" | tr 'a-z.-' 'A-Z__')_$(printf '%s' "$EXT" | tr 'a-z' 'A-Z')"
    eval "known=\${$key:-}"
    if [ -n "$known" ]; then
        printf '%s' "$known"
        return
    fi
    release_asset_field "$asset_name" digest | sed 's/^sha256://'
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

# Compare numeric version components (major.minor.patch.revision).
# Returns -1 when current < target, 0 when equal, 1 when current > target,
# and 'unknown' if either version cannot be parsed safely.
version_compare() {
    awk -v current="$1" -v target="$2" '
        BEGIN {
            nc = split(current, c, /[^0-9]+/)
            nt = split(target, t, /[^0-9]+/)
            if (nc < 4 || nt < 4 || c[1] == "" || c[2] == "" || c[3] == "" || c[4] == "" ||
                t[1] == "" || t[2] == "" || t[3] == "" || t[4] == "") {
                print "unknown"
                exit
            }
            for (i = 1; i <= 4; i++) {
                if ((c[i] + 0) < (t[i] + 0)) { print -1; exit }
                if ((c[i] + 0) > (t[i] + 0)) { print 1; exit }
            }
            print 0
        }
    '
}

install_core() {
    if core_installed; then
        current_version="$(sing-box version 2>/dev/null | awk 'NR == 1 {print $3}')"
        target_version="$(printf '%s' "$PE_VERSION" | sed 's/-r/-pdk-r/')"
        comparison="$(version_compare "$current_version" "$target_version")"
        case "$comparison" in
            0)
                say "Ядро уже актуально: $(sing-box version 2>/dev/null | head -n 1)"
                return
                ;;
            1)
                say "Установлено более новое ядро ($current_version), чем запрошено ($target_version); downgrade пропущен"
                return
                ;;
            -1)
                say "Обновляю podkop-engine: $current_version -> $target_version"
                ;;
            *)
                warn "Не удалось сравнить версию установленного ядра '$current_version' с '$target_version'. Обновление пропущено; для принудительной установки задайте PE_FORCE_CORE_UPDATE=1"
                [ "${PE_FORCE_CORE_UPDATE:-0}" = "1" ] || return
                ;;
        esac
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

    say "Архитектура: $ARCH_NAME. Скачиваю $file через GitHub API"
    if ! download_core_asset "$file" "$WORK/$file"; then
        if [ "$EXT" = "apk" ]; then
            SHORT_ARCH="$(apk --print-arch 2>/dev/null || true)"
            if [ -n "$SHORT_ARCH" ] && [ "$SHORT_ARCH" != "$ARCH_NAME" ]; then
                warn "Пакет для $ARCH_NAME не найден, пробую архитектуру apk: $SHORT_ARCH"
                ARCH_NAME="$SHORT_ARCH"
                file="${PE_FLAVOR}_${PE_VERSION}_openwrt_${ARCH_NAME}.${EXT}"
                download_core_asset "$file" "$WORK/$file" \
                    || die "не удалось скачать пакет для архитектуры $ARCH_NAME"
            else
                die "не удалось скачать пакет $file для архитектуры $ARCH_NAME"
            fi
        else
            die "не удалось скачать пакет $file для архитектуры $ARCH_NAME"
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

apply_safe_defaults() {
    [ "$DO_SAFE_DEFAULTS" = "1" ] || {
        say "Безопасные UCI-настройки пропущены (--no-safe-defaults)"
        return 0
    }
    command -v uci >/dev/null 2>&1 || {
        warn "uci не найден; автоматические настройки Podkop не применены"
        return 0
    }
    [ -r /lib/functions.sh ] || {
        warn "/lib/functions.sh не найден; не удалось перечислить секции Podkop"
        return 0
    }

    . /lib/functions.sh
    config_load podkop
    safe_defaults_changed=0

    _rtr_enable_resolve_for_proxy_section() {
        local section="$1" connection_type current
        config_get connection_type "$section" "connection_type"
        [ "$connection_type" = "proxy" ] || return 0
        current="$(uci -q get "podkop.$section.resolve_real_ip_for_routing" 2>/dev/null || true)"
        if [ "$current" != "1" ]; then
            uci -q set "podkop.$section.resolve_real_ip_for_routing=1" || {
                warn "Не удалось включить resolve_real_ip_for_routing для секции $section"
                return 0
            }
            say "Включён resolve_real_ip_for_routing для секции $section"
            safe_defaults_changed=1
        fi
        return 0
    }

    config_foreach _rtr_enable_resolve_for_proxy_section section

    sb_version_text="$(sing-box version 2>/dev/null || true)"
    if printf '%s\n' "$sb_version_text" | grep -q 'tls.utls-fallback'; then
        current="$(uci -q get podkop.settings.enable_utls_fallback 2>/dev/null || true)"
        if [ "$current" != "1" ]; then
            uci -q set podkop.settings.enable_utls_fallback=1 || warn "Не удалось включить uTLS fallback"
            safe_defaults_changed=1
            say "Включён uTLS fallback для совместимости REALITY"
        fi
    else
        warn "Текущая сборка sing-box не содержит tls.utls-fallback; настройка не включена"
    fi

    if [ "$safe_defaults_changed" -eq 1 ]; then
        uci commit podkop || die "не удалось сохранить настройки Podkop"
    fi
}

# Ask before changing the device. The backup estimate is shown before the user decides.
choose_xhttp_policy
choose_backup_policy
create_backup

[ "$DO_ADDON" = "1" ] && install_addon
[ "$DO_CORE" = "1" ] && install_core
apply_xhttp_filter_choice
apply_safe_defaults

if [ -x "$ROOT/etc/init.d/podkop" ]; then
    say "Перезапускаю Podkop"
    "$ROOT/etc/init.d/podkop" restart || warn "не удалось перезапустить Podkop"
fi

say ""
say "Готово (rtr-subs $ADDON_VERSION). Фильтр XHTTP и резервное копирование настроены по выбору пользователя."
exit 0
