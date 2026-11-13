#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_FILE="/etc/systemd/system/waydroid-network.service"
WAYDROID_SUBNET="192.168.240.0/24"

# Перезапустити скрипт із правами root, якщо його запущено звичайним користувачем.
if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -- bash "$0" "$@"
fi

for cmd in ip iptables systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Помилка: не знайдено команду '$cmd'." >&2
        exit 1
    fi
done

# Визначити інтерфейс, яким система виходить до інтернету.
OUT_IF="$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"

if [[ -z "$OUT_IF" ]]; then
    echo "Помилка: не вдалося визначити мережевий інтерфейс." >&2
    echo "Перевірте підключення або задайте OUT_IF у скрипті вручну." >&2
    exit 1
fi

echo "Зовнішній мережевий інтерфейс: $OUT_IF"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Network forwarding and NAT for Waydroid
After=firewalld.service docker.service waydroid-container.service
Wants=firewalld.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -i waydroid0 -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD 1 -i waydroid0 -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -o waydroid0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD 1 -o waydroid0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/iptables -t nat -C POSTROUTING -s ${WAYDROID_SUBNET} -o ${OUT_IF} -j MASQUERADE 2>/dev/null || /usr/sbin/iptables -t nat -I POSTROUTING 1 -s ${WAYDROID_SUBNET} -o ${OUT_IF} -j MASQUERADE'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now waydroid-network.service

echo
systemctl status waydroid-network.service --no-pager

echo
echo "Правила FORWARD для Waydroid:"
iptables -S FORWARD | grep -- 'waydroid0' || true

echo
echo "Правило NAT для Waydroid:"
iptables -t nat -S POSTROUTING | grep -- "$WAYDROID_SUBNET" || true
