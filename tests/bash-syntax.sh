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

exit "$status"
