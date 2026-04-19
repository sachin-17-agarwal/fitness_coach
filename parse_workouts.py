"""
parse_workouts.py — Parse Health Auto Export workout data.
"""

from datetime import datetime

from data import now_local


def _today_str() -> str:
    try:
        return now_local().strftime("%Y-%m-%d")
    except Exception:
        return datetime.now().strftime("%Y-%m-%d")


def _parse_datetime(raw: str):
    if not raw:
        return None
    text = str(raw).strip()
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except Exception:
        pass
    try:
        return datetime.strptime(text[:19].replace("T", " "), "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None

def is_workout_payload(payload: dict) -> bool:
    return "workouts" in payload.get("data", {})

def extract_qty(val) -> float:
    if val is None:
        return None
    if isinstance(val, dict):
        v = val.get("qty")
        return float(v) if v is not None else None
    try:
        return float(val)
    except Exception:
        return None

def parse_workouts(payload: dict) -> list:
    workouts = payload.get("data", {}).get("workouts", [])
    parsed = []

    for w in workouts:
        try:
            # Dates — use 'start' and 'end' fields
            start_raw = w.get("start") or w.get("startDate") or ""
            end_raw = w.get("end") or w.get("endDate") or ""

            start_dt = _parse_datetime(start_raw)
            end_dt = _parse_datetime(end_raw)

            date = start_dt.strftime("%Y-%m-%d") if start_dt else _today_str()

            # Duration — field is in seconds, convert to minutes
            duration_seconds = extract_qty(w.get("duration"))
            if duration_seconds:
                duration_minutes = round(duration_seconds / 60, 1)
            elif start_dt and end_dt:
                duration_minutes = round((end_dt - start_dt).total_seconds() / 60, 1)
            else:
                duration_minutes = None

            # Heart rate — nested dict format: heartRate.avg.qty
            hr = w.get("heartRate", {})
            avg_hr = extract_qty(hr.get("avg")) if hr else None
            min_hr = extract_qty(hr.get("min")) if hr else None
            max_hr = extract_qty(hr.get("max")) if hr else None

            # Fallback to top-level avgHeartRate / maxHeartRate
            if avg_hr is None:
                avg_hr = extract_qty(w.get("avgHeartRate"))
            if max_hr is None:
                max_hr = extract_qty(w.get("maxHeartRate"))

            # Energy — activeEnergyBurned in kJ, convert to kcal
            energy_raw = extract_qty(w.get("activeEnergyBurned"))
            energy_kcal = round(energy_raw / 4.184, 1) if energy_raw else None

            # Workout type — use 'name' field
            workout_type = w.get("name") or w.get("workoutActivityType") or "Unknown"

            parsed.append({
                "date": date,
                "workout_type": workout_type,
                "start_time": start_dt.isoformat(timespec="seconds") if start_dt else (start_raw[:19] if start_raw else None),
                "end_time": end_dt.isoformat(timespec="seconds") if end_dt else (end_raw[:19] if end_raw else None),
                "duration_minutes": duration_minutes,
                "avg_heart_rate": avg_hr,
                "min_heart_rate": min_hr,
                "max_heart_rate": max_hr,
                "active_energy_kcal": energy_kcal,
                "source": w.get("source", "Apple Watch"),
            })
        except Exception as e:
            print(f"Failed to parse workout: {e}")
            continue

    return parsed

def save_workouts(parsed: list):
    if not parsed:
        return
    from data import get_supabase
    supabase = get_supabase()
    if not supabase:
        print("⚠️ No Supabase client available; skipping workout save.")
        return
    for w in parsed:
        # Postgres treats NULL as distinct in unique indexes, so an on_conflict
        # composite with a NULL member will duplicate rather than upsert.
        # Require start_time before writing.
        if not w.get("start_time") or not w.get("date") or not w.get("workout_type"):
            print(f"⚠️ Skipping workout with missing key fields: {w}")
            continue
        try:
            supabase.table("apple_workouts").upsert(
                w, on_conflict="date,workout_type,start_time"
            ).execute()
            print(f"✅ Workout: {w['workout_type']} | {w['date']} | {w['duration_minutes']}min | avg HR {w['avg_heart_rate']} | {w['active_energy_kcal']}kcal")
        except Exception as e:
            print(f"⚠️ Failed to save workout: {e}")
