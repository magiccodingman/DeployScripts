#!/usr/bin/env bash

CHECK_FAILURES=0
check_pass() { log_ok "$*"; }
check_fail() { log_err "$*"; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }

validate_harbor() {
  CHECK_FAILURES=0
  printf '\nHarbor Validation\n'
  printf '%s\n' '-----------------'

  if [[ -f ${INSTALL_DIR}/harbor.yml ]]; then
    check_pass "Harbor configuration exists."
  else
    check_fail "Harbor configuration missing: ${INSTALL_DIR}/harbor.yml"
  fi

  if [[ -f ${INSTALL_DIR}/docker-compose.yml ]]; then
    check_pass "Generated Docker Compose file exists."
    if docker compose -f "${INSTALL_DIR}/docker-compose.yml" config >/dev/null 2>&1; then
      check_pass "Docker Compose configuration parses successfully."
    else
      check_fail "Docker Compose configuration is invalid."
    fi

    local compose_services
    compose_services=$(docker compose -f "${INSTALL_DIR}/docker-compose.yml" config --services 2>/dev/null || true)
    if grep -Eq '^(database|postgresql)$' <<<"$compose_services"; then
      check_fail "Local Harbor PostgreSQL service is present; external database was expected."
    else
      check_pass "No local Harbor PostgreSQL service is configured."
    fi
  else
    check_fail "Generated Docker Compose file missing."
  fi

  if [[ -f ${INSTALL_DIR}/common/config/registry/config.yml ]]; then
    local storage_driver
    storage_driver=$(python3 - "${INSTALL_DIR}/common/config/registry/config.yml" <<'PY'
import sys,yaml
with open(sys.argv[1]) as f: cfg=yaml.safe_load(f)
storage=cfg.get('storage') or {}
print('s3' if 's3' in storage else '')
PY
)
    if [[ $storage_driver == s3 ]]; then
      check_pass "Registry is configured with S3 storage (no filesystem blob backend)."
    else
      check_fail "Registry is not configured with S3 storage."
    fi
  else
    check_fail "Generated registry configuration is missing."
  fi

  if [[ -f $SECRET_FILE ]]; then
    local mode owner
    mode=$(stat -c '%a' "$SECRET_FILE")
    owner=$(stat -c '%u' "$SECRET_FILE")
    if [[ $owner == 0 && $mode == 600 ]]; then
      check_pass "Secret file is root-owned mode 0600."
    else
      check_fail "Secret file permissions are unsafe."
    fi
  else
    check_fail "Secret file is missing."
  fi

  if [[ $TLS_MODE != none ]]; then
    if [[ -s ${TLS_CERT_PATH:-} && -s ${TLS_KEY_PATH:-} ]] && openssl x509 -in "$TLS_CERT_PATH" -noout -checkend 86400 >/dev/null 2>&1; then
      check_pass "TLS certificate/key are present and certificate is currently valid."
    else
      check_fail "TLS certificate/key validation failed."
    fi
  fi

  if [[ $TLS_MODE == letsencrypt ]]; then
    if systemctl is-enabled --quiet deployscripts-harbor-cert-renew.timer 2>/dev/null; then
      check_pass "Let's Encrypt renewal timer is enabled."
    else
      check_fail "Let's Encrypt renewal timer is not enabled."
    fi
  fi

  if [[ -f ${INSTALL_DIR}/docker-compose.yml ]]; then
    local expected_services running_services
    expected_services=$(docker compose -f "${INSTALL_DIR}/docker-compose.yml" config --services 2>/dev/null | sort)
    running_services=$(docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps --status running --services 2>/dev/null | sort)
    if [[ -n $expected_services && $expected_services == "$running_services" ]]; then
      check_pass "All Harbor Compose services report running state."
    else
      check_fail "One or more Harbor Compose services are not running."
    fi
  fi

  if [[ $CHECK_FAILURES -eq 0 ]]; then
    printf '\nHARBOR READINESS: PASS\n'
    return 0
  fi
  printf '\nHARBOR READINESS: FAIL (%d check(s) failed)\n' "$CHECK_FAILURES"
  return 1
}
