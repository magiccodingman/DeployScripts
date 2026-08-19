#!/usr/bin/env python3
import argparse
import os
import stat
import tempfile

import yaml


def normalize_env_file(value):
    if isinstance(value, (str, dict)):
        items = [value]
    elif isinstance(value, list):
        items = value
    else:
        raise ValueError(f"unsupported env_file value type: {type(value).__name__}")

    normalized = []
    changed = False
    for item in items:
        if isinstance(item, str):
            normalized.append({"path": item, "format": "raw"})
            changed = True
            continue

        if not isinstance(item, dict) or "path" not in item:
            raise ValueError("env_file mappings must contain a path")

        updated = dict(item)
        if updated.get("format") != "raw":
            updated["format"] = "raw"
            changed = True
        normalized.append(updated)

    return normalized, changed


def protect(config):
    services = config.get("services") or {}
    if not isinstance(services, dict):
        raise ValueError("Compose services must be a mapping")

    protected = 0
    changed = False
    for service_name, service in services.items():
        if not isinstance(service, dict) or "env_file" not in service:
            continue
        normalized, service_changed = normalize_env_file(service["env_file"])
        service["env_file"] = normalized
        protected += len(normalized)
        changed = changed or service_changed

    if protected == 0:
        raise ValueError("generated Harbor Compose file contains no env_file declarations")
    return protected, changed


def check(config):
    services = config.get("services") or {}
    found = 0
    invalid = []
    for service_name, service in services.items():
        if not isinstance(service, dict) or "env_file" not in service:
            continue
        value = service["env_file"]
        items = value if isinstance(value, list) else [value]
        for item in items:
            found += 1
            if not isinstance(item, dict) or not item.get("path") or item.get("format") != "raw":
                invalid.append(service_name)

    if found == 0:
        raise ValueError("generated Harbor Compose file contains no env_file declarations")
    if invalid:
        names = ", ".join(sorted(set(invalid)))
        raise ValueError(f"Harbor env_file declarations are not raw for service(s): {names}")
    return found


def write_atomic(path, config):
    current_mode = stat.S_IMODE(os.stat(path).st_mode)
    directory = os.path.dirname(path) or "."
    fd, temp_path = tempfile.mkstemp(prefix=".docker-compose.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            yaml.safe_dump(config, handle, sort_keys=False, default_flow_style=False)
        os.chmod(temp_path, current_mode)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def main():
    parser = argparse.ArgumentParser(
        description="Make Harbor-generated Compose env_file declarations literal/raw."
    )
    parser.add_argument("compose_file")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    with open(args.compose_file, encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    if not isinstance(config, dict):
        raise SystemExit("Compose file must contain a mapping")

    try:
        if args.check:
            count = check(config)
            print(f"Harbor Compose raw env_file protection: PASS ({count} declaration(s))")
            return

        count, changed = protect(config)
        if changed:
            write_atomic(args.compose_file, config)
        print(f"Protected {count} Harbor env_file declaration(s) with Compose raw format.")
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
