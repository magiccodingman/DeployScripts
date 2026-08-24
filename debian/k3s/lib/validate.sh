#!/usr/bin/env bash

CHECK_FAILURES=0
check_pass() { log_ok "$*"; }
check_fail() { log_err "$*"; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }

check_root_mode() {
  local path=$1 expected_mode=$2 label=$3 owner mode
  if [[ ! -f $path ]]; then
    check_fail "${label} is missing: ${path}"
    return
  fi
  owner=$(stat -c '%u' "$path")
  mode=$(stat -c '%a' "$path")
  if [[ $owner == 0 && $mode == "$expected_mode" ]]; then
    check_pass "${label} is root-owned mode ${expected_mode}."
  else
    check_fail "${label} permissions are unsafe (owner ${owner}, mode ${mode}; expected root/${expected_mode})."
  fi
}

wait_for_service() {
  local service=$1 attempts=${2:-90}
  for _ in $(seq 1 "$attempts"); do
    systemctl is-active --quiet "$service" && return 0
    sleep 2
  done
  return 1
}

wait_for_server_node() {
  local attempts=${1:-120}
  for _ in $(seq 1 "$attempts"); do
    if k3s kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; then
      return 0
    fi
    sleep 2
  done
  return 1
}

validate_k3s() {
  CHECK_FAILURES=0
  local desired service
  desired=$(desired_service_role)
  [[ $desired == server ]] && service=k3s || service=k3s-agent

  printf '\nK3s Validation\n'
  printf '%s\n' '--------------'

  if command -v k3s >/dev/null 2>&1; then
    check_pass "K3s binary is installed: $(k3s --version | head -n 1)"
  else
    check_fail "K3s binary is not installed."
  fi

  if systemctl is-enabled --quiet "$service.service" 2>/dev/null; then
    check_pass "${service}.service is enabled."
  else
    check_fail "${service}.service is not enabled."
  fi

  if systemctl is-active --quiet "$service.service" 2>/dev/null; then
    check_pass "${service}.service is active."
  else
    check_fail "${service}.service is not active."
  fi

  if [[ $desired == server ]]; then
    check_root_mode "${K3S_DROPIN_DIR}/10-deployscripts-cluster.yaml" 600 "Cluster configuration"
  fi
  check_root_mode "${K3S_DROPIN_DIR}/20-deployscripts-node.yaml" 600 "Node configuration"
  check_root_mode "${K3S_DROPIN_DIR}/30-deployscripts-role.yaml" 600 "Role configuration"
  if [[ $desired == server ]]; then
    check_root_mode "$K3S_MANAGED_TOKEN_FILE" 600 "Managed server token"
  else
    check_root_mode "$K3S_MANAGED_AGENT_TOKEN_FILE" 600 "Managed agent token"
  fi
  if [[ $desired == server && -f $K3S_MANAGED_AGENT_TOKEN_FILE ]]; then
    check_root_mode "$K3S_MANAGED_AGENT_TOKEN_FILE" 600 "Managed agent token"
  fi
  if [[ -f ${K3S_CONFIG_DIR}/registries.yaml ]]; then
    check_root_mode "${K3S_CONFIG_DIR}/registries.yaml" 600 "Private registry configuration"
  fi

  if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]]; then
    check_pass "IPv4 forwarding is enabled."
  else
    check_fail "IPv4 forwarding is not enabled."
  fi

  if [[ $desired == server && -x $(command -v k3s 2>/dev/null || true) ]]; then
    if k3s kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
      local ready
      ready=$(k3s kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      if [[ $ready == True ]]; then
        check_pass "Kubernetes node ${NODE_NAME} is Ready."
      else
        check_fail "Kubernetes node ${NODE_NAME} is not Ready."
      fi
    else
      check_fail "Kubernetes API did not return node ${NODE_NAME}."
    fi

    if [[ $DATASTORE == embedded-etcd ]]; then
      if k3s etcd-snapshot ls >/dev/null 2>&1; then
        check_pass "Embedded-etcd snapshot subsystem is available."
      else
        check_fail "Embedded-etcd snapshot subsystem is unavailable."
      fi
    fi
  elif [[ $desired == agent ]]; then
    if [[ -s /var/lib/rancher/k3s/agent/kubelet.kubeconfig && -S /run/k3s/containerd/containerd.sock ]]; then
      check_pass "Agent kubelet configuration and containerd socket are present."
    else
      check_fail "Agent runtime files are incomplete."
    fi
  fi

  if [[ $CHECK_FAILURES -eq 0 ]]; then
    printf '\nK3S READINESS: PASS\n'
    return 0
  fi
  printf '\nK3S READINESS: FAIL (%d check(s) failed)\n' "$CHECK_FAILURES"
  return 1
}

wait_for_k3s_readiness() {
  local desired service
  desired=$(desired_service_role)
  [[ $desired == server ]] && service=k3s || service=k3s-agent
  log_info "Waiting for ${service}.service..."
  if ! wait_for_service "$service" 90; then
    journalctl -u "$service.service" --no-pager -n 100 >&2 || true
    die "${service}.service did not become active."
  fi
  if [[ $desired == server ]]; then
    log_info "Waiting for Kubernetes node ${NODE_NAME} to become Ready..."
    if ! wait_for_server_node 150; then
      journalctl -u k3s.service --no-pager -n 150 >&2 || true
      die "Kubernetes node ${NODE_NAME} did not become Ready."
    fi
  fi
}
