from __future__ import annotations

import http.client
import hashlib
import hmac
import json
import math
import os
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch


BACKEND = Path(__file__).resolve().parents[1]
ADDON_ROOT = Path(os.environ["SURVIVAL_ADDON_ROOT"]).resolve()
sys.path.insert(0, str(BACKEND))

from fishing_api.application import ApiError, FishingApplication  # noqa: E402
from fishing_api.config import Settings  # noqa: E402
from fishing_api.definitions import (  # noqa: E402
    DefinitionError,
    DefinitionSet,
    load_definitions,
    load_rule,
)
from fishing_api.gameplay_stats import load_gameplay_stats  # noqa: E402
from fishing_api.server import make_handler  # noqa: E402
from fishing_api.supabase import SupabaseRpcClient  # noqa: E402


class FakeRpc:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []
        self.grants: dict[object, tuple[tuple[object, ...], dict[str, object]]] = {}

    def rpc(self, name: str, payload: dict[str, object]) -> dict[str, object]:
        self.calls.append((name, payload))
        if name == "get_fishing_profile":
            return {
                "schema_version": 1,
                "account_id": payload["p_account_id"],
                "revision": 0,
                "entitlements": {},
                "achievements": {},
                "save": {
                    "permanent_effects": {},
                    "gameplay_stats": {"online_seconds_total": 0},
                },
                "public": {},
            }
        if name == "grant_out_of_match_reward":
            grant_id = payload["p_grant_id"]
            fingerprint = (
                payload["p_account_id"], payload["p_reward_id"],
                payload["p_definition_version"], payload["p_amount"],
            )
            existing = self.grants.get(grant_id)
            if existing is not None:
                if existing[0] != fingerprint:
                    raise ApiError("grant_id_conflict", 409)
                return existing[1]
            response: dict[str, object] = {
                "ok": True,
                "duplicate": False,
                "applied_total": payload["p_amount"],
                "grant": {
                    "grant_id": grant_id,
                    "reward_id": payload["p_reward_id"],
                    "amount": payload["p_amount"],
                },
                "profile": {
                    "account_id": payload["p_account_id"],
                    "revision": 1,
                    "save": {"gameplay_stats": {"initial_wood": 10}},
                },
            }
            self.grants[grant_id] = (fingerprint, response)
            return response
        return {
            "ok": True,
            "remaining_seconds": 60,
            "profile": {
                "schema_version": 1,
                "account_id": payload.get("p_account_id"),
                "revision": 0,
                "entitlements": {},
                "achievements": {},
                "save": {
                    "permanent_effects": {},
                    "gameplay_stats": {"online_seconds_total": 5},
                },
                "public": {},
            },
            "grant": None,
        }


def definitions() -> DefinitionSet:
    return DefinitionSet(1, "a" * 64, [{
        "reward_id": "test_reward",
        "display_name": "Test",
        "weight": 1.0,
        "effect_key": "hero_attack_flat",
        "effect_scope": "permanent",
        "value_min": 1.0,
        "value_max": 1.0,
        "stacking_rule": "add",
        "cap_value": None,
    }])


class DefinitionTests(unittest.TestCase):
    def test_match_reward_csv_is_rejected_by_out_of_match_backend(self) -> None:
        path = ADDON_ROOT / "data/csv/玩家档案系统/fishing_reward_definitions.csv"
        with self.assertRaisesRegex(DefinitionError, "invalid effect_scope"):
            load_definitions(path)

    def test_enabled_fixture_is_canonical_and_rule_matches(self) -> None:
        fixture = Path(__file__).parent / "fixtures"
        first = load_definitions(fixture / "fishing_reward_definitions.csv")
        second = load_definitions(fixture / "fishing_reward_definitions.csv")
        self.assertEqual(first.version, 9001)
        self.assertEqual(
            [row["reward_id"] for row in first.rows],
            ["test_hero_attack_flat"],
        )
        self.assertEqual(first.digest, second.digest)
        rule = load_rule(fixture / "fishing_system_rules.csv")
        self.assertEqual((rule.interval_min_seconds, rule.interval_max_seconds), (10, 10))
        self.assertEqual(rule.definition_version, first.version)


class ConfigTests(unittest.TestCase):
    def test_default_csv_paths_resolve_from_addon_root(self) -> None:
        environment = {
            "SURVIVAL_ADDON_ROOT": str(ADDON_ROOT),
            "FISHING_API_TOKEN": "t" * 32,
            "FISHING_ACCOUNT_ID_PEPPER": "p" * 32,
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SECRET_KEY": "sb_secret_test",
        }
        with patch.dict(os.environ, environment, clear=True):
            settings = Settings.from_env()
        self.assertEqual(
            settings.reward_csv,
            ADDON_ROOT / "data/csv/玩家档案系统/fishing_reward_definitions.csv",
        )
        self.assertEqual(
            settings.rule_csv,
            ADDON_ROOT / "data/csv/玩家档案系统/fishing_system_rules.csv",
        )
        self.assertEqual(
            settings.gameplay_stats_csv,
            ADDON_ROOT / "data/csv/玩家档案系统/player_gameplay_stats.csv",
        )

    def test_gameplay_stats_csv_has_36_typed_defaults_plus_player_id(self) -> None:
        stats = load_gameplay_stats(
            ADDON_ROOT / "data/csv/玩家档案系统/player_gameplay_stats.csv"
        )
        self.assertEqual(len(stats), 36)
        self.assertEqual(stats["initial_wood"], 10)
        self.assertEqual(stats["tower_attack_interval"], 1.7)
        self.assertEqual(stats["online_seconds_total"], 0)


class SupabaseClientTests(unittest.TestCase):
    def test_secret_key_uses_apikey_without_bearer_header(self) -> None:
        client = SupabaseRpcClient(
            "https://example.supabase.co", "sb_secret_test", 1
        )

        class Response:
            def __enter__(self) -> "Response": return self
            def __exit__(self, *args: object) -> None: return None
            def read(self) -> bytes: return b'{"ok":true}'

        with patch("urllib.request.urlopen", return_value=Response()) as request:
            self.assertEqual(client.rpc("test_rpc", {}), {"ok": True})
        sent = request.call_args.args[0]
        self.assertEqual(sent.get_header("Apikey"), "sb_secret_test")
        self.assertIsNone(sent.get_header("Authorization"))

    def test_legacy_key_uses_bearer_header(self) -> None:
        client = SupabaseRpcClient("https://example.supabase.co", "legacy", 1)

        class Response:
            def __enter__(self) -> "Response": return self
            def __exit__(self, *args: object) -> None: return None
            def read(self) -> bytes: return b'{}'

        with patch("urllib.request.urlopen", return_value=Response()) as request:
            client.rpc("test_rpc", {})
        sent = request.call_args.args[0]
        self.assertEqual(sent.get_header("Authorization"), "Bearer legacy")


class ApplicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rpc = FakeRpc()
        stats = load_gameplay_stats(
            ADDON_ROOT / "data/csv/玩家档案系统/player_gameplay_stats.csv"
        )
        self.application = FishingApplication(
            "x" * 32, "p" * 32, definitions(), self.rpc, stats
        )

    def test_authentication_and_heartbeat_contract(self) -> None:
        self.assertTrue(self.application.authorized("Bearer " + "x" * 32))
        self.assertFalse(self.application.authorized("Bearer wrong"))
        response = self.application.heartbeat({
            "account_id": "123456",
            "session_id": "session:123",
            "request_id": "request:123",
        })
        self.assertTrue(response["ok"])
        name, payload = self.rpc.calls[-1]
        self.assertEqual(name, "heartbeat_fishing_session")
        expected_account_id = hmac.new(
            ("p" * 32).encode(), b"123456", hashlib.sha256
        ).hexdigest()
        self.assertEqual(payload["p_account_id"], expected_account_id)
        self.assertEqual(response["profile"]["account_id"], "123456")
        self.assertEqual(
            response["profile"]["save"]["gameplay_stats"]["online_seconds_total"],
            5,
        )
        self.assertEqual(payload["p_interval_min_seconds"], 60)
        self.assertEqual(payload["p_interval_max_seconds"], 600)
        self.assertNotIn("elapsed_seconds", payload)

    def test_profile_initializes_gameplay_stats_before_reading(self) -> None:
        response = self.application.profile({"account_id": "123456"})
        self.assertTrue(response["ok"] if "ok" in response else True)
        self.assertEqual(
            [name for name, _ in self.rpc.calls[-2:]],
            ["ensure_player_gameplay_stats", "get_fishing_profile"],
        )
        self.assertEqual(
            self.rpc.calls[-2][1]["p_gameplay_stats"]["online_seconds_total"], 0
        )
        self.assertEqual(
            response["save"]["gameplay_stats"]["online_seconds_total"], 0
        )

    def test_out_of_match_grant_is_initialized_and_idempotent(self) -> None:
        payload = {
            "account_id": "123456",
            "grant_id": "11111111-1111-1111-1111-111111111111",
            "reward_id": "test_reward",
            "definition_version": 1,
            "amount": 1,
        }
        first = self.application.grant_out_of_match_reward(payload)
        second = self.application.grant_out_of_match_reward(payload)
        self.assertFalse(first["duplicate"])
        self.assertEqual(first, second)
        names = [name for name, _ in self.rpc.calls]
        self.assertEqual(names[-4:], [
            "ensure_player_gameplay_stats", "grant_out_of_match_reward",
            "ensure_player_gameplay_stats", "grant_out_of_match_reward",
        ])
        grant_payload = self.rpc.calls[-1][1]
        self.assertEqual(grant_payload["p_account_id"],
                         self.application._database_account_id("123456"))

    def test_out_of_match_grant_conflicting_retry_is_rejected(self) -> None:
        base = {
            "account_id": "123456",
            "grant_id": "22222222-2222-2222-2222-222222222222",
            "reward_id": "test_reward",
            "definition_version": 1,
            "amount": 1,
        }
        self.application.grant_out_of_match_reward(base)
        conflict = dict(base, amount=2)
        with self.assertRaisesRegex(ApiError, "grant_id_conflict"):
            self.application.grant_out_of_match_reward(conflict)

    def test_out_of_match_grant_rejects_non_integer_payload(self) -> None:
        base = {
            "account_id": "123456",
            "grant_id": "33333333-3333-3333-3333-333333333333",
            "reward_id": "test_reward",
            "definition_version": 1,
            "amount": 1,
        }
        with self.assertRaisesRegex(ApiError, "grant_numeric_payload_invalid"):
            self.application.grant_out_of_match_reward(dict(base, amount=1.5))
        with self.assertRaisesRegex(ApiError, "grant_numeric_payload_invalid"):
            self.application.grant_out_of_match_reward(dict(base, definition_version=True))
    def test_account_id_pepper_changes_database_identity(self) -> None:
        first = self.application._database_account_id("123456")
        other = FishingApplication(
            "x" * 32, "q" * 32, definitions(), self.rpc
        )._database_account_id("123456")
        self.assertRegex(first, r"^[0-9a-f]{64}$")
        self.assertNotEqual(first, other)

    def test_rejects_untrusted_identity_shapes(self) -> None:
        with self.assertRaises(ApiError):
            self.application.profile({"account_id": "mock_account_1"})
        with self.assertRaises(ApiError):
            self.application.heartbeat({
                "account_id": "123",
                "session_id": "short",
                "request_id": "request:123",
            })


class OnlineSecondsSemanticsTests(unittest.TestCase):
    class Timer:
        def __init__(self, lease_seconds: int = 15) -> None:
            self.lease_seconds = lease_seconds
            self.session_id: str | None = None
            self.last_heartbeat_at: float | None = None
            self.responses: dict[str, int] = {}
            self.total = 0

        def heartbeat(self, session_id: str, request_id: str, now: float) -> int:
            if request_id in self.responses:
                return self.responses[request_id]
            elapsed = 0
            if self.last_heartbeat_at is not None:
                delta = now - self.last_heartbeat_at
                if (self.session_id != session_id
                        and 0 <= delta <= self.lease_seconds):
                    raise ValueError("fishing_session_active")
                if self.session_id == session_id and 0 <= delta <= self.lease_seconds:
                    elapsed = math.floor(delta)
            self.session_id = session_id
            self.last_heartbeat_at = now
            self.total += elapsed
            self.responses[request_id] = elapsed
            return elapsed

    def test_first_and_valid_adjacent_heartbeat(self) -> None:
        timer = self.Timer()
        self.assertEqual(timer.heartbeat("session-a", "request-1", 100), 0)
        self.assertEqual(timer.heartbeat("session-a", "request-2", 105.9), 5)
        self.assertEqual(timer.total, 5)

    def test_duplicate_request_does_not_advance_or_increment(self) -> None:
        timer = self.Timer()
        timer.heartbeat("session-a", "request-1", 100)
        self.assertEqual(timer.heartbeat("session-a", "request-2", 105), 5)
        self.assertEqual(timer.heartbeat("session-a", "request-2", 110), 5)
        self.assertEqual(timer.last_heartbeat_at, 105)
        self.assertEqual(timer.total, 5)

    def test_new_session_is_rejected_during_active_lease(self) -> None:
        timer = self.Timer()
        timer.heartbeat("session-a", "request-1", 100)
        with self.assertRaisesRegex(ValueError, "fishing_session_active"):
            timer.heartbeat("session-b", "request-2", 110)
        self.assertEqual(timer.total, 0)

    def test_same_session_after_lease_does_not_count_gap(self) -> None:
        timer = self.Timer()
        timer.heartbeat("session-a", "request-1", 100)
        self.assertEqual(timer.heartbeat("session-a", "request-2", 116), 0)
        self.assertEqual(timer.total, 0)

    def test_new_session_after_lease_does_not_count_gap(self) -> None:
        timer = self.Timer()
        timer.heartbeat("session-a", "request-1", 100)
        self.assertEqual(timer.heartbeat("session-b", "request-2", 116), 0)
        self.assertEqual(timer.total, 0)


class HttpTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rpc = FakeRpc()
        application = FishingApplication(
            "z" * 32, "p" * 32, definitions(), self.rpc
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(application))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, method: str, path: str, body: object | None = None,
                token: str | None = None) -> tuple[int, dict[str, object]]:
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=2
        )
        headers = {}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if token is not None:
            headers["Authorization"] = token
        connection.request(method, path, body=data, headers=headers)
        response = connection.getresponse()
        payload = json.loads(response.read().decode())
        connection.close()
        return response.status, payload

    def test_health_and_authenticated_profile(self) -> None:
        status, payload = self.request("GET", "/health")
        self.assertEqual((status, payload["ok"]), (200, True))
        status, payload = self.request("POST", "/v1/profile", {"account_id": "123"})
        self.assertEqual((status, payload["error"]), (401, "unauthorized"))
        status, payload = self.request(
            "POST", "/v1/profile", {"account_id": "123"}, "Bearer " + "z" * 32
        )
        self.assertEqual((status, payload["account_id"]), (200, "123"))


    def test_authenticated_out_of_match_grant_route_and_validation(self) -> None:
        token = "Bearer " + "z" * 32
        body = {
            "account_id": "123",
            "grant_id": "44444444-4444-4444-4444-444444444444",
            "reward_id": "test_reward",
            "definition_version": 1,
            "amount": 1,
        }
        status, payload = self.request(
            "POST", "/v1/rewards/grant", body, token
        )
        self.assertEqual((status, payload["ok"]), (200, True))
        self.assertEqual(payload["profile"]["account_id"], "123")
        status, payload = self.request(
            "POST", "/v1/rewards/grant", dict(body, amount=1.5), token
        )
        self.assertEqual(
            (status, payload["error"]),
            (400, "grant_numeric_payload_invalid"),
        )
if __name__ == "__main__":
    unittest.main()