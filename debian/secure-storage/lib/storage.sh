#!/usr/bin/env bash

prompt_recovery_passphrase() {
  local first second
  [[ -t 0 ]] || die "A recovery passphrase is required, but stdin is not interactive."

  while true; do
    read -r -s -p "Enter human recovery passphrase: " first
    printf '\n'
    [[ ${#first} -ge 12 ]] || { log_warn "Use at least 12 characters."; continue; }

    read -r -s -p "Confirm recovery passphrase: " second
    printf '\n'
    [[ $first == "$second" ]] || { log_warn "Passphrases did not match."; continue; }

    RECOVERY_PASSPHRASE=$first
    unset first second
    return 0
  done
}

ensure_image_parent() {
  run install -d -m 0700 "$(dirname "$IMAGE_PATH")"
}

ensure_image() {
  if [[ -e $IMAGE_PATH ]]; then
    [[ -f $IMAGE_PATH ]] || die "Image path exists but is not a regular file: ${IMAGE_PATH}"
    log_ok "Encrypted image exists: ${IMAGE_PATH}"
    return 0
  fi

  [[ -n ${IMAGE_SIZE:-} ]] || die "--image-size is required when creating a new encrypted image."

  ensure_image_parent

  local requested_bytes available_bytes
  requested_bytes=$(numfmt --from=iec "$IMAGE_SIZE" 2>/dev/null) ||
    die "Invalid image size: ${IMAGE_SIZE} (examples: 10G, 26G, 512M)"
  available_bytes=$(df --output=avail -B1 "$(dirname "$IMAGE_PATH")" | tail -n1 | tr -d ' ')

  local reserve=$((2 * 1024 * 1024 * 1024))
  (( requested_bytes + reserve <= available_bytes )) ||
    die "Not enough free space for ${IMAGE_SIZE}; at least 2 GiB must remain outside the image."

  log_info "Allocating ${IMAGE_SIZE} encrypted image at ${IMAGE_PATH}..."
  run fallocate -l "$IMAGE_SIZE" "$IMAGE_PATH"
  run chmod 0600 "$IMAGE_PATH"
}

ensure_luks() {
  if cryptsetup isLuks "$IMAGE_PATH" >/dev/null 2>&1; then
    log_ok "Image contains an existing LUKS header."
    return 0
  fi

  [[ ${DRY_RUN:-0} -eq 0 ]] || {
    log_info "Would initialize ${IMAGE_PATH} as LUKS2 and enroll recovery + machine keys."
    return 0
  }

  prompt_recovery_passphrase

  log_info "Initializing LUKS2 container..."
  printf '%s' "$RECOVERY_PASSPHRASE" |
    cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$IMAGE_PATH"

  ensure_machine_key "$RECOVERY_PASSPHRASE"
  unset RECOVERY_PASSPHRASE
}

ensure_machine_key() {
  local recovery_passphrase=${1:-}

  run install -d -m 0700 "$(dirname "$KEY_PATH")"

  if [[ -f $KEY_PATH ]]; then
    [[ $(stat -c '%a' "$KEY_PATH") == "600" ]] || run chmod 0600 "$KEY_PATH"

    if [[ ${DRY_RUN:-0} -eq 0 ]] &&
       cryptsetup open --test-passphrase --key-file "$KEY_PATH" "$IMAGE_PATH" >/dev/null 2>&1; then
      log_ok "Machine auto-unlock key is enrolled: ${KEY_PATH}"
      return 0
    fi

    [[ ${DRY_RUN:-0} -eq 1 ]] && return 0
    die "Machine key exists but does not unlock the LUKS image: ${KEY_PATH}"
  fi

  [[ ${DRY_RUN:-0} -eq 0 ]] || {
    log_info "Would create root-only machine key: ${KEY_PATH}"
    return 0
  }

  if [[ -z $recovery_passphrase ]]; then
    log_warn "Machine key is missing; a valid recovery passphrase is needed to create a replacement."
    prompt_recovery_passphrase
    recovery_passphrase=$RECOVERY_PASSPHRASE
  fi

  log_info "Generating root-only machine key..."
  umask 077
  head -c 64 /dev/urandom > "$KEY_PATH"
  chmod 0600 "$KEY_PATH"

  if ! printf '%s' "$recovery_passphrase" |
      cryptsetup luksAddKey --key-file=- "$IMAGE_PATH" "$KEY_PATH"; then
    rm -f "$KEY_PATH"
    die "Could not enroll machine key. The recovery passphrase may be incorrect."
  fi

  unset RECOVERY_PASSPHRASE recovery_passphrase
  log_ok "Machine key created and enrolled: ${KEY_PATH}"
}

ensure_mapping() {
  if [[ -e /dev/mapper/$NAME ]]; then
    log_ok "LUKS mapping is already active: /dev/mapper/${NAME}"
    return 0
  fi

  log_info "Opening encrypted image as ${NAME}..."
  run cryptsetup open --type luks --key-file "$KEY_PATH" "$IMAGE_PATH" "$NAME"
}

ensure_filesystem() {
  [[ ${DRY_RUN:-0} -eq 0 ]] || {
    log_info "Would create ext4 only if /dev/mapper/${NAME} has no filesystem."
    return 0
  }

  local filesystem
  filesystem=$(blkid -o value -s TYPE "/dev/mapper/${NAME}" 2>/dev/null || true)

  case "$filesystem" in
    ext4)
      log_ok "Existing ext4 filesystem detected."
      ;;
    "")
      log_info "Creating ext4 filesystem..."
      mkfs.ext4 -F -L "$NAME" "/dev/mapper/${NAME}"
      ;;
    *)
      die "/dev/mapper/${NAME} already contains unsupported filesystem '${filesystem}'."
      ;;
  esac
}

ensure_crypttab() {
  local line="${NAME} ${IMAGE_PATH} ${KEY_PATH} luks"
  replace_managed_line /etc/crypttab "^[[:space:]]*${NAME}[[:space:]]+" "$line"
  [[ -f /etc/crypttab ]] && run chmod 0644 /etc/crypttab
}

ensure_fstab_mount() {
  local source="/dev/mapper/${NAME}"
  local line="${source} ${MOUNT_PATH} ext4 defaults 0 2"
  replace_managed_line /etc/fstab "^[[:space:]]*${source//\//\\/}[[:space:]]+" "$line"
}

ensure_mount() {
  run install -d -m 0750 "$MOUNT_PATH"

  if mountpoint -q "$MOUNT_PATH"; then
    local current_source
    current_source=$(findmnt -n -o SOURCE --target "$MOUNT_PATH")
    [[ $current_source == "/dev/mapper/${NAME}" ]] ||
      die "${MOUNT_PATH} is already mounted from ${current_source}, expected /dev/mapper/${NAME}."
    log_ok "Encrypted filesystem mounted: ${MOUNT_PATH}"
    return 0
  fi

  log_info "Mounting encrypted filesystem at ${MOUNT_PATH}..."
  run mount "/dev/mapper/${NAME}" "$MOUNT_PATH"
}

configure_storage() {
  ensure_packages cryptsetup e2fsprogs util-linux

  ensure_image
  ensure_luks

  if cryptsetup isLuks "$IMAGE_PATH" >/dev/null 2>&1; then
    ensure_machine_key
  fi

  ensure_mapping
  ensure_filesystem
  ensure_crypttab
  ensure_fstab_mount
  ensure_mount

  run systemctl daemon-reload

  log_ok "Secure storage configured."
  printf '\nAUTO-UNLOCK KEY: %s\n' "$KEY_PATH"
  printf 'MOUNT PATH:      %s\n' "$MOUNT_PATH"
  printf 'LUKS IMAGE:      %s\n\n' "$IMAGE_PATH"
}
