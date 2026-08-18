#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK_DIR=$(mktemp -d)
SSH_PORT=2222
VM_PID=""
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
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

cleanup() {
  if [[ -n $VM_PID ]] && kill -0 "$VM_PID" 2>/dev/null; then
    kill "$VM_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$VM_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$VM_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

show_vm_diagnostics() {
  printf '\n--- VM serial console (tail) ---\n' >&2
  tail -n 250 "${WORK_DIR}/serial.log" 2>/dev/null >&2 || true
  printf '%s\n' '--- end VM serial console ---' >&2
}

wait_for_ssh() {
  for _ in $(seq 1 180); do
    if ssh "${SSH_OPTS[@]}" ci@127.0.0.1 true >/dev/null 2>&1; then
      return 0
    fi
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

printf 'Installing QEMU/cloud-image test dependencies...\n'
sudo apt-get update
sudo apt-get install -y \
  qemu-system-x86 \
  qemu-utils \
  cloud-image-utils \
  expect \
  openssh-client \
  curl

printf 'Downloading Debian 13 generic cloud image...\n'
curl --fail --location --retry 5 --retry-delay 2 \
  --output "${WORK_DIR}/debian-base.qcow2" \
  "$DEBIAN_IMAGE_URL"

cp --reflink=auto "${WORK_DIR}/debian-base.qcow2" "${WORK_DIR}/debian-ci.qcow2"
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
instance-id: deployscripts-secure-storage-ci
local-hostname: deployscripts-ci
EOF

cloud-localds "${WORK_DIR}/seed.img" \
  "${WORK_DIR}/user-data" \
  "${WORK_DIR}/meta-data"

ACCEL=tcg
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL=kvm
fi
printf 'Starting Debian 13 QEMU VM with %s acceleration...\n' "$ACCEL"

qemu-system-x86_64 \
  -accel "$ACCEL" \
  -m 3072 \
  -smp 2 \
  -drive "file=${WORK_DIR}/debian-ci.qcow2,if=virtio,format=qcow2" \
  -drive "file=${WORK_DIR}/seed.img,if=virtio,format=raw,readonly=on" \
  -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
  -display none \
  -serial "file:${WORK_DIR}/serial.log" \
  -daemonize \
  -pidfile "${WORK_DIR}/qemu.pid"

VM_PID=$(cat "${WORK_DIR}/qemu.pid")
wait_for_ssh
run_guest 'cloud-init status --wait'

printf 'Copying PR contents into Debian VM...\n'
tar --exclude='.git' -C "$ROOT" -czf - . | \
  ssh "${SSH_OPTS[@]}" ci@127.0.0.1 \
    'mkdir -p /home/ci/DeployScripts && tar -xzf - -C /home/ci/DeployScripts'

printf 'Running syntax/regression tests inside Debian VM...\n'
run_guest 'cd /home/ci/DeployScripts && bash tests/bash-syntax.sh'

cat > "${WORK_DIR}/first-run.exp" <<'EXPECT'
set timeout 1800
set remote_cmd "cd /home/ci/DeployScripts && sudo bash debian/secure-storage/setup.sh --name ci-secure --mount /srv/secure --image-size 6G --swap 512M --docker"
spawn ssh -tt \
  -i $env(SSH_KEY) \
  -p $env(SSH_PORT) \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 \
  -o ServerAliveInterval=5 \
  -o LogLevel=ERROR \
  ci@127.0.0.1 $remote_cmd
expect "Enter human recovery passphrase:"
send -- "DeployScripts-CI-Recovery-123!\r"
expect "Confirm recovery passphrase:"
send -- "DeployScripts-CI-Recovery-123!\r"
expect eof
catch wait result
exit [lindex $result 3]
EXPECT

printf 'Running first secure-storage provisioning pass...\n'
export SSH_KEY SSH_PORT
expect "${WORK_DIR}/first-run.exp"

printf 'Validating first converged state...\n'
run_guest 'cd /home/ci/DeployScripts && sudo bash debian/secure-storage/setup.sh --name ci-secure --mount /srv/secure --swap 512M --docker --check'

printf 'Rerunning provisioning non-interactively to prove idempotency...\n'
run_guest 'cd /home/ci/DeployScripts && sudo bash debian/secure-storage/setup.sh --name ci-secure --mount /srv/secure --swap 512M --docker --non-interactive'

printf 'Checking encrypted runtime locations before reboot...\n'
run_guest "sudo docker info --format '{{.DockerRootDir}}' | grep -Fx '/srv/secure/docker'"
run_guest "sudo containerd config dump | awk -F'\"' '/^root[[:space:]]*=/{print \$2; exit}' | grep -Fx '/srv/secure/containerd'"
run_guest "grep -Fq '/srv/secure/swapfile' /proc/swaps"
run_guest "printf 'secure-storage-ci\\n' | sudo tee /srv/secure/ci-persistence-marker >/dev/null"

printf 'Rebooting the Debian VM to validate crypttab/fstab/systemd ordering...\n'
run_guest 'sudo reboot' >/dev/null 2>&1 || true
sleep 5
wait_for_ssh

printf 'Validating boot-time state after real VM reboot...\n'
for _ in $(seq 1 60); do
  if run_guest 'sudo systemctl is-active --quiet docker.service containerd.service' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

run_guest 'test -f /srv/secure/ci-persistence-marker'
run_guest "grep -Fq '/srv/secure/swapfile' /proc/swaps"
run_guest "sudo docker info --format '{{.DockerRootDir}}' | grep -Fx '/srv/secure/docker'"
run_guest "sudo containerd config dump | awk -F'\"' '/^root[[:space:]]*=/{print \$2; exit}' | grep -Fx '/srv/secure/containerd'"
run_guest 'cd /home/ci/DeployScripts && sudo bash debian/secure-storage/setup.sh --name ci-secure --mount /srv/secure --swap 512M --docker --check'

printf 'Secure-storage Debian 13 VM integration: PASS\n'
