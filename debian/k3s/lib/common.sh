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
  local path=$1 destination
  [[ -e $path ]] || return 0
  if [[ -z ${BACKUP_DIR:-} ]]; then
    BACKUP_DIR="/var/backups/deployscripts/$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  destination="${BACKUP_DIR}${path}"
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

ensure_absolute_path() {
  local value=$1 label=$2
  [[ $value == /* ]] || die "${label} must be an absolute path: ${value}"
  [[ $value =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "${label} contains unsupported characters: ${value}"
}

validate_node_name() {
  local value=$1
  [[ ${#value} -le 63 ]] || die "Node name is longer than 63 characters: ${value}"
  [[ $value =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    die "Invalid Kubernetes node name: ${value}"
}

validate_ip() {
  local value=$1 label=$2
  python3 - "$value" "$label" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError as exc:
    raise SystemExit(f"Invalid {sys.argv[2]}: {sys.argv[1]} ({exc})")
PY
}

ip_is_global() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]).is_global else 1)
PY
}

validate_api_endpoint() {
  local endpoint=$1
  python3 - "$endpoint" <<'PY'
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
parsed = urlsplit(value)
if parsed.scheme != "https" or not parsed.hostname or parsed.path not in ("", "/"):
    raise SystemExit(f"API endpoint must be an HTTPS host URL without a path: {value}")
if parsed.query or parsed.fragment or parsed.username or parsed.password:
    raise SystemExit(f"API endpoint contains unsupported URL components: {value}")
try:
    port = parsed.port
except ValueError as exc:
    raise SystemExit(f"Invalid API endpoint port: {exc}")
if port is not None and not 1 <= port <= 65535:
    raise SystemExit(f"Invalid API endpoint port: {port}")
PY
}

normalize_api_endpoint() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

parsed = urlsplit(sys.argv[1])
host = parsed.hostname
if ":" in host:
    host = f"[{host}]"
print(f"https://{host}:{parsed.port or 6443}")
PY
}

api_endpoint_host() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname)
PY
}

validate_interface_name() {
  local value=$1
  [[ $value =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "Invalid network interface name: ${value}"
}

validate_node_label() {
  local value=$1
  [[ -n $value && $value != *$'\n'* ]] || die "Invalid node label: ${value}"
  [[ $value =~ ^[A-Za-z0-9./_-]+=[A-Za-z0-9._-]*$ ]] || die "Invalid node label: ${value}"
}

validate_node_taint() {
  local value=$1
  [[ -n $value && $value != *$'\n'* ]] || die "Invalid node taint: ${value}"
  [[ $value =~ ^[A-Za-z0-9./_-]+(=[A-Za-z0-9._-]+)?:(NoSchedule|PreferNoSchedule|NoExecute)$ ]] ||
    die "Invalid node taint: ${value}"
}

validate_disable_component() {
  case "$1" in
    coredns|servicelb|traefik|local-storage|metrics-server|runtimes) ;;
    *) die "Unsupported packaged component for --disable: $1";;
  esac
}

write_if_changed() {
  local source=$1 destination=$2 mode=$3
  if [[ -f $destination ]] && cmp -s "$source" "$destination"; then
    rm -f "$source"
    log_ok "Configuration already converged: ${destination}"
    return 0
  fi
  backup_file "$destination"
  run install -D -o root -g root -m "$mode" "$source" "$destination"
  [[ ${DRY_RUN:-0} -eq 1 ]] || rm -f "$source"
  log_ok "Wrote ${destination}"
}
