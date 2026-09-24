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

    # The programme's computed prescription replaces the coach's arithmetic
    # in the reply. Off, the substitution runs in shadow and only logs the
    # difference. This is the go-live switch: a config change, not a deploy.
    programme_substitution: bool = False

    # The session-opening reply is a typed plan (plan.py) rendered into the
    # card's text, with every departure from the programme carrying its
    # reason. Off, the opening is prose as before. Any failure of the plan
    # call falls back to prose on its own.
    plan_contract: bool = True
    # reply_contract.numbers: a number the coach states about a lift must be
    # in the context it was handed, or one rewrite is asked for.
    numbers_contract: bool = True

    # The block's length when the memory row `block_weeks` is not set: 4 on
    # a cut (three loading weeks and a deload), 5 on a bulk (four and one).
    # Changed a few times a year from Settings → Training block in the app.
    block_weeks: int = 5

    # flags.py: with a token, every coach flag is also filed as an issue on
    # this repository. A fine-grained token with issues write, set on the
    # server only.
    github_flags_token: str = ""
    github_flags_repo: str = "sachin-17-agarwal/fitness_coach"

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
