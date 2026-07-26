#!/bin/bash
# Remove public ingress after Tailscale connectivity has been verified.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo bash scripts/lockdown-vpn.sh"
  exit 1
fi

if ! ip link show tailscale0 >/dev/null 2>&1; then
  echo "Tailscale is not connected; refusing to change firewall rules."
  exit 1
fi

TAILSCALE_IP=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -1)
if [ -z "$TAILSCALE_IP" ]; then
  echo "Tailscale has no VPN address; refusing to change firewall rules."
  exit 1
fi

PUBLIC_INTERFACE=$(ip route show default | awk 'NR==1 {print $5}')
if [ -z "$PUBLIC_INTERFACE" ]; then
  echo "Could not identify the public network interface."
  exit 1
fi
case "$PUBLIC_INTERFACE" in
  lo|tailscale0|docker0|br-*)
    echo "Refusing to treat $PUBLIC_INTERFACE as the public interface."
    exit 1
    ;;
esac

# Docker-published ports bypass normal UFW input rules. Block traffic arriving
# from the public interface at Docker's supported user firewall chain.
if ! iptables -C DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
  iptables -I DOCKER-USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
if ! iptables -C DOCKER-USER -i "$PUBLIC_INTERFACE" -j DROP 2>/dev/null; then
  iptables -I DOCKER-USER 2 -i "$PUBLIC_INTERFACE" -j DROP
fi

if command -v ufw >/dev/null 2>&1; then
  ufw default deny incoming >/dev/null
  ufw allow in on tailscale0 >/dev/null
  ufw delete allow 22/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null
fi

SCRIPT_PATH=$(readlink -f "$0")
cat > /etc/systemd/system/privacy-stack-vpn-lockdown.service <<EOF
[Unit]
Description=Keep Privacy Stack ingress restricted to Tailscale
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable privacy-stack-vpn-lockdown.service >/dev/null

echo "Public ingress disabled."
echo "VPN address: $TAILSCALE_IP"
echo "Applications remain available through Tailscale on their existing ports."
