#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=debian/k3s/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=debian/k3s/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=debian/k3s/lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=debian/k3s/lib/validate.sh
source "${SCRIPT_DIR}/lib/validate.sh"
trap 'on_error "$LINENO"' ERR

MODE=""
NODE_NAME=""
NODE_IP=""
NODE_EXTERNAL_IP=""
API_ENDPOINT=""
DATASTORE=""
FLANNEL_BACKEND=""
FLANNEL_IFACE=""
TOKEN_SOURCE=""
AGENT_TOKEN_SOURCE=""
REGISTRY_CONFIG_SOURCE=""
K3S_VERSION=""
K3S_CHANNEL="stable"
K3S_INSTALL_URL=${K3S_INSTALL_URL:-https://get.k3s.io}
SECRETS_ENCRYPTION=-1
SNAPSHOT_SCHEDULE=""
SNAPSHOT_RETENTION=""
TLS_SANS=()
DISABLED_COMPONENTS=()
NODE_LABELS=()
NODE_TAINTS=()
CHECK_ONLY=0
DRY_RUN=0
ALLOW_PUBLIC_VXLAN=0
VERSION_EXPLICIT=0
CHANNEL_EXPLICIT=0
STATE_WAS_PRESENT=0

usage() {
  cat <<'EOF'
Debian K3s

Creates the first server of a K3s cluster, joins additional embedded-etcd
servers, or joins worker agents. Configuration is written as native K3s YAML
drop-ins and safe reruns converge the requested node state.

Usage:
  sudo ./setup.sh --mode MODE [options]
  sudo ./setup.sh --check

Node role:
  --mode MODE              init-server, join-server, or join-agent
  --node-name NAME         Unique Kubernetes node name
  --node-ip IP             Private or WireGuard node address preferred
  --node-external-ip IP    Optional public address advertised for the node
  --node-label KEY=VALUE   Initial node label; repeatable
  --node-taint TAINT       Initial node taint; repeatable

Cluster connectivity:
  --api-endpoint URL       Stable HTTPS API/registration URL; port defaults to 6443
  --token-file PATH        Root-owned 0600 server/join token file
  --agent-token-file PATH  Optional distinct root-owned 0600 agent token file
  --tls-san NAME_OR_IP     Additional Kubernetes API certificate SAN; repeatable

Cluster architecture (server modes):
  --datastore TYPE         sqlite or embedded-etcd; required for init-server
  --flannel-backend TYPE   vxlan or wireguard-native; required for server modes
  --flannel-iface IFACE    Force Flannel traffic over a specific interface
  --secrets-encryption     Encrypt Kubernetes Secrets at rest (default)
  --no-secrets-encryption  Disable Kubernetes Secret encryption
  --disable COMPONENT      Disable a packaged K3s component; repeatable
  --snapshot-schedule CRON Embedded-etcd snapshot cron (default: every 12 hours)
  --snapshot-retention N   Local embedded-etcd snapshot retention (default: 5)
  --allow-public-vxlan     Permit VXLAN when --node-ip is publicly routable

Install and registry:
  --version VERSION        Install an exact K3s version on a new host
  --channel CHANNEL        Install from a release channel (default: stable)
  --registry-config PATH   Install a root-only K3s registries.yaml

Modes:
  --check                  Read-only validation; existing state supplies options
  --dry-run                Show intended mutations without changing the host
  --non-interactive        Never prompt (the current workflow never needs to prompt)
  -h, --help               Show this help

Examples:
  sudo ./setup.sh \
    --mode init-server \
    --node-name prod-k3s-01 \
    --node-ip 10.250.0.11 \
    --node-external-ip 203.0.113.11 \
    --api-endpoint https://k3s-prod-api.example.com:6443 \
    --datastore embedded-etcd \
    --flannel-backend vxlan \
    --flannel-iface wg0 \
    --token-file /root/k3s-production.token

  sudo ./setup.sh \
    --mode join-server \
    --node-name prod-k3s-02 \
    --node-ip 10.250.0.12 \
    --api-endpoint https://k3s-prod-api.example.com:6443 \
    --flannel-backend vxlan \
    --flannel-iface wg0 \
    --token-file /root/k3s-production.token
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --mode) [[ $# -ge 2 ]] || die "--mode requires a value."; MODE=$2; shift 2;;
      --node-name) [[ $# -ge 2 ]] || die "--node-name requires a value."; NODE_NAME=$2; shift 2;;
      --node-ip) [[ $# -ge 2 ]] || die "--node-ip requires a value."; NODE_IP=$2; shift 2;;
      --node-external-ip) [[ $# -ge 2 ]] || die "--node-external-ip requires a value."; NODE_EXTERNAL_IP=$2; shift 2;;
      --api-endpoint) [[ $# -ge 2 ]] || die "--api-endpoint requires a value."; API_ENDPOINT=$2; shift 2;;
      --datastore) [[ $# -ge 2 ]] || die "--datastore requires a value."; DATASTORE=$2; shift 2;;
      --flannel-backend) [[ $# -ge 2 ]] || die "--flannel-backend requires a value."; FLANNEL_BACKEND=$2; shift 2;;
      --flannel-iface) [[ $# -ge 2 ]] || die "--flannel-iface requires a value."; FLANNEL_IFACE=$2; shift 2;;
      --token-file) [[ $# -ge 2 ]] || die "--token-file requires a value."; TOKEN_SOURCE=$2; shift 2;;
      --agent-token-file) [[ $# -ge 2 ]] || die "--agent-token-file requires a value."; AGENT_TOKEN_SOURCE=$2; shift 2;;
      --tls-san) [[ $# -ge 2 ]] || die "--tls-san requires a value."; TLS_SANS+=("$2"); shift 2;;
      --node-label) [[ $# -ge 2 ]] || die "--node-label requires a value."; NODE_LABELS+=("$2"); shift 2;;
      --node-taint) [[ $# -ge 2 ]] || die "--node-taint requires a value."; NODE_TAINTS+=("$2"); shift 2;;
      --disable) [[ $# -ge 2 ]] || die "--disable requires a value."; DISABLED_COMPONENTS+=("$2"); shift 2;;
      --secrets-encryption) SECRETS_ENCRYPTION=1; shift;;
      --no-secrets-encryption) SECRETS_ENCRYPTION=0; shift;;
      --snapshot-schedule) [[ $# -ge 2 ]] || die "--snapshot-schedule requires a value."; SNAPSHOT_SCHEDULE=$2; shift 2;;
      --snapshot-retention) [[ $# -ge 2 ]] || die "--snapshot-retention requires a value."; SNAPSHOT_RETENTION=$2; shift 2;;
      --allow-public-vxlan) ALLOW_PUBLIC_VXLAN=1; shift;;
      --version) [[ $# -ge 2 ]] || die "--version requires a value."; K3S_VERSION=$2; VERSION_EXPLICIT=1; shift 2;;
      --channel) [[ $# -ge 2 ]] || die "--channel requires a value."; K3S_CHANNEL=$2; CHANNEL_EXPLICIT=1; shift 2;;
      --registry-config) [[ $# -ge 2 ]] || die "--registry-config requires a value."; REGISTRY_CONFIG_SOURCE=$2; shift 2;;
      --check) CHECK_ONLY=1; shift;;
      --dry-run) DRY_RUN=1; shift;;
      --non-interactive) shift;;
      -h|--help) usage; exit 0;;
      *) die "Unknown option: $1 (use --help)";;
    esac
  done
}

load_saved_state() {
  [[ -f $K3S_STATE_FILE ]] || return 0
  STATE_WAS_PRESENT=1
  local owner mode
  owner=$(stat -c '%u' "$K3S_STATE_FILE")
  mode=$(stat -c '%a' "$K3S_STATE_FILE")
  [[ $owner == 0 && $((8#$mode & 022)) -eq 0 ]] ||
    die "K3s state must be root-owned and not group/world writable: ${K3S_STATE_FILE}"
  # shellcheck disable=SC1090
  source "$K3S_STATE_FILE"

  [[ -z $MODE || -z ${DEPLOYSCRIPTS_K3S_MODE:-} || $MODE == "$DEPLOYSCRIPTS_K3S_MODE" ]] ||
    die "Existing node mode is ${DEPLOYSCRIPTS_K3S_MODE}; refusing requested mode ${MODE}."
  [[ -z $NODE_NAME || -z ${DEPLOYSCRIPTS_K3S_NODE_NAME:-} || $NODE_NAME == "$DEPLOYSCRIPTS_K3S_NODE_NAME" ]] ||
    die "Existing node name is ${DEPLOYSCRIPTS_K3S_NODE_NAME}; refusing requested name ${NODE_NAME}."
  [[ -z $NODE_IP || -z ${DEPLOYSCRIPTS_K3S_NODE_IP:-} || $NODE_IP == "$DEPLOYSCRIPTS_K3S_NODE_IP" ]] ||
    die "Existing node IP is ${DEPLOYSCRIPTS_K3S_NODE_IP}; explicit node-IP changes are not yet supported."
  [[ -z $DATASTORE || -z ${DEPLOYSCRIPTS_K3S_DATASTORE:-} || $DATASTORE == "$DEPLOYSCRIPTS_K3S_DATASTORE" ]] ||
    die "Existing datastore is ${DEPLOYSCRIPTS_K3S_DATASTORE}; refusing requested datastore ${DATASTORE}."
  [[ -z $FLANNEL_BACKEND || -z ${DEPLOYSCRIPTS_K3S_FLANNEL_BACKEND:-} || $FLANNEL_BACKEND == "$DEPLOYSCRIPTS_K3S_FLANNEL_BACKEND" ]] ||
    die "Existing Flannel backend is ${DEPLOYSCRIPTS_K3S_FLANNEL_BACKEND}; refusing requested backend ${FLANNEL_BACKEND}."
  [[ -z $FLANNEL_IFACE || $FLANNEL_IFACE == "${DEPLOYSCRIPTS_K3S_FLANNEL_IFACE:-}" ]] ||
    die "Existing Flannel interface is ${DEPLOYSCRIPTS_K3S_FLANNEL_IFACE:-none}; refusing requested interface ${FLANNEL_IFACE}."
  [[ -z $NODE_EXTERNAL_IP || $NODE_EXTERNAL_IP == "${DEPLOYSCRIPTS_K3S_NODE_EXTERNAL_IP:-}" ]] ||
    die "Existing external node IP is ${DEPLOYSCRIPTS_K3S_NODE_EXTERNAL_IP:-none}; explicit external-IP changes are not yet supported."
  [[ $SECRETS_ENCRYPTION -eq -1 || -z ${DEPLOYSCRIPTS_K3S_SECRETS_ENCRYPTION:-} || $SECRETS_ENCRYPTION == "$DEPLOYSCRIPTS_K3S_SECRETS_ENCRYPTION" ]] ||
    die "Existing Secret-encryption setting conflicts with the requested setting."

  MODE=${MODE:-${DEPLOYSCRIPTS_K3S_MODE:-}}
  NODE_NAME=${NODE_NAME:-${DEPLOYSCRIPTS_K3S_NODE_NAME:-}}
  NODE_IP=${NODE_IP:-${DEPLOYSCRIPTS_K3S_NODE_IP:-}}
  NODE_EXTERNAL_IP=${NODE_EXTERNAL_IP:-${DEPLOYSCRIPTS_K3S_NODE_EXTERNAL_IP:-}}
  API_ENDPOINT=${API_ENDPOINT:-${DEPLOYSCRIPTS_K3S_API_ENDPOINT:-}}
  DATASTORE=${DATASTORE:-${DEPLOYSCRIPTS_K3S_DATASTORE:-}}
  FLANNEL_BACKEND=${FLANNEL_BACKEND:-${DEPLOYSCRIPTS_K3S_FLANNEL_BACKEND:-}}
  FLANNEL_IFACE=${FLANNEL_IFACE:-${DEPLOYSCRIPTS_K3S_FLANNEL_IFACE:-}}
  [[ $SECRETS_ENCRYPTION -ne -1 ]] || SECRETS_ENCRYPTION=${DEPLOYSCRIPTS_K3S_SECRETS_ENCRYPTION:-1}
  SNAPSHOT_SCHEDULE=${SNAPSHOT_SCHEDULE:-${DEPLOYSCRIPTS_K3S_SNAPSHOT_SCHEDULE:-}}
  SNAPSHOT_RETENTION=${SNAPSHOT_RETENTION:-${DEPLOYSCRIPTS_K3S_SNAPSHOT_RETENTION:-}}
  ((${#TLS_SANS[@]})) || TLS_SANS=("${DEPLOYSCRIPTS_K3S_TLS_SANS[@]:-}")
  ((${#DISABLED_COMPONENTS[@]})) || DISABLED_COMPONENTS=("${DEPLOYSCRIPTS_K3S_DISABLED_COMPONENTS[@]:-}")
  ((${#NODE_LABELS[@]})) || NODE_LABELS=("${DEPLOYSCRIPTS_K3S_NODE_LABELS[@]:-}")
  ((${#NODE_TAINTS[@]})) || NODE_TAINTS=("${DEPLOYSCRIPTS_K3S_NODE_TAINTS[@]:-}")
}

remove_empty_array_items() {
  local array_name=$1 value
  local -n values=$array_name
  local cleaned=()
  for value in "${values[@]}"; do [[ -z $value ]] || cleaned+=("$value"); done
  values=("${cleaned[@]}")
}

resolve_and_validate() {
  [[ $VERSION_EXPLICIT -eq 0 || $CHANNEL_EXPLICIT -eq 0 ]] || die "--version and --channel are mutually exclusive."
  case "$MODE" in init-server|join-server|join-agent) ;; *) die "--mode must be init-server, join-server, or join-agent.";; esac
  [[ -n $NODE_NAME ]] || die "--node-name is required."
  [[ -n $NODE_IP ]] || die "--node-ip is required."
  [[ -n $API_ENDPOINT ]] || die "--api-endpoint is required."
  validate_node_name "$NODE_NAME"
  validate_ip "$NODE_IP" "node IP"
  [[ -z $NODE_EXTERNAL_IP ]] || validate_ip "$NODE_EXTERNAL_IP" "node external IP"
  validate_api_endpoint "$API_ENDPOINT"
  API_ENDPOINT=$(normalize_api_endpoint "$API_ENDPOINT")
  [[ -z $FLANNEL_IFACE ]] || validate_interface_name "$FLANNEL_IFACE"

  remove_empty_array_items TLS_SANS
  remove_empty_array_items DISABLED_COMPONENTS
  remove_empty_array_items NODE_LABELS
  remove_empty_array_items NODE_TAINTS
  local value
  for value in "${TLS_SANS[@]}"; do [[ -n $value && $value != *$'\n'* ]] || die "Invalid TLS SAN: ${value}"; done
  for value in "${DISABLED_COMPONENTS[@]}"; do validate_disable_component "$value"; done
  for value in "${NODE_LABELS[@]}"; do validate_node_label "$value"; done
  for value in "${NODE_TAINTS[@]}"; do validate_node_taint "$value"; done

  if [[ $MODE == init-server ]]; then
    case "$DATASTORE" in sqlite|embedded-etcd) ;; *) die "init-server requires --datastore sqlite or embedded-etcd.";; esac
  elif [[ $MODE == join-server ]]; then
    [[ -z $DATASTORE || $DATASTORE == embedded-etcd ]] || die "join-server only supports embedded-etcd clusters."
    DATASTORE=embedded-etcd
  else
    [[ -z $DATASTORE ]] || die "--datastore does not apply to join-agent."
    DATASTORE=""
  fi

  if [[ $MODE == join-agent ]]; then
    [[ -z $FLANNEL_BACKEND ]] || die "--flannel-backend is a server-only cluster setting."
    [[ ${#DISABLED_COMPONENTS[@]} -eq 0 ]] || die "--disable is a server-only cluster setting."
  else
    case "$FLANNEL_BACKEND" in vxlan|wireguard-native) ;; *) die "Server modes require --flannel-backend vxlan or wireguard-native.";; esac
  fi

  [[ $SECRETS_ENCRYPTION -ne -1 ]] || SECRETS_ENCRYPTION=1
  SNAPSHOT_SCHEDULE=${SNAPSHOT_SCHEDULE:-"0 */12 * * *"}
  SNAPSHOT_RETENTION=${SNAPSHOT_RETENTION:-5}
  [[ $SNAPSHOT_RETENTION =~ ^[1-9][0-9]*$ ]] || die "--snapshot-retention must be a positive integer."
  [[ -n $SNAPSHOT_SCHEDULE && $SNAPSHOT_SCHEDULE != *$'\n'* ]] || die "Invalid snapshot schedule."

  if [[ $MODE != join-agent && $FLANNEL_BACKEND == vxlan && $ALLOW_PUBLIC_VXLAN -eq 0 ]] && ip_is_global "$NODE_IP"; then
    die "Refusing VXLAN over publicly routable --node-ip ${NODE_IP}. Use a private/WireGuard node IP, select wireguard-native, or explicitly pass --allow-public-vxlan."
  fi

  if [[ -n $FLANNEL_IFACE && ! -d /sys/class/net/$FLANNEL_IFACE ]]; then
    die "Flannel interface does not exist on this host: ${FLANNEL_IFACE}"
  fi
  if ! ip -o addr show 2>/dev/null | grep -Fqw "$NODE_IP"; then
    die "--node-ip is not assigned to a local interface: ${NODE_IP}"
  fi
}

print_network_requirements() {
  printf '\nRequired firewall scope\n'
  printf '%s\n' '-----------------------'
  printf 'TCP 6443: cluster nodes and HAProxy -> K3s servers\n'
  [[ $MODE == join-agent ]] || printf 'TCP 2379-2380: K3s servers -> K3s servers (embedded-etcd only)\n'
  printf 'TCP 10250: cluster nodes -> cluster nodes\n'
  if [[ $FLANNEL_BACKEND == wireguard-native ]]; then
    printf 'UDP 51820: cluster nodes -> cluster nodes\n'
  elif [[ $FLANNEL_BACKEND == vxlan ]]; then
    printf 'UDP 8472: cluster nodes -> cluster nodes; never expose this port publicly\n'
  fi
  printf 'This tool validates requirements but does not replace the host firewall.\n'
}

ensure_install_is_managed() {
  if [[ $STATE_WAS_PRESENT -eq 0 ]] && { command -v k3s >/dev/null 2>&1 || [[ -e /etc/systemd/system/k3s.service || -e /etc/systemd/system/k3s-agent.service ]]; }; then
    die "K3s is already installed without DeployScripts state. Refusing to adopt an unmanaged installation."
  fi
}

main() {
  parse_args "$@"
  require_root
  ensure_debian
  load_saved_state
  resolve_and_validate
  ensure_install_is_managed
  ensure_role_compatible
  ensure_no_unmanaged_config_conflicts

  if [[ $CHECK_ONLY -eq 1 ]]; then
    validate_k3s
    exit $?
  fi

  ensure_kernel_prerequisites
  ensure_tokens
  write_k3s_configs
  save_state
  install_k3s_binary_and_service
  start_k3s_service
  if [[ $DRY_RUN -eq 0 ]]; then
    wait_for_k3s_readiness
    validate_k3s
  else
    log_info "Dry run complete; no host changes were made."
  fi
  print_network_requirements

  printf '\nK3s setup complete.\n'
  printf 'Mode:         %s\n' "$MODE"
  printf 'Node:         %s (%s)\n' "$NODE_NAME" "$NODE_IP"
  printf 'API endpoint: %s\n' "$API_ENDPOINT"
  printf 'Configuration: %s\n' "$K3S_DROPIN_DIR"
  [[ $MODE == join-agent ]] || printf 'Admin kubeconfig: /etc/rancher/k3s/k3s.yaml (root-only)\n'
  [[ $MODE != init-server ]] || printf 'Server join token: %s (root-only; contents not printed)\n' "$K3S_MANAGED_TOKEN_FILE"
  printf '\nRerun read-only validation with:\n  sudo %s --check\n' "${SCRIPT_DIR}/setup.sh"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
