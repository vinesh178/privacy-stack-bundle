#!/bin/bash
# Keep application ports private while preserving temporary public SSH access.

set -euo pipefail

APPLY_ONLY=false
if [ "${1:-}" = "--apply-only" ]; then
  APPLY_ONLY=true
elif [ -n "${1:-}" ]; then
  echo "Usage: sudo bash scripts/protect-onboarding.sh [--apply-only]"
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo bash scripts/protect-onboarding.sh"
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

apply_ipv4_rules() {
  iptables -N PRIVACY_STACK_INPUT 2>/dev/null || true
  iptables -F PRIVACY_STACK_INPUT
  iptables -A PRIVACY_STACK_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A PRIVACY_STACK_INPUT -p tcp --dport 22 -j ACCEPT
  iptables -A PRIVACY_STACK_INPUT -p udp --dport 41641 -j ACCEPT
  iptables -A PRIVACY_STACK_INPUT -p udp --sport 67 --dport 68 -j ACCEPT
  iptables -A PRIVACY_STACK_INPUT -p icmp -j ACCEPT
  iptables -A PRIVACY_STACK_INPUT -j DROP
  while iptables -D INPUT -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT 2>/dev/null; do :; done
  iptables -I INPUT 1 -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT

  iptables -N PRIVACY_STACK_DOCKER 2>/dev/null || true
  iptables -F PRIVACY_STACK_DOCKER
  iptables -A PRIVACY_STACK_DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A PRIVACY_STACK_DOCKER -j DROP
  while iptables -D DOCKER-USER -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_DOCKER 2>/dev/null; do :; done
  iptables -I DOCKER-USER 1 -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_DOCKER
}

apply_ipv6_rules() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -L INPUT >/dev/null 2>&1 || return 0

  ip6tables -N PRIVACY_STACK_INPUT 2>/dev/null || true
  ip6tables -F PRIVACY_STACK_INPUT
  ip6tables -A PRIVACY_STACK_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ip6tables -A PRIVACY_STACK_INPUT -p tcp --dport 22 -j ACCEPT
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
}

apply_ipv4_rules
apply_ipv6_rules

[ "$APPLY_ONLY" = true ] && exit 0

SCRIPT_PATH=$(readlink -f "$0")
cat > /etc/systemd/system/privacy-stack-onboarding-firewall.service <<EOF
[Unit]
Description=Protect Privacy Stack during onboarding
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH --apply-only
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable privacy-stack-onboarding-firewall.service >/dev/null

echo "Onboarding firewall active: public SSH allowed; application ingress blocked."
