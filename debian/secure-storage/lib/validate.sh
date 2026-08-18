#!/usr/bin/env bash

CHECK_FAILURES=0

check_pass() { log_ok "$*"; }
check_fail() { log_err "$*"; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }

validate_secure_storage() {
  CHECK_FAILURES=0

  printf '\nSecure Storage Validation\n'
  printf '%s\n' '-------------------------'

  if [[ -f $IMAGE_PATH ]]; then
    check_pass "Image exists: ${IMAGE_PATH}"
  else
    check_fail "Image missing: ${IMAGE_PATH}"
  fi

  if [[ -f $IMAGE_PATH ]] && cryptsetup isLuks "$IMAGE_PATH" >/dev/null 2>&1; then
    check_pass "Image is a valid LUKS container."
  else
    check_fail "Image is not a valid LUKS container."
  fi

  if [[ -f $KEY_PATH ]]; then
    local mode
    mode=$(stat -c '%a' "$KEY_PATH")
    if [[ $mode == "600" ]]; then
      check_pass "Machine key permissions are 0600: ${KEY_PATH}"
    else
      check_fail "Machine key permissions are ${mode}, expected 0600."
    fi

    if [[ -f $IMAGE_PATH ]] &&
       cryptsetup open --test-passphrase --key-file "$KEY_PATH" "$IMAGE_PATH" >/dev/null 2>&1; then
      check_pass "Machine key successfully unlocks the LUKS image."
    else
      check_fail "Machine key does not unlock the LUKS image."
    fi
  else
    check_fail "Machine key missing: ${KEY_PATH}"
  fi

  if [[ -e /dev/mapper/$NAME ]]; then
    check_pass "Mapper active: /dev/mapper/${NAME}"
  else
    check_fail "Mapper inactive: /dev/mapper/${NAME}"
  fi

  if mountpoint -q "$MOUNT_PATH"; then
    local source
    source=$(findmnt -n -o SOURCE --target "$MOUNT_PATH")
    if [[ $source == "/dev/mapper/${NAME}" ]]; then
      check_pass "Mount active: ${MOUNT_PATH}"
    else
      check_fail "${MOUNT_PATH} mounted from unexpected source ${source}."
    fi
  else
    check_fail "Mount inactive: ${MOUNT_PATH}"
  fi

  if awk -v n="$NAME" -v i="$IMAGE_PATH" -v k="$KEY_PATH" \
      '$1 == n && $2 == i && $3 == k && $4 ~ /(^|,)luks(,|$)/ {found=1} END {exit !found}' \
      /etc/crypttab 2>/dev/null; then
    check_pass "/etc/crypttab contains expected auto-unlock entry."
  else
    check_fail "/etc/crypttab is missing the expected auto-unlock entry."
  fi

  if awk -v s="/dev/mapper/${NAME}" -v m="$MOUNT_PATH" \
      '$1 == s && $2 == m && $3 == "ext4" {found=1} END {exit !found}' \
      /etc/fstab 2>/dev/null; then
    check_pass "/etc/fstab contains expected mount entry."
  else
    check_fail "/etc/fstab is missing the expected mount entry."
  fi

  if [[ $SWAP_MODE == "encrypted" || -f "${MOUNT_PATH}/swapfile" ]]; then
    if [[ -f ${MOUNT_PATH}/swapfile ]]; then
      check_pass "Encrypted swapfile exists: ${MOUNT_PATH}/swapfile"

      if grep -Fq "${MOUNT_PATH}/swapfile" /proc/swaps; then
        check_pass "Encrypted swapfile is active."
      else
        check_fail "Encrypted swapfile exists but is not active."
      fi

      if awk -v p="${MOUNT_PATH}/swapfile" \
          '$1 == p && $2 == "none" && $3 == "swap" {found=1} END {exit !found}' /etc/fstab; then
        check_pass "Encrypted swapfile is configured for boot."
      else
        check_fail "Encrypted swapfile is not configured in /etc/fstab."
      fi
    else
      check_fail "Encrypted swap requested but swapfile is missing."
    fi
  fi

  if [[ ${DOCKER_REQUESTED:-0} -eq 1 || -f /etc/docker/daemon.json ]]; then
    if command -v jq >/dev/null 2>&1 && [[ -s /etc/docker/daemon.json ]]; then
      local docker_root
      docker_root=$(jq -r '.["data-root"] // empty' /etc/docker/daemon.json 2>/dev/null || true)
      if [[ $docker_root == "${MOUNT_PATH}/docker" ]]; then
        check_pass "Docker data-root targets encrypted storage."
      else
        check_fail "Docker data-root is '${docker_root:-unset}', expected ${MOUNT_PATH}/docker."
      fi
    else
      check_fail "Docker configuration cannot be validated (daemon.json or jq missing)."
    fi

    if [[ -s /etc/containerd/config.toml ]]; then
      local containerd_root
      containerd_root=$(containerd_root_from_toml < /etc/containerd/config.toml)
      containerd_root=${containerd_root:-/var/lib/containerd}
      if [[ $containerd_root == "${MOUNT_PATH}/containerd" ]]; then
        check_pass "containerd persistent root targets encrypted storage."
      else
        check_fail "containerd root is '${containerd_root}', expected ${MOUNT_PATH}/containerd."
      fi
    else
      check_fail "containerd configuration is missing."
    fi

    local service
    for service in docker.service containerd.service; do
      if grep -Fq "RequiresMountsFor=${MOUNT_PATH}" \
          "/etc/systemd/system/${service}.d/secure-storage.conf" 2>/dev/null; then
        check_pass "${service} requires secure mount."
      else
        check_fail "${service} does not require secure mount."
      fi
    done

    if systemctl is-active --quiet docker.service; then
      local active_docker_root
      active_docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
      if [[ $active_docker_root == "${MOUNT_PATH}/docker" ]]; then
        check_pass "Running Docker daemon uses encrypted data-root."
      else
        check_fail "Running Docker daemon uses '${active_docker_root:-unknown}'."
      fi
    else
      check_fail "Docker service is not active."
    fi

    if systemctl is-active --quiet containerd.service; then
      local active_containerd_root
      active_containerd_root=$(containerd config dump 2>/dev/null | containerd_root_from_toml)
      if [[ $active_containerd_root == "${MOUNT_PATH}/containerd" ]]; then
        check_pass "Running containerd uses encrypted persistent root."
      else
        check_fail "Running containerd uses '${active_containerd_root:-unknown}'."
      fi
    else
      check_fail "containerd service is not active."
    fi
  fi

  if ((CHECK_FAILURES == 0)); then
    printf '\nBOOT READINESS: PASS\n'
    return 0
  fi

  printf '\nBOOT READINESS: FAIL (%d check(s) failed)\n' "$CHECK_FAILURES"
  return 1
}
