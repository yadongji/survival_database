from __future__ import annotations

import hmac
import hashlib
import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Protocol

from .definitions import DefinitionSet


ACCOUNT_ID = re.compile(r"^[0-9]{1,20}$")
OPAQUE_ID = re.compile(r"^[A-Za-z0-9_.:-]{8,128}$")
GRANT_ID = re.compile(r"^[0-9a-fA-F-]{36}$")


class RpcClient(Protocol):
    def rpc(self, function_name: str, payload: dict[str, Any]) -> Any: ...


class ApiError(ValueError):
    def __init__(self, code: str, status: int):
        super().__init__(code)
        self.code = code
        self.status = status


def _string(payload: dict[str, Any], name: str, pattern: re.Pattern[str]) -> str:
    value = payload.get(name)
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ApiError(f"{name}_invalid", 400)
    return value


@dataclass
class FishingApplication:
    token: str
    account_id_pepper: str
    definitions: DefinitionSet
    rpc_client: RpcClient
    gameplay_stats: dict[str, Any] = field(default_factory=dict)
    heartbeat_lease_seconds: int = 15
    interval_min_seconds: int = 60
    interval_max_seconds: int = 600

    def authorized(self, header: str | None) -> bool:
        expected = f"Bearer {self.token}"
        return header is not None and hmac.compare_digest(header, expected)

    def sync_definitions(self) -> Any:
        return self.rpc_client.rpc("sync_fishing_reward_definitions", {
            "p_definition_version": self.definitions.version,
            "p_definition_hash": self.definitions.digest,
            "p_definitions": self.definitions.rows,
        })

    def _database_account_id(self, account_id: str) -> str:
        return hmac.new(
            self.account_id_pepper.encode("utf-8"),
            account_id.encode("ascii"),
            hashlib.sha256,
        ).hexdigest()

    def _ensure_gameplay_stats(self, database_account_id: str) -> Any:
        return self.rpc_client.rpc("ensure_player_gameplay_stats", {
            "p_account_id": database_account_id,
            "p_gameplay_stats": self.gameplay_stats,
        })

    def _public_response(self, value: Any, database_account_id: str,
                         public_account_id: str) -> Any:
        if isinstance(value, dict):
            return {
                key: (public_account_id if key == "account_id"
                      and child == database_account_id else self._public_response(
                          child, database_account_id, public_account_id
                      ))
                for key, child in value.items()
            }
        if isinstance(value, list):
            return [self._public_response(
                child, database_account_id, public_account_id
            ) for child in value]
        return value

    def profile(self, payload: dict[str, Any]) -> Any:
        account_id = _string(payload, "account_id", ACCOUNT_ID)
        database_account_id = self._database_account_id(account_id)
        self._ensure_gameplay_stats(database_account_id)
        response = self.rpc_client.rpc("get_fishing_profile", {
            "p_account_id": database_account_id,
        })
        return self._public_response(response, database_account_id, account_id)

    def grant_out_of_match_reward(self, payload: dict[str, Any]) -> Any:
        account_id = _string(payload, "account_id", ACCOUNT_ID)
        grant_id = _string(payload, "grant_id", GRANT_ID)
        try:
            uuid.UUID(grant_id)
        except ValueError as exc:
            raise ApiError("grant_id_invalid", 400) from exc
        reward_id = _string(payload, "reward_id", OPAQUE_ID)
        definition_version = payload.get("definition_version")
        amount = payload.get("amount")
        if (type(definition_version) is not int or definition_version < 1
                or type(amount) is not int or amount < 0):
            raise ApiError("grant_numeric_payload_invalid", 400)
        database_account_id = self._database_account_id(account_id)
        self._ensure_gameplay_stats(database_account_id)
        response = self.rpc_client.rpc("grant_out_of_match_reward", {
            "p_account_id": database_account_id,
            "p_grant_id": grant_id,
            "p_reward_id": reward_id,
            "p_definition_version": definition_version,
            "p_amount": amount,
        })
        return self._public_response(response, database_account_id, account_id)

    def heartbeat(self, payload: dict[str, Any]) -> Any:
        account_id = _string(payload, "account_id", ACCOUNT_ID)
        database_account_id = self._database_account_id(account_id)
        session_id = _string(payload, "session_id", OPAQUE_ID)
        request_id = _string(payload, "request_id", OPAQUE_ID)
        self._ensure_gameplay_stats(database_account_id)
        response = self.rpc_client.rpc("heartbeat_fishing_session", {
            "p_account_id": database_account_id,
            "p_session_id": session_id,
            "p_request_id": request_id,
            "p_definition_version": self.definitions.version,
            "p_heartbeat_lease_seconds": self.heartbeat_lease_seconds,
            "p_interval_min_seconds": self.interval_min_seconds,
            "p_interval_max_seconds": self.interval_max_seconds,
        })
        return self._public_response(response, database_account_id, account_id)