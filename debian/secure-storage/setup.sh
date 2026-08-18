#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/storage.sh
source "${SCRIPT_DIR}/lib/storage.sh"
# shellcheck source=lib/swap.sh
source "${SCRIPT_DIR}/lib/swap.sh"
# shellcheck source=lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/lib/validate.sh"

trap 'on_error "$LINENO"' ERR

NAME="secure-storage"
MOUNT_PATH="/srv/secure"
IMAGE_PATH=""
IMAGE_SIZE=""
KEY_PATH=""
SWAP_MODE="ask"
SWAP_SIZE=""
DOCKER_REQUESTED=0
CHECK_ONLY=0
DRY_RUN=0
NON_INTERACTIVE=0

usage() {
  cat <<'EOF'
Debian Secure Storage

Creates or converges a file-backed LUKS2 encrypted filesystem with automatic
unlock/mount, optional encrypted swap, and optional Docker/containerd storage.

Usage:
  sudo ./setup.sh [options]

Storage:
  --name NAME             Logical LUKS mapper name (default: secure-storage)
  --mount PATH            Mount path (default: /srv/secure)
  --image-path PATH       LUKS image path
                           (default: /var/lib/deployscripts/secure-storage/NAME.img)
  --image-size SIZE       Size when creating a new image, e.g. 26G
  --key-path PATH         Root-only auto-unlock key path
                           (default: /root/.deployscripts/keys/NAME.key)

Swap:
  --swap SIZE             Disable existing swap and create encrypted swapfile
  --no-swap               Leave current swap configuration untouched
  --disable-swap          Disable active/configured swap without replacement

Optional modules:
  --docker                Install/configure Docker and move persistent Docker
                           + containerd data beneath the encrypted mount

Modes:
  --check                 Read-only validation of an existing installation
  --dry-run               Show intended mutations without changing the host
  --non-interactive       Never prompt; required choices must be passed as flags
  -h, --help              Show this help

Secrets:
  Recovery passphrases are requested interactively and are never accepted as
  command-line arguments. A random machine key is generated for automatic boot
  unlock; its path is printed after setup.

Example:
  sudo ./setup.sh \
    --name harbor-secure \
    --mount /srv/secure \
    --image-size 26G \
    --swap 12G \
    --docker
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value."
        NAME=$2; shift 2 ;;
      --mount)
        [[ $# -ge 2 ]] || die "--mount requires a value."
        MOUNT_PATH=$2; shift 2 ;;
      --image-path)
        [[ $# -ge 2 ]] || die "--image-path requires a value."
        IMAGE_PATH=$2; shift 2 ;;
      --image-size)
        [[ $# -ge 2 ]] || die "--image-size requires a value."
        IMAGE_SIZE=$2; shift 2 ;;
      --key-path)
        [[ $# -ge 2 ]] || die "--key-path requires a value."
        KEY_PATH=$2; shift 2 ;;
      --swap)
        [[ $# -ge 2 ]] || die "--swap requires a size."
        SWAP_MODE="encrypted"; SWAP_SIZE=$2; shift 2 ;;
      --no-swap)
        SWAP_MODE="leave"; shift ;;
      --disable-swap)
        SWAP_MODE="disable"; shift ;;
      --docker)
        DOCKER_REQUESTED=1; shift ;;
      --check)
        CHECK_ONLY=1; shift ;;
      --dry-run)
        DRY_RUN=1; shift ;;
      --non-interactive)
        NON_INTERACTIVE=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1 (use --help)" ;;
    esac
  done
}

resolve_defaults() {
  validate_name "$NAME"
  IMAGE_PATH=${IMAGE_PATH:-"/var/lib/deployscripts/secure-storage/${NAME}.img"}
  KEY_PATH=${KEY_PATH:-"/root/.deployscripts/keys/${NAME}.key"}

  ensure_absolute_path "$MOUNT_PATH" "Mount path"
  ensure_absolute_path "$IMAGE_PATH" "Image path"
  ensure_absolute_path "$KEY_PATH" "Key path"

  [[ $MOUNT_PATH != "/" ]] || die "Refusing to use / as secure mount."
  [[ $IMAGE_PATH != "$MOUNT_PATH"* ]] ||
    die "The encrypted image cannot live inside the filesystem that it unlocks."

  if [[ $SWAP_MODE == "ask" ]]; then
    if [[ $NON_INTERACTIVE -eq 1 || $CHECK_ONLY -eq 1 ]]; then
      SWAP_MODE="leave"
    else
      local answer
      read -r -p "Configure swap inside encrypted storage? [Y/n]: " answer
      case "${answer,,}" in
        ""|y|yes)
          SWAP_MODE="encrypted"
          read -r -p "Encrypted swap size [4G]: " SWAP_SIZE
          SWAP_SIZE=${SWAP_SIZE:-4G}
          ;;
        n|no)
          read -r -p "Disable existing swap entirely? [y/N]: " answer
          case "${answer,,}" in
            y|yes) SWAP_MODE="disable" ;;
            *) SWAP_MODE="leave" ;;
          esac
          ;;
        *)
          die "Unrecognized response."
          ;;
      esac
    fi
  fi
}

main() {
  parse_args "$@"
  resolve_defaults

  require_root
  ensure_debian

  if [[ $CHECK_ONLY -eq 1 ]]; then
    command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup is required for --check."
    command -v findmnt >/dev/null 2>&1 || die "findmnt is required for --check."
    validate_secure_storage
    exit $?
  fi

  if [[ $NON_INTERACTIVE -eq 1 && ! -e $IMAGE_PATH ]]; then
    die "Creating a new LUKS volume requires an interactive recovery passphrase. Remove --non-interactive for first creation."
  fi

  configure_storage
  configure_swap

  if [[ $DOCKER_REQUESTED -eq 1 ]]; then
    configure_docker
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    validate_secure_storage
  else
    log_info "Dry run complete; no host changes were made."
  fi

  cat <<EOF

Setup complete.

Auto-unlock key: ${KEY_PATH}
Encrypted image: ${IMAGE_PATH}
Mount path:      ${MOUNT_PATH}

For the only definitive boot-path test, reboot the host and then run:
  sudo ${SCRIPT_DIR}/setup.sh --name ${NAME} --mount ${MOUNT_PATH} --image-path ${IMAGE_PATH} --key-path ${KEY_PATH} --check

The --check command does not modify the installation.
EOF
}

main "$@"
