#!/usr/bin/env bash

K3S_CONFIG_DIR=${K3S_CONFIG_DIR:-/etc/rancher/k3s}
K3S_DROPIN_DIR=${K3S_DROPIN_DIR:-${K3S_CONFIG_DIR}/config.yaml.d}
K3S_STATE_DIR=${K3S_STATE_DIR:-/var/lib/deployscripts/k3s}
K3S_STATE_FILE=${K3S_STATE_FILE:-${K3S_STATE_DIR}/state.env}
K3S_MANAGED_TOKEN_FILE=${K3S_MANAGED_TOKEN_FILE:-${K3S_CONFIG_DIR}/deployscripts-server-token}
K3S_MANAGED_AGENT_TOKEN_FILE=${K3S_MANAGED_AGENT_TOKEN_FILE:-${K3S_CONFIG_DIR}/deployscripts-agent-token}

yaml_quote() {
  local value=${1//\'/\'\'}
  printf "'%s'" "$value"
}

render_list() {
  local key=$1
  shift
  (($#)) || return 0
  printf '%s:\n' "$key"
  local value
  for value in "$@"; do
    printf '  - '
    yaml_quote "$value"
    printf '\n'
  done
}

render_cluster_config() {
  local destination=$1 endpoint_host
  endpoint_host=$(api_endpoint_host "$API_ENDPOINT")
  {
    printf '# Managed by DeployScripts K3s. Cluster-wide server settings.\n'
    render_list tls-san "$endpoint_host" "${TLS_SANS[@]}"
    printf 'flannel-backend: '
    yaml_quote "$FLANNEL_BACKEND"
    printf '\n'
    printf 'secrets-encryption: %s\n' "$([[ $SECRETS_ENCRYPTION -eq 1 ]] && printf true || printf false)"
    render_list disable "${DISABLED_COMPONENTS[@]}"
    if [[ $DATASTORE == embedded-etcd ]]; then
      printf 'etcd-snapshot-compress: true\n'
      printf 'etcd-snapshot-retention: %s\n' "$SNAPSHOT_RETENTION"
      printf 'etcd-snapshot-schedule-cron: '
      yaml_quote "$SNAPSHOT_SCHEDULE"
      printf '\n'
    fi
    # MODE is module state supplied by setup.sh or a focused renderer test.
    # shellcheck disable=SC2153
    if [[ $MODE != join-agent && ( -n ${AGENT_TOKEN_SOURCE:-} || -s $K3S_MANAGED_AGENT_TOKEN_FILE ) ]]; then
      printf 'agent-token-file: '
      yaml_quote "$K3S_MANAGED_AGENT_TOKEN_FILE"
      printf '\n'
    fi
  } > "$destination"
}

render_node_config() {
  local destination=$1
  {
    printf '# Managed by DeployScripts K3s. Node-specific settings.\n'
    printf 'node-name: '
    yaml_quote "$NODE_NAME"
    printf '\nnode-ip: '
    yaml_quote "$NODE_IP"
    printf '\n'
    if [[ -n $NODE_EXTERNAL_IP ]]; then
      printf 'node-external-ip: '
      yaml_quote "$NODE_EXTERNAL_IP"
      printf '\n'
    fi
    if [[ -n $FLANNEL_IFACE ]]; then
      printf 'flannel-iface: '
      yaml_quote "$FLANNEL_IFACE"
      printf '\n'
    fi
    render_list node-label "${NODE_LABELS[@]}"
    render_list node-taint "${NODE_TAINTS[@]}"
  } > "$destination"
}

render_role_config() {
  local destination=$1 token_path=$K3S_MANAGED_TOKEN_FILE
  [[ $MODE != join-agent ]] || token_path=$K3S_MANAGED_AGENT_TOKEN_FILE
  {
    printf '# Managed by DeployScripts K3s. Installation role settings.\n'
    case "$MODE" in
      init-server)
        [[ $DATASTORE != embedded-etcd ]] || printf 'cluster-init: true\n'
        ;;
      join-server|join-agent)
        printf 'server: '
        yaml_quote "$API_ENDPOINT"
        printf '\n'
        ;;
      *) die "Cannot render unknown mode: ${MODE}";;
    esac
    printf 'token-file: '
    yaml_quote "$token_path"
    printf '\n'
  } > "$destination"
}

copy_token_file() {
  local source=$1 destination=$2 label=$3
  [[ -s $source ]] || die "${label} is missing or empty: ${source}"
  ensure_absolute_path "$source" "$label"
  local owner mode
  owner=$(stat -c '%u' "$source")
  mode=$(stat -c '%a' "$source")
  [[ $owner == 0 ]] || die "${label} must be owned by root: ${source}"
  (( (8#$mode & 077) == 0 )) || die "${label} must not be accessible to group or other users: ${source}"
  if [[ $source == "$destination" ]]; then
    run chmod 0600 "$destination"
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  cp "$source" "$tmp"
  chmod 0600 "$tmp"
  write_if_changed "$tmp" "$destination" 0600
}

ensure_tokens() {
  run install -d -o root -g root -m 0700 "$K3S_CONFIG_DIR"

  if [[ $MODE == join-agent ]]; then
    if [[ -n ${AGENT_TOKEN_SOURCE:-} ]]; then
      copy_token_file "$AGENT_TOKEN_SOURCE" "$K3S_MANAGED_AGENT_TOKEN_FILE" "Agent token file"
    elif [[ -n ${TOKEN_SOURCE:-} ]]; then
      copy_token_file "$TOKEN_SOURCE" "$K3S_MANAGED_AGENT_TOKEN_FILE" "Agent token file"
    elif [[ ! -s $K3S_MANAGED_AGENT_TOKEN_FILE ]]; then
      die "Joining an agent requires --agent-token-file PATH or --token-file PATH."
    fi
    return 0
  fi

  if [[ -n ${TOKEN_SOURCE:-} ]]; then
    copy_token_file "$TOKEN_SOURCE" "$K3S_MANAGED_TOKEN_FILE" "Server token file"
  elif [[ $MODE == init-server && ! -s $K3S_MANAGED_TOKEN_FILE ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "Would generate a root-only server token at ${K3S_MANAGED_TOKEN_FILE}."
    else
      umask 077
      openssl rand -hex 32 > "$K3S_MANAGED_TOKEN_FILE"
      chmod 0600 "$K3S_MANAGED_TOKEN_FILE"
      log_ok "Generated root-only server token: ${K3S_MANAGED_TOKEN_FILE}"
    fi
  elif [[ ! -s $K3S_MANAGED_TOKEN_FILE ]]; then
    die "Joining a server requires --token-file PATH."
  fi

  if [[ -n ${AGENT_TOKEN_SOURCE:-} ]]; then
    copy_token_file "$AGENT_TOKEN_SOURCE" "$K3S_MANAGED_AGENT_TOKEN_FILE" "Agent token file"
  fi
}

install_registry_config() {
  [[ -n ${REGISTRY_CONFIG_SOURCE:-} ]] || return 0
  [[ -s $REGISTRY_CONFIG_SOURCE ]] || die "Registry configuration is missing or empty: ${REGISTRY_CONFIG_SOURCE}"
  ensure_absolute_path "$REGISTRY_CONFIG_SOURCE" "Registry configuration"
  local tmp owner mode
  owner=$(stat -c '%u' "$REGISTRY_CONFIG_SOURCE")
  mode=$(stat -c '%a' "$REGISTRY_CONFIG_SOURCE")
  [[ $owner == 0 && $((8#$mode & 077)) -eq 0 ]] ||
    die "Registry configuration must be root-owned and inaccessible to group/other users: ${REGISTRY_CONFIG_SOURCE}"
  tmp=$(mktemp)
  cp "$REGISTRY_CONFIG_SOURCE" "$tmp"
  chmod 0600 "$tmp"
  write_if_changed "$tmp" "${K3S_CONFIG_DIR}/registries.yaml" 0600
}

ensure_no_unmanaged_config_conflicts() {
  local owned_pattern
  owned_pattern='^[[:space:]]*(server|token|token-file|agent-token|agent-token-file|cluster-init|node-name|node-ip|node-external-ip|node-label|node-taint|flannel-backend|flannel-iface|secrets-encryption|disable|tls-san|etcd-snapshot-compress|etcd-snapshot-retention|etcd-snapshot-schedule-cron)[[:space:]]*:'
  local candidates=() file
  [[ -f ${K3S_CONFIG_DIR}/config.yaml ]] && candidates+=("${K3S_CONFIG_DIR}/config.yaml")
  if [[ -d $K3S_DROPIN_DIR ]]; then
    while IFS= read -r -d '' file; do candidates+=("$file"); done < <(
      find "$K3S_DROPIN_DIR" -maxdepth 1 -type f -name '*.yaml' \
        ! -name '10-deployscripts-cluster.yaml' \
        ! -name '20-deployscripts-node.yaml' \
        ! -name '30-deployscripts-role.yaml' -print0
    )
  fi
  for file in "${candidates[@]}"; do
    if grep -Eq "$owned_pattern" "$file"; then
      die "Unmanaged K3s configuration overlaps DeployScripts-owned settings: ${file}"
    fi
  done
}

write_k3s_configs() (
  run install -d -o root -g root -m 0755 "$K3S_DROPIN_DIR"
  local work
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  if [[ $MODE != join-agent ]]; then
    render_cluster_config "${work}/10-deployscripts-cluster.yaml"
    write_if_changed "${work}/10-deployscripts-cluster.yaml" "${K3S_DROPIN_DIR}/10-deployscripts-cluster.yaml" 0600
  else
    if [[ -e ${K3S_DROPIN_DIR}/10-deployscripts-cluster.yaml ]]; then
      die "Agent has a DeployScripts server cluster configuration. Refusing ambiguous role state."
    fi
  fi

  render_node_config "${work}/20-deployscripts-node.yaml"
  render_role_config "${work}/30-deployscripts-role.yaml"
  write_if_changed "${work}/20-deployscripts-node.yaml" "${K3S_DROPIN_DIR}/20-deployscripts-node.yaml" 0600
  write_if_changed "${work}/30-deployscripts-role.yaml" "${K3S_DROPIN_DIR}/30-deployscripts-role.yaml" 0600
  install_registry_config
)

write_array_state() {
  local name=$1
  shift
  printf '%s=(' "$name"
  (($# == 0)) || printf ' %q' "$@"
  printf ' )\n'
}

save_state() {
  [[ $DRY_RUN -eq 0 ]] || { log_info "Would save DeployScripts state: ${K3S_STATE_FILE}"; return 0; }
  install -d -o root -g root -m 0755 "$K3S_STATE_DIR"
  local tmp
  tmp=$(mktemp "${K3S_STATE_DIR}/.state.XXXXXX")
  {
    printf '# Managed by DeployScripts K3s. Contains no cluster tokens.\n'
    printf 'DEPLOYSCRIPTS_K3S_MODE=%q\n' "$MODE"
    printf 'DEPLOYSCRIPTS_K3S_NODE_NAME=%q\n' "$NODE_NAME"
    printf 'DEPLOYSCRIPTS_K3S_NODE_IP=%q\n' "$NODE_IP"
    printf 'DEPLOYSCRIPTS_K3S_NODE_EXTERNAL_IP=%q\n' "$NODE_EXTERNAL_IP"
    printf 'DEPLOYSCRIPTS_K3S_API_ENDPOINT=%q\n' "$API_ENDPOINT"
    printf 'DEPLOYSCRIPTS_K3S_DATASTORE=%q\n' "$DATASTORE"
    printf 'DEPLOYSCRIPTS_K3S_FLANNEL_BACKEND=%q\n' "$FLANNEL_BACKEND"
    printf 'DEPLOYSCRIPTS_K3S_FLANNEL_IFACE=%q\n' "$FLANNEL_IFACE"
    printf 'DEPLOYSCRIPTS_K3S_SECRETS_ENCRYPTION=%q\n' "$SECRETS_ENCRYPTION"
    printf 'DEPLOYSCRIPTS_K3S_SNAPSHOT_SCHEDULE=%q\n' "$SNAPSHOT_SCHEDULE"
    printf 'DEPLOYSCRIPTS_K3S_SNAPSHOT_RETENTION=%q\n' "$SNAPSHOT_RETENTION"
    write_array_state DEPLOYSCRIPTS_K3S_TLS_SANS "${TLS_SANS[@]}"
    write_array_state DEPLOYSCRIPTS_K3S_DISABLED_COMPONENTS "${DISABLED_COMPONENTS[@]}"
    write_array_state DEPLOYSCRIPTS_K3S_NODE_LABELS "${NODE_LABELS[@]}"
    write_array_state DEPLOYSCRIPTS_K3S_NODE_TAINTS "${NODE_TAINTS[@]}"
  } > "$tmp"
  chmod 0644 "$tmp"
  write_if_changed "$tmp" "$K3S_STATE_FILE" 0644
}
