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

# Install deterministic chains at position one. This avoids depending on
# pre-existing firewall rule order and defaults to denying public ingress.
iptables -N PRIVACY_STACK_INPUT 2>/dev/null || true
iptables -F PRIVACY_STACK_INPUT
iptables -A PRIVACY_STACK_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A PRIVACY_STACK_INPUT -p udp --dport 41641 -j ACCEPT
iptables -A PRIVACY_STACK_INPUT -p udp --sport 67 --dport 68 -j ACCEPT
iptables -A PRIVACY_STACK_INPUT -p icmp -j ACCEPT
iptables -A PRIVACY_STACK_INPUT -j DROP
while iptables -D INPUT -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT 2>/dev/null; do :; done
iptables -I INPUT 1 -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT

# Docker-published ports traverse DOCKER-USER rather than normal INPUT rules.
iptables -N PRIVACY_STACK_DOCKER 2>/dev/null || true
iptables -F PRIVACY_STACK_DOCKER
iptables -A PRIVACY_STACK_DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A PRIVACY_STACK_DOCKER -j DROP
while iptables -D DOCKER-USER -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_DOCKER 2>/dev/null; do :; done
iptables -I DOCKER-USER 1 -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_DOCKER

if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -N PRIVACY_STACK_INPUT 2>/dev/null || true
  ip6tables -F PRIVACY_STACK_INPUT
  ip6tables -A PRIVACY_STACK_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ip6tables -A PRIVACY_STACK_INPUT -p udp --dport 41641 -j ACCEPT
  ip6tables -A PRIVACY_STACK_INPUT -p udp --sport 547 --dport 546 -j ACCEPT
  ip6tables -A PRIVACY_STACK_INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -A PRIVACY_STACK_INPUT -j DROP
  while ip6tables -D INPUT -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT 2>/dev/null; do :; done
  ip6tables -I INPUT 1 -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT

  if ip6tables -L DOCKER-USER >/dev/null 2>&1; then
    ip6tables -N PRIVACY_STACK_DOCKER 2>/dev/null || true
    ip6tables -F PRIVACY_STACK_DOCKER
    ip6tables -A PRIVACY_STACK_DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A PRIVACY_STACK_DOCKER -j DROP
    while ip6tables -D DOCKER-USER -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_DOCKER 2>/dev/null; do :; done
    ip6tables -I DOCKER-USER 1 -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_DOCKER
  fi
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
