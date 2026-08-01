#!/usr/bin/env bash
# Общие функции для скриптов remnawave-node-toolkit

# shellcheck disable=SC2034
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "%b[*]%b %s\n" "$BLUE"   "$NC" "$*"; }
ok()    { printf "%b[+]%b %s\n" "$GREEN"  "$NC" "$*"; }
warn()  { printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$*"; }
err()   { printf "%b[x]%b %s\n" "$RED"    "$NC" "$*" >&2; }
title() { printf "\n%b== %s ==%b\n" "$BOLD" "$*" "$NC"; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "Запусти от root: sudo bash $0"
        exit 1
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "Не нашёл /etc/os-release — ОС не поддерживается"
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian) ;;
        *)
            err "Поддерживаются только Ubuntu/Debian. У тебя: $OS_ID"
            exit 1
            ;;
    esac
}

# Папка под бэкап измененных файлов
backup_dir() {
    local ts d
    ts="$(date +%Y%m%d-%H%M%S)"
    d="/var/backups/remnawave-toolkit/${ts}-$$"
    mkdir -p "$d"
    echo "$d"
}

backup_file() {
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        cp -a "$src" "$dst/"
    fi
}

# Ждём освобождения dpkg/apt (часто держит unattended-upgrades на свежих VPS)
wait_for_apt_lock() {
    local max_wait="${APT_LOCK_WAIT:-600}"
    local interval=5
    local waited=0
    local locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    while true; do
        local busy=0
        local lock
        for lock in "${locks[@]}"; do
            if command -v fuser >/dev/null 2>&1; then
                if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
                    busy=1
                    break
                fi
            fi
        done
        if (( busy == 0 )); then
            if pgrep -x unattended-upgr >/dev/null 2>&1 \
                || pgrep -x apt-get >/dev/null 2>&1 \
                || pgrep -x apt >/dev/null 2>&1 \
                || pgrep -x dpkg >/dev/null 2>&1; then
                busy=1
            fi
        fi
        if (( busy == 0 )); then
            return 0
        fi
        if (( waited == 0 )); then
            info "apt/dpkg занят (часто unattended-upgrades) — жду до ${max_wait}s..."
        elif (( waited % 30 == 0 )); then
            info "всё ещё жду apt/dpkg... ${waited}s"
        fi
        if (( waited >= max_wait )); then
            err "apt/dpkg не освободился за ${max_wait}s. Повтори позже или: systemctl stop unattended-upgrades"
            exit 1
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    local attempt max_attempts=8
    local err_out

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        wait_for_apt_lock
        err_out="$(mktemp)"
        if apt-get update -qq 2>"$err_out" \
            && apt-get install -y -qq --no-install-recommends "$@" >/dev/null 2>>"$err_out"; then
            rm -f "$err_out"
            return 0
        fi
        if grep -qiE 'Could not get lock|Unable to acquire|is another process using it' "$err_out"; then
            warn "apt lock (попытка $attempt/$max_attempts), жду 15s..."
            rm -f "$err_out"
            sleep 15
            continue
        fi
        cat "$err_out" >&2 || true
        rm -f "$err_out"
        err "Не удалось установить пакеты: $*"
        exit 1
    done
    err "apt так и не освободился после $max_attempts попыток. Пакеты: $*"
    exit 1
}

confirm() {
    local prompt="${1:-Продолжить?} [y/N]: "
    local ans
    read -r -p "$prompt" ans
    [[ "$ans" =~ ^[yYдД] ]]
}

# Определяет основной сетевой интерфейс по default route
default_iface() {
    ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

# Безопасное определение SSH-порта: сперва из активной sshd-сессии, потом из конфига
detect_ssh_port() {
    local p
    p="$(ss -tnlp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}')"
    if [[ -z "$p" ]]; then
        p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
    fi
    echo "${p:-22}"
}
