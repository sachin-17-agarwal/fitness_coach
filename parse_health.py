"""
parse_health.py — Parse Health Auto Export v2 JSON format into flat daily summaries.
"""

from datetime import datetime, timedelta
from collections import defaultdict

def parse_health_export(payload: dict) -> dict:
    """
    Parse Health Auto Export REST API v2 format into a flat daily summary.
    
    Input format:
    {
        "data": {
            "metrics": [
                {
                    "name": "heart_rate_variability",
                    "units": "ms",
                    "data": [
                        {"qty": 46.7, "date": "2026-03-10 06:54:00 +1100"},
                        ...
                    ]
                },
                ...
            ]
        }
    }
    """
    try:
        metrics = payload.get("data", {}).get("metrics", [])
        if not metrics:
            # Try flat format (old style)
            return parse_flat_format(payload)
    except:
        return parse_flat_format(payload)

    # Group data by metric name
    metric_data = {}
    for metric in metrics:
        name = metric.get("name", "")
        data = metric.get("data", [])
        metric_data[name] = data

    # Determine target date — use today's date in local time
    today = datetime.now().strftime("%Y-%m-%d")

    def get_values_for_date(data_points, target_date, metric_type="latest"):
        """Extract values for a specific date from data points."""
        values = []
        for point in data_points:
            raw_date = point.get("date", "")
            # Parse date handling timezone offset
            try:
                dt = datetime.strptime(raw_date[:19], "%Y-%m-%d %H:%M:%S")
                point_date = dt.strftime("%Y-%m-%d")
            except:
                continue
            if point_date == target_date:
                qty = point.get("qty")
                if qty is not None:
                    values.append(float(qty))
        return values

    def latest_value(data_points):
        """Get the most recent value regardless of date."""
        valid = [(p.get("date", ""), p.get("qty")) for p in data_points if p.get("qty") is not None]
        if not valid:
            return None
        valid.sort(key=lambda x: x[0], reverse=True)
        return float(valid[0][1])

    # HRV — average of today's readings
    hrv_vals = get_values_for_date(metric_data.get("heart_rate_variability", []), today)
    hrv = round(sum(hrv_vals) / len(hrv_vals), 1) if hrv_vals else None

    # Resting HR — latest reading for today
    rhr_vals = get_values_for_date(metric_data.get("resting_heart_rate", []), today)
    resting_hr = rhr_vals[-1] if rhr_vals else latest_value(metric_data.get("resting_heart_rate", []))

    # Heart rate — average for today
    hr_vals = get_values_for_date(metric_data.get("heart_rate", []), today)
    heart_rate = round(sum(hr_vals) / len(hr_vals), 1) if hr_vals else None

    # Sleep — sum of asleep duration for last night
    # Sleep Analysis sends duration in hours for each segment
    sleep_vals = get_values_for_date(metric_data.get("sleep_analysis", []), today)
    # Also check yesterday since sleep spans midnight
    yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    sleep_vals_yesterday = get_values_for_date(metric_data.get("sleep_analysis", []), yesterday)
    all_sleep = sleep_vals + sleep_vals_yesterday
    sleep_hours = round(sum(all_sleep), 2) if all_sleep else None

    # Steps — sum for today
    steps_vals = get_values_for_date(metric_data.get("step_count", []), today)
    steps = int(sum(steps_vals)) if steps_vals else None

    # Active energy — sum for today, convert kJ to kcal if needed
    energy_vals = get_values_for_date(metric_data.get("active_energy", []), today)
    active_energy = None
    if energy_vals:
        total = sum(energy_vals)
        # Health Auto Export sends in kJ, convert to kcal
        active_energy = round(total / 4.184, 1)

    # Weight — latest reading
    weight_raw = latest_value(metric_data.get("body_mass", []))
    weight_kg = round(weight_raw / 2.205, 2) if weight_raw and weight_raw > 150 else weight_raw

    # Body fat — latest reading, convert decimal to percentage
    bf_raw = latest_value(metric_data.get("body_fat_percentage", []))
    body_fat_pct = round(bf_raw * 100, 1) if bf_raw and bf_raw < 1 else bf_raw

    # Exercise minutes — sum for today
    exercise_vals = get_values_for_date(metric_data.get("apple_exercise_time", []), today)
    exercise_minutes = int(sum(exercise_vals)) if exercise_vals else None

    # Respiratory rate — average for today
    resp_vals = get_values_for_date(metric_data.get("respiratory_rate", []), today)
    respiratory_rate = round(sum(resp_vals) / len(resp_vals), 1) if resp_vals else None

    # VO2 Max — latest
    vo2_max = latest_value(metric_data.get("vo2_max", []))

    return {
        "date": today,
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
    """Handle the old flat JSON format as fallback."""
    def safe_float(val):
        try: return float(val)
        except: return None

    weight_raw = safe_float(payload.get("weight_kg"))
    weight_kg = round(weight_raw / 2.205, 2) if weight_raw and weight_raw > 150 else weight_raw

    exercise_raw = safe_float(payload.get("exercise_minutes"))
    exercise_minutes = round(exercise_raw * 60) if exercise_raw and exercise_raw < 24 else exercise_raw

    body_fat_raw = safe_float(payload.get("body_fat_pct"))
    body_fat_pct = round(body_fat_raw * 100, 1) if body_fat_raw and body_fat_raw < 1 else body_fat_raw

    respiratory = safe_float(payload.get("respiratory_rate") or payload.get("respiratory_minutes"))

    return {
        "date": payload.get("date", datetime.now().strftime("%Y-%m-%d")),
        "sleep_hours": safe_float(payload.get("sleep_hours")),
        "hrv": safe_float(payload.get("hrv")),
        "resting_hr": safe_float(payload.get("resting_hr")),
        "heart_rate": safe_float(payload.get("heart_rate")),
        "steps": safe_float(payload.get("steps")),
        "active_energy_kcal": safe_float(payload.get("active_energy_kcal")),
        "weight_kg": weight_kg,
        "body_fat_pct": body_fat_pct,
        "exercise_minutes": exercise_minutes,
        "respiratory_rate": respiratory,
        "vo2_max": safe_float(payload.get("vo2_max")),
    }
