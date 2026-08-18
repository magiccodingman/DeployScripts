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

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this script as root (for example: sudo $0 ...)."
}

os_release_value() {
  local key=$1
  [[ $key =~ ^[A-Z0-9_]+$ ]] || die "Invalid os-release key requested: ${key}"
  [[ -r /etc/os-release ]] || die "Cannot identify operating system."
  (
    set +u
    # shellcheck disable=SC1091
    source /etc/os-release
    printf '%s' "${!key:-}"
  )
}

ensure_debian() {
  local detected_id
  detected_id=$(os_release_value ID)
  [[ $detected_id == debian ]] ||
    die "This tool currently supports Debian only (detected: ${detected_id:-unknown})."
}

ensure_absolute_path() {
  local value=$1 label=$2
  [[ $value == /* ]] || die "${label} must be an absolute path: ${value}"
  [[ $value =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "${label} contains unsupported characters: ${value}"
}

validate_hostname() {
  local value=$1
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
    die "Invalid hostname: ${value}"
  [[ $value == *.* ]] || die "Hostname should be a fully-qualified domain name: ${value}"
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

backup_file() {
  local path=$1
  [[ -e $path ]] || return 0
  if [[ -z ${BACKUP_DIR:-} ]]; then
    BACKUP_DIR="/var/backups/deployscripts/$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  local destination="${BACKUP_DIR}${path}"
  [[ -e $destination ]] && return 0
  run install -d -m 0700 "$(dirname "$destination")"
  run cp -a "$path" "$destination"
  log_info "Backed up ${path} -> ${destination}"
}

ensure_packages() {
  local missing=() package
  for package in "$@"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' || missing+=("$package")
  done
  ((${#missing[@]} == 0)) && return 0
  log_info "Refreshing APT metadata..."
  run apt-get update
  log_info "Installing packages: ${missing[*]}"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

nearest_existing_parent() {
  local path=$1
  while [[ ! -e $path && $path != / ]]; do path=$(dirname "$path"); done
  printf '%s' "$path"
}

ensure_nonroot_storage_boundary() {
  local path=$1 existing mount_target
  [[ ${ALLOW_ROOT_FILESYSTEM:-0} -eq 1 ]] && return 0
  existing=$(nearest_existing_parent "$path")
  mount_target=$(findmnt -n -o TARGET --target "$existing" 2>/dev/null || true)
  [[ -n $mount_target ]] || die "Could not determine backing mount for ${path}."
  [[ $mount_target != / ]] || die "${path} resolves to the root filesystem. Refusing Harbor writable state on root; use --allow-root-filesystem only when intentional."
  log_ok "Harbor root is backed by dedicated mount: ${mount_target}"
}

normalize_endpoint() {
  local endpoint=$1
  if [[ $endpoint != http://* && $endpoint != https://* ]]; then
    endpoint="https://${endpoint}"
  fi
  [[ $endpoint =~ ^https?://[^/]+/?$ ]] || die "S3 endpoint must be a host URL without a path: ${endpoint}"
  printf '%s' "${endpoint%/}"
}

prompt_secret() {
  local var_name=$1 label=$2 value
  [[ ${NON_INTERACTIVE:-0} -eq 0 ]] || die "${label} is required in non-interactive mode. Supply it through the documented environment variable or secret file."
  [[ -t 0 ]] || die "${label} is required but stdin is not interactive. Supply it through the documented environment variable or secret file."
  read -r -s -p "${label}: " value
  printf '\n'
  [[ -n $value ]] || die "${label} cannot be empty."
  printf -v "$var_name" '%s' "$value"
}

load_secret_file() {
  [[ -f $SECRET_FILE ]] || return 0
  local mode owner
  mode=$(stat -c '%a' "$SECRET_FILE")
  owner=$(stat -c '%u' "$SECRET_FILE")
  [[ $owner == 0 && $mode == 600 ]] || die "Secret file must be owned by root with mode 0600: ${SECRET_FILE}"

  local env_db=${HARBOR_DB_PASSWORD:-}
  local env_access=${HARBOR_S3_ACCESS_KEY:-}
  local env_secret=${HARBOR_S3_SECRET_KEY:-}
  local env_admin=${HARBOR_ADMIN_PASSWORD:-}
  # shellcheck disable=SC1090
  source "$SECRET_FILE"
  [[ -n $env_db ]] && HARBOR_DB_PASSWORD=$env_db
  [[ -n $env_access ]] && HARBOR_S3_ACCESS_KEY=$env_access
  [[ -n $env_secret ]] && HARBOR_S3_SECRET_KEY=$env_secret
  [[ -n $env_admin ]] && HARBOR_ADMIN_PASSWORD=$env_admin
  log_ok "Loaded Harbor secrets from ${SECRET_FILE}"
}

ensure_secrets() {
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    : "${HARBOR_DB_PASSWORD:=dry-run-db-password}"
    : "${HARBOR_S3_ACCESS_KEY:=dry-run-access-key}"
    : "${HARBOR_S3_SECRET_KEY:=dry-run-secret-key}"
    : "${HARBOR_ADMIN_PASSWORD:=dry-run-admin-password}"
    return 0
  fi

  [[ -n ${HARBOR_DB_PASSWORD:-} ]] || prompt_secret HARBOR_DB_PASSWORD "PostgreSQL password"
  [[ -n ${HARBOR_S3_ACCESS_KEY:-} ]] || prompt_secret HARBOR_S3_ACCESS_KEY "S3 access key"
  [[ -n ${HARBOR_S3_SECRET_KEY:-} ]] || prompt_secret HARBOR_S3_SECRET_KEY "S3 secret key"
  [[ -n ${HARBOR_ADMIN_PASSWORD:-} ]] || prompt_secret HARBOR_ADMIN_PASSWORD "Initial Harbor admin password"
}

save_secret_file() {
  [[ ${DRY_RUN:-0} -eq 0 ]] || { log_info "Would save root-only secret file: ${SECRET_FILE}"; return 0; }
  install -d -m 0700 "$(dirname "$SECRET_FILE")"
  local tmp
  tmp=$(mktemp "$(dirname "$SECRET_FILE")/.secrets.XXXXXX")
  {
    printf '# Managed by DeployScripts Harbor. Keep mode 0600.\n'
    printf 'HARBOR_DB_PASSWORD=%q\n' "$HARBOR_DB_PASSWORD"
    printf 'HARBOR_S3_ACCESS_KEY=%q\n' "$HARBOR_S3_ACCESS_KEY"
    printf 'HARBOR_S3_SECRET_KEY=%q\n' "$HARBOR_S3_SECRET_KEY"
    printf 'HARBOR_ADMIN_PASSWORD=%q\n' "$HARBOR_ADMIN_PASSWORD"
  } > "$tmp"
  chmod 0600 "$tmp"
  if [[ -f $SECRET_FILE ]] && cmp -s "$tmp" "$SECRET_FILE"; then rm -f "$tmp"; return 0; fi
  backup_file "$SECRET_FILE"
  mv "$tmp" "$SECRET_FILE"
  log_ok "Harbor secrets stored root-only at ${SECRET_FILE}"
}
