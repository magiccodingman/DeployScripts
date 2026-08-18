#!/usr/bin/env python3
import argparse
import os
from pathlib import Path

import yaml


def required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--template", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--hostname", required=True)
    p.add_argument("--data-volume", required=True)
    p.add_argument("--log-location", required=True)
    p.add_argument("--db-host", required=True)
    p.add_argument("--db-port", type=int, default=5432)
    p.add_argument("--db-name", default="harbor")
    p.add_argument("--db-user", default="harbor")
    p.add_argument("--db-ssl-mode", default="require")
    p.add_argument("--s3-endpoint", required=True)
    p.add_argument("--s3-bucket", required=True)
    p.add_argument("--s3-region", default="us-east-1")
    p.add_argument("--s3-root-prefix", default="")
    p.add_argument("--s3-force-path-style", action="store_true")
    p.add_argument("--s3-skip-verify", action="store_true")
    p.add_argument("--disable-s3-redirect", action="store_true")
    p.add_argument("--tls-cert")
    p.add_argument("--tls-key")
    return p.parse_args()


def main():
    args = parse_args()
    if bool(args.tls_cert) != bool(args.tls_key):
        raise SystemExit("--tls-cert and --tls-key must be supplied together")

    with open(args.template, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)

    cfg["hostname"] = args.hostname
    cfg["http"] = {"port": 80}
    if args.tls_cert:
        cfg["https"] = {
            "port": 443,
            "certificate": args.tls_cert,
            "private_key": args.tls_key,
        }
    else:
        cfg.pop("https", None)

    cfg["harbor_admin_password"] = required_env("HARBOR_ADMIN_PASSWORD")
    cfg["data_volume"] = args.data_volume

    cfg["external_database"] = {
        "harbor": {
            "host": args.db_host,
            "port": args.db_port,
            "db_name": args.db_name,
            "username": args.db_user,
            "password": required_env("HARBOR_DB_PASSWORD"),
            "ssl_mode": args.db_ssl_mode,
            "max_idle_conns": 2,
            "max_open_conns": 0,
        }
    }

    s3 = {
        "accesskey": required_env("HARBOR_S3_ACCESS_KEY"),
        "secretkey": required_env("HARBOR_S3_SECRET_KEY"),
        "region": args.s3_region,
        "regionendpoint": args.s3_endpoint,
        "forcepathstyle": bool(args.s3_force_path_style),
        "bucket": args.s3_bucket,
        "secure": args.s3_endpoint.startswith("https://"),
        "skipverify": bool(args.s3_skip_verify),
        "v4auth": True,
    }
    if args.s3_root_prefix:
        s3["rootdirectory"] = args.s3_root_prefix

    cfg["storage_service"] = {
        "s3": s3,
        "redirect": {"disable": bool(args.disable_s3_redirect)},
    }

    # Keep job metadata authoritative in PostgreSQL instead of the local FILE logger.
    cfg.setdefault("jobservice", {})["job_loggers"] = ["STD_OUTPUT", "DB"]
    cfg.setdefault("log", {}).setdefault("local", {})["location"] = args.log_location

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with open(output, "w", encoding="utf-8") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False, default_flow_style=False)
    os.chmod(output, 0o600)


if __name__ == "__main__":
    main()
