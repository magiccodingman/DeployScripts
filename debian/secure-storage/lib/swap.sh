#!/usr/bin/env bash

comment_existing_fstab_swaps() {
  local preserve_path=${1:-}
  [[ -f /etc/fstab ]] || return 0

  if ! awk -v preserve="$preserve_path" 'NF && $1 !~ /^#/ && $3 == "swap" && $1 != preserve {found=1} END {exit !found}' /etc/fstab; then
    return 0
  fi

  backup_file /etc/fstab

  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    log_info "Would disable existing swap entries in /etc/fstab."
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  awk -v preserve="$preserve_path" '
    NF && $1 !~ /^#/ && $3 == "swap" && $1 != preserve {
      print "# Disabled by DeployScripts secure-storage: " $0
      next
    }
    { print }
  ' /etc/fstab > "$tmp"
  cat "$tmp" > /etc/fstab
  rm -f "$tmp"
}

disable_all_swap() {
  local preserve_path=${1:-}

  if [[ -r /proc/swaps ]] && (( $(wc -l < /proc/swaps) > 1 )); then
    log_info "Disabling currently active swap..."
    run swapoff -a
  else
    log_ok "No active swap currently detected."
  fi

  comment_existing_fstab_swaps "$preserve_path"
}

ensure_swapfile() {
  local swapfile="${MOUNT_PATH}/swapfile"

  [[ -n ${SWAP_SIZE:-} ]] || die "Internal error: swap size not specified."

  if [[ -e $swapfile ]]; then
    [[ -f $swapfile ]] || die "Swap path exists and is not a regular file: ${swapfile}"

    local actual requested
    actual=$(stat -c '%s' "$swapfile")
    requested=$(numfmt --from=iec "$SWAP_SIZE" 2>/dev/null) || die "Invalid swap size: ${SWAP_SIZE}"
    [[ $actual -eq $requested ]] ||
      die "Existing ${swapfile} size is $(human_bytes "$actual"), requested ${SWAP_SIZE}. Refusing to resize active storage automatically."
  else
    log_info "Creating ${SWAP_SIZE} encrypted swapfile at ${swapfile}..."
    run fallocate -l "$SWAP_SIZE" "$swapfile"
    run chmod 0600 "$swapfile"
    run mkswap "$swapfile"
  fi

  local line="${swapfile} none swap sw 0 0"
  replace_managed_line /etc/fstab "^[[:space:]]*${swapfile//\//\\/}[[:space:]]+" "$line"

  if [[ ${DRY_RUN:-0} -eq 0 ]] && ! grep -Fq "$swapfile" /proc/swaps; then
    swapon "$swapfile"
  fi

  run systemctl daemon-reload
  log_ok "Encrypted swap configured: ${swapfile} (${SWAP_SIZE})"
}

configure_swap() {
  case "$SWAP_MODE" in
    leave)
      log_info "Swap configuration left unchanged."
      ;;
    disable)
      disable_all_swap ""
      run systemctl daemon-reload
      log_ok "Swap disabled."
      ;;
    encrypted)
      ensure_packages util-linux
      disable_all_swap "${MOUNT_PATH}/swapfile"
      ensure_swapfile
      ;;
    *)
      die "Unknown swap mode: ${SWAP_MODE}"
      ;;
  esac
}
