from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class GameplayStatsError(ValueError):
    pass


@dataclass(frozen=True)
class GameplayStatsDefinition:
    field_id: str
    storage_type: str
    default_value: int | float
    min_value: int | float | None
    max_value: int | float | None


def _number(raw: str, field: str) -> int | float:
    try:
        value = float(raw)
    except ValueError as exc:
        raise GameplayStatsError(f"invalid {field}: {raw}") from exc
    return int(value) if value.is_integer() else value


def load_gameplay_stats(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {}
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        required = {
            "field_id", "storage_type", "default_value", "unit",
            "min_value", "max_value", "enabled",
        }
        if not reader.fieldnames or not required.issubset(reader.fieldnames):
            raise GameplayStatsError("gameplay stats CSV schema invalid")
        for row in reader:
            field_id = (row.get("field_id") or "").strip()
            if not field_id or field_id.startswith("#"):
                continue
            enabled = (row.get("enabled") or "").strip().lower()
            if enabled in {"0", "false", "no", "off"}:
                continue
            if field_id in result:
                raise GameplayStatsError(f"duplicate gameplay stat: {field_id}")
            storage_type = (row.get("storage_type") or "").strip()
            if storage_type not in {"integer", "decimal", "percentage"}:
                raise GameplayStatsError(f"invalid storage_type: {field_id}")
            value = _number((row.get("default_value") or "").strip(), field_id)
            minimum = ((row.get("min_value") or "").strip())
            maximum = ((row.get("max_value") or "").strip())
            min_value = _number(minimum, f"{field_id}.min_value") if minimum else None
            max_value = _number(maximum, f"{field_id}.max_value") if maximum else None
            if storage_type == "integer" and not isinstance(value, int):
                raise GameplayStatsError(f"integer default is not integral: {field_id}")
            if min_value is not None and value < min_value:
                raise GameplayStatsError(f"default below minimum: {field_id}")
            if max_value is not None and value > max_value:
                raise GameplayStatsError(f"default above maximum: {field_id}")
            result[field_id] = value
    if len(result) != 38:
        raise GameplayStatsError(f"expected 38 gameplay stats plus player_id, got {len(result)}")
    return result