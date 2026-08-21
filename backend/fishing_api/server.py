from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .application import ApiError, FishingApplication
from .config import ConfigError, Settings
from .definitions import DefinitionError, load_definitions, load_rule
from .gameplay_stats import GameplayStatsError, load_gameplay_stats
from .supabase import SupabaseError, SupabaseRpcClient


MAX_BODY_BYTES = 16 * 1024


def make_handler(application: FishingApplication) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "SurvivalFishingAPI/1"

        def log_message(self, format_string: str, *args: object) -> None:
            sys.stderr.write("[FishingAPI] " + format_string % args + "\n")

        def _send(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self) -> bool:
            if application.authorized(self.headers.get("Authorization")):
                return True
            self._send(401, {"ok": False, "error": "unauthorized"})
            return False

        def _body(self) -> dict[str, Any]:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError as exc:
                raise ApiError("content_length_invalid", 400) from exc
            if length <= 0 or length > MAX_BODY_BYTES:
                raise ApiError("request_body_size_invalid", 413)
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ApiError("request_json_invalid", 400) from exc
            if not isinstance(payload, dict):
                raise ApiError("request_json_invalid", 400)
            return payload

        def do_GET(self) -> None:
            if self.path == "/health":
                self._send(200, {"ok": True, "service": "survival-fishing-api"})
                return
            self._send(404, {"ok": False, "error": "route_not_found"})

        def do_POST(self) -> None:
            if not self._authorized():
                return
            try:
                payload = self._body()
                if self.path == "/v1/profile":
                    response = application.profile(payload)
                elif self.path == "/v1/rewards/grant":
                    response = application.grant_out_of_match_reward(payload)
                elif self.path == "/v1/fishing/heartbeat":
                    response = application.heartbeat(payload)
                else:
                    raise ApiError("route_not_found", 404)
                self._send(200, response if isinstance(response, dict) else {
                    "ok": True, "data": response,
                })
            except ApiError as exc:
                self._send(exc.status, {"ok": False, "error": exc.code})
            except SupabaseError as exc:
                self._send(exc.status, {"ok": False, "error": exc.code})
            except Exception:
                self._send(500, {"ok": False, "error": "internal_error"})

    return Handler


def build_application(settings: Settings) -> FishingApplication:
    definitions = load_definitions(settings.reward_csv)
    rule = load_rule(settings.rule_csv)
    if definitions.version != rule.definition_version:
        raise DefinitionError("reward and rule definition versions differ")
    gameplay_stats = load_gameplay_stats(settings.gameplay_stats_csv)
    client = SupabaseRpcClient(
        settings.supabase_url,
        settings.supabase_key,
        settings.request_timeout_seconds,
    )
    application = FishingApplication(
        settings.api_token,
        settings.account_id_pepper,
        definitions,
        client,
        gameplay_stats,
        heartbeat_lease_seconds=rule.heartbeat_lease_seconds,
        interval_min_seconds=rule.interval_min_seconds,
        interval_max_seconds=rule.interval_max_seconds,
    )
    application.sync_definitions()
    return application


def main() -> int:
    try:
        settings = Settings.from_env()
        application = build_application(settings)
    except (ConfigError, DefinitionError, GameplayStatsError, SupabaseError) as exc:
        print(f"FISHING_API_STARTUP_ERROR {exc}", file=sys.stderr)
        return 2
    server = ThreadingHTTPServer(
        (settings.host, settings.port), make_handler(application)
    )
    print(f"FISHING_API_READY http://{settings.host}:{settings.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())