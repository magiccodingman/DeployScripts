#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=linux/codex-remote/lib/common.sh
source "$ROOT/linux/codex-remote/lib/common.sh"
# shellcheck source=linux/codex-remote/lib/local-ssh.sh
source "$ROOT/linux/codex-remote/lib/local-ssh.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

NAME="test-box"
HOST="192.0.2.10"
REMOTE_USER="tester"
PORT=2222
PORT_SET=1
KEY_PATH="$HOME/.ssh/codex_test_box"
KEY_PATH_SET=0
SSH_CONFIG="$HOME/.ssh/config"
SSH_INCLUDE_DIR="${SSH_CONFIG}.d/deployscripts"
HOST_CONFIG="${SSH_INCLUDE_DIR}/codex-remote-test_box.conf"
BACKUP_ROOT="$HOME/.local/state/deployscripts/backups/codex-remote"
BACKUP_LIMIT=10
DRY_RUN=0
ROTATE_KEY=0
RETARGET=0
REPLACE_EXISTING=0

printf 'unit: generate and validate dedicated key\n'
ensure_local_key "deployscripts:codex-remote:${NAME}"
validate_key_pair "$KEY_PATH"

printf 'unit: recover a missing public key\n'
rm -f "${KEY_PATH}.pub"
ensure_local_key "deployscripts:codex-remote:${NAME}"
validate_key_pair "$KEY_PATH"

printf 'unit: preserve unrelated SSH configuration through a managed include\n'
mkdir -p "$(dirname "$SSH_CONFIG")"
printf '%s\n' 'Host unrelated' '    HostName unrelated.example.com' > "$SSH_CONFIG"
ensure_ssh_include
ensure_host_config
grep -Fq 'Host unrelated' "$SSH_CONFIG"
grep -Fq "Include ${SSH_INCLUDE_DIR}/*.conf" "$SSH_CONFIG"
grep -Fq 'Host test-box' "$HOST_CONFIG"
validate_effective_ssh_config

printf 'unit: retain at most ten backups for a repeatedly changed file\n'
for octet in $(seq 11 23); do
  HOST="192.0.2.${octet}"
  ensure_host_config
done
bucket=$(backup_bucket_for "$HOST_CONFIG")
backup_count=$(find "$bucket" -maxdepth 1 -type f | wc -l)
[[ $backup_count -eq 10 ]] || { printf 'Expected 10 backups, found %s\n' "$backup_count" >&2; exit 1; }

printf 'unit: refuse an unmanaged exact alias without explicit replacement\n'
NAME="legacy-box"
HOST_CONFIG="${SSH_INCLUDE_DIR}/codex-remote-legacy_box.conf"
printf '%s\n' 'Host legacy-box' '    HostName old.example.com' >> "$SSH_CONFIG"
if (ensure_host_config >/dev/null 2>&1); then
  printf 'Expected unmanaged alias conflict to fail.\n' >&2
  exit 1
fi

printf 'CODEX REMOTE UNIT TESTS: PASS\n'

