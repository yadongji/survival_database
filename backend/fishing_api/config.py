from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


DATABASE_ROOT = Path(__file__).resolve().parents[2]


class ConfigError(ValueError):
    pass


def _positive_int(name: str, default: str) -> int:
    try:
        value = int(os.environ.get(name, default))
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer") from exc
    if value <= 0:
        raise ConfigError(f"{name} must be positive")
    return value


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    api_token: str
    supabase_url: str
    supabase_key: str
    account_id_pepper: str
    reward_csv: Path
    rule_csv: Path
    gameplay_stats_csv: Path
    request_timeout_seconds: int

    @classmethod
    def from_env(cls) -> "Settings":
        addon_root_raw = os.environ.get("SURVIVAL_ADDON_ROOT", "")
        addon_root = Path(addon_root_raw).expanduser().resolve() if addon_root_raw else None

        def csv_path(name: str, default: str) -> Path:
            configured = os.environ.get(name, "")
            if configured:
                path = Path(configured).expanduser()
                return (path if path.is_absolute() else DATABASE_ROOT / path).resolve()
            if addon_root is None:
                raise ConfigError("SURVIVAL_ADDON_ROOT is required")
            return (addon_root / default).resolve()

        settings = cls(
            host=os.environ.get("FISHING_API_HOST", "127.0.0.1"),
            port=_positive_int("FISHING_API_PORT", "8765"),
            api_token=os.environ.get("FISHING_API_TOKEN", ""),
            supabase_url=os.environ.get("SUPABASE_URL", "").rstrip("/"),
            supabase_key=(os.environ.get("SUPABASE_SECRET_KEY", "")
                          or os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")),
            account_id_pepper=os.environ.get("FISHING_ACCOUNT_ID_PEPPER", ""),
            reward_csv=csv_path(
                "FISHING_REWARD_CSV",
                "data/csv/玩家档案系统/star_blessing_reward_definitions.csv",
            ),
            rule_csv=csv_path(
                "FISHING_RULE_CSV",
                "data/csv/玩家档案系统/fishing_system_rules.csv",
            ),
            gameplay_stats_csv=csv_path(
                "GAMEPLAY_STATS_CSV",
                "data/csv/玩家档案系统/player_gameplay_stats.csv",
            ),
            request_timeout_seconds=_positive_int(
                "FISHING_REQUEST_TIMEOUT_SECONDS", "20"
            ),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if self.host not in {"127.0.0.1", "localhost", "::1"}:
            raise ConfigError("FISHING_API_HOST must be loopback-only")
        if len(self.api_token) < 24:
            raise ConfigError("FISHING_API_TOKEN must contain at least 24 characters")
        if not self.supabase_url.startswith("https://"):
            raise ConfigError("SUPABASE_URL must use https")
        if not self.supabase_key:
            raise ConfigError("SUPABASE_SECRET_KEY or SUPABASE_SERVICE_ROLE_KEY is required")
        if len(self.account_id_pepper) < 32:
            raise ConfigError("FISHING_ACCOUNT_ID_PEPPER must contain at least 32 characters")
        if not self.reward_csv.is_file():
            raise ConfigError(f"reward CSV not found: {self.reward_csv}")
        if not self.rule_csv.is_file():
            raise ConfigError(f"fishing rule CSV not found: {self.rule_csv}")
        if not self.gameplay_stats_csv.is_file():
            raise ConfigError(f"gameplay stats CSV not found: {self.gameplay_stats_csv}")