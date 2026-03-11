"""
parse_health.py — Parse Health Auto Export v2 JSON format into flat daily summaries.
"""

from datetime import datetime, timedelta

def parse_health_export(payload: dict) -> dict:
    try:
        metrics = payload.get("data", {}).get("metrics", [])
        if not metrics:
            return parse_flat_format(payload)
    except:
        return parse_flat_format(payload)

    # Build metric lookup
    metric_data = {}
    for metric in metrics:
        name = metric.get("name", "")
        data = metric.get("data", [])
        metric_data[name] = data
    print(f"Metric names received: {list(metric_data.keys())}")

    # Date references
    today = datetime.now().strftime("%Y-%m-%d")
    yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")

    def get_qty_values(data_points, target_date):
        """Get qty values for a specific date."""
        values = []
        for point in data_points:
            raw_date = point.get("date", "")
            try:
                dt = datetime.strptime(raw_date[:19], "%Y-%m-%d %H:%M:%S")
                if dt.strftime("%Y-%m-%d") == target_date:
                    qty = point.get("qty")
                    if qty is not None:
                        values.append(float(qty))
            except:
                continue
        return values

    def latest_qty(data_points):
        """Get most recent qty value."""
        valid = []
        for p in data_points:
            qty = p.get("qty")
            if qty is not None:
                valid.append((p.get("date", ""), float(qty)))
        if not valid:
            return None
        valid.sort(key=lambda x: x[0], reverse=True)
        return valid[0][1]

    # HRV — average of today's readings
    hrv_vals = get_qty_values(metric_data.get("heart_rate_variability", []), today)
    if not hrv_vals:
        hrv_vals = get_qty_values(metric_data.get("heart_rate_variability", []), yesterday)
    hrv = round(sum(hrv_vals) / len(hrv_vals), 1) if hrv_vals else None

    # Resting HR — latest
    rhr_vals = get_qty_values(metric_data.get("resting_heart_rate", []), today)
    if not rhr_vals:
        rhr_vals = get_qty_values(metric_data.get("resting_heart_rate", []), yesterday)
    resting_hr = rhr_vals[-1] if rhr_vals else latest_qty(metric_data.get("resting_heart_rate", []))

    # Heart rate — average
    hr_vals = get_qty_values(metric_data.get("heart_rate", []), today)
    if not hr_vals:
        hr_vals = get_qty_values(metric_data.get("heart_rate", []), yesterday)
    heart_rate = round(sum(hr_vals) / len(hr_vals), 1) if hr_vals else None

    # Sleep — totalSleep field from summary object
    sleep_raw = metric_data.get("sleep_analysis", [])
    sleep_hours = None
    if sleep_raw:
        sorted_sleep = sorted(sleep_raw, key=lambda x: x.get("date", ""), reverse=True)
        latest = sorted_sleep[0]
        total = latest.get("totalSleep")
        if total:
            sleep_hours = round(float(total), 2)

    # Steps — sum for today
    steps_vals = get_qty_values(metric_data.get("step_count", []), today)
    steps = int(sum(steps_vals)) if steps_vals else None

    # Active energy — sum for today, convert kJ to kcal
    energy_vals = get_qty_values(metric_data.get("active_energy", []), today)
    active_energy = round(sum(energy_vals) / 4.184, 1) if energy_vals else None

    # Weight — latest, convert lbs to kg if needed
    weight_raw = latest_qty(metric_data.get("weight_body_mass", []))
    if weight_raw is None:
        weight_raw = latest_qty(metric_data.get("body_mass", []))
    weight_kg = round(weight_raw / 2.205, 2) if weight_raw and weight_raw > 150 else weight_raw

    # Body fat — latest, convert decimal to percentage
    bf_raw = latest_qty(metric_data.get("body_fat_percentage", []))
    body_fat_pct = round(bf_raw * 100, 1) if bf_raw and bf_raw < 1 else bf_raw

    # Exercise minutes — sum for today
    exercise_vals = get_qty_values(metric_data.get("apple_exercise_time", []), today)
    exercise_minutes = int(sum(exercise_vals)) if exercise_vals else None

    # Respiratory rate — average
    resp_vals = get_qty_values(metric_data.get("respiratory_rate", []), today)
    if not resp_vals:
        resp_vals = get_qty_values(metric_data.get("respiratory_rate", []), yesterday)
    respiratory_rate = round(sum(resp_vals) / len(resp_vals), 1) if resp_vals else None

    # VO2 Max — latest
    vo2_max = latest_qty(metric_data.get("vo2_max", []))

    result = {
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
    print(f"Parsed: {result}")
    return result

def parse_flat_format(payload: dict) -> dict:
    """Handle flat JSON format as fallback."""
    def safe_float(val):
        try: return float(val)
        except: return None

    weight_raw = safe_float(payload.get("weight_kg"))
    weight_kg = round(weight_raw / 2.205, 2) if weight_raw and weight_raw > 150 else weight_raw
    exercise_raw = safe_float(payload.get("exercise_minutes"))
    exercise_minutes = round(exercise_raw * 60) if exercise_raw and exercise_raw < 24 else exercise_raw
    body_fat_raw = safe_float(payload.get("body_fat_pct"))
    body_fat_pct = round(body_fat_raw * 100, 1) if body_fat_raw and body_fat_raw < 1 else body_fat_raw

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
        "respiratory_rate": safe_float(payload.get("respiratory_rate")),
        "vo2_max": safe_float(payload.get("vo2_max")),
    }