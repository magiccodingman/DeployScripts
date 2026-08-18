#!/usr/bin/env python3
"""S3 compatibility probe used by the Debian Harbor deployment tool.

Botocore defaults may add flexible request checksums to S3 PutObject. Some
S3-compatible servers do not implement the resulting streaming/checksum trailer
request form. Harbor's registry storage driver does not require that SDK-only
checksum behavior, so this probe requests checksums only when the operation
actually requires them and signs the ordinary payload instead.
"""

from __future__ import annotations

import os
import uuid

import boto3
from botocore.config import Config


def build_client(
    *,
    endpoint: str,
    region: str,
    access_key: str,
    secret_key: str,
    force_path_style: bool,
    skip_verify: bool,
):
    addressing_style = "path" if force_path_style else "virtual"
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        verify=not skip_verify,
        config=Config(
            signature_version="s3v4",
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
            s3={
                "addressing_style": addressing_style,
                "payload_signing_enabled": True,
            },
        ),
    )


def probe_from_env() -> None:
    endpoint = os.environ["HARBOR_S3_ENDPOINT"]
    bucket = os.environ["HARBOR_S3_BUCKET"]
    region = os.environ["HARBOR_S3_REGION"]
    force_path_style = os.environ["HARBOR_S3_FORCE_PATH_STYLE"] == "1"
    skip_verify = os.environ["HARBOR_S3_SKIP_VERIFY"] == "1"
    mode = os.environ.get("HARBOR_S3_PROBE_MODE", "write")

    client = build_client(
        endpoint=endpoint,
        region=region,
        access_key=os.environ["HARBOR_S3_ACCESS_KEY"],
        secret_key=os.environ["HARBOR_S3_SECRET_KEY"],
        force_path_style=force_path_style,
        skip_verify=skip_verify,
    )

    client.head_bucket(Bucket=bucket)
    if mode != "write":
        return

    key = f".deployscripts-probe/{uuid.uuid4().hex}"
    try:
        client.put_object(
            Bucket=bucket,
            Key=key,
            Body=b"deployscripts-harbor-probe",
            ContentLength=len(b"deployscripts-harbor-probe"),
        )
    finally:
        try:
            client.delete_object(Bucket=bucket, Key=key)
        except Exception:
            pass


if __name__ == "__main__":
    probe_from_env()
