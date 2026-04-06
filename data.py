"""
data.py - Fetches recovery data from Supabase.
Apple Health data is written to Supabase via the health webhook in webhook.py.
Falls back to mock data if no real data exists yet.
"""

import os
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


_supabase_client = None


def get_supabase():
    """Return a cached Supabase client (one per process)."""
    global _supabase_client
    if _supabase_client is not None:
        return _supabase_client

    from supabase import create_client

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_KEY")
    if not url or not key:
        return None
    _supabase_client = create_client(url, key)
    return _supabase_client


CYCLE = ["Pull", "Push", "Legs", "Cardio+Abs", "Yoga"]


def get_app_timezone() -> ZoneInfo:
    timezone_name = os.environ.get("APP_TIMEZONE", "Australia/Sydney")
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
        hrv_readings = [r["hrv"] for r in hrv_result.data if r.get("hrv")]
        hrv_avg = round(sum(hrv_readings) / len(hrv_readings), 1) if hrv_readings else "N/A"

        rhr_result = (
            supabase.table("recovery")
            .select("resting_hr")
            .gte("date", seven_days_ago)
            .lte("date", today)
            .execute()
        )
        rhr_readings = [r["resting_hr"] for r in rhr_result.data if r.get("resting_hr")]
        rhr_baseline = round(sum(rhr_readings) / len(rhr_readings), 1) if rhr_readings else "N/A"

        sleep_hours = row.get("sleep_hours")
        sleep_quality = _derive_sleep_quality(sleep_hours)

        return {
            "date": row.get("date", today),
            "sleep_hours": sleep_hours if sleep_hours is not None else "N/A",
            "sleep_quality": sleep_quality,
            "hrv": row.get("hrv", "N/A"),
            "hrv_avg": hrv_avg,
            "hrv_status": row.get("hrv_status", "Unknown"),
            "resting_hr": row.get("resting_hr", "N/A"),
            "resting_hr_baseline": rhr_baseline,
        }
    except Exception as e:
        print(f"Supabase data fetch failed: {e}. Using mock data.")
        return get_mock_data()


def get_mock_data() -> dict:
    """Mock data for testing before Apple Health is connected."""
    return {
        "date": now_local().strftime("%Y-%m-%d"),
        "sleep_hours": 6.5,
        "sleep_quality": "Average",
        "hrv": 58,
        "hrv_avg": 62,
        "hrv_status": "Suppressed",
        "resting_hr": 54,
        "resting_hr_baseline": 52,
    }
