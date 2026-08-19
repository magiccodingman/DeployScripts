#!/usr/bin/env bash

ensure_kernel_prerequisites() {
  ensure_packages curl ca-certificates iptables openssl python3 kmod

  run modprobe overlay
  run modprobe br_netfilter

  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
# Managed by DeployScripts K3s.
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  write_if_changed "$tmp" /etc/sysctl.d/90-deployscripts-k3s.conf 0644
  run sysctl --system

  if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
    log_warn "Swap is active. K3s may run, but workload behavior depends on kubelet swap configuration. This tool does not modify swap."
  fi
}

installed_service_role() {
  if systemctl cat k3s.service >/dev/null 2>&1; then
    printf server
  elif systemctl cat k3s-agent.service >/dev/null 2>&1; then
    printf agent
  fi
}

desired_service_role() {
  case "$MODE" in
    init-server|join-server) printf server;;
    join-agent) printf agent;;
    *) die "Unknown K3s mode: ${MODE}";;
  esac
}

ensure_role_compatible() {
  local installed desired
  installed=$(installed_service_role)
  desired=$(desired_service_role)
  [[ -z $installed || $installed == "$desired" ]] ||
    die "This host already has the K3s ${installed} service, but ${MODE} requires ${desired}. Refusing to change roles."
}

install_k3s_binary_and_service() {
  local desired installed_version="" install_script
  desired=$(desired_service_role)
  if command -v k3s >/dev/null 2>&1; then
    installed_version=$(k3s --version | awk 'NR == 1 {print $3}')
    if [[ -n $K3S_VERSION && $installed_version != "$K3S_VERSION" ]]; then
      die "K3s ${installed_version} is installed, but --version requested ${K3S_VERSION}. Upgrades are intentionally out of scope for this setup command."
    fi
    log_ok "K3s already installed: ${installed_version}"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "Would install K3s ${K3S_VERSION:-from channel ${K3S_CHANNEL}} as the ${desired} service."
    return 0
  fi

  install_script=$(mktemp)
  curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
    --output "$install_script" "$K3S_INSTALL_URL"
  chmod 0700 "$install_script"

  log_info "Installing K3s ${K3S_VERSION:-from channel ${K3S_CHANNEL}} as a ${desired}..."
  if [[ -n $K3S_VERSION ]]; then
    INSTALL_K3S_EXEC="$desired" \
      INSTALL_K3S_SKIP_START=true \
      INSTALL_K3S_VERSION="$K3S_VERSION" \
      sh "$install_script"
  else
    INSTALL_K3S_EXEC="$desired" \
      INSTALL_K3S_SKIP_START=true \
      INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
      sh "$install_script"
  fi
  rm -f "$install_script"
}

start_k3s_service() {
  local service
  service=$(desired_service_role)
  [[ $service == server ]] && service=k3s || service=k3s-agent
  run systemctl enable "$service.service"
  run systemctl restart "$service.service"
  [[ $DRY_RUN -eq 1 ]] || log_ok "Started ${service}.service"
}
