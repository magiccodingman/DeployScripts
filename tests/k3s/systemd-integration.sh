#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK_DIR=$(mktemp -d)
SSH_PORT=2222
SSH_WAIT_ATTEMPTS=90
VM_PID=""
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
DEBIAN_IMAGE_CACHE=${DEPLOYSCRIPTS_DEBIAN_IMAGE_CACHE:-"${HOME}/.cache/deployscripts/debian-13-genericcloud-amd64.qcow2"}
SSH_KEY="${WORK_DIR}/id_ed25519"
SSH_OPTS=(
  -i "$SSH_KEY"
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o ServerAliveInterval=5
  -o LogLevel=ERROR
)

stop_vm_forcefully() {
  [[ -n $VM_PID ]] || return 0
  if kill -0 "$VM_PID" 2>/dev/null; then
    kill "$VM_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$VM_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$VM_PID" 2>/dev/null || true
  fi
  VM_PID=""
}

cleanup() {
  stop_vm_forcefully
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

show_vm_diagnostics() {
  printf '\n--- QEMU process log (tail) ---\n' >&2
  tail -n 150 "${WORK_DIR}/qemu.log" 2>/dev/null >&2 || true
  printf '%s\n' '--- end QEMU process log ---' >&2
  printf '\n--- VM serial console (tail) ---\n' >&2
  tail -n 300 "${WORK_DIR}/serial.log" 2>/dev/null >&2 || true
  printf '%s\n' '--- end VM serial console ---' >&2
}

wait_for_ssh() {
  for _ in $(seq 1 "$SSH_WAIT_ATTEMPTS"); do
    if [[ -n $VM_PID ]] && ! kill -0 "$VM_PID" 2>/dev/null; then
      show_vm_diagnostics
      printf 'Debian VM exited before SSH became available.\n' >&2
      return 1
    fi
    if ssh "${SSH_OPTS[@]}" ci@127.0.0.1 true >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  show_vm_diagnostics
  printf 'Timed out waiting for SSH on Debian VM.\n' >&2
  return 1
}

run_guest() {
  local command=$1
  # The caller supplies a complete remote command string intentionally.
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" ci@127.0.0.1 "$command"
}

wait_for_vm_exit() {
  local previous_pid=$1
  for _ in $(seq 1 90); do
    kill -0 "$previous_pid" 2>/dev/null || return 0
    sleep 1
  done
  show_vm_diagnostics
  printf 'Timed out waiting for Debian VM process %s to exit.\n' "$previous_pid" >&2
  return 1
}

start_vm() {
  : > "${WORK_DIR}/serial.log"
  : > "${WORK_DIR}/qemu.log"
  qemu-system-x86_64 \
    -accel "$ACCEL" \
    -m 4096 \
    -smp 2 \
    -drive "file=${WORK_DIR}/debian-ci.qcow2,if=virtio,format=qcow2" \
    -drive "file=${WORK_DIR}/seed.img,if=virtio,format=raw,readonly=on" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -display none \
    -serial "file:${WORK_DIR}/serial.log" \
    >"${WORK_DIR}/qemu.log" 2>&1 &
  VM_PID=$!
  sleep 1
  if ! kill -0 "$VM_PID" 2>/dev/null; then
    show_vm_diagnostics
    printf 'QEMU exited immediately after launch.\n' >&2
    return 1
  fi
  wait_for_ssh
}

printf 'Installing minimal QEMU/cloud-image test dependencies...\n'
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  qemu-system-x86 \
  qemu-utils \
  cloud-image-utils \
  openssh-client \
  curl

if [[ -s $DEBIAN_IMAGE_CACHE ]]; then
  printf 'Using cached Debian 13 generic cloud image: %s\n' "$DEBIAN_IMAGE_CACHE"
else
  printf 'Downloading Debian 13 generic cloud image...\n'
  install -d -m 0755 "$(dirname "$DEBIAN_IMAGE_CACHE")"
  cache_tmp="${DEBIAN_IMAGE_CACHE}.tmp.$$"
  curl --fail --location --retry 5 --retry-delay 2 --output "$cache_tmp" "$DEBIAN_IMAGE_URL"
  mv "$cache_tmp" "$DEBIAN_IMAGE_CACHE"
fi

cp --reflink=auto "$DEBIAN_IMAGE_CACHE" "${WORK_DIR}/debian-ci.qcow2"
qemu-img resize "${WORK_DIR}/debian-ci.qcow2" 20G
ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"
PUBLIC_KEY=$(cat "${SSH_KEY}.pub")

cat > "${WORK_DIR}/user-data" <<EOF
#cloud-config
users:
  - default
  - name: ci
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${PUBLIC_KEY}
ssh_pwauth: false
disable_root: true
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
package_update: false
EOF

cat > "${WORK_DIR}/meta-data" <<'EOF'
instance-id: deployscripts-k3s-ci
local-hostname: k3s-ci-01
EOF
cloud-localds "${WORK_DIR}/seed.img" "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"

if [[ -e /dev/kvm ]]; then sudo chmod 0666 /dev/kvm || true; fi
ACCEL=tcg
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; fi
printf 'Starting Debian 13 K3s test VM with %s acceleration...\n' "$ACCEL"
start_vm
run_guest 'cloud-init status --wait'

printf 'Copying PR contents into Debian VM...\n'
tar --exclude='.git' -C "$ROOT" -czf - . | \
  ssh "${SSH_OPTS[@]}" ci@127.0.0.1 \
    'mkdir -p /home/ci/DeployScripts && tar -xzf - -C /home/ci/DeployScripts'

printf 'Running K3s renderer, state, secret, and shell regression tests...\n'
run_guest 'cd /home/ci/DeployScripts && bash tests/bash-syntax.sh && bash tests/k3s/config-render.sh && sudo bash tests/k3s/state-and-secrets.sh'

printf 'Provisioning a clean embedded-etcd K3s server...\n'
# The guest expands NODE_IP and the embedded awk program; the local harness
# intentionally passes the full command as one single-quoted remote string.
# shellcheck disable=SC2016
run_guest 'cd /home/ci/DeployScripts && NODE_IP=$(ip -4 -o addr show scope global | awk '\''NR == 1 {sub(/\/.*/, "", $4); print $4}'\'') && printf '\''DeployScripts-K3s-CI-Server-Token\n'\'' | sudo tee /root/k3s-ci.token >/dev/null && sudo chmod 0600 /root/k3s-ci.token && sudo bash debian/k3s/setup.sh --mode init-server --node-name k3s-ci-01 --node-ip "$NODE_IP" --api-endpoint https://127.0.0.1:6443 --datastore embedded-etcd --flannel-backend vxlan --token-file /root/k3s-ci.token --non-interactive'

printf 'Validating the first converged state...\n'
run_guest 'cd /home/ci/DeployScripts && sudo bash debian/k3s/setup.sh --check'

printf 'Rerunning provisioning from saved non-secret state...\n'
run_guest 'cd /home/ci/DeployScripts && sudo bash debian/k3s/setup.sh --non-interactive'

printf 'Powering off the VM for a cold-boot persistence check...\n'
OLD_VM_PID=$VM_PID
run_guest 'sudo systemctl poweroff' >/dev/null 2>&1 || true
wait_for_vm_exit "$OLD_VM_PID"
VM_PID=""
sleep 2

printf 'Starting the same Debian/K3s disk again...\n'
start_vm
run_guest 'cloud-init status --wait'
for _ in $(seq 1 90); do
  if run_guest 'sudo systemctl is-active --quiet k3s.service' >/dev/null 2>&1; then break; fi
  sleep 2
done

printf 'Validating K3s after cold boot...\n'
run_guest 'cd /home/ci/DeployScripts && sudo bash debian/k3s/setup.sh --check'
printf 'K3s Debian 13 VM lifecycle: PASS\n'
