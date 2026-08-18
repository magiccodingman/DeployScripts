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

exit "$status"
