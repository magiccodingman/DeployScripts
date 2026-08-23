#!/usr/bin/env bash

key_public_material() {
  awk 'NR == 1 { print $1 " " $2 }' "$1"
}

validate_key_pair() {
  local private_key=$1 public_key=${1}.pub derived expected private_mode
  [[ -f $private_key ]] || die "Private SSH key is missing: ${private_key}"
  [[ -f $public_key ]] || die "Public SSH key is missing: ${public_key}"
  private_mode=$(stat -c '%a' "$private_key")
  if [[ $private_mode != 600 ]]; then
    [[ ${CHECK_ONLY:-0} -eq 0 ]] || die "Private SSH key must have mode 0600 (found ${private_mode}): ${private_key}"
    chmod 0600 "$private_key"
  fi
  derived=$(ssh-keygen -y -f "$private_key" | awk '{print $1 " " $2}')
  expected=$(key_public_material "$public_key")
  [[ $derived == "$expected" ]] || die "SSH public and private keys do not match: ${private_key}"
}

generate_key_at() {
  local path=$1 comment=$2
  install -d -m 0700 "$(dirname "$path")"
  ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$path"
  chmod 0600 "$path"
  chmod 0644 "${path}.pub"
}

ensure_local_key() {
  local comment=$1
  PENDING_KEY_PATH=""
  ROTATION_DIR=""

  if [[ -f $KEY_PATH && ! -f ${KEY_PATH}.pub ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "Would regenerate missing public key ${KEY_PATH}.pub"
    else
      local derived_public
      derived_public=$(ssh-keygen -y -f "$KEY_PATH")
      printf '%s %s\n' "$derived_public" "$comment" > "${KEY_PATH}.pub"
      chmod 0644 "${KEY_PATH}.pub"
      log_ok "Regenerated ${KEY_PATH}.pub"
    fi
  elif [[ ! -f $KEY_PATH && -f ${KEY_PATH}.pub ]]; then
    die "Public key exists without its private key: ${KEY_PATH}.pub"
  fi

  if [[ ! -f $KEY_PATH ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "Would generate dedicated Ed25519 key at ${KEY_PATH}"
      return 0
    fi
    generate_key_at "$KEY_PATH" "$comment"
    log_ok "Generated dedicated SSH identity: ${KEY_PATH}"
  fi

  validate_key_pair "$KEY_PATH"

  if [[ $ROTATE_KEY -eq 1 ]]; then
    [[ $DRY_RUN -eq 0 ]] || { log_info "Would safely rotate ${KEY_PATH}"; return 0; }
    ROTATION_DIR=$(mktemp -d "$(dirname "$KEY_PATH")/.codex-remote-rotation.XXXXXX")
    chmod 0700 "$ROTATION_DIR"
    PENDING_KEY_PATH="${ROTATION_DIR}/key"
    generate_key_at "$PENDING_KEY_PATH" "$comment"
    log_info "Generated a pending replacement identity. The current key remains active until verification succeeds."
  fi
}

finalize_key_rotation() {
  [[ -n ${PENDING_KEY_PATH:-} ]] || return 0
  backup_file "$KEY_PATH"
  backup_file "${KEY_PATH}.pub"

  local private_tmp public_tmp
  private_tmp=$(mktemp "$(dirname "$KEY_PATH")/.key.XXXXXX")
  public_tmp=$(mktemp "$(dirname "$KEY_PATH")/.key.pub.XXXXXX")
  cp -- "$PENDING_KEY_PATH" "$private_tmp"
  cp -- "${PENDING_KEY_PATH}.pub" "$public_tmp"
  chmod 0600 "$private_tmp"
  chmod 0644 "$public_tmp"
  mv -f -- "$private_tmp" "$KEY_PATH"
  mv -f -- "$public_tmp" "${KEY_PATH}.pub"
  rm -rf -- "$ROTATION_DIR"
  ROTATION_DIR=""
  PENDING_KEY_PATH=""
  validate_key_pair "$KEY_PATH"
  log_ok "Activated the verified replacement identity: ${KEY_PATH}"
}

cleanup_rotation() {
  [[ -n ${ROTATION_DIR:-} && -d ${ROTATION_DIR:-} ]] && rm -rf -- "$ROTATION_DIR"
  return 0
}

managed_value() {
  local key=$1 file=$2
  [[ -f $file ]] || return 0
  sed -n "s/^# ${key}=//p" "$file" | head -n1
}

load_managed_host_defaults() {
  [[ -f $HOST_CONFIG ]] || return 0
  local stored_host stored_user stored_port stored_key
  stored_host=$(managed_value DEPLOYSCRIPTS_HOST "$HOST_CONFIG")
  stored_user=$(managed_value DEPLOYSCRIPTS_USER "$HOST_CONFIG")
  stored_port=$(managed_value DEPLOYSCRIPTS_PORT "$HOST_CONFIG")
  stored_key=$(managed_value DEPLOYSCRIPTS_KEY_PATH "$HOST_CONFIG")

  if [[ -n $HOST && -n $stored_host && $HOST != "$stored_host" && $RETARGET -eq 0 ]]; then
    die "Managed alias ${NAME} currently targets ${stored_host}; use --retarget to change it to ${HOST}."
  fi
  if [[ -n $REMOTE_USER && -n $stored_user && $REMOTE_USER != "$stored_user" && $RETARGET -eq 0 ]]; then
    die "Managed alias ${NAME} currently uses ${stored_user}; use --retarget to change it to ${REMOTE_USER}."
  fi
  if [[ $PORT_SET -eq 1 && -n $stored_port && $PORT != "$stored_port" && $RETARGET -eq 0 ]]; then
    die "Managed alias ${NAME} currently uses port ${stored_port}; use --retarget to change it to ${PORT}."
  fi

  HOST=${HOST:-$stored_host}
  REMOTE_USER=${REMOTE_USER:-$stored_user}
  [[ $PORT_SET -eq 1 ]] || PORT=${stored_port:-22}
  [[ $KEY_PATH_SET -eq 1 ]] || KEY_PATH=${stored_key:-$KEY_PATH}
}

find_unmanaged_alias() {
  [[ -f $SSH_CONFIG ]] || return 1
  local candidate
  while IFS= read -r -d '' candidate; do
    [[ $candidate == "$HOST_CONFIG" ]] && continue
    awk -v target="$NAME" '
      BEGIN { IGNORECASE=1 }
      $1 == "Host" {
        for (i=2; i<=NF; i++) if ($i == target) { print FILENAME ":" FNR; exit }
      }
    ' "$candidate"
  done < <(
    {
      printf '%s\0' "$SSH_CONFIG"
      [[ -d ${SSH_CONFIG}.d ]] && find "${SSH_CONFIG}.d" -type f -print0
    } | awk 'BEGIN { RS="\0"; ORS="\0" } !seen[$0]++'
  ) | head -n1
}

ensure_ssh_include() {
  local include_glob="${SSH_INCLUDE_DIR}/*.conf"
  local marker="# Managed by DeployScripts codex-remote"
  local temporary body
  if [[ $DRY_RUN -eq 0 ]]; then
    install -d -m 0700 "$(dirname "$SSH_CONFIG")" "$SSH_INCLUDE_DIR"
    temporary=$(mktemp "$(dirname "$SSH_CONFIG")/.config.XXXXXX")
  else
    temporary=$(mktemp "${TMPDIR:-/tmp}/deployscripts-ssh-config.XXXXXX")
  fi
  {
    printf '%s\nInclude %s\n' "$marker" "$include_glob"
    if [[ -f $SSH_CONFIG ]]; then
      awk -v marker="$marker" -v include_path="$include_glob" '
        $0 == marker { next }
        $1 == "Include" && $2 == include_path { next }
        { print }
      ' "$SSH_CONFIG"
    fi
  } > "$temporary"
  body=$(mktemp "${TMPDIR:-/tmp}/deployscripts-ssh-validation.XXXXXX")
  cp -- "$temporary" "$body"
  ssh -G -F "$body" deployscripts-config-probe >/dev/null 2>&1
  rm -f -- "$body"
  write_file_if_changed "$temporary" "$SSH_CONFIG" 0600
}

render_host_config() {
  cat <<EOF
# Managed by DeployScripts codex-remote. Edit by rerunning setup.sh.
# DEPLOYSCRIPTS_HOST=${HOST}
# DEPLOYSCRIPTS_USER=${REMOTE_USER}
# DEPLOYSCRIPTS_PORT=${PORT}
# DEPLOYSCRIPTS_KEY_PATH=${KEY_PATH}
Host ${NAME}
    HostName ${HOST}
    User ${REMOTE_USER}
    Port ${PORT}
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
EOF
}

ensure_host_config() {
  local conflict temporary
  if [[ ! -f $HOST_CONFIG ]]; then
    conflict=$(find_unmanaged_alias || true)
    if [[ -n $conflict && $REPLACE_EXISTING -eq 0 ]]; then
      die "SSH alias ${NAME} is already declared at ${conflict}. Use --replace-existing to let the managed include take precedence."
    fi
    [[ -z $conflict ]] || log_warn "The managed include will take precedence over existing alias declaration ${conflict}."
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    temporary=$(mktemp "${SSH_INCLUDE_DIR}/.host.XXXXXX")
  else
    temporary=$(mktemp "${TMPDIR:-/tmp}/deployscripts-ssh-host.XXXXXX")
  fi
  render_host_config > "$temporary"
  ssh -G -F "$temporary" "$NAME" >/dev/null 2>&1
  write_file_if_changed "$temporary" "$HOST_CONFIG" 0600
}

validate_effective_ssh_config() {
  local output effective_host effective_user effective_port identities
  output=$(ssh -G -F "$SSH_CONFIG" "$NAME" 2>/dev/null)
  effective_host=$(awk '$1 == "hostname" {print $2; exit}' <<< "$output")
  effective_user=$(awk '$1 == "user" {print $2; exit}' <<< "$output")
  effective_port=$(awk '$1 == "port" {print $2; exit}' <<< "$output")
  identities=$(awk '$1 == "identityfile" {$1=""; sub(/^ /, ""); print}' <<< "$output")
  [[ $effective_host == "$HOST" ]] || die "Effective HostName is ${effective_host}, expected ${HOST}."
  [[ $effective_user == "$REMOTE_USER" ]] || die "Effective SSH user is ${effective_user}, expected ${REMOTE_USER}."
  [[ $effective_port == "$PORT" ]] || die "Effective SSH port is ${effective_port}, expected ${PORT}."
  grep -Fxq "$KEY_PATH" <<< "$identities" || die "Effective SSH configuration does not include ${KEY_PATH}."
  log_ok "Local SSH configuration resolves to the requested host, user, port, and identity."
}
