#!/bin/sh
# Builds rtr-subs.sh: install.sh with the files from ./files embedded (base64 tar.gz)
set -eu
cd "$(dirname "$0")"
OUT="${1:-rtr-subs.sh}"
{
    cat install.sh
    echo '#PAYLOAD#'
    tar czf - -C files podkop subscription.sh main.js section.js podkop.ru.lmo | base64 | tr -d '\n' | fold -w 76
    echo
} > "$OUT"
chmod +x "$OUT"
echo "Built $OUT ($(wc -c < "$OUT") bytes)"
