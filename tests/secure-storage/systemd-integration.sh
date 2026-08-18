#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CI_ID=${GITHUB_RUN_ID:-$$}
IMAGE="deployscripts-secure-storage-ci:${CI_ID}"
CONTAINER="deployscripts-secure-storage-ci-${CI_ID}"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_systemd() {
  local state=""
  for _ in $(seq 1 90); do
    state=$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)
    case "$state" in
      running|degraded)
        printf 'systemd state: %s\n' "$state"
        return 0
        ;;
    esac
    sleep 2
  done

  docker logs "$CONTAINER" || true
  printf 'systemd did not become ready; last state: %s\n' "$state" >&2
  return 1
}

wait_for_secure_services() {
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" mountpoint -q /srv/secure \
      && docker exec "$CONTAINER" systemctl is-active --quiet containerd.service \
      && docker exec "$CONTAINER" systemctl is-active --quiet docker.service; then
      return 0
    fi
    sleep 2
  done

  docker exec "$CONTAINER" systemctl --no-pager --failed || true
  docker exec "$CONTAINER" journalctl --no-pager -n 200 || true
  return 1
}

printf 'Building disposable Debian 13 systemd test image...\n'
docker build \
  --file "$ROOT/tests/secure-storage/Dockerfile" \
  --tag "$IMAGE" \
  "$ROOT"

printf 'Starting privileged Debian systemd environment...\n'
docker run --detach \
  --name "$CONTAINER" \
  --privileged \
  --cgroupns=host \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run \
  --tmpfs /run/lock \
  "$IMAGE" >/dev/null

wait_for_systemd

docker cp "$ROOT/." "$CONTAINER:/opt/DeployScripts"

# Nested Docker is deliberately tested with vfs so the CI environment does not
# depend on overlay-on-overlay support. The provisioning script must preserve
# this existing daemon setting while adding its encrypted data-root.
docker exec "$CONTAINER" bash -lc \
  'install -d -m 0755 /etc/docker && printf "%s\n" '\''{"storage-driver":"vfs"}'\'' > /etc/docker/daemon.json'

printf 'Running repository syntax/regression tests inside Debian...\n'
docker exec "$CONTAINER" bash -lc \
  'cd /opt/DeployScripts && bash tests/bash-syntax.sh'

printf 'Running first secure-storage provisioning pass...\n'
docker exec -i "$CONTAINER" tee /tmp/secure-storage-first-run.exp >/dev/null <<'EXPECT'
set timeout 1200
spawn bash /opt/DeployScripts/debian/secure-storage/setup.sh \
  --name ci-secure \
  --mount /srv/secure \
  --image-size 6G \
  --swap 512M \
  --docker
expect "Enter human recovery passphrase:"
send "DeployScripts-CI-Recovery-123!\r"
expect "Confirm recovery passphrase:"
send "DeployScripts-CI-Recovery-123!\r"
expect eof
catch wait result
exit [lindex $result 3]
EXPECT

docker exec "$CONTAINER" expect /tmp/secure-storage-first-run.exp

printf 'Validating first converged state...\n'
docker exec "$CONTAINER" bash -lc '
  cd /opt/DeployScripts
  bash debian/secure-storage/setup.sh \
    --name ci-secure \
    --mount /srv/secure \
    --swap 512M \
    --docker \
    --check
'

printf 'Rerunning provisioning non-interactively to prove idempotency...\n'
docker exec "$CONTAINER" bash -lc '
  cd /opt/DeployScripts
  bash debian/secure-storage/setup.sh \
    --name ci-secure \
    --mount /srv/secure \
    --swap 512M \
    --docker \
    --non-interactive
'

printf 'Writing persistence marker and restarting Debian systemd environment...\n'
docker exec "$CONTAINER" bash -lc \
  'printf "secure-storage-ci\n" > /srv/secure/ci-persistence-marker'

docker restart --time 30 "$CONTAINER" >/dev/null
wait_for_systemd
wait_for_secure_services

printf 'Validating persistence and boot-time convergence after restart...\n'
docker exec "$CONTAINER" test -f /srv/secure/ci-persistence-marker
docker exec "$CONTAINER" grep -Fq '/srv/secure/swapfile' /proc/swaps
docker exec "$CONTAINER" bash -lc '
  cd /opt/DeployScripts
  bash debian/secure-storage/setup.sh \
    --name ci-secure \
    --mount /srv/secure \
    --swap 512M \
    --docker \
    --check
'

printf 'Secure-storage Debian systemd integration: PASS\n'
