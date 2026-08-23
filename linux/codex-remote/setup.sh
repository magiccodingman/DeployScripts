#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=linux/codex-remote/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=linux/codex-remote/lib/local-ssh.sh
source "$SCRIPT_DIR/lib/local-ssh.sh"
# shellcheck source=linux/codex-remote/lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"
# shellcheck source=linux/codex-remote/lib/validate.sh
source "$SCRIPT_DIR/lib/validate.sh"
trap 'on_error $LINENO' ERR
trap cleanup_rotation EXIT

NAME=""
HOST=""
REMOTE_USER=""
PORT=22
PORT_SET=0
KEY_PATH=""
KEY_PATH_SET=0
SSH_CONFIG="$HOME/.ssh/config"
SSH_INCLUDE_DIR=""
HOST_CONFIG=""
BOOTSTRAP_IDENTITY=""
BACKUP_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/deployscripts/backups/codex-remote"
BACKUP_LIMIT=10
CODEX_INSTALL="ensure"
CODEX_INSTALL_URL="${DEPLOYSCRIPTS_CODEX_INSTALL_URL:-https://chatgpt.com/codex/install.sh}"
AUTH_MODE="device"
REPLACE_EXISTING=0
RETARGET=0
ROTATE_KEY=0
CHECK_ONLY=0
DRY_RUN=0
NON_INTERACTIVE=0
PENDING_KEY_PATH=""
ROTATION_DIR=""
SSH_ARGS=()

usage() {
  cat <<'EOF_USAGE'
Codex Remote Host Provisioning

Creates or converges a dedicated SSH identity and concrete SSH alias, installs
the public key on a Debian/Ubuntu host, installs Codex, and validates the remote
Codex app-server path used by ChatGPT remote connections.

Usage:
  ./linux/codex-remote/setup.sh --name ALIAS --host HOST --user USER [options]

Required on first run:
  --name ALIAS                 Concrete SSH alias exposed to Codex
  --host HOST                  Remote IP address or DNS name
  --user USER                  Remote SSH account

After a successful run, --host, --user, --port, and --key-path are recovered
from the managed host file, so read-only checks and repairs need only --name.

Connection:
  --port PORT                  SSH port (default: 22)
  --bootstrap-identity PATH    Existing identity for initial remote access
  --key-path PATH              Dedicated key path
                               (default: ~/.ssh/codex_NAME)
  --ssh-config PATH            Main SSH config (default: ~/.ssh/config)

Codex:
  --codex-install MODE         ensure (default), update, or skip
  --auth MODE                  device (default) or skip

Existing state:
  --replace-existing           Let the managed alias take precedence over an
                               existing unmanaged exact Host declaration
  --retarget                   Permit a managed alias to change host/user/port
  --rotate-key                 Verify and activate a replacement identity

Backups:
  --backup-root PATH           Local backup root
  --backup-limit NUMBER        Backups retained per changed file (default: 10)

Modes:
  --check                      Read-only end-to-end validation
  --dry-run                    Show intended changes without mutation
  --non-interactive            Never prompt; initial access must already work
  -h, --help                   Show this help

The initial SSH connection uses normal OpenSSH authentication. It may prompt for
the remote account password and host-key confirmation. Passwords are never read
or stored by this script.
EOF_USAGE
}

parse_args() {
  while (($#)); do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name requires a value."; NAME=$2; shift 2 ;;
      --host) [[ $# -ge 2 ]] || die "--host requires a value."; HOST=$2; shift 2 ;;
      --user) [[ $# -ge 2 ]] || die "--user requires a value."; REMOTE_USER=$2; shift 2 ;;
      --port) [[ $# -ge 2 ]] || die "--port requires a value."; PORT=$2; PORT_SET=1; shift 2 ;;
      --bootstrap-identity) [[ $# -ge 2 ]] || die "--bootstrap-identity requires a path."; BOOTSTRAP_IDENTITY=$2; shift 2 ;;
      --key-path) [[ $# -ge 2 ]] || die "--key-path requires a path."; KEY_PATH=$2; KEY_PATH_SET=1; shift 2 ;;
      --ssh-config) [[ $# -ge 2 ]] || die "--ssh-config requires a path."; SSH_CONFIG=$2; shift 2 ;;
      --codex-install) [[ $# -ge 2 ]] || die "--codex-install requires a mode."; CODEX_INSTALL=$2; shift 2 ;;
      --auth) [[ $# -ge 2 ]] || die "--auth requires a mode."; AUTH_MODE=$2; shift 2 ;;
      --replace-existing) REPLACE_EXISTING=1; shift ;;
      --retarget) RETARGET=1; shift ;;
      --rotate-key) ROTATE_KEY=1; shift ;;
      --backup-root) [[ $# -ge 2 ]] || die "--backup-root requires a path."; BACKUP_ROOT=$2; shift 2 ;;
      --backup-limit) [[ $# -ge 2 ]] || die "--backup-limit requires a number."; BACKUP_LIMIT=$2; shift 2 ;;
      --check) CHECK_ONLY=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done
}

resolve_configuration() {
  [[ -n $NAME ]] || die "--name is required."
  validate_name "$NAME"
  local normalized_name
  normalized_name=$(safe_name "$NAME")

  SSH_CONFIG=$(expand_home_path "$SSH_CONFIG")
  BACKUP_ROOT=$(expand_home_path "$BACKUP_ROOT")
  BOOTSTRAP_IDENTITY=$(expand_home_path "$BOOTSTRAP_IDENTITY")
  [[ -n $KEY_PATH ]] && KEY_PATH=$(expand_home_path "$KEY_PATH")
  SSH_INCLUDE_DIR="${SSH_CONFIG}.d/deployscripts"
  HOST_CONFIG="${SSH_INCLUDE_DIR}/codex-remote-${normalized_name}.conf"
  [[ -n $KEY_PATH ]] || KEY_PATH="$HOME/.ssh/codex_${normalized_name}"

  load_managed_host_defaults
  [[ -n $HOST ]] || die "--host is required for a new managed alias."
  [[ -n $REMOTE_USER ]] || die "--user is required for a new managed alias."
  validate_host "$HOST"
  validate_user "$REMOTE_USER"
  validate_port "$PORT"
  if [[ ! $BACKUP_LIMIT =~ ^[0-9]+$ ]] || ((BACKUP_LIMIT < 1 || BACKUP_LIMIT > 100)); then
    die "--backup-limit must be between 1 and 100."
  fi
  [[ $CODEX_INSTALL == ensure || $CODEX_INSTALL == update || $CODEX_INSTALL == skip ]] ||
    die "--codex-install must be ensure, update, or skip."
  [[ $AUTH_MODE == device || $AUTH_MODE == skip ]] || die "--auth must be device or skip."
  [[ $CHECK_ONLY -eq 0 || $DRY_RUN -eq 0 ]] || die "--check and --dry-run cannot be combined."
  [[ $CHECK_ONLY -eq 0 || $ROTATE_KEY -eq 0 ]] || die "--check and --rotate-key cannot be combined."

  ensure_absolute_path "$SSH_CONFIG" "SSH config"
  ensure_absolute_path "$KEY_PATH" "SSH key path"
  ensure_absolute_path "$BACKUP_ROOT" "Backup root"
  [[ -z $BOOTSTRAP_IDENTITY ]] || ensure_absolute_path "$BOOTSTRAP_IDENTITY" "Bootstrap identity"
  [[ -z $BOOTSTRAP_IDENTITY || -f $BOOTSTRAP_IDENTITY ]] || die "Bootstrap identity not found: ${BOOTSTRAP_IDENTITY}"
}

main() {
  parse_args "$@"
  resolve_configuration
  require_commands ssh ssh-keygen awk sed sha256sum base64
  ssh_base_args

  if [[ $CHECK_ONLY -eq 1 ]]; then
    validate_all
    printf '\nCODEX REMOTE READINESS: PASS\n'
    return 0
  fi

  ensure_local_key "deployscripts:codex-remote:${NAME}"
  ensure_ssh_include
  ensure_host_config

  if [[ $DRY_RUN -eq 1 ]]; then
    remote_backup_and_install_key "${KEY_PATH}.pub" final
    log_info "Would ensure Debian/Ubuntu prerequisites, Codex (${CODEX_INSTALL}), and authentication (${AUTH_MODE})."
    printf '\nDry run complete; no local or remote changes were made.\n'
    return 0
  fi

  if [[ -n $PENDING_KEY_PATH ]]; then
    remote_backup_and_install_key "${PENDING_KEY_PATH}.pub" pending
    if ! test_key_directly "$PENDING_KEY_PATH"; then
      remote_backup_and_install_key "${KEY_PATH}.pub" final ||
        log_warn "Could not remove the unusable pending key marker; the current final key remains authorized."
      die "The replacement identity could not authenticate; the current key remains unchanged."
    fi
    log_ok "The pending replacement identity authenticated successfully."
    finalize_key_rotation
    ssh_base_args
  fi

  remote_backup_and_install_key "${KEY_PATH}.pub" final
  validate_unattended_ssh
  ensure_remote_platform
  [[ $CODEX_INSTALL == skip ]] || ensure_remote_packages
  ensure_remote_codex
  ensure_codex_authentication
  validate_all

  cat <<EOF

CODEX REMOTE READINESS: PASS

SSH alias:      ${NAME}
Remote target:  ${REMOTE_USER}@${HOST}:${PORT}
Identity:       ${KEY_PATH}
Host config:    ${HOST_CONFIG}

The host is ready to add under ChatGPT Settings > Connections > SSH.
EOF
}

main "$@"
