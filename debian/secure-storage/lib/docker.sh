#!/usr/bin/env bash

MIGRATED_SOURCES=()
MIGRATION_DESTINATIONS=()

containerd_root_from_toml() {
  awk '
    BEGIN { in_section = 0 }
    /^[[:space:]]*\[/ { in_section = 1 }
    !in_section && /^[[:space:]]*root[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*root[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

      quote = substr(value, 1, 1)
      if ((quote == "\"" || quote == "\047") && substr(value, length(value), 1) == quote) {
        value = substr(value, 2, length(value) - 2)
      }

      print value
      exit
    }
  '
}

write_containerd_root_config() {
  local file=$1
  local target=$2
  local tmp
  tmp=$(mktemp)

  awk -v target="$target" '
    BEGIN {
      in_section = 0
      wrote_root = 0
    }

    !in_section && /^[[:space:]]*root[[:space:]]*=/ {
      print "root = \047" target "\047"
      wrote_root = 1
      next
    }

    /^[[:space:]]*\[/ {
      if (!wrote_root) {
        print "root = \047" target "\047"
        print ""
        wrote_root = 1
      }
      in_section = 1
    }

    { print }

    END {
      if (!wrote_root) {
        print "root = \047" target "\047"
      }
    }
  ' "$file" > "$tmp"

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

ensure_docker_repository() {
  ensure_packages ca-certificates curl

  run install -m 0755 -d /etc/apt/keyrings

  log_info "Refreshing Docker's official APT signing key..."
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    printf '[DRY-RUN] refresh Docker signing key at /etc/apt/keyrings/docker.asc\n'
  else
    local key_tmp
    key_tmp=$(mktemp)
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$key_tmp"
    if [[ ! -f /etc/apt/keyrings/docker.asc ]] || ! cmp -s "$key_tmp" /etc/apt/keyrings/docker.asc; then
      backup_file /etc/apt/keyrings/docker.asc
      install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc
    fi
    rm -f "$key_tmp"
  fi

  local version_codename arch
  version_codename=$(os_release_value VERSION_CODENAME)
  [[ -n $version_codename ]] || die "Debian VERSION_CODENAME is missing from /etc/os-release."
  arch=$(dpkg --print-architecture)

  local desired
  desired=$(cat <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${version_codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
)

  if [[ ! -f /etc/apt/sources.list.d/docker.sources ]] ||
     [[ "$(cat /etc/apt/sources.list.d/docker.sources)" != "$desired" ]]; then
    backup_file /etc/apt/sources.list.d/docker.sources
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      log_info "Would write Docker APT repository configuration."
    else
      printf '%s\n' "$desired" > /etc/apt/sources.list.d/docker.sources
    fi
  fi

  run apt-get update
}

install_docker_engine() {
  ensure_docker_repository

  local conflicts=(docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc)
  local installed_conflicts=()
  local package
  for package in "${conflicts[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' && installed_conflicts+=("$package")
  done

  if ((${#installed_conflicts[@]})); then
    die "Conflicting Docker packages are installed: ${installed_conflicts[*]}. Remove/migrate them deliberately before using --docker."
  fi

  log_info "Installing Docker Engine from Docker's official Debian repository..."
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin rsync jq
  run apt-get clean
}

stop_container_services() {
  run systemctl stop docker.service docker.socket containerd.service 2>/dev/null || true
}

migrate_directory() {
  local source=$1
  local destination=$2
  local marker="${destination}/.deployscripts-migration-source"

  run install -d -m 0711 "$destination"

  [[ $source == "$destination" ]] && return 0
  path_has_content "$source" || return 0

  if path_has_content "$destination"; then
    if [[ -f $marker ]] && [[ "$(cat "$marker")" == "$source" ]]; then
      log_info "Resuming interrupted migration ${source} -> ${destination}..."
    else
      die "Both ${source} and ${destination} contain data. Refusing to merge automatically because the destination is not marked as an interrupted DeployScripts migration."
    fi
  else
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      log_info "Would mark ${destination} as an in-progress migration from ${source}."
    else
      printf '%s\n' "$source" > "$marker"
      chmod 0600 "$marker"
    fi
  fi

  log_info "Migrating ${source} -> ${destination}..."
  run rsync -aHAX --numeric-ids --delete \
    --exclude='.deployscripts-migration-source' \
    "${source}/" "${destination}/"

  MIGRATED_SOURCES+=("$source")
  MIGRATION_DESTINATIONS+=("$destination")
}

cleanup_migrated_sources() {
  local source destination
  for source in "${MIGRATED_SOURCES[@]}"; do
    case "$source" in
      /var/lib/docker|/var/lib/containerd)
        if mountpoint -q "$source"; then
          log_warn "Old runtime path is a mount point; not deleting it automatically: ${source}"
          continue
        fi
        log_info "Removing migrated unencrypted runtime copy: ${source}"
        run rm -rf --one-file-system "$source"
        ;;
      *)
        log_warn "Data was migrated from custom path ${source}; leaving the old copy in place for manual review."
        ;;
    esac
  done

  for destination in "${MIGRATION_DESTINATIONS[@]}"; do
    run rm -f "${destination}/.deployscripts-migration-source"
  done
}

configure_docker_daemon_json() {
  local target="${MOUNT_PATH}/docker"
  run install -d -m 0711 "$target"
  run install -d -m 0755 /etc/docker

  local current='{}'
  if [[ -s /etc/docker/daemon.json ]]; then
    jq empty /etc/docker/daemon.json >/dev/null 2>&1 ||
      die "/etc/docker/daemon.json is not valid JSON."
    current=$(cat /etc/docker/daemon.json)
  fi

  local desired
  desired=$(printf '%s' "$current" | jq --arg root "$target" '.["data-root"] = $root')

  if [[ ! -f /etc/docker/daemon.json ]] || [[ "$(cat /etc/docker/daemon.json)" != "$desired" ]]; then
    backup_file /etc/docker/daemon.json
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      log_info "Would set Docker data-root to ${target}."
    else
      printf '%s\n' "$desired" > /etc/docker/daemon.json
      chmod 0644 /etc/docker/daemon.json
    fi
  fi
}

configure_containerd_root() {
  local target="${MOUNT_PATH}/containerd"
  run install -d -m 0711 "$target"
  run install -d -m 0755 /etc/containerd

  if [[ ! -s /etc/containerd/config.toml ]]; then
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      log_info "Would generate /etc/containerd/config.toml and set root to ${target}."
      return 0
    fi
    containerd config default > /etc/containerd/config.toml
  fi

  local current_root
  current_root=$(containerd_root_from_toml < /etc/containerd/config.toml)
  current_root=${current_root:-/var/lib/containerd}

  if [[ $current_root != "$target" ]]; then
    backup_file /etc/containerd/config.toml
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      log_info "Would set containerd persistent root to ${target}."
    else
      write_containerd_root_config /etc/containerd/config.toml "$target"
    fi
  fi

  if [[ ${DRY_RUN:-0} -eq 0 ]]; then
    local parsed_root
    parsed_root=$(containerd --config /etc/containerd/config.toml config dump 2>/dev/null | containerd_root_from_toml)
    [[ $parsed_root == "$target" ]] ||
      die "containerd rejected or normalized the configured root unexpectedly: ${parsed_root:-unset}"
  fi
}

ensure_service_mount_dependency() {
  local service=$1
  local dir="/etc/systemd/system/${service}.d"
  local file="${dir}/secure-storage.conf"
  local desired
  desired=$(cat <<EOF
# Managed by DeployScripts secure-storage
[Unit]
RequiresMountsFor=${MOUNT_PATH}
After=$(systemd-escape --path --suffix=mount "$MOUNT_PATH")
EOF
)

  run install -d -m 0755 "$dir"

  if [[ ! -f $file ]] || [[ "$(cat "$file")" != "$desired" ]]; then
    backup_file "$file"
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      log_info "Would make ${service} require ${MOUNT_PATH}."
    else
      printf '%s\n' "$desired" > "$file"
      chmod 0644 "$file"
    fi
  fi
}

configure_docker() {
  mountpoint -q "$MOUNT_PATH" || die "Secure mount must be active before configuring Docker."

  install_docker_engine

  local old_docker_root="/var/lib/docker"
  local old_containerd_root="/var/lib/containerd"

  if systemctl is-active --quiet docker.service; then
    old_docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || printf '/var/lib/docker')
  elif [[ -s /etc/docker/daemon.json ]]; then
    old_docker_root=$(jq -r '.["data-root"] // "/var/lib/docker"' /etc/docker/daemon.json)
  fi

  if [[ -s /etc/containerd/config.toml ]]; then
    old_containerd_root=$(containerd_root_from_toml < /etc/containerd/config.toml)
    old_containerd_root=${old_containerd_root:-/var/lib/containerd}
  fi

  stop_container_services

  migrate_directory "$old_docker_root" "${MOUNT_PATH}/docker"
  migrate_directory "$old_containerd_root" "${MOUNT_PATH}/containerd"

  configure_docker_daemon_json
  configure_containerd_root

  ensure_service_mount_dependency containerd.service
  ensure_service_mount_dependency docker.service

  run systemctl daemon-reload
  run systemctl enable containerd.service docker.service
  run systemctl start containerd.service
  run systemctl start docker.service

  if [[ ${DRY_RUN:-0} -eq 0 ]]; then
    local actual
    actual=$(docker info --format '{{.DockerRootDir}}')
    [[ $actual == "${MOUNT_PATH}/docker" ]] ||
      die "Docker started with unexpected data-root: ${actual}"

    local containerd_actual
    containerd_actual=$(containerd config dump 2>/dev/null | containerd_root_from_toml)
    [[ $containerd_actual == "${MOUNT_PATH}/containerd" ]] ||
      die "containerd started with unexpected root: ${containerd_actual:-unset}"
  fi

  cleanup_migrated_sources
  log_ok "Docker persistent storage is encrypted under ${MOUNT_PATH}."
}
