#!/usr/bin/env bash
#
# rollback.sh — откат изменений, сделанных optimize.sh / protect.sh.
# Снимает наши конфиги, отключает сервисы. Бэкапы остаются в /var/backups/remnawave-toolkit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_root

WHAT="${1:-all}"

rollback_optimize() {
    title "Откат: optimize"

    rm -f /etc/sysctl.d/99-remnawave-optimize.conf
    rm -f /etc/modules-load.d/remnawave-bbr.conf
    rm -f /etc/modules-load.d/remnawave-conntrack.conf
    rm -f /etc/systemd/system.conf.d/remnawave-limits.conf
    rm -f /etc/systemd/user.conf.d/remnawave-limits.conf
    rm -f /etc/systemd/journald.conf.d/remnawave-size.conf

    # Удаляем наш блок из limits.conf
    sed -i '/# === remnawave-node-toolkit ===/,/# === \/remnawave-node-toolkit ===/d' \
        /etc/security/limits.conf 2>/dev/null || true

    for svc in remnawave-nic-tune remnawave-cpu-perf remnawave-thp-off; do
        systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$svc.service"
    done

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true
    systemctl restart systemd-journald

    rm -f /var/lib/remnawave-toolkit/optimize.installed
    ok "optimize откатан (sysctl значения вернутся к дефолтам после reboot)"
}

rollback_protect() {
    title "Откат: protect"

    # Отменить сейфти-таймер если жив
    if [[ -f /tmp/remnawave-fw-safety.pid ]]; then
        kill "$(cat /tmp/remnawave-fw-safety.pid)" 2>/dev/null || true
        rm -f /tmp/remnawave-fw-safety.pid
    fi

    systemctl disable --now remnawave-blocklist.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/remnawave-blocklist.timer
    rm -f /etc/systemd/system/remnawave-blocklist.service
    rm -f /usr/local/sbin/remnawave-update-scanners
    rm -f /usr/local/sbin/remnawave-update-spamhaus
    rm -f /usr/local/sbin/remnawave-update-geoblock
    rm -rf /etc/remnawave-toolkit

    # Снять nftables правила
    nft flush ruleset

    # Если был бэкап /etc/nftables.conf — восстановим, иначе пишем пустой
    LATEST_BACKUP="$(ls -1dt /var/backups/remnawave-toolkit/*/ 2>/dev/null | head -1 || true)"
    if [[ -n "$LATEST_BACKUP" && -f "${LATEST_BACKUP}nftables.conf" ]]; then
        cp -a "${LATEST_BACKUP}nftables.conf" /etc/nftables.conf
        nft -f /etc/nftables.conf 2>/dev/null || true
        info "Восстановлен /etc/nftables.conf из $LATEST_BACKUP"
    else
        cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
flush ruleset
NFT
        warn "Бэкап /etc/nftables.conf не найден. Создан пустой /etc/nftables.conf."
    fi

    systemctl daemon-reload
    systemctl restart nftables 2>/dev/null || true

    # Если на этой машине когда-то был UFW — попробуем его перезапустить,
    # чтобы он восстановил свои правила
    if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')" == "active" ]]; then
        info "Перезапускаю UFW, чтобы восстановить его правила"
        ufw reload >/dev/null 2>&1 || systemctl restart ufw 2>/dev/null || true
    fi

    rm -f /var/lib/remnawave-toolkit/protect.installed
    ok "protect откатан"
}

case "$WHAT" in
    optimize) rollback_optimize ;;
    protect)  rollback_protect ;;
    all)      rollback_optimize; rollback_protect ;;
    *)
        err "Использование: $0 [optimize|protect|all]"
        exit 1
        ;;
esac

ok "Бэкапы по-прежнему в /var/backups/remnawave-toolkit/"
