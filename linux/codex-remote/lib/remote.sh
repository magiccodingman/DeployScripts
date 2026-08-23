#!/usr/bin/env bash

ssh_base_args() {
  SSH_ARGS=(-F "$SSH_CONFIG" -o ConnectTimeout=10)
  [[ $NON_INTERACTIVE -eq 0 ]] || SSH_ARGS+=(-o BatchMode=yes)
  [[ -z $BOOTSTRAP_IDENTITY ]] || SSH_ARGS+=(-i "$BOOTSTRAP_IDENTITY")
}

remote_ssh() {
  # Arguments after the host are intentionally interpreted by the remote shell.
  # shellcheck disable=SC2029
  ssh "${SSH_ARGS[@]}" "$NAME" "$@"
}

remote_ssh_tty() {
  ssh -t "${SSH_ARGS[@]}" "$NAME" "$@"
}

remote_login_shell() {
  local command=$1 encoded
  encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
  remote_ssh sh -s -- "$encoded" <<'REMOTE_LOGIN_SHELL'
set -eu
encoded=$1
command=$(printf '%s' "$encoded" | base64 -d)
shell=$(getent passwd "$(id -un)" 2>/dev/null | awk -F: '{print $7}')
if [ -z "$shell" ] || [ ! -x "$shell" ]; then
  shell=${SHELL:-/bin/sh}
fi
exec "$shell" -lc "$command"
REMOTE_LOGIN_SHELL
}

remote_login_shell_tty() {
  local command=$1 encoded
  encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
  remote_ssh_tty "encoded='${encoded}'; command=\$(printf '%s' \"\$encoded\" | base64 -d); shell=\$(getent passwd \"\$(id -un)\" 2>/dev/null | awk -F: '{print \$7}'); [ -x \"\$shell\" ] || shell=\${SHELL:-/bin/sh}; exec \"\$shell\" -lc \"\$command\""
}

remote_backup_and_install_key() {
  local public_key_file=$1 mode=$2
  local final_marker="deployscripts:codex-remote:${NAME}"
  local pending_marker="${final_marker}:pending"
  local public_material public_line encoded
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "Would install the ${mode} managed public key for ${NAME} on ${REMOTE_USER}@${HOST}."
    return 0
  fi
  public_material=$(key_public_material "$public_key_file")
  if [[ $mode == pending ]]; then
    public_line="${public_material} ${pending_marker}"
  else
    public_line="${public_material} ${final_marker}"
  fi
  encoded=$(printf '%s' "$public_line" | base64 | tr -d '\n')

  remote_ssh sh -s -- "$final_marker" "$pending_marker" "$mode" "$BACKUP_LIMIT" "$encoded" <<'REMOTE_AUTHORIZED_KEYS'
set -eu
final_marker=$1
pending_marker=$2
mode=$3
backup_limit=$4
encoded=$5
public_line=$(printf '%s' "$encoded" | base64 -d)
ssh_dir=$HOME/.ssh
authorized_keys=$ssh_dir/authorized_keys
backup_dir=$HOME/.local/state/deployscripts/backups/codex-remote/authorized_keys
umask 077
mkdir -p "$ssh_dir"
chmod 0700 "$ssh_dir"
if [ ! -e "$authorized_keys" ]; then
  : > "$authorized_keys"
fi
chmod 0600 "$authorized_keys"
temporary=$(mktemp "$ssh_dir/.authorized_keys.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
if [ "$mode" = pending ]; then
  awk -v pending="$pending_marker" '$NF != pending { print }' "$authorized_keys" > "$temporary"
else
  awk -v final="$final_marker" -v pending="$pending_marker" '$NF != final && $NF != pending { print }' "$authorized_keys" > "$temporary"
fi
printf '%s\n' "$public_line" >> "$temporary"
chmod 0600 "$temporary"
if cmp -s "$temporary" "$authorized_keys"; then
  exit 0
fi
mkdir -p "$backup_dir"
chmod 0700 "$HOME/.local/state/deployscripts" "$HOME/.local/state/deployscripts/backups" \
  "$HOME/.local/state/deployscripts/backups/codex-remote" "$backup_dir" 2>/dev/null || true
timestamp=$(date -u +%Y%m%dT%H%M%S.%NZ)
cp -a "$authorized_keys" "$backup_dir/$timestamp"
mv -f "$temporary" "$authorized_keys"
trap - EXIT HUP INT TERM
find "$backup_dir" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -rn | \
  awk -v keep="$backup_limit" 'NR > keep {sub(/^[^ ]+ /, ""); print}' | \
  while IFS= read -r old; do rm -f -- "$old"; done
REMOTE_AUTHORIZED_KEYS
}

test_key_directly() {
  local identity=$1
  local effective user_known_hosts strict_host_key proxy_jump host_key_alias
  effective=$(ssh -G -F "$SSH_CONFIG" "$NAME" 2>/dev/null)
  user_known_hosts=$(awk '$1 == "userknownhostsfile" {$1=""; sub(/^ /, ""); print; exit}' <<< "$effective")
  strict_host_key=$(awk '$1 == "stricthostkeychecking" {print $2; exit}' <<< "$effective")
  proxy_jump=$(awk '$1 == "proxyjump" {print $2; exit}' <<< "$effective")
  host_key_alias=$(awk '$1 == "hostkeyalias" {print $2; exit}' <<< "$effective")

  local direct_args=(-F /dev/null -p "$PORT" -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -i "$identity")
  [[ -z $user_known_hosts || $user_known_hosts == none ]] || direct_args+=(-o "UserKnownHostsFile=${user_known_hosts}")
  [[ -z $strict_host_key ]] || direct_args+=(-o "StrictHostKeyChecking=${strict_host_key}")
  [[ -z $proxy_jump || $proxy_jump == none ]] || direct_args+=(-J "$proxy_jump")
  [[ -z $host_key_alias || $host_key_alias == none ]] || direct_args+=(-o "HostKeyAlias=${host_key_alias}")
  ssh "${direct_args[@]}" "${REMOTE_USER}@${HOST}" true
}

ensure_remote_platform() {
  local platform
  # Variables in this command are intentionally expanded on the remote host.
  # shellcheck disable=SC2016
  platform=$(remote_ssh '. /etc/os-release 2>/dev/null || exit 1; printf "%s" "$ID"') ||
    die "Could not identify the remote operating system."
  case "$platform" in
    debian|ubuntu) log_ok "Supported remote platform detected: ${platform}" ;;
    *) die "Codex remote provisioning currently supports Debian and Ubuntu targets (detected: ${platform:-unknown})." ;;
  esac
}

ensure_remote_packages() {
  local missing
  # Variables in this command are intentionally expanded on the remote host.
  # shellcheck disable=SC2016
  missing=$(remote_ssh 'missing=""; for package in curl ca-certificates git; do dpkg-query -W -f="${Status}" "$package" 2>/dev/null | grep -q "ok installed" || missing="$missing $package"; done; printf "%s" "$missing"')
  [[ -n ${missing// /} ]] || { log_ok "Remote prerequisites are installed."; return 0; }

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "Would install remote packages:${missing}"
    return 0
  fi

  local remote_uid
  remote_uid=$(remote_ssh id -u)
  if [[ $remote_uid == 0 ]]; then
    remote_ssh_tty "env DEBIAN_FRONTEND=noninteractive apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y${missing}"
  else
    if [[ $NON_INTERACTIVE -eq 1 ]]; then
      remote_ssh "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y${missing}" ||
        die "Remote packages are missing and non-interactive sudo is unavailable:${missing}"
    else
      remote_ssh_tty "sudo env DEBIAN_FRONTEND=noninteractive apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y${missing}"
    fi
  fi
  log_ok "Installed remote prerequisites:${missing}"
}

codex_available() {
  remote_login_shell 'command -v codex >/dev/null 2>&1'
}

ensure_remote_codex() {
  local quoted_url
  quoted_url=$(shell_quote "$CODEX_INSTALL_URL")
  case "$CODEX_INSTALL" in
    skip)
      codex_available || die "Codex is not available in the remote login-shell PATH and --codex-install skip was requested."
      ;;
    ensure)
      codex_available && { log_ok "Codex is already available in the remote login-shell PATH."; return 0; }
      remote_login_shell "curl -fsSL ${quoted_url} | sh"
      ;;
    update)
      remote_login_shell "curl -fsSL ${quoted_url} | sh"
      ;;
    *) die "Unexpected Codex installation mode: ${CODEX_INSTALL}" ;;
  esac
  if ! codex_available; then
    ensure_remote_codex_path
  fi
  codex_available || die "Codex installation completed but codex is not available in the remote login-shell PATH."
  log_ok "Codex is available in the remote login-shell PATH."
}

ensure_remote_codex_path() {
  local bin_dir encoded
  # Variables in this command are intentionally expanded on the remote host.
  # shellcheck disable=SC2016
  bin_dir=$(remote_ssh 'for candidate in "$HOME/.local/bin/codex" "$HOME/.codex/bin/codex"; do if [ -x "$candidate" ]; then dirname "$candidate"; exit 0; fi; done; exit 1') ||
    die "Codex was installed but its executable could not be located in a supported per-user bin directory."
  encoded=$(printf '%s' "$bin_dir" | base64 | tr -d '\n')
  remote_ssh sh -s -- "$BACKUP_LIMIT" "$encoded" <<'REMOTE_CODEX_PATH'
set -eu
backup_limit=$1
bin_dir=$(printf '%s' "$2" | base64 -d)
shell_path=$(getent passwd "$(id -un)" 2>/dev/null | awk -F: '{print $7}')
shell_name=$(basename "${shell_path:-sh}")
case "$shell_name" in
  bash)
    if [ -e "$HOME/.bash_profile" ]; then profile=$HOME/.bash_profile
    elif [ -e "$HOME/.bash_login" ]; then profile=$HOME/.bash_login
    else profile=$HOME/.profile
    fi
    ;;
  zsh) profile=$HOME/.zprofile ;;
  *) profile=$HOME/.profile ;;
esac
begin='# BEGIN DeployScripts codex-remote PATH'
end='# END DeployScripts codex-remote PATH'
temporary=$(mktemp "$HOME/.codex-profile.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
if [ -f "$profile" ]; then
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$profile" > "$temporary"
fi
cat >> "$temporary" <<EOF_PATH
$begin
case ":\$PATH:" in
  *":${bin_dir}:"*) ;;
  *) PATH="${bin_dir}:\$PATH" ;;
esac
export PATH
$end
EOF_PATH
if [ -f "$profile" ] && cmp -s "$temporary" "$profile"; then
  exit 0
fi
backup_dir=$HOME/.local/state/deployscripts/backups/codex-remote/profile
mkdir -p "$backup_dir"
chmod 0700 "$HOME/.local/state/deployscripts" "$HOME/.local/state/deployscripts/backups" \
  "$HOME/.local/state/deployscripts/backups/codex-remote" "$backup_dir" 2>/dev/null || true
if [ -f "$profile" ]; then
  timestamp=$(date -u +%Y%m%dT%H%M%S.%NZ)
  cp -a "$profile" "$backup_dir/$timestamp"
fi
chmod 0644 "$temporary"
mv -f "$temporary" "$profile"
trap - EXIT HUP INT TERM
find "$backup_dir" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -rn | \
  awk -v keep="$backup_limit" 'NR > keep {sub(/^[^ ]+ /, ""); print}' | \
  while IFS= read -r old; do rm -f -- "$old"; done
REMOTE_CODEX_PATH
  log_ok "Added ${bin_dir} to the remote login-shell PATH through a managed profile block."
}

codex_authenticated() {
  remote_login_shell 'codex login status >/dev/null 2>&1'
}

ensure_codex_authentication() {
  codex_authenticated && { log_ok "Remote Codex authentication is active."; return 0; }
  case "$AUTH_MODE" in
    skip)
      log_warn "Remote Codex is not authenticated; authentication was skipped."
      ;;
    device)
      [[ $NON_INTERACTIVE -eq 0 ]] || die "Remote Codex is not authenticated. Rerun interactively or use --auth skip."
      log_info "Starting Codex device-code authentication on the remote host..."
      remote_login_shell_tty 'codex login --device-auth'
      codex_authenticated || die "Codex device authentication did not produce an active login."
      log_ok "Remote Codex authentication is active."
      ;;
    *) die "Unexpected authentication mode: ${AUTH_MODE}" ;;
  esac
}
