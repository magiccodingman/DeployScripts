#!/usr/bin/env bash

ensure_tls_material_dir() {
  TLS_DIR="${HARBOR_ROOT}/tls"
  run install -d -m 0700 "$TLS_DIR"
  TLS_CERT_PATH="${TLS_DIR}/${HOSTNAME}.crt"
  TLS_KEY_PATH="${TLS_DIR}/${HOSTNAME}.key"
}

copy_tls_material() {
  local cert_source=$1 key_source=$2
  [[ -s $cert_source && -s $key_source ]] || die "TLS certificate/key source is missing."
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    log_info "Would copy TLS certificate and key into encrypted Harbor storage."
    return 0
  fi
  install -m 0644 "$cert_source" "$TLS_CERT_PATH"
  install -m 0600 "$key_source" "$TLS_KEY_PATH"
  openssl x509 -in "$TLS_CERT_PATH" -noout -checkend 86400 >/dev/null || die "TLS certificate is expired or expires within 24 hours."
  openssl pkey -in "$TLS_KEY_PATH" -noout >/dev/null 2>&1 || die "TLS private key is invalid."
  log_ok "TLS material staged under encrypted Harbor root."
}

ensure_acme_email() {
  [[ -n $ACME_EMAIL ]] && return 0
  [[ ${NON_INTERACTIVE:-0} -eq 0 ]] || die "--letsencrypt requires --acme-email in non-interactive mode."
  [[ -t 0 ]] || die "--letsencrypt requires --acme-email when stdin is not interactive."
  read -r -p "Let's Encrypt account email: " ACME_EMAIL
  [[ $ACME_EMAIL == *@*.* ]] || die "Invalid ACME email address."
}

issue_letsencrypt_certificate() {
  ensure_acme_email
  ensure_tls_material_dir
  ACME_ROOT="${HARBOR_ROOT}/letsencrypt"
  ACME_CONFIG="${ACME_ROOT}/config"
  ACME_WORK="${ACME_ROOT}/work"
  ACME_LOGS="${ACME_ROOT}/logs"
  run install -d -m 0700 "$ACME_CONFIG" "$ACME_WORK" "$ACME_LOGS"

  local live_cert="${ACME_CONFIG}/live/${HOSTNAME}/fullchain.pem"
  local live_key="${ACME_CONFIG}/live/${HOSTNAME}/privkey.pem"

  if [[ ! -s $live_cert || ! -s $live_key ]]; then
    log_info "Requesting Let's Encrypt certificate for ${HOSTNAME} using HTTP-01 standalone challenge..."
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      log_info "Would stop an existing Harbor proxy if needed, run certbot, and stage the resulting certificate."
      return 0
    fi
    if [[ -f ${INSTALL_DIR}/docker-compose.yml ]]; then
      (cd "$INSTALL_DIR" && docker compose down) || true
    fi
    certbot certonly --standalone --preferred-challenges http \
      --non-interactive --agree-tos --email "$ACME_EMAIL" -d "$HOSTNAME" \
      --config-dir "$ACME_CONFIG" --work-dir "$ACME_WORK" --logs-dir "$ACME_LOGS"
  fi

  [[ ${DRY_RUN:-0} -eq 1 ]] || copy_tls_material "$live_cert" "$live_key"
}

configure_existing_tls() {
  ensure_tls_material_dir
  if [[ -n $SOURCE_TLS_CERT && -n $SOURCE_TLS_KEY ]]; then
    ensure_absolute_path "$SOURCE_TLS_CERT" "TLS certificate path"
    ensure_absolute_path "$SOURCE_TLS_KEY" "TLS key path"
    copy_tls_material "$SOURCE_TLS_CERT" "$SOURCE_TLS_KEY"
    return 0
  fi
  [[ -s $TLS_CERT_PATH && -s $TLS_KEY_PATH ]] || die "Existing-TLS mode has no staged certificate. Supply --tls-cert and --tls-key."
  openssl x509 -in "$TLS_CERT_PATH" -noout -checkend 86400 >/dev/null || die "Staged TLS certificate is expired or expires within 24 hours."
  openssl pkey -in "$TLS_KEY_PATH" -noout >/dev/null 2>&1 || die "Staged TLS private key is invalid."
  log_ok "Reusing staged TLS material under encrypted Harbor root."
}

install_letsencrypt_renewal() {
  [[ $TLS_MODE == letsencrypt ]] || return 0
  [[ ${DRY_RUN:-0} -eq 0 ]] || { log_info "Would install Harbor Let's Encrypt renewal timer."; return 0; }

  local renew_script="/usr/local/sbin/deployscripts-harbor-cert-renew"
  local prepare_flag=""
  [[ $WITH_TRIVY -eq 1 ]] && prepare_flag="--with-trivy"

  cat > "$renew_script" <<EOF_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(printf '%q' "$HARBOR_ROOT")
INSTALL_DIR=$(printf '%q' "$INSTALL_DIR")
HOSTNAME=$(printf '%q' "$HOSTNAME")
ACME_CONFIG=$(printf '%q' "$ACME_CONFIG")
ACME_WORK=$(printf '%q' "$ACME_WORK")
ACME_LOGS=$(printf '%q' "$ACME_LOGS")
TLS_CERT=$(printf '%q' "$TLS_CERT_PATH")
TLS_KEY=$(printf '%q' "$TLS_KEY_PATH")
PREPARE_FLAG=$(printf '%q' "$prepare_flag")

pre_hook="cd \"\$INSTALL_DIR\" && docker compose down"
post_hook="install -m 0644 \"\$ACME_CONFIG/live/\$HOSTNAME/fullchain.pem\" \"\$TLS_CERT\" && install -m 0600 \"\$ACME_CONFIG/live/\$HOSTNAME/privkey.pem\" \"\$TLS_KEY\" && cd \"\$INSTALL_DIR\" && ./prepare \$PREPARE_FLAG && docker compose up -d"
certbot renew --config-dir "\$ACME_CONFIG" --work-dir "\$ACME_WORK" --logs-dir "\$ACME_LOGS" --pre-hook "\$pre_hook" --post-hook "\$post_hook"
EOF_SCRIPT
  chmod 0750 "$renew_script"

  cat > /etc/systemd/system/deployscripts-harbor-cert-renew.service <<EOF_UNIT
# Managed by DeployScripts Harbor
[Unit]
Description=Renew Harbor Let's Encrypt certificate
RequiresMountsFor=${HARBOR_ROOT}
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${renew_script}
EOF_UNIT

  cat > /etc/systemd/system/deployscripts-harbor-cert-renew.timer <<'EOF_TIMER'
# Managed by DeployScripts Harbor
[Unit]
Description=Periodic Harbor certificate renewal

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

  systemctl daemon-reload
  systemctl enable --now deployscripts-harbor-cert-renew.timer
  log_ok "Let's Encrypt renewal timer enabled."
}
