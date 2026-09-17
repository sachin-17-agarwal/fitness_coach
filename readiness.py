"""The readiness score, computed on the server.

A port of `Recovery.compositeScore` in the iOS app (Models/Recovery.swift),
kept identical on purpose: the widget reads its number from here without the
app running, and the Home tab computes the same formula on the phone. The two
must agree to the point, so the anchors below are the Swift anchors and the
tests pin them. Change both or neither.

Weights: sleep 0.40, HRV against the 7-day mean 0.40, resting HR against the
7-day mean 0.20; a missing input drops out and the rest renormalise.
"""

from __future__ import annotations

from datetime import timedelta

from data import get_supabase, now_local

GREEN_AT = 75
YELLOW_AT = 55


def _interp(x: float, x0: float, x1: float, y0: float, y1: float) -> float:
    t = (x - x0) / (x1 - x0)
    return y0 + t * (y1 - y0)


def sleep_component(hours: float) -> float:
    """8h+ → 100, 7.5h → 92, 7h → 82, 6h → 58, 5h → 32, 4h → 15, <4h trails to 0."""
    if hours >= 8:
        return 100.0
    if hours >= 7.5:
        return _interp(hours, 7.5, 8.0, 92, 100)
    if hours >= 7.0:
        return _interp(hours, 7.0, 7.5, 82, 92)
    if hours >= 6.0:
        return _interp(hours, 6.0, 7.0, 58, 82)
    if hours >= 5.0:
        return _interp(hours, 5.0, 6.0, 32, 58)
    if hours >= 4.0:
        return _interp(hours, 4.0, 5.0, 15, 32)
    if hours >= 3.0:
        return _interp(hours, 3.0, 4.0, 5, 15)
    return max(0.0, hours * 1.5)


def hrv_component(ratio: float) -> float:
    """HRV today over the 7-day mean; higher is better."""
    if ratio >= 1.10:
        return 100.0
    if ratio >= 1.00:
        return _interp(ratio, 1.00, 1.10, 85, 100)
    if ratio >= 0.90:
        return _interp(ratio, 0.90, 1.00, 65, 85)
    if ratio >= 0.80:
        return _interp(ratio, 0.80, 0.90, 40, 65)
    if ratio >= 0.70:
        return _interp(ratio, 0.70, 0.80, 20, 40)
    if ratio >= 0.60:
        return _interp(ratio, 0.60, 0.70, 10, 20)
    return 5.0


def rhr_component(ratio: float) -> float:
    """Resting HR today over the 7-day mean; lower is better."""
    if ratio < 0.95:
        return 100.0
    if ratio < 1.00:
        return _interp(ratio, 0.95, 1.00, 100, 85)
    if ratio < 1.05:
        return _interp(ratio, 1.00, 1.05, 85, 65)
    if ratio < 1.10:
        return _interp(ratio, 1.05, 1.10, 65, 40)
    if ratio < 1.15:
        return _interp(ratio, 1.10, 1.15, 40, 20)
    return 10.0


def composite_score(sleep_hours, hrv, hrv_avg, resting_hr, rhr_avg) -> int | None:
    """0–100, or None when no input is present."""
    weighted = 0.0
    total = 0.0
    if sleep_hours is not None:
        weighted += sleep_component(float(sleep_hours)) * 0.40
        total += 0.40
    if hrv is not None and hrv_avg and hrv_avg > 0:
        weighted += hrv_component(float(hrv) / float(hrv_avg)) * 0.40
        total += 0.40
    if resting_hr is not None and rhr_avg and rhr_avg > 0:
        weighted += rhr_component(float(resting_hr) / float(rhr_avg)) * 0.20
        total += 0.20
    if total <= 0:
        return None
    score = weighted / total
    return min(100, max(0, int(round(score))))


def level_for(score: int | None) -> str:
    """green | yellow | red | unknown — the Home tab's zones."""
    if score is None:
        return "unknown"
    if score >= GREEN_AT:
        return "green"
    if score >= YELLOW_AT:
        return "yellow"
    return "red"


def _mean(values: list) -> float | None:
    nums = [float(v) for v in values if v is not None]
    return sum(nums) / len(nums) if nums else None


def readiness_from_rows(latest: dict | None, week_rows: list[dict]) -> dict:
    """The score and its inputs from a latest row and the trailing week."""
    latest = latest or {}
    hrv_avg = _mean([r.get("hrv") for r in week_rows])
    rhr_avg = _mean([r.get("resting_hr") for r in week_rows])
    score = composite_score(latest.get("sleep_hours"), latest.get("hrv"), hrv_avg,
                            latest.get("resting_hr"), rhr_avg)
    hrv = latest.get("hrv")
    rhr = latest.get("resting_hr")
    return {
        "date": str(latest.get("date") or "") or None,
        "score": score,
        "level": level_for(score),
        "hrv": hrv,
        "hrv_delta": int(round(float(hrv) - hrv_avg)) if hrv is not None and hrv_avg else None,
        "sleep_hours": latest.get("sleep_hours"),
        "resting_hr": rhr,
        "rhr_delta": int(round(float(rhr) - rhr_avg)) if rhr is not None and rhr_avg else None,
    }


def readiness_today() -> dict:
    """Today's readiness from the recovery table, the way the Home tab reads it:
    the newest row on or before today, against the rows of the last seven
    days (`date >= today - 7`, the app's window)."""
    supabase = get_supabase()
    if not supabase:
        return readiness_from_rows(None, [])
    today = now_local().strftime("%Y-%m-%d")
    since = (now_local() - timedelta(days=7)).strftime("%Y-%m-%d")
    cols = "date, hrv, resting_hr, sleep_hours"
    recent = (supabase.table("recovery").select(cols).lte("date", today)
              .order("date", desc=True).limit(7).execute().data or [])
    week = (supabase.table("recovery").select(cols).gte("date", since)
            .order("date", desc=True).execute().data or [])
    return readiness_from_rows(latest_with_readings(recent), week)


def latest_with_readings(rows: list[dict]) -> dict | None:
    """The newest row that carries a reading. A morning weigh-in writes
    today's row with weight alone, hours before the Health export delivers
    HRV and sleep; taking that row as "today" read as no recovery data at
    all. Yesterday's read, labelled as such, is the honest answer."""
    for row in rows:
        if any(row.get(k) is not None for k in ("hrv", "sleep_hours", "resting_hr")):
            return row
    return None
