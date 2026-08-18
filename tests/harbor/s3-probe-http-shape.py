#!/usr/bin/env python3
"""Regression test: Harbor S3 probe must not require checksum trailers."""

from __future__ import annotations

import importlib.util
import pathlib
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "debian" / "harbor" / "lib" / "s3_probe.py"
spec = importlib.util.spec_from_file_location("deployscripts_s3_probe", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

captured: dict[str, str] = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_PUT(self) -> None:  # noqa: N802 - stdlib handler API
        captured.update({k.lower(): v for k, v in self.headers.items()})
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        self.send_response(200)
        self.send_header("ETag", '"deployscripts-test"')
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def log_message(self, _format: str, *_args: object) -> None:
        return


server = HTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.handle_request, daemon=True)
thread.start()

client = module.build_client(
    endpoint=f"http://127.0.0.1:{server.server_port}",
    region="us-east-1",
    access_key="deployscripts-access",
    secret_key="deployscripts-secret",
    force_path_style=True,
    skip_verify=False,
)
payload = b"deployscripts-harbor-probe"
client.put_object(Bucket="harbor", Key="probe", Body=payload, ContentLength=len(payload))
thread.join(timeout=10)
server.server_close()
assert not thread.is_alive(), "test HTTP server did not receive PutObject"

assert captured.get("content-length") == str(len(payload)), captured
assert captured.get("transfer-encoding", "").lower() != "chunked", captured
assert "aws-chunked" not in captured.get("content-encoding", "").lower(), captured
assert "x-amz-trailer" not in captured, captured
assert "x-amz-sdk-checksum-algorithm" not in captured, captured
assert not any(key.startswith("x-amz-checksum-") for key in captured), captured
content_sha = captured.get("x-amz-content-sha256", "")
assert len(content_sha) == 64 and all(c in "0123456789abcdef" for c in content_sha.lower()), captured

print("Harbor S3 probe HTTP request shape: PASS")
