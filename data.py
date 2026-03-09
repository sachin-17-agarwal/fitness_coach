"""
data.py — Fetches recovery data from Supabase.
Apple Health data is written to Supabase via the /health webhook in webhook.py.
Falls back to mock data if no real data exists yet.
"""

import os
from datetime import datetime, timedelta

def get_supabase():
    from supabase import create_client
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_KEY")
    if not url or not key:
        return None
    return create_client(url, key)

def get_athlete_context() -> dict:
    """
    Returns today's recovery data from Supabase.
    Falls back to mock data if Supabase isn't connected or no data exists yet.
    """
    supabase = get_supabase()
    
    if not supabase:
        print("⚠️  No Supabase credentials. Using mock data.")
        return get_mock_data()
    
    try:
        yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        
        result = supabase.table("recovery")\
            .select("*")\
            .eq("date", yesterday)\
            .execute()
        
        if not result.data:
            print("⚠️  No recovery data for yesterday. Using mock data.")
            return get_mock_data()
        
        row = result.data[0]
        return {
            "sleep_hours": row.get("sleep_hours", "N/A"),
            "sleep_quality": row.get("sleep_quality", "Unknown"),
            "hrv": row.get("hrv", "N/A"),
            "hrv_avg": row.get("hrv_avg_7day", "N/A"),
            "hrv_status": row.get("hrv_status", "Unknown"),
            "resting_hr": row.get("resting_hr", "N/A"),
            "resting_hr_baseline": row.get("resting_hr_baseline", "N/A"),
        }

    except Exception as e:
        print(f"⚠️  Supabase data fetch failed: {e}. Using mock data.")
        return get_mock_data()

def get_mock_data() -> dict:
    """Mock data for testing before Apple Health is connected."""
    return {
        "sleep_hours": 6.5,
        "sleep_quality": "Average",
        "hrv": 58,
        "hrv_avg": 62,
        "hrv_status": "🔶 Suppressed",
        "resting_hr": 54,
        "resting_hr_baseline": 52,
    }
