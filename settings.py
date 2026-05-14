"""
settings.py — Typed configuration loaded from environment variables.

Centralises every os.environ.get() lookup so defaults, types, and required
fields live in one place. Construction is cheap (just reads env), so call
get_settings() per request when you need an up-to-date snapshot.
"""

from typing import Optional

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Anthropic
    anthropic_api_key: Optional[str] = None

    # Supabase
    supabase_url: Optional[str] = None
    supabase_key: Optional[str] = None

    # Webhook auth
    app_api_token: str = ""
    health_webhook_token: str = ""

    # Telegram
    telegram_bot_token: str = ""
    telegram_chat_id: str = ""

    # Server
    port: int = 5000
    app_timezone: str = "Australia/Sydney"
    log_level: str = "INFO"

    # Athlete profile (used in coach context block)
    athlete_name: str = "Athlete"
    athlete_current_weight_kg: int = 0
    athlete_goal_weight_kg: int = 0


def get_settings() -> Settings:
    """Return a fresh Settings instance.

    Not cached so that env vars patched in tests are picked up. Construction
    is microseconds — there's no perf reason to cache.
    """
    return Settings()
