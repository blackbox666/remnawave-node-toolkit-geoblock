#!/usr/bin/env bash
#
# install.sh — точка входа remnawave-node-toolkit.
# Использование:
#   sudo bash install.sh                    — интерактивное меню
#   sudo bash install.sh optimize           — только оптимизация
#   sudo bash install.sh protect            — только защита
#   sudo bash install.sh all                — оптимизация + защита
#   sudo bash install.sh rollback [opt|prot|all] — откат
#
# Установка с GitHub (публичный репо). CDN иногда отдаёт старый install.sh — добавь ?время к URL:
#   curl -fsSL "https://raw.githubusercontent.com/ded-maxim-1337/remnawave-node-toolkit-geoblock/main/install.sh?$(date +%s)" | sudo bash -s all
# Скрипты protect/optimize при скачивании с raw.githubusercontent.com получают свой nocache= (см. _repo_curl).
# Отключить: REMNAWAVE_CACHE_BUST=0
# Приватный репо: raw не отдаёт файлы без токена — git clone и sudo bash install.sh из каталога.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"

# Если запущено через curl|bash — самих скриптов рядом нет, нужно скачать
REPO_URL="${REMNAWAVE_REPO_URL:-https://raw.githubusercontent.com/ded-maxim-1337/remnawave-node-toolkit-geoblock/main}"
REPO_URL="${REPO_URL%/}"

_repo_curl() {
    # $1 = путь от корня репо (scripts/protect.sh), $2 = локальный файл (-o)
    local relpath="${1#./}"
    local dest="$2"
    local url="$REPO_URL/$relpath"
    if [[ "${REMNAWAVE_CACHE_BUST:-1}" == "1" && "$REPO_URL" == *"raw.githubusercontent.com"* ]]; then
        local q
        q="$(date +%s%N 2>/dev/null || echo "$(date +%s)$RANDOM")"
        url="${url}?nocache=${q}"
    fi
    curl -fsSL \
        -H 'Cache-Control: no-cache' \
        -H 'Pragma: no-cache' \
        "$url" -o "$dest"
}

if [[ ! -d "$SCRIPTS" ]]; then
    if [[ "$REPO_URL" == *"REPLACE_ME"* ]]; then
        echo "[x] В install.sh всё ещё placeholder REPLACE_ME в REPO_URL."
        echo "    A) Поправь в этом файле строку REPO_URL (GitHub-логин и имя репозитория) и закоммить."
        echo "    B) Или без правки файла (подставь свои USER и REPO):"
        echo "       export REMNAWAVE_REPO_URL=https://raw.githubusercontent.com/USER/REPO/main"
        echo "       curl -fsSL \"\$REMNAWAVE_REPO_URL/install.sh\" | sudo env REMNAWAVE_REPO_URL=\"\$REMNAWAVE_REPO_URL\" bash -s all"
        exit 1
    fi
    SCRIPTS="$(mktemp -d)/scripts"
    mkdir -p "$SCRIPTS/lib"
    echo "[*] Скачиваю модули из $REPO_URL (без кэша CDN) ..."
    for f in lib/common.sh optimize.sh protect.sh rollback.sh; do
        _repo_curl "scripts/$f" "$SCRIPTS/$f" \
            || { echo "[x] Не удалось скачать $f"; exit 1; }
    done
    chmod +x "$SCRIPTS"/*.sh "$SCRIPTS"/lib/*.sh
fi

# shellcheck source=scripts/lib/common.sh
. "$SCRIPTS/lib/common.sh"

require_root
detect_os

run_optimize() { bash "$SCRIPTS/optimize.sh"; }
run_protect()  { bash "$SCRIPTS/protect.sh"; }
run_rollback() { bash "$SCRIPTS/rollback.sh" "${1:-all}"; }

show_menu() {
    clear
    cat <<'BANNER'
┌─────────────────────────────────────────────────┐
│   remnawave-node-toolkit                        │
│   Оптимизация и защита Remnawave-ноды           │
├─────────────────────────────────────────────────┤
│                                                 │
│   1) Оптимизатор системы                        │
│      (BBR, sysctl, лимиты, swap, NIC, THP)      │
│                                                 │
│   2) Защита ноды                                │
│      (nftables, anti-DDoS, ASN-блок TSPU,       │
│       Spamhaus, авто-бан сканеров)              │
│                                                 │
│   3) Установить ВСЁ (1 + 2)                     │
│                                                 │
│   4) Откат                                      │
│                                                 │
│   0) Выход                                      │
│                                                 │
└─────────────────────────────────────────────────┘
BANNER
    read -r -p "Выбор: " choice
    case "$choice" in
        1) run_optimize ;;
        2) run_protect ;;
        3) run_optimize; run_protect ;;
        4)
            echo "  a) optimize"
            echo "  b) protect"
            echo "  c) всё"
            read -r -p "Что откатить? [c]: " r
            case "$r" in
                a|A) run_rollback optimize ;;
                b|B) run_rollback protect ;;
                *)   run_rollback all ;;
            esac
            ;;
        0) exit 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

case "${1:-}" in
    optimize)  run_optimize ;;
    protect)   run_protect ;;
    all)       run_optimize; run_protect ;;
    rollback)  run_rollback "${2:-all}" ;;
    "")        show_menu ;;
    -h|--help)
        sed -n '2,12p' "$0"
        ;;
    *)
        err "Неизвестная команда: $1"
        sed -n '2,12p' "$0"
        exit 1
        ;;
esac
