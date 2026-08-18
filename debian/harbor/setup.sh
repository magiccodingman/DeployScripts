#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/harbor.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/tls.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
trap 'on_error $LINENO' ERR

HARBOR_VERSION="2.15.2"
HARBOR_ROOT="/srv/secure/harbor"
HOSTNAME=""
DB_HOST=""
DB_PORT=5432
DB_NAME="harbor"
DB_USER="harbor"
DB_SSL_MODE="require"
S3_ENDPOINT=""
S3_BUCKET=""
S3_REGION="us-east-1"
S3_ROOT_PREFIX=""
S3_FORCE_PATH_STYLE=1
S3_SKIP_VERIFY=0
S3_REDIRECT_DISABLED=0
WITH_TRIVY=-1
TLS_MODE="auto"
ACME_EMAIL=""
SOURCE_TLS_CERT=""
SOURCE_TLS_KEY=""
SECRET_FILE=""
ALLOW_ROOT_FILESYSTEM=0
DRY_RUN=0
CHECK_ONLY=0
NON_INTERACTIVE=0
INSTALL_DIR=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""

usage() {
  cat <<'EOF_USAGE'
Debian Harbor

Installs or converges Harbor with external PostgreSQL and S3-compatible registry
storage. Harbor's writable local state can be kept beneath an encrypted mount.

Usage:
  sudo ./setup.sh [options]

Required configuration:
  --hostname FQDN          Public Harbor hostname, e.g. harbor.example.com
  --db-host HOST           External PostgreSQL hostname (a DNS name is preferred)
  --s3-endpoint URL        S3-compatible endpoint, e.g. https://s3.example.com
  --s3-bucket NAME         Existing bucket for Harbor registry artifacts

Harbor/storage:
  --root PATH              Harbor local root (default: /srv/secure/harbor)
  --version VERSION        Harbor version (default: 2.15.2)
  --allow-root-filesystem  Permit Harbor writable state on the OS root filesystem
  --with-trivy             Enable Harbor's optional Trivy scanner
  --without-trivy          Explicitly disable Trivy on an existing deployment

PostgreSQL:
  --db-port PORT           Default: 5432
  --db-name NAME           Default: harbor
  --db-user USER           Default: harbor
  --db-ssl-mode MODE       Default: require

S3:
  --s3-region REGION       Default: us-east-1
  --s3-root-prefix PREFIX  Optional object-key prefix inside the bucket
  --s3-virtual-hosted-style  Disable forced path-style addressing
  --s3-skip-verify         Skip TLS verification to S3 (not recommended)
  --disable-s3-redirect    Proxy pulls through Harbor instead of S3 presigned redirects

HTTPS:
  --letsencrypt            Obtain/renew a Let's Encrypt certificate; Harbor nginx terminates TLS
  --http-only              Explicitly configure Harbor without HTTPS
  --acme-email EMAIL       Let's Encrypt account email (prompted if omitted interactively)
  --tls-cert PATH          Use an existing certificate instead of Let's Encrypt
  --tls-key PATH           Existing certificate private key (required with --tls-cert)

Secrets (never accepted as CLI arguments):
  --secret-file PATH       Root-owned 0600 Bash env file. Default: ROOT/secrets.env

  Or set these environment variables before running:
    HARBOR_DB_PASSWORD
    HARBOR_S3_ACCESS_KEY
    HARBOR_S3_SECRET_KEY
    HARBOR_ADMIN_PASSWORD

  Missing secrets are prompted interactively on first run and then stored in the
  encrypted Harbor root for idempotent reruns.

Modes:
  --check                  Read-only validation of an existing deployment
  --dry-run                Show intended mutations without changing the host
  --non-interactive        Never prompt for missing secrets/email
  -h, --help               Show this help

Example:
  sudo ./setup.sh \
    --hostname harbor.example.com \
    --db-host postgres.example.com \
    --s3-endpoint https://s3.example.com \
    --s3-bucket harbor \
    --letsencrypt
EOF_USAGE
}

while (($#)); do
  case "$1" in
    --hostname) HOSTNAME=${2:?}; shift 2;;
    --root) HARBOR_ROOT=${2:?}; shift 2;;
    --version) HARBOR_VERSION=${2:?}; shift 2;;
    --allow-root-filesystem) ALLOW_ROOT_FILESYSTEM=1; shift;;
    --with-trivy) WITH_TRIVY=1; shift;;
    --without-trivy) WITH_TRIVY=0; shift;;
    --db-host) DB_HOST=${2:?}; shift 2;;
    --db-port) DB_PORT=${2:?}; shift 2;;
    --db-name) DB_NAME=${2:?}; shift 2;;
    --db-user) DB_USER=${2:?}; shift 2;;
    --db-ssl-mode) DB_SSL_MODE=${2:?}; shift 2;;
    --s3-endpoint) S3_ENDPOINT=${2:?}; shift 2;;
    --s3-bucket) S3_BUCKET=${2:?}; shift 2;;
    --s3-region) S3_REGION=${2:?}; shift 2;;
    --s3-root-prefix) S3_ROOT_PREFIX=${2:?}; shift 2;;
    --s3-virtual-hosted-style) S3_FORCE_PATH_STYLE=0; shift;;
    --s3-skip-verify) S3_SKIP_VERIFY=1; shift;;
    --disable-s3-redirect) S3_REDIRECT_DISABLED=1; shift;;
    --letsencrypt) TLS_MODE="letsencrypt"; shift;;
    --http-only) TLS_MODE="none"; shift;;
    --acme-email) ACME_EMAIL=${2:?}; shift 2;;
    --tls-cert) SOURCE_TLS_CERT=${2:?}; TLS_MODE="existing"; shift 2;;
    --tls-key) SOURCE_TLS_KEY=${2:?}; TLS_MODE="existing"; shift 2;;
    --secret-file) SECRET_FILE=${2:?}; shift 2;;
    --check) CHECK_ONLY=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --non-interactive) NON_INTERACTIVE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

# These variables are module state consumed by the sourced Harbor helper files.
# Exporting them also makes that relationship explicit to ShellCheck.
export ALLOW_ROOT_FILESYSTEM DB_NAME DB_USER DB_SSL_MODE S3_REGION S3_ROOT_PREFIX \
  S3_FORCE_PATH_STYLE S3_SKIP_VERIFY S3_REDIRECT_DISABLED NON_INTERACTIVE \
  TLS_CERT_PATH TLS_KEY_PATH

require_root
ensure_debian
[[ -n $HOSTNAME ]] || die "--hostname is required."
[[ -n $DB_HOST ]] || die "--db-host is required."
[[ -n $S3_ENDPOINT ]] || die "--s3-endpoint is required."
[[ -n $S3_BUCKET ]] || die "--s3-bucket is required."
validate_hostname "$HOSTNAME"
[[ $DB_PORT =~ ^[0-9]+$ ]] || die "Invalid PostgreSQL port: ${DB_PORT}"
S3_ENDPOINT=$(normalize_endpoint "$S3_ENDPOINT")
ensure_absolute_path "$HARBOR_ROOT" "Harbor root"
[[ -n $SECRET_FILE ]] || SECRET_FILE="${HARBOR_ROOT}/secrets.env"
ensure_absolute_path "$SECRET_FILE" "Secret file"
STATE_FILE="${HARBOR_ROOT}/deployscripts-state.env"
if [[ -f $STATE_FILE ]]; then
  state_tls_mode=""; state_acme_email=""; state_with_trivy=""
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  state_tls_mode=${DEPLOYSCRIPTS_HARBOR_TLS_MODE:-}
  state_acme_email=${DEPLOYSCRIPTS_HARBOR_ACME_EMAIL:-}
  state_with_trivy=${DEPLOYSCRIPTS_HARBOR_WITH_TRIVY:-}
  [[ $TLS_MODE == auto && -n $state_tls_mode ]] && TLS_MODE=$state_tls_mode
  [[ -z $ACME_EMAIL && -n $state_acme_email ]] && ACME_EMAIL=$state_acme_email
  [[ $WITH_TRIVY -eq -1 && -n $state_with_trivy ]] && WITH_TRIVY=$state_with_trivy
fi
[[ $TLS_MODE == auto ]] && TLS_MODE=none
[[ $WITH_TRIVY -eq -1 ]] && WITH_TRIVY=0
if [[ $TLS_MODE == existing && ( -n $SOURCE_TLS_CERT || -n $SOURCE_TLS_KEY ) ]]; then
  [[ -n $SOURCE_TLS_CERT && -n $SOURCE_TLS_KEY ]] || die "--tls-cert and --tls-key must be supplied together."
fi
[[ $TLS_MODE != none || -z $ACME_EMAIL ]] || die "--acme-email requires --letsencrypt."

INSTALL_DIR="${HARBOR_ROOT}/installer/v${HARBOR_VERSION}"

if [[ $CHECK_ONLY -eq 1 ]]; then
  ensure_nonroot_storage_boundary "$HARBOR_ROOT"
  [[ -x ${INSTALL_DIR}/prepare ]] || die "Harbor installer not found at ${INSTALL_DIR}."
  [[ -f $SECRET_FILE ]] || die "Harbor secret file not found: ${SECRET_FILE}"
  load_secret_file
  ensure_secrets
  command -v psql >/dev/null 2>&1 || die "psql is required for --check."
  command -v python3 >/dev/null 2>&1 || die "python3 is required for --check."
  python3 -c 'import boto3, yaml' >/dev/null 2>&1 || die "python3-boto3 and python3-yaml are required for --check."
  command -v openssl >/dev/null 2>&1 || die "openssl is required for --check."
  if [[ $TLS_MODE != none ]]; then
    TLS_CERT_PATH="${HARBOR_ROOT}/tls/${HOSTNAME}.crt"
    TLS_KEY_PATH="${HARBOR_ROOT}/tls/${HOSTNAME}.key"
  fi
  check_postgresql
  s3_probe read
  validate_harbor
  exit $?
fi

ensure_harbor_root
load_secret_file
ensure_secrets
ensure_packages curl ca-certificates postgresql-client python3-boto3 python3-yaml openssl
ensure_docker_ready
ensure_installer
save_secret_file
check_postgresql
s3_probe write

case "$TLS_MODE" in
  letsencrypt)
    ensure_packages certbot
    issue_letsencrypt_certificate
    ;;
  existing)
    configure_existing_tls
    ;;
  none)
    log_warn "HTTPS is disabled. Harbor's own documentation recommends HTTPS for production deployments."
    ;;
  *) die "Unexpected TLS mode: ${TLS_MODE}";;
esac

render_harbor_yml
prepare_harbor
start_harbor
install_letsencrypt_renewal
if [[ ${DRY_RUN:-0} -eq 0 ]]; then
  {
    printf 'DEPLOYSCRIPTS_HARBOR_TLS_MODE=%q\n' "$TLS_MODE"
    printf 'DEPLOYSCRIPTS_HARBOR_ACME_EMAIL=%q\n' "$ACME_EMAIL"
    printf 'DEPLOYSCRIPTS_HARBOR_WITH_TRIVY=%q\n' "$WITH_TRIVY"
  } > "$STATE_FILE"
  chmod 0644 "$STATE_FILE"
fi
validate_harbor

printf '\nHarbor setup complete.\n'
printf 'URL: %s://%s\n' "$([[ $TLS_MODE == none ]] && printf http || printf https)" "$HOSTNAME"
printf 'Harbor root: %s\n' "$HARBOR_ROOT"
printf 'Secrets: %s\n' "$SECRET_FILE"
