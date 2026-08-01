"""
data.py - Fetches recovery data from Supabase.
Apple Health data is written to Supabase via the health webhook in webhook.py.
Falls back to mock data if no real data exists yet.
"""

import logging
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from settings import get_settings

log = logging.getLogger(__name__)


_supabase_client = None


def get_supabase():
    """Return a cached Supabase client (one per process)."""
    global _supabase_client
    if _supabase_client is not None:
        return _supabase_client

    from supabase import create_client

    settings = get_settings()
    if not settings.supabase_url or not settings.supabase_key:
        return None
    _supabase_client = create_client(settings.supabase_url, settings.supabase_key)
    return _supabase_client


# The resistance rotation. It rolls continuously — Cardio+Abs is followed
# straight back into Pull — and is NOT interrupted by yoga.
CYCLE = ["Pull", "Push", "Legs", "Cardio+Abs"]

# Yoga is active recovery pinned to Sunday, not a rotation position. It used
# to be the fifth entry in CYCLE, which made it fire every fifth day and drift
# through the week; the athlete trains daily and takes yoga on Sunday whatever
# the rotation happens to be showing. Sunday therefore OVERRIDES the session
# type without consuming a rotation slot: a Saturday Pull is followed by a
# Monday Push, with the yoga day passing over the top.
YOGA_WEEKDAY = 6  # Monday=0 … Sunday=6, matching datetime.weekday()
YOGA_SESSION_TYPE = "Yoga"


def is_yoga_day(when=None) -> bool:
    """True when the given (or current) local date falls on the yoga day."""
    return (when or now_local()).weekday() == YOGA_WEEKDAY


def session_type_for(mesocycle_day: int, when=None) -> str:
    """Today's session type: the rotation, with Sunday overriding it."""
    if is_yoga_day(when):
        return YOGA_SESSION_TYPE
    return CYCLE[(mesocycle_day - 1) % len(CYCLE)]


def next_session_type_for(mesocycle_day: int, when=None) -> str:
    """Tomorrow's session type.

    Three cases, and the middle one is the reason this isn't a one-liner:
    tomorrow is the yoga day; today IS the yoga day, so the rotation position
    that Sunday passed over is what comes next; or the ordinary case of
    stepping one along the rotation.
    """
    today = when or now_local()
    tomorrow = today + timedelta(days=1)
    if is_yoga_day(tomorrow):
        return YOGA_SESSION_TYPE
    if is_yoga_day(today):
        return CYCLE[(mesocycle_day - 1) % len(CYCLE)]
    return CYCLE[mesocycle_day % len(CYCLE)]


def get_app_timezone() -> ZoneInfo:
    timezone_name = get_settings().app_timezone
    try:
        return ZoneInfo(timezone_name)
    except Exception:
        return ZoneInfo("Australia/Sydney")


def now_local() -> datetime:
    return datetime.now(get_app_timezone())


def today_local_str() -> str:
    """Return today's date as YYYY-MM-DD in the app timezone."""
    return now_local().strftime("%Y-%m-%d")


def _derive_sleep_quality(sleep_hours) -> str:
    """Derive a sleep quality label from hours slept."""
    if sleep_hours is None:
        return "Unknown"
    try:
        hours = float(sleep_hours)
    except (TypeError, ValueError):
        return "Unknown"
    if hours >= 7.5:
        return "Good"
    elif hours >= 6.0:
        return "Average"
    elif hours >= 4.5:
        return "Poor"
    else:
        return "Very Poor"


def _pick_recovery_row(rows: list[dict]) -> dict | None:
    for row in rows:
        if any(row.get(field) is not None for field in ["sleep_hours", "hrv", "resting_hr"]):
            return row
    return rows[0] if rows else None


def _data_age_days(row_date) -> int | None:
    """How many days old the recovery row is relative to today (local)."""
    if not row_date:
        return None
    try:
        d = datetime.strptime(str(row_date), "%Y-%m-%d").date()
    except (TypeError, ValueError):
        return None
    return (now_local().date() - d).days


def get_athlete_context() -> dict:
    """
    Returns the most recent recovery data up to today's local date.
    Falls back to mock data if Supabase isn't connected or no data exists yet.
    """
    supabase = get_supabase()

    if not supabase:
        print("No Supabase credentials. Using mock data.")
        return get_mock_data()

    try:
        today = now_local().strftime("%Y-%m-%d")

        result = (
            supabase.table("recovery")
            .select("*")
            .lte("date", today)
            .order("date", desc=True)
            .limit(3)
            .execute()
        )

        row = _pick_recovery_row(result.data or [])
        if not row:
            print("No recovery data found. Using mock data.")
            return get_mock_data()

        seven_days_ago = (now_local() - timedelta(days=7)).strftime("%Y-%m-%d")
        hrv_result = (
            supabase.table("recovery")
            .select("hrv")
            .gte("date", seven_days_ago)
            .lte("date", today)
            .execute()
        )
        hrv_readings = [
            r["hrv"] for r in (hrv_result.data or [])
            if isinstance(r, dict) and r.get("hrv") is not None
        ]
        hrv_avg = round(sum(hrv_readings) / len(hrv_readings), 1) if hrv_readings else "N/A"

        rhr_result = (
            supabase.table("recovery")
            .select("resting_hr")
            .gte("date", seven_days_ago)
            .lte("date", today)
            .execute()
        )
        rhr_readings = [
            r["resting_hr"] for r in (rhr_result.data or [])
            if isinstance(r, dict) and r.get("resting_hr") is not None
        ]
        rhr_baseline = round(sum(rhr_readings) / len(rhr_readings), 1) if rhr_readings else "N/A"

        sleep_hours = row.get("sleep_hours")
        sleep_quality = _derive_sleep_quality(sleep_hours)

        def _v(field):
            value = row.get(field)
            return value if value is not None else "N/A"

        return {
            "date": row.get("date", today),
            "data_age_days": _data_age_days(row.get("date")),
            "sleep_hours": sleep_hours if sleep_hours is not None else "N/A",
            "sleep_quality": sleep_quality,
            "hrv": row.get("hrv", "N/A"),
            "hrv_avg": hrv_avg,
            "hrv_status": row.get("hrv_status", "Unknown"),
            "resting_hr": row.get("resting_hr", "N/A"),
            "resting_hr_baseline": rhr_baseline,
            "heart_rate": _v("heart_rate"),
            "steps": _v("steps"),
            "active_energy_kcal": _v("active_energy_kcal"),
            "exercise_minutes": _v("exercise_minutes"),
            "respiratory_rate": _v("respiratory_rate"),
            "weight_kg": _v("weight_kg"),
            "body_fat_pct": _v("body_fat_pct"),
            "vo2_max": _v("vo2_max"),
        }
    except Exception:
        log.exception("Supabase data fetch failed; using mock data")
        return get_mock_data()


def get_mock_data() -> dict:
    """Mock data for testing before Apple Health is connected."""
    return {
        "date": now_local().strftime("%Y-%m-%d"),
        "data_age_days": 0,
        "sleep_hours": 6.5,
        "sleep_quality": "Average",
        "hrv": 58,
        "hrv_avg": 62,
        "hrv_status": "Suppressed",
        "resting_hr": 54,
        "resting_hr_baseline": 52,
        "heart_rate": 68,
        "steps": 8200,
        "active_energy_kcal": 540,
        "exercise_minutes": 42,
        "respiratory_rate": 14.5,
        "weight_kg": 82,
        "body_fat_pct": 18.5,
        "vo2_max": 44,
    }
