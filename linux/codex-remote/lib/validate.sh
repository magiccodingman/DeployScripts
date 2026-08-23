#!/usr/bin/env bash

validate_remote_key_marker() {
  local marker="deployscripts:codex-remote:${NAME}"
  remote_ssh "test \"\$(stat -c '%a' \"\$HOME/.ssh\")\" = 700 && test \"\$(stat -c '%a' \"\$HOME/.ssh/authorized_keys\")\" = 600 && awk -v marker=$(shell_quote "$marker") '\$NF == marker { found=1 } END { exit !found }' \"\$HOME/.ssh/authorized_keys\"" ||
    die "Remote SSH permissions or the managed authorized-key marker are invalid."
  log_ok "Remote SSH permissions and managed authorized-key entry are valid."
}

validate_unattended_ssh() {
  ssh -F "$SSH_CONFIG" -o ConnectTimeout=10 -o BatchMode=yes "$NAME" true ||
    die "Unattended SSH validation failed for ${NAME}."
  log_ok "Unattended SSH succeeds through alias ${NAME}."
}

validate_remote_codex() {
  local version
  codex_available || die "codex is unavailable in the remote login-shell PATH."
  version=$(remote_login_shell 'codex --version')
  [[ -n $version ]] || die "codex --version returned no output."
  remote_login_shell 'codex app-server --help >/dev/null 2>&1' || die "Codex app-server validation failed."
  log_ok "Remote Codex CLI and app-server are available: ${version}"
}

validate_all() {
  validate_key_pair "$KEY_PATH"
  log_ok "Local dedicated SSH keypair is valid."
  validate_effective_ssh_config
  validate_unattended_ssh
  validate_remote_key_marker
  validate_remote_codex
  if codex_authenticated; then
    log_ok "Remote Codex authentication is active."
  elif [[ $AUTH_MODE == skip ]]; then
    log_warn "Remote Codex authentication is not active (--auth skip)."
  else
    die "Remote Codex authentication is not active."
  fi
}
