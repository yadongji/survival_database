from __future__ import annotations

import http.client
import json
import re
import time
import urllib.error
import urllib.request
from typing import Any


def _safe_error_detail(raw: bytes) -> str:
    """Keep useful PostgREST diagnostics without logging account-like values."""
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        value = None
    if isinstance(value, dict):
        fields = []
        for key in ("code", "message", "hint", "details"):
            item = value.get(key)
            if isinstance(item, str) and item:
                fields.append(f"{key}={item}")
        detail = "; ".join(fields)
    else:
        detail = ""
    if not detail:
        detail = "http_error_body_unparseable"
    detail = re.sub(r"[0-9a-fA-F]{64}", "<redacted>", detail)
    return detail[:512]


class SupabaseError(RuntimeError):
    def __init__(self, code: str, status: int = 502, detail: str = ""):
        super().__init__(code)
        self.code = code
        self.status = status
        self.detail = detail


class SupabaseRpcClient:
    def __init__(self, base_url: str, service_key: str, timeout: int):
        self.base_url = base_url
        self.service_key = service_key
        self.timeout = timeout

    def rpc(self, function_name: str, payload: dict[str, Any]) -> Any:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        headers = {
            "apikey": self.service_key,
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
        }
        if not self.service_key.startswith("sb_secret_"):
            headers["Authorization"] = f"Bearer {self.service_key}"
        request = urllib.request.Request(
            f"{self.base_url}/rest/v1/rpc/{function_name}",
            data=body,
            method="POST",
            headers=headers,
        )
        transient_errors = (
            urllib.error.URLError,
            TimeoutError,
            http.client.RemoteDisconnected,
            ConnectionResetError,
            BrokenPipeError,
        )
        for attempt in range(2):
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    raw = response.read()
                break
            except urllib.error.HTTPError as exc:
                raw = exc.read()
                detail = _safe_error_detail(raw)
                raise SupabaseError(
                    "supabase_rpc_rejected", 502,
                    f"function={function_name}; http_status={exc.code}; {detail}",
                ) from exc
            except transient_errors as exc:
                if attempt == 0:
                    time.sleep(0.1)
                    continue
                raise SupabaseError(
                    "supabase_unavailable", 503,
                    f"function={function_name}; transport={type(exc).__name__}; attempts=2",
                ) from exc
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SupabaseError("supabase_response_invalid", 502) from exc