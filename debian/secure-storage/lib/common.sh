#!/usr/bin/env bash

log_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_ok()   { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }

die() {
  log_err "$*"
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  log_err "Command failed at line ${line_no} (exit ${exit_code})."
  exit "$exit_code"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this script as root (for example: sudo $0 ...)."
}

ensure_debian() {
  [[ -r /etc/os-release ]] || die "Cannot identify operating system."

  # Read os-release in a subshell so fields such as NAME cannot overwrite
  # global provisioning state (for example, the LUKS mapper NAME).
  local detected_id
  detected_id=$(
    # shellcheck disable=SC1091
    source /etc/os-release
    printf '%s' "${ID:-}"
  )

  [[ $detected_id == "debian" ]] ||
    die "This tool currently supports Debian only (detected: ${detected_id:-unknown})."
}

ensure_absolute_path() {
  local value=$1
  local label=$2
  [[ $value == /* ]] || die "${label} must be an absolute path: ${value}"
  [[ $value =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "${label} contains unsupported characters. Use letters, numbers, '.', '_', '-' and '/': ${value}"
}

validate_name() {
  [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ||
    die "Name may contain only letters, numbers, '.', '_' and '-' and must begin with a letter or number."
}

run() {
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_shell() {
  local command=$1
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$command"
    return 0
  fi
  bash -c "$command"
}

backup_file() {
  local path=$1
  [[ -e $path ]] || return 0

  if [[ -n ${BACKUP_DIR:-} && -e ${BACKUP_DIR}${path} ]]; then
    return 0
  fi

  if [[ -z ${BACKUP_DIR:-} ]]; then
    BACKUP_DIR="/var/backups/deployscripts/$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  local destination="${BACKUP_DIR}${path}"
  run install -d -m 0700 "$(dirname "$destination")"
  run cp -a "$path" "$destination"
  log_info "Backed up ${path} -> ${destination}"
}

ensure_packages() {
  local packages=("$@")
  local missing=()
  local package

  for package in "${packages[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' || missing+=("$package")
  done

  ((${#missing[@]} == 0)) && return 0

  log_info "Refreshing APT metadata..."
  run apt-get update
  log_info "Installing packages: ${missing[*]}"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

replace_managed_line() {
  local file=$1
  local match_regex=$2
  local desired_line=$3

  if [[ -f $file ]] && grep -Eq "$match_regex" "$file"; then
    local existing
    existing=$(grep -E "$match_regex" "$file" | head -n1)
    [[ $existing == "$desired_line" ]] && return 0
    die "Conflicting existing entry in ${file}: ${existing}"
  fi

  backup_file "$file"
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    printf '[DRY-RUN] append to %s: %s\n' "$file" "$desired_line"
  else
    touch "$file"
    printf '%s\n' "$desired_line" >> "$file"
  fi
}

human_bytes() {
  numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
}

path_has_content() {
  local path=$1
  [[ -d $path ]] && find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}
