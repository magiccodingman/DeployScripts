#!/usr/bin/env bash

harbor_release_url() {
  printf 'https://github.com/goharbor/harbor/releases/download/v%s/harbor-online-installer-v%s.tgz' "$HARBOR_VERSION" "$HARBOR_VERSION"
}

ensure_harbor_root() {
  ensure_absolute_path "$HARBOR_ROOT" "Harbor root"
  ensure_nonroot_storage_boundary "$HARBOR_ROOT"
  run install -d -m 0750 "$HARBOR_ROOT" "$HARBOR_ROOT/data" "$HARBOR_ROOT/logs" "$HARBOR_ROOT/downloads" "$HARBOR_ROOT/installer"
}

ensure_docker_ready() {
  command -v docker >/dev/null 2>&1 || die "Docker is required. Run secure-storage setup with --docker first, or install Docker deliberately."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
  systemctl is-active --quiet docker.service || die "docker.service is not active."
  local docker_root
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  [[ -n $docker_root ]] || die "Docker daemon is not responding."
  log_ok "Docker is active (data-root: ${docker_root})."
}

ensure_installer() {
  INSTALL_DIR="${HARBOR_ROOT}/installer/v${HARBOR_VERSION}"
  local marker="${HARBOR_ROOT}/.deployscripts-harbor-version"

  if [[ -f $marker ]]; then
    local existing_version
    existing_version=$(cat "$marker")
    if [[ $existing_version != "$HARBOR_VERSION" && -f "${HARBOR_ROOT}/installer/v${existing_version}/docker-compose.yml" ]]; then
      die "Existing Harbor version is ${existing_version}; automatic in-place upgrades are intentionally not implemented. Use the matching version or perform a deliberate Harbor upgrade."
    fi
  fi

  if [[ -x ${INSTALL_DIR}/prepare && -f ${INSTALL_DIR}/harbor.yml.tmpl ]]; then
    log_ok "Harbor installer already present: v${HARBOR_VERSION}"
  else
    local archive="${HARBOR_ROOT}/downloads/harbor-online-installer-v${HARBOR_VERSION}.tgz"
    if [[ ! -s $archive ]]; then
      log_info "Downloading Harbor v${HARBOR_VERSION} online installer..."
      run curl --fail --location --retry 5 --retry-delay 2 --output "$archive" "$(harbor_release_url)"
    fi
    [[ ${DRY_RUN:-0} -eq 1 ]] && { log_info "Would extract Harbor installer to ${INSTALL_DIR}"; return 0; }
    rm -rf "$INSTALL_DIR"
    install -d -m 0750 "$INSTALL_DIR"
    tar -xzf "$archive" --strip-components=1 -C "$INSTALL_DIR"
    [[ -x ${INSTALL_DIR}/prepare && -f ${INSTALL_DIR}/harbor.yml.tmpl ]] || die "Downloaded Harbor installer is incomplete."
    log_ok "Harbor installer extracted: ${INSTALL_DIR}"
  fi

  if [[ ${DRY_RUN:-0} -eq 0 ]]; then
    printf '%s\n' "$HARBOR_VERSION" > "$marker"
    chmod 0644 "$marker"
    ln -sfn "v${HARBOR_VERSION}" "${HARBOR_ROOT}/installer/current"
  fi
}

check_postgresql() {
  log_info "Validating external PostgreSQL connectivity..."
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    log_info "Would connect to PostgreSQL host ${DB_HOST}:${DB_PORT}/${DB_NAME} with sslmode=${DB_SSL_MODE}."
    return 0
  fi
  PGPASSWORD="$HARBOR_DB_PASSWORD" psql \
    "host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} sslmode=${DB_SSL_MODE}" \
    -X -v ON_ERROR_STOP=1 -Atqc 'SELECT 1' | grep -qx '1' || die "External PostgreSQL validation failed."
  log_ok "External PostgreSQL connection succeeded."
}

s3_probe() {
  local mode=${1:-write}
  log_info "Validating S3-compatible storage (${S3_ENDPOINT}, bucket ${S3_BUCKET})..."
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    log_info "Would validate S3 bucket access using Signature V4 and path-style=${S3_FORCE_PATH_STYLE}."
    return 0
  fi
  HARBOR_S3_ENDPOINT="$S3_ENDPOINT" \
  HARBOR_S3_BUCKET="$S3_BUCKET" \
  HARBOR_S3_REGION="$S3_REGION" \
  HARBOR_S3_FORCE_PATH_STYLE="$S3_FORCE_PATH_STYLE" \
  HARBOR_S3_SKIP_VERIFY="$S3_SKIP_VERIFY" \
  HARBOR_S3_PROBE_MODE="$mode" \
  HARBOR_S3_ACCESS_KEY="$HARBOR_S3_ACCESS_KEY" \
  HARBOR_S3_SECRET_KEY="$HARBOR_S3_SECRET_KEY" \
  python3 - <<'PY'
import os, uuid
import boto3
from botocore.config import Config

endpoint = os.environ['HARBOR_S3_ENDPOINT']
bucket = os.environ['HARBOR_S3_BUCKET']
region = os.environ['HARBOR_S3_REGION']
style = 'path' if os.environ['HARBOR_S3_FORCE_PATH_STYLE'] == '1' else 'virtual'
verify = os.environ['HARBOR_S3_SKIP_VERIFY'] != '1'
mode = os.environ.get('HARBOR_S3_PROBE_MODE', 'write')
client = boto3.client(
    's3', endpoint_url=endpoint, region_name=region,
    aws_access_key_id=os.environ['HARBOR_S3_ACCESS_KEY'],
    aws_secret_access_key=os.environ['HARBOR_S3_SECRET_KEY'],
    verify=verify,
    config=Config(signature_version='s3v4', s3={'addressing_style': style}),
)
client.head_bucket(Bucket=bucket)
if mode == 'write':
    key = f'.deployscripts-probe/{uuid.uuid4().hex}'
    try:
        client.put_object(Bucket=bucket, Key=key, Body=b'deployscripts-harbor-probe')
    finally:
        try:
            client.delete_object(Bucket=bucket, Key=key)
        except Exception:
            pass
PY
  log_ok "S3 bucket validation succeeded."
}

render_harbor_yml() {
  local output="${INSTALL_DIR}/harbor.yml"
  local args=(
    --template "${INSTALL_DIR}/harbor.yml.tmpl"
    --output "$output"
    --hostname "$HOSTNAME"
    --data-volume "${HARBOR_ROOT}/data"
    --log-location "${HARBOR_ROOT}/logs"
    --db-host "$DB_HOST"
    --db-port "$DB_PORT"
    --db-name "$DB_NAME"
    --db-user "$DB_USER"
    --db-ssl-mode "$DB_SSL_MODE"
    --s3-endpoint "$S3_ENDPOINT"
    --s3-bucket "$S3_BUCKET"
    --s3-region "$S3_REGION"
  )
  [[ -n $S3_ROOT_PREFIX ]] && args+=(--s3-root-prefix "$S3_ROOT_PREFIX")
  [[ $S3_FORCE_PATH_STYLE -eq 1 ]] && args+=(--s3-force-path-style)
  [[ $S3_SKIP_VERIFY -eq 1 ]] && args+=(--s3-skip-verify)
  [[ $S3_REDIRECT_DISABLED -eq 1 ]] && args+=(--disable-s3-redirect)
  [[ -n ${TLS_CERT_PATH:-} ]] && args+=(--tls-cert "$TLS_CERT_PATH" --tls-key "$TLS_KEY_PATH")

  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    log_info "Would render Harbor configuration at ${output}."
    return 0
  fi

  backup_file "$output"
  HARBOR_DB_PASSWORD="$HARBOR_DB_PASSWORD" \
  HARBOR_S3_ACCESS_KEY="$HARBOR_S3_ACCESS_KEY" \
  HARBOR_S3_SECRET_KEY="$HARBOR_S3_SECRET_KEY" \
  HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASSWORD" \
    python3 "${SCRIPT_DIR}/lib/render_config.py" "${args[@]}"
  log_ok "Rendered Harbor configuration: ${output}"
}

prepare_harbor() {
  local prepare_args=()
  [[ $WITH_TRIVY -eq 1 ]] && prepare_args+=(--with-trivy)
  log_info "Running Harbor's official prepare step..."
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    printf '[DRY-RUN] cd %q && ./prepare' "$INSTALL_DIR"
    printf ' %q' "${prepare_args[@]}"
    printf '\n'
    return 0
  fi
  (cd "$INSTALL_DIR" && ./prepare "${prepare_args[@]}")
  docker compose -f "${INSTALL_DIR}/docker-compose.yml" config >/dev/null
  log_ok "Harbor prepare and Docker Compose validation succeeded."
}

harbor_health_probe() {
  local url curl_args=()
  if [[ $TLS_MODE == none ]]; then
    url="http://127.0.0.1/api/v2.0/health"
    curl_args=(-H "Host: ${HOSTNAME}")
  else
    url="https://${HOSTNAME}/api/v2.0/health"
    # TLS material is validated separately. This local loopback probe uses the
    # configured hostname while bypassing public DNS during service startup.
    curl_args=(-k --resolve "${HOSTNAME}:443:127.0.0.1")
  fi

  local body
  body=$(curl --silent --show-error --max-time 5 "${curl_args[@]}" "$url" 2>/dev/null || true)
  [[ -n $body ]] || return 1
  python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("status") == "healthy" else 1)' <<<"$body"
}

wait_for_harbor_health() {
  [[ ${DRY_RUN:-0} -eq 1 ]] && return 0
  log_info "Waiting for Harbor API health to become healthy..."
  local i
  for i in $(seq 1 60); do
    if harbor_health_probe; then
      log_ok "Harbor API reports healthy."
      return 0
    fi
    sleep 2
  done
  docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps >&2 || true
  die "Harbor did not report healthy within the startup window."
}

start_harbor() {
  [[ ${DRY_RUN:-0} -eq 1 ]] && { log_info "Would start Harbor with Docker Compose."; return 0; }
  log_info "Starting/converging Harbor services..."
  (cd "$INSTALL_DIR" && docker compose up -d)
  log_ok "Harbor Compose stack started."
  wait_for_harbor_health
}
