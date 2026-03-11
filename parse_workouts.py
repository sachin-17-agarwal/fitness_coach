"""
parse_workouts.py — Parse Health Auto Export workout data.
Handles the workouts format: data.workouts[]
"""

from datetime import datetime

def is_workout_payload(payload: dict) -> bool:
    """Check if this payload contains workout data rather than health metrics."""
    return "workouts" in payload.get("data", {})

def parse_workouts(payload: dict) -> list:
    """
    Parse workout records from Health Auto Export.
    Returns list of workout dicts ready for Supabase.
    """
    workouts = payload.get("data", {}).get("workouts", [])
    parsed = []

    for w in workouts:
        try:
            # Get workout date from startDate or date field
            start_raw = w.get("startDate") or w.get("date") or ""
            end_raw = w.get("endDate") or ""

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
            duration_minutes = None
            if start_dt and end_dt:
                duration_minutes = round((end_dt - start_dt).total_seconds() / 60, 1)
            elif w.get("duration"):
                duration_minutes = round(float(w.get("duration", 0)), 1)

            # Heart rate stats
            hr_data = w.get("heartRateData", [])
            avg_hr = None
            min_hr = None
            max_hr = None
            if hr_data:
                avgs = [h.get("Avg") for h in hr_data if h.get("Avg")]
                mins = [h.get("Min") for h in hr_data if h.get("Min")]
                maxs = [h.get("Max") for h in hr_data if h.get("Max")]
                if avgs:
                    avg_hr = round(sum(avgs) / len(avgs), 1)
                if mins:
                    min_hr = min(mins)
                if maxs:
                    max_hr = max(maxs)

            # Energy — convert kJ to kcal if needed
            energy_raw = w.get("activeEnergyBurned") or w.get("totalEnergyBurned") or w.get("energy")
            energy_kcal = None
            if energy_raw:
                e = float(energy_raw)
                energy_kcal = round(e / 4.184, 1) if e > 500 else round(e, 1)

            parsed.append({
                "date": date,
                "workout_type": w.get("workoutActivityType") or w.get("type") or "Unknown",
                "start_time": start_raw[:19] if start_raw else None,
                "end_time": end_raw[:19] if end_raw else None,
                "duration_minutes": duration_minutes,
                "avg_heart_rate": avg_hr,
                "min_heart_rate": min_hr,
                "max_heart_rate": max_hr,
                "active_energy_kcal": energy_kcal,
                "source": w.get("source", ""),
                "metadata": str(w.get("metadata", {})),
            })
        except Exception as e:
            print(f"Failed to parse workout: {e}")
            continue

    return parsed

def save_workouts(parsed: list):
    """Save parsed workouts to Supabase apple_workouts table."""
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
            print(f"✅ Workout saved: {w['workout_type']} on {w['date']} ({w['duration_minutes']}min)")
        except Exception as e:
            print(f"⚠️ Failed to save workout: {e}")
