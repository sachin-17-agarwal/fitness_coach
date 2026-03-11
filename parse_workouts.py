"""
parse_workouts.py — Parse Health Auto Export workout data.
"""

from datetime import datetime

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
    except:
        return None

def parse_workouts(payload: dict) -> list:
    workouts = payload.get("data", {}).get("workouts", [])
    parsed = []

    for w in workouts:
        try:
            # Dates — use 'start' and 'end' fields
            start_raw = w.get("start") or w.get("startDate") or ""
            end_raw = w.get("end") or w.get("endDate") or ""

            start_dt = None
            end_dt = None
            try:
                start_dt = datetime.strptime(start_raw[:19], "%Y-%m-%d %H:%M:%S")
            except:
                pass
            try:
                end_dt = datetime.strptime(end_raw[:19], "%Y-%m-%d %H:%M:%S")
            except:
                pass

            date = start_dt.strftime("%Y-%m-%d") if start_dt else datetime.now().strftime("%Y-%m-%d")

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
                "start_time": start_raw[:19] if start_raw else None,
                "end_time": end_raw[:19] if end_raw else None,
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
    import os
    from supabase import create_client
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_KEY")
    if not url or not key or not parsed:
        return
    supabase = create_client(url, key)
    for w in parsed:
        try:
            supabase.table("apple_workouts").upsert(
                w, on_conflict="date,workout_type,start_time"
            ).execute()
            print(f"✅ Workout: {w['workout_type']} | {w['date']} | {w['duration_minutes']}min | avg HR {w['avg_heart_rate']} | {w['active_energy_kcal']}kcal")
        except Exception as e:
            print(f"⚠️ Failed to save workout: {e}")
