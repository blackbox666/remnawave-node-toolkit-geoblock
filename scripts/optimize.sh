#!/usr/bin/env bash
#
# optimize.sh — оптимизатор системы для Remnawave-ноды.
# Тюнит ядро, сеть, лимиты, swap, journald, отключает THP, поднимает CPU governor.
#
# Идемпотентен: повторный запуск перезапишет конфиги (старые уйдут в бэкап).
# Откат: scripts/rollback.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_root
detect_os

BACKUP="$(backup_dir)"
info "Бэкап изменяемых файлов: $BACKUP"

# ─── 1. Зависимости ──────────────────────────────────────────────────────────
title "Установка зависимостей"
apt_install ca-certificates curl irqbalance ethtool
ok "Зависимости установлены"

# ─── 2. Sysctl ───────────────────────────────────────────────────────────────
title "Sysctl: BBR, буферы, conntrack, anti-spoof"

backup_file /etc/sysctl.conf "$BACKUP"
backup_file /etc/sysctl.d/99-remnawave-optimize.conf "$BACKUP"

cat > /etc/sysctl.d/99-remnawave-optimize.conf <<'SYSCTL'
# === remnawave-node-toolkit / optimize ===

# --- Network core ---
net.core.default_qdisc            = fq
net.core.netdev_max_backlog       = 250000
net.core.somaxconn                = 65535
net.core.rmem_default             = 2097152
net.core.wmem_default             = 2097152
net.core.rmem_max                 = 67108864
net.core.wmem_max                 = 67108864
net.core.optmem_max               = 65536

# --- TCP ---
net.ipv4.tcp_congestion_control   = bbr
net.ipv4.tcp_fastopen             = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse             = 1
net.ipv4.tcp_fin_timeout          = 15
net.ipv4.tcp_keepalive_time       = 300
net.ipv4.tcp_keepalive_intvl      = 30
net.ipv4.tcp_keepalive_probes     = 5
net.ipv4.tcp_max_syn_backlog      = 65535
net.ipv4.tcp_max_tw_buckets       = 2000000
net.ipv4.tcp_mtu_probing          = 1
net.ipv4.tcp_no_metrics_save      = 1
net.ipv4.tcp_rfc1337              = 1
net.ipv4.tcp_sack                 = 1
net.ipv4.tcp_window_scaling       = 1
net.ipv4.tcp_rmem                 = 4096 87380 67108864
net.ipv4.tcp_wmem                 = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat        = 131072
net.ipv4.tcp_ecn                  = 1
net.ipv4.ip_local_port_range      = 10000 65535

# --- UDP ---
net.ipv4.udp_rmem_min             = 8192
net.ipv4.udp_wmem_min             = 8192

# --- IP forwarding (для XRay/VLESS host network mode) ---
net.ipv4.ip_forward               = 1
net.ipv4.conf.all.forwarding      = 1
net.ipv6.conf.all.forwarding      = 1

# --- Conntrack: больше одновременных соединений ---
net.netfilter.nf_conntrack_max                  = 2000000
net.nf_conntrack_max                            = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_buckets              = 500000

# --- SYN flood (на уровне ядра) ---
net.ipv4.tcp_syncookies           = 1
net.ipv4.tcp_synack_retries       = 2
net.ipv4.tcp_syn_retries          = 2

# --- Anti-spoof / ICMP ---
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv4.conf.all.secure_redirects         = 0
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- Память ---
vm.swappiness                = 10
vm.dirty_ratio               = 10
vm.dirty_background_ratio    = 5
vm.overcommit_memory         = 1

# --- Файловые дескрипторы ---
fs.file-max                  = 2097152
fs.nr_open                   = 2097152
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192

# --- Kernel Hardening ---
# ASLR: полная рандомизация адресного пространства
kernel.randomize_va_space    = 2
# Ограничить доступ к dmesg для непривилегированных пользователей
kernel.dmesg_restrict        = 1
# Запретить ptrace к процессам вне родительской иерархии (антиинъекции)
kernel.yama.ptrace_scope     = 1
# Защита симлинков: разрешать follow только если владелец совпадает
fs.protected_symlinks        = 1
# Защита хардлинков: запретить ссылки на файлы, которыми не владеешь
fs.protected_hardlinks       = 1
# IPv6: отключить редиректы (как для IPv4)
net.ipv6.conf.all.accept_redirects      = 0
net.ipv6.conf.default.accept_redirects  = 0
SYSCTL

# Подгрузить модули
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
echo "tcp_bbr"      > /etc/modules-load.d/remnawave-bbr.conf
echo "nf_conntrack" > /etc/modules-load.d/remnawave-conntrack.conf

# Применить, не падая на отсутствующих ключах (например, если nf_conntrack ещё не загрузился)
sysctl --system >/dev/null 2>&1 || true

if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx bbr; then
    ok "BBR активен"
else
    warn "BBR не применился, проверь поддержку ядра (uname -r)"
fi

# ─── 3. Лимиты файловых дескрипторов ─────────────────────────────────────────
title "Лимиты"

backup_file /etc/security/limits.conf "$BACKUP"
# Удалить наш предыдущий блок, если был
sed -i '/# === remnawave-node-toolkit ===/,/# === \/remnawave-node-toolkit ===/d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<'LIMITS'
# === remnawave-node-toolkit ===
*       soft    nofile  1048576
*       hard    nofile  1048576
*       soft    nproc   1048576
*       hard    nproc   1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
# === /remnawave-node-toolkit ===
LIMITS

# Лимиты для systemd-сервисов (Docker запускается оттуда)
mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat > /etc/systemd/system.conf.d/remnawave-limits.conf <<'L'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
L
cp /etc/systemd/system.conf.d/remnawave-limits.conf /etc/systemd/user.conf.d/remnawave-limits.conf
ok "nofile/nproc подняты до 1048576"

# ─── 4. Swap ─────────────────────────────────────────────────────────────────
title "Swap"
if [[ ! -f /swapfile ]] && ! swapon --show | grep -q .; then
    SWAP_SIZE="${REMNAWAVE_SWAP_SIZE:-2G}"
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Создан /swapfile $SWAP_SIZE"
else
    info "Swap уже есть, пропускаю"
fi

# ─── 5. journald: ограничить размер логов ────────────────────────────────────
title "journald (ограничение размера логов)"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/remnawave-size.conf <<'J'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
J
systemctl restart systemd-journald
ok "journald: 200M макс."

# ─── 6. Тюнинг сетевой карты ─────────────────────────────────────────────────
title "NIC tuning"
NIC="$(default_iface || true)"
if [[ -n "${NIC:-}" ]]; then
    cat > /etc/systemd/system/remnawave-nic-tune.service <<EOF
[Unit]
Description=Remnawave NIC tuning ($NIC)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
    ethtool -G $NIC rx 4096 tx 4096 2>/dev/null || true; \
    ethtool -K $NIC gro on gso on tso on 2>/dev/null || true; \
    ip link set $NIC txqueuelen 10000 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now remnawave-nic-tune.service >/dev/null 2>&1 || true
    ok "NIC=$NIC: ring buffer 4096, GRO/GSO/TSO on"
else
    warn "Не определил основной интерфейс, NIC tuning пропущен"
fi

# ─── 7. CPU governor = performance ───────────────────────────────────────────
title "CPU governor"
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    cat > /etc/systemd/system/remnawave-cpu-perf.service <<'EOF'
[Unit]
Description=Remnawave CPU governor → performance
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$c" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now remnawave-cpu-perf.service >/dev/null 2>&1 || true
    ok "CPU governor → performance"
else
    info "cpufreq недоступен (вероятно, виртуалка) — пропуск"
fi

# ─── 8. THP off (лучше для сетевых нагрузок) ────────────────────────────────
title "Transparent Huge Pages → never"
cat > /etc/systemd/system/remnawave-thp-off.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now remnawave-thp-off.service >/dev/null 2>&1 || true
ok "THP отключен"

# ─── 9. IRQ balance ──────────────────────────────────────────────────────────
title "irqbalance"
systemctl enable --now irqbalance >/dev/null 2>&1 || true
ok "irqbalance запущен"

# ─── 10. Маркер установки ────────────────────────────────────────────────────
mkdir -p /var/lib/remnawave-toolkit
cat > /var/lib/remnawave-toolkit/optimize.installed <<EOF
installed_at=$(date -Is)
backup=$BACKUP
nic=${NIC:-none}
EOF

title "ГОТОВО"
ok "Оптимизатор применён."
echo
echo "  Текущие значения:"
printf "    %-40s %s\n" "tcp_congestion_control:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "default_qdisc:"          "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "somaxconn:"              "$(sysctl -n net.core.somaxconn 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "nf_conntrack_max:"       "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "file-max:"               "$(sysctl -n fs.file-max 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "randomize_va_space:"     "$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "dmesg_restrict:"         "$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "yama.ptrace_scope:"      "$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo n/a)"
printf "    %-40s %s\n" "protected_symlinks:"     "$(sysctl -n fs.protected_symlinks 2>/dev/null || echo n/a)"
echo
warn "Часть лимитов (nofile для пользовательских shell-сессий) применится после перелогина."
warn "Перезагрузка не обязательна, но желательна, чтобы systemd-сервисы подхватили новые DefaultLimit*."
