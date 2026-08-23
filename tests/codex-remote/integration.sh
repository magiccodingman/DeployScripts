#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
require() { command -v "$1" >/dev/null 2>&1 || { printf 'Missing command: %s\n' "$1" >&2; exit 1; }; }
require docker
require ssh-keygen
require ssh-keyscan

TEST_ROOT=$(mktemp -d)
CONTAINER="deployscripts-codex-remote-$RANDOM-$RANDOM"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/context"
ssh-keygen -q -t ed25519 -N '' -C integration-bootstrap -f "$TEST_ROOT/bootstrap"
cp "$TEST_ROOT/bootstrap.pub" "$TEST_ROOT/context/bootstrap.pub"

cat > "$TEST_ROOT/context/Dockerfile" <<'DOCKERFILE'
FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server bash ca-certificates coreutils && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash codextest && mkdir -p /run/sshd /home/codextest/.ssh && chmod 0700 /home/codextest/.ssh
COPY bootstrap.pub /home/codextest/.ssh/authorized_keys
RUN chown -R codextest:codextest /home/codextest/.ssh && chmod 0600 /home/codextest/.ssh/authorized_keys
RUN printf '%s\n' '#!/bin/sh' 'case "$*" in' \
  '  "--version") echo "codex-cli test" ;;' \
  '  "login status") echo "Logged in using test credentials" ;;' \
  '  "app-server --help") echo "test app-server" ;;' \
  '  *) echo "unexpected fake codex arguments: $*" >&2; exit 1 ;;' \
  'esac' > /usr/local/bin/codex && chmod 0755 /usr/local/bin/codex
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE

docker build -q -t "$CONTAINER" "$TEST_ROOT/context" >/dev/null
docker run -d --name "$CONTAINER" -p 127.0.0.1::22 "$CONTAINER" >/dev/null
PORT=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}' "$CONTAINER")

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME/.ssh"
chmod 0700 "$HOME/.ssh"
ssh-keyscan -p "$PORT" 127.0.0.1 > "$HOME/.ssh/known_hosts" 2>/dev/null

COMMON_ARGS=(
  --name codex-integration
  --host 127.0.0.1
  --user codextest
  --port "$PORT"
  --bootstrap-identity "$TEST_ROOT/bootstrap"
  --codex-install skip
  --auth skip
  --non-interactive
)

printf 'integration: clean first provisioning\n'
"$ROOT/linux/codex-remote/setup.sh" "${COMMON_ARGS[@]}"

printf 'integration: second non-interactive convergence using only managed state\n'
"$ROOT/linux/codex-remote/setup.sh" \
  --name codex-integration \
  --codex-install skip \
  --auth skip \
  --non-interactive

printf 'integration: repair missing public key and removed remote marker\n'
rm -f "$HOME/.ssh/codex_codex_integration.pub"
ssh -F "$HOME/.ssh/config" codex-integration \
  "sed -i '/deployscripts:codex-remote:codex-integration$/d' \"\$HOME/.ssh/authorized_keys\""
"$ROOT/linux/codex-remote/setup.sh" \
  --name codex-integration \
  --bootstrap-identity "$TEST_ROOT/bootstrap" \
  --codex-install skip \
  --auth skip \
  --non-interactive

printf 'integration: rotate only after the replacement identity authenticates\n'
old_fingerprint=$(ssh-keygen -lf "$HOME/.ssh/codex_codex_integration" | awk '{print $2}')
"$ROOT/linux/codex-remote/setup.sh" \
  --name codex-integration \
  --rotate-key \
  --codex-install skip \
  --auth skip \
  --non-interactive
new_fingerprint=$(ssh-keygen -lf "$HOME/.ssh/codex_codex_integration" | awk '{print $2}')
[[ $old_fingerprint != "$new_fingerprint" ]] || { printf 'Key fingerprint did not change during rotation.\n' >&2; exit 1; }

printf 'integration: read-only validation\n'
"$ROOT/linux/codex-remote/setup.sh" \
  --name codex-integration \
  --auth skip \
  --check \
  --non-interactive

printf 'CODEX REMOTE INTEGRATION: PASS\n'
