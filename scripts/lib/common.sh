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

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "$@" >/dev/null
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
