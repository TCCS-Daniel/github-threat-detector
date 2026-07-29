import base64
import hashlib
import hmac
import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

from db_writer import record_delivery, upsert_github_event
from normalizer import to_github_event_row

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _verify_signature(secret: str, body_bytes: bytes, signature_header: str | None) -> bool:
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), body_bytes, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)


def _headers_lower(event_headers: dict[str, str] | None) -> dict[str, str]:
    if not event_headers:
        return {}
    return {k.lower(): v for k, v in event_headers.items()}


def _body_bytes(event: dict[str, Any]) -> bytes:
    body_str = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body_str)
    return body_str.encode("utf-8")


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    headers = _headers_lower(event.get("headers"))
    body_bytes = _body_bytes(event)

    secret = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
    signature = headers.get("x-hub-signature-256")
    if not secret or not _verify_signature(secret, body_bytes, signature):
        logger.warning("signature verification failed delivery_id=%s", headers.get("x-github-delivery"))
        return {"statusCode": 401, "body": "invalid signature"}

    if headers.get("x-github-event") == "ping":
        return {"statusCode": 200, "body": "pong"}

    try:
        body = json.loads(body_bytes)
    except json.JSONDecodeError:
        return {"statusCode": 400, "body": "invalid json"}

    try:
        row = to_github_event_row(headers, body)
    except ValueError as exc:
        logger.warning("normalize failed: %s", exc)
        return {"statusCode": 400, "body": "bad request"}

    try:
        record_delivery(row["id"], row["source"], row["event_type"], row.get("repo_name"))
    except Exception:
        logger.exception("audit insert failed delivery_id=%s", row.get("id"))

    if not row.get("repo_name"):
        logger.info("missing repo_name, skipping delivery_id=%s event_type=%s",
                    row.get("id"), row.get("event_type"))
        return {"statusCode": 200, "body": "skipped"}

    row["created_at"] = datetime.now(timezone.utc).isoformat()

    try:
        upsert_github_event(row)
    except Exception:
        logger.exception("db insert failed delivery_id=%s", row.get("id"))
        return {"statusCode": 500, "body": "internal error"}

    return {"statusCode": 200, "body": "ok"}
