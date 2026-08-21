from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any


class SupabaseError(RuntimeError):
    def __init__(self, code: str, status: int = 502):
        super().__init__(code)
        self.code = code
        self.status = status


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
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            exc.read()
            raise SupabaseError("supabase_rpc_rejected", 502) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise SupabaseError("supabase_unavailable", 503) from exc
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SupabaseError("supabase_response_invalid", 502) from exc