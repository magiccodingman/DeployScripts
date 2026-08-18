#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

status=0
while IFS= read -r -d '' script; do
  printf 'bash -n %s\n' "${script#"$ROOT"/}"
  if ! bash -n "$script"; then
    status=1
  fi
done < <(find "$ROOT" -type f -name '*.sh' -print0 | sort -z)

# Regression test for a Bash-global failure discovered during the first real
# secure-storage deployment. /etc/os-release defines NAME, which must never
# overwrite the provisioning mapper NAME when Debian detection runs.
if [[ -r /etc/os-release ]] && grep -Eq '^ID=("?debian"?)$' /etc/os-release; then
  printf 'state regression: ensure_debian preserves mapper NAME\n'
  if ! (
    # shellcheck disable=SC1091
    source "$ROOT/debian/secure-storage/lib/common.sh"
    NAME="harbor-secure"
    ensure_debian
    [[ $NAME == "harbor-secure" ]]
  ); then
    printf 'FAIL: ensure_debian mutated mapper NAME\n' >&2
    status=1
  fi
fi

printf 'containerd regression: parse v2/v3 TOML root quoting\n'
if ! (
  # shellcheck disable=SC1091
  source "$ROOT/debian/secure-storage/lib/docker.sh"

  single=$(printf '%s\n' \
    'version = 3' \
    "root = '/var/lib/containerd'" \
    "state = '/run/containerd'" \
    '[plugins]' \
    "root = 'nested-value-that-must-not-win'" | containerd_root_from_toml)
  [[ $single == '/var/lib/containerd' ]]

  double=$(printf '%s\n' \
    'version = 2' \
    'root = "/custom/containerd"' \
    '[grpc]' | containerd_root_from_toml)
  [[ $double == '/custom/containerd' ]]

  omitted=$(printf '%s\n' 'version = 3' '[grpc]' "address = '/run/containerd.sock'" | containerd_root_from_toml)
  [[ -z $omitted ]]

  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' 'version = 3' '[grpc]' "address = '/run/containerd.sock'" > "$tmp"
  write_containerd_root_config "$tmp" '/srv/secure/containerd'
  [[ $(containerd_root_from_toml < "$tmp") == '/srv/secure/containerd' ]]
); then
  printf 'FAIL: containerd TOML root compatibility regression\n' >&2
  status=1
fi

exit "$status"
