#!/usr/bin/env bash

log_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_ok()   { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }

die() { log_err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  log_err "Command failed at line ${line_no} (exit ${exit_code})."
  exit "$exit_code"
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

validate_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "Name may contain only letters, numbers, '.', '_' and '-' and must begin with a letter or number."
}

validate_host() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.:%_-]*$ ]] ||
    die "Invalid SSH hostname or address: $1"
}

validate_user() {
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9._-]*[$]?$ ]] || die "Invalid remote username: $1"
}

validate_port() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) || die "Invalid SSH port: $1"
}

ensure_absolute_path() {
  local value=$1 label=$2
  [[ $value == /* ]] || die "${label} must be an absolute path: ${value}"
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "${label} contains a newline."
}

expand_home_path() {
  local value=$1
  if [[ $value == "~" ]]; then
    printf '%s' "$HOME"
  elif [[ $value == "~/"* ]]; then
    printf '%s/%s' "$HOME" "${value#\~/}"
  else
    printf '%s' "$value"
  fi
}

safe_name() {
  printf '%s' "$1" | tr '.-' '__' | tr -cd 'A-Za-z0-9_'
}

require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null 2>&1 || die "Required local command is unavailable: ${command}"
  done
}

shell_quote() {
  local value=$1
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

backup_bucket_for() {
  local path=$1 digest base
  digest=$(printf '%s' "$path" | sha256sum | awk '{print substr($1,1,12)}')
  base=$(basename "$path")
  printf '%s/%s-%s' "$BACKUP_ROOT" "$digest" "$base"
}

prune_backups() {
  local directory=$1
  [[ -d $directory ]] || return 0
  local backups=() index
  mapfile -d '' backups < <(find "$directory" -maxdepth 1 -type f -printf '%T@ %p\0' | sort -zrn)
  for ((index=BACKUP_LIMIT; index<${#backups[@]}; index++)); do
    run rm -f -- "${backups[index]#* }"
  done
}

backup_file() {
  local path=$1
  [[ -e $path ]] || return 0
  [[ ${DRY_RUN:-0} -eq 0 ]] || { log_info "Would back up ${path}"; return 0; }

  local directory timestamp destination
  directory=$(backup_bucket_for "$path")
  timestamp=$(date -u +%Y%m%dT%H%M%S.%NZ)
  destination="${directory}/${timestamp}"
  install -d -m 0700 "$directory"
  cp -a -- "$path" "$destination"
  log_info "Backed up ${path} -> ${destination}"
  prune_backups "$directory"
}

write_file_if_changed() {
  local source=$1 destination=$2 mode=$3
  if [[ -f $destination ]] && cmp -s "$source" "$destination"; then
    rm -f -- "$source"
    return 0
  fi

  backup_file "$destination"
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    log_info "Would update ${destination}"
    rm -f -- "$source"
    return 0
  fi

  install -d -m 0700 "$(dirname "$destination")"
  chmod "$mode" "$source"
  mv -f -- "$source" "$destination"
  log_ok "Updated ${destination}"
}
