"""
parse_health.py - Parse Health Auto Export payloads into flat daily summaries.
"""

from datetime import datetime, timedelta


def _coerce_date(value) -> str | None:
    if not value:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).strftime("%Y-%m-%d")
    except Exception:
        pass
    try:
        return datetime.strptime(text[:10], "%Y-%m-%d").strftime("%Y-%m-%d")
    except Exception:
        return None


def _latest_metric_date(metrics: list) -> str | None:
    dates = []
    for metric in metrics:
        for point in metric.get("data", []):
            parsed = _coerce_date(point.get("date"))
            if parsed:
                dates.append(parsed)
    return max(dates) if dates else None


def parse_health_export(payload: dict) -> dict:
    try:
        metrics = payload.get("data", {}).get("metrics", [])
        if not metrics:
            return parse_flat_format(payload)
    except Exception:
        return parse_flat_format(payload)

    metric_data = {}
    for metric in metrics:
        metric_data[metric.get("name", "")] = metric.get("data", [])

    target_date = (
        _coerce_date(payload.get("date"))
        or _latest_metric_date(metrics)
        or datetime.now().strftime("%Y-%m-%d")
    )
    fallback_date = (
        datetime.strptime(target_date, "%Y-%m-%d") - timedelta(days=1)
    ).strftime("%Y-%m-%d")

    def get_qty_values(data_points, desired_date):
        values = []
        for point in data_points:
            if _coerce_date(point.get("date")) != desired_date:
                continue
            qty = point.get("qty")
            if qty is None:
                continue
            try:
                values.append(float(qty))
            except Exception:
                continue
        return values

    def latest_qty(data_points):
        valid = []
        for point in data_points:
            qty = point.get("qty")
            if qty is None:
                continue
            try:
                valid.append((_coerce_date(point.get("date")) or "", float(qty)))
            except Exception:
                continue
        if not valid:
            return None
        valid.sort(key=lambda x: x[0], reverse=True)
        return valid[0][1]

    def get_daily_values(name):
        values = get_qty_values(metric_data.get(name, []), target_date)
        if not values:
            values = get_qty_values(metric_data.get(name, []), fallback_date)
        return values

    hrv_vals = get_daily_values("heart_rate_variability")
    hrv = round(sum(hrv_vals) / len(hrv_vals), 1) if hrv_vals else None

    rhr_vals = get_daily_values("resting_heart_rate")
    resting_hr = rhr_vals[-1] if rhr_vals else latest_qty(metric_data.get("resting_heart_rate", []))

    hr_vals = get_daily_values("heart_rate")
    heart_rate = round(sum(hr_vals) / len(hr_vals), 1) if hr_vals else None

    sleep_raw = metric_data.get("sleep_analysis", [])
    sleep_hours = None
    if sleep_raw:
        matching = [
            point for point in sleep_raw
            if _coerce_date(point.get("date")) in {target_date, fallback_date}
        ]
        latest_sleep = sorted(
            matching or sleep_raw,
            key=lambda x: x.get("date", ""),
            reverse=True,
        )[0]
        total = latest_sleep.get("totalSleep")
        if total:
            sleep_hours = round(float(total), 2)

    steps_vals = get_daily_values("step_count")
    steps = int(sum(steps_vals)) if steps_vals else None

    energy_vals = get_daily_values("active_energy")
    active_energy = round(sum(energy_vals) / 4.184, 1) if energy_vals else None

    weight_raw = latest_qty(metric_data.get("weight_body_mass", []))
    if weight_raw is None:
        weight_raw = latest_qty(metric_data.get("body_mass", []))
    weight_kg = round(weight_raw / 2.205, 2) if weight_raw and weight_raw > 150 else weight_raw

    bf_raw = latest_qty(metric_data.get("body_fat_percentage", []))
    body_fat_pct = round(bf_raw * 100, 1) if bf_raw and bf_raw < 1 else bf_raw

    exercise_vals = get_daily_values("apple_exercise_time")
    exercise_minutes = int(sum(exercise_vals)) if exercise_vals else None

    resp_vals = get_daily_values("respiratory_rate")
    respiratory_rate = round(sum(resp_vals) / len(resp_vals), 1) if resp_vals else None

    vo2_max = latest_qty(metric_data.get("vo2_max", []))

    return {
        "date": target_date,
        "sleep_hours": sleep_hours,
        "hrv": hrv,
        "resting_hr": resting_hr,
        "heart_rate": heart_rate,
        "steps": steps,
        "active_energy_kcal": active_energy,
        "weight_kg": weight_kg,
        "body_fat_pct": body_fat_pct,
        "exercise_minutes": exercise_minutes,
        "respiratory_rate": respiratory_rate,
        "vo2_max": vo2_max,
    }


def parse_flat_format(payload: dict) -> dict:
    """Handle flat JSON format as fallback."""

    def safe_float(val):
        try:
            return float(val)
        except Exception:
            return None

    weight_raw = safe_float(payload.get("weight_kg"))
    weight_kg = round(weight_raw / 2.205, 2) if weight_raw and weight_raw > 150 else weight_raw

    exercise_minutes = safe_float(payload.get("exercise_minutes"))

    body_fat_raw = safe_float(payload.get("body_fat_pct"))
    body_fat_pct = round(body_fat_raw * 100, 1) if body_fat_raw and body_fat_raw < 1 else body_fat_raw

    return {
        "date": _coerce_date(payload.get("date")) or datetime.now().strftime("%Y-%m-%d"),
        "sleep_hours": safe_float(payload.get("sleep_hours")),
        "hrv": safe_float(payload.get("hrv")),
        "resting_hr": safe_float(payload.get("resting_hr")),
        "heart_rate": safe_float(payload.get("heart_rate")),
        "steps": safe_float(payload.get("steps")),
        "active_energy_kcal": safe_float(payload.get("active_energy_kcal")),
        "weight_kg": weight_kg,
        "body_fat_pct": body_fat_pct,
        "exercise_minutes": exercise_minutes,
        "respiratory_rate": safe_float(payload.get("respiratory_rate")),
        "vo2_max": safe_float(payload.get("vo2_max")),
    }
