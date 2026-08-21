from __future__ import annotations

import csv
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class DefinitionError(ValueError):
    pass


@dataclass(frozen=True)
class DefinitionSet:
    version: int
    digest: str
    rows: list[dict[str, Any]]


@dataclass(frozen=True)
class FishingRule:
    heartbeat_lease_seconds: int
    interval_min_seconds: int
    interval_max_seconds: int
    definition_version: int


def _number(raw: str, field: str) -> float:
    try:
        return float(raw)
    except ValueError as exc:
        raise DefinitionError(f"invalid {field}: {raw}") from exc


def load_definitions(path: Path) -> DefinitionSet:
    rows: list[dict[str, Any]] = []
    versions: set[int] = set()
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        for raw in csv.DictReader(source):
            reward_id = (raw.get("reward_id") or "").strip()
            if not reward_id or reward_id.startswith("#"):
                continue
            if (raw.get("enabled") or "").strip().lower() not in {
                "1", "true", "yes", "on"
            }:
                continue
            version = int(raw["definition_version"])
            versions.add(version)
            weight = _number(raw["weight"], "weight")
            value_min = _number(raw["value_min"], "value_min")
            value_max = _number(raw["value_max"], "value_max")
            effect_scope = raw["effect_scope"].strip()
            stacking_rule = raw["stacking_rule"].strip()
            cap_raw = (raw.get("cap_value") or "").strip()
            if weight <= 0 or value_max < value_min:
                raise DefinitionError(f"invalid numeric range for {reward_id}")
            if not value_min.is_integer() or not value_max.is_integer():
                raise DefinitionError(f"reward values must be integers for {reward_id}")
            if effect_scope not in {"immediate", "permanent"}:
                raise DefinitionError(f"invalid effect_scope for {reward_id}")
            if stacking_rule not in {"add", "max"}:
                raise DefinitionError(f"invalid stacking_rule for {reward_id}")
            rows.append({
                "reward_id": reward_id,
                "display_name": raw["display_name"].strip(),
                "weight": weight,
                "effect_key": raw["effect_key"].strip(),
                "effect_scope": effect_scope,
                "value_min": value_min,
                "value_max": value_max,
                "stacking_rule": stacking_rule,
                "cap_value": _number(cap_raw, "cap_value") if cap_raw else None,
            })
    if not rows:
        raise DefinitionError("enabled fishing reward definition missing")
    if len(versions) != 1:
        raise DefinitionError("enabled rewards must share one definition_version")
    rows.sort(key=lambda row: row["reward_id"])
    canonical = json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return DefinitionSet(versions.pop(), hashlib.sha256(canonical.encode()).hexdigest(), rows)


def load_rule(path: Path) -> FishingRule:
    enabled: list[dict[str, str]] = []
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            rule_id = (row.get("fishing_rule_id") or "").strip()
            if not rule_id or rule_id.startswith("#"):
                continue
            if (row.get("enabled") or "").strip().lower() in {
                "1", "true", "yes", "on"
            }:
                enabled.append(row)
    if len(enabled) != 1:
        raise DefinitionError("exactly one fishing rule must be enabled")
    row = enabled[0]
    try:
        rule = FishingRule(
            heartbeat_lease_seconds=int(row["heartbeat_lease_seconds"]),
            interval_min_seconds=int(row["reward_interval_min_seconds"]),
            interval_max_seconds=int(row["reward_interval_max_seconds"]),
            definition_version=int(row["definition_version"]),
        )
    except ValueError as exc:
        raise DefinitionError("fishing rule contains an invalid integer") from exc
    if rule.heartbeat_lease_seconds < 1 or rule.interval_min_seconds < 1 \
            or rule.interval_max_seconds < rule.interval_min_seconds:
        raise DefinitionError("fishing rule interval is invalid")
    return rule