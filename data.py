"""
data.py — Pulls Apple Health + MyFitnessPal data from Google Sheets.

Setup:
1. Install Health Auto Export app on iPhone
2. Configure it to export to Google Sheets (it does this automatically)
3. Set up MyFitnessPal → Zapier → Google Sheets (or manual CSV import)
4. Create a Google Service Account and download credentials.json
5. Share your Google Sheet with the service account email
"""

import os
from datetime import datetime, timedelta
import gspread
from google.oauth2.service_account import Credentials

# ── Config — update these with your actual sheet names / column positions ────
GOOGLE_CREDENTIALS_FILE = "credentials.json"   # Your service account credentials
SPREADSHEET_NAME = "Health Data"               # Name of your Google Sheet

# Sheet tab names (Health Auto Export creates these automatically)
SLEEP_TAB = "Sleep"
HRV_TAB = "HeartRateVariability"
RESTING_HR_TAB = "RestingHeartRate"
NUTRITION_TAB = "Nutrition"   # MyFitnessPal data via Zapier

# ─────────────────────────────────────────────────────────────────────────────

def get_google_sheet():
    """Authenticate and return the Google Spreadsheet."""
    scopes = [
        "https://www.googleapis.com/auth/spreadsheets.readonly",
        "https://www.googleapis.com/auth/drive.readonly"
    ]
    creds = Credentials.from_service_account_file(
        GOOGLE_CREDENTIALS_FILE, scopes=scopes
    )
    client = gspread.authorize(creds)
    return client.open(SPREADSHEET_NAME)

def get_latest_value(sheet, date_col=0, value_col=1, days_back=1):
    """Get the most recent value from a sheet for a given number of days back."""
    try:
        all_rows = sheet.get_all_values()
        if len(all_rows) < 2:
            return None
        
        target_date = (datetime.now() - timedelta(days=days_back)).strftime("%Y-%m-%d")
        
        # Search from bottom (most recent) upward
        for row in reversed(all_rows[1:]):
            if len(row) > value_col and target_date in row[date_col]:
                try:
                    return float(row[value_col])
                except (ValueError, IndexError):
                    continue
        return None
    except Exception as e:
        print(f"Warning: Could not fetch data — {e}")
        return None

def get_recent_average(sheet, value_col=1, days=7):
    """Get average of a metric over the last N days."""
    try:
        all_rows = sheet.get_all_values()
        if len(all_rows) < 2:
            return None
        
        values = []
        for i in range(1, min(days + 1, len(all_rows))):
            row = all_rows[-(i)]
            if len(row) > value_col:
                try:
                    values.append(float(row[value_col]))
                except ValueError:
                    continue
        
        return round(sum(values) / len(values), 1) if values else None
    except Exception:
        return None

def classify_hrv(hrv: float, hrv_avg: float) -> str:
    """Classify HRV status relative to 7-day baseline."""
    if hrv is None or hrv_avg is None:
        return "Unknown"
    diff_pct = ((hrv - hrv_avg) / hrv_avg) * 100
    if diff_pct < -20:
        return "⚠️ Significantly Suppressed"
    elif diff_pct < -10:
        return "🔶 Suppressed"
    elif diff_pct > 10:
        return "✅ Elevated (good)"
    else:
        return "✅ Normal"

def classify_sleep(hours: float) -> str:
    if hours is None:
        return "Unknown"
    if hours >= 7.5:
        return "Good"
    elif hours >= 6:
        return "Average"
    else:
        return "Poor ⚠️"

def get_athlete_context() -> dict:
    """
    Main function — returns a dict of all health metrics for today.
    Falls back to mock data if Google Sheets is not configured yet.
    """
    
    # ── Check if credentials exist, else return mock data for testing ─────
    if not os.path.exists(GOOGLE_CREDENTIALS_FILE):
        print("⚠️  No Google credentials found. Using mock data for testing.")
        return get_mock_data()
    
    try:
        spreadsheet = get_google_sheet()
        
        # Sleep
        sleep_sheet = spreadsheet.worksheet(SLEEP_TAB)
        sleep_hours = get_latest_value(sleep_sheet, date_col=0, value_col=1)
        
        # HRV
        hrv_sheet = spreadsheet.worksheet(HRV_TAB)
        hrv = get_latest_value(hrv_sheet, date_col=0, value_col=1)
        hrv_avg = get_recent_average(hrv_sheet, value_col=1, days=7)
        
        # Resting HR
        hr_sheet = spreadsheet.worksheet(RESTING_HR_TAB)
        resting_hr = get_latest_value(hr_sheet, date_col=0, value_col=1)
        resting_hr_baseline = get_recent_average(hr_sheet, value_col=1, days=14)
        
        # Nutrition (from MyFitnessPal via Zapier)
        nutrition_sheet = spreadsheet.worksheet(NUTRITION_TAB)
        calories = get_latest_value(nutrition_sheet, date_col=0, value_col=1)
        protein_g = get_latest_value(nutrition_sheet, date_col=0, value_col=2)
        carbs_g = get_latest_value(nutrition_sheet, date_col=0, value_col=3)
        fat_g = get_latest_value(nutrition_sheet, date_col=0, value_col=4)
        
        return {
            "sleep_hours": sleep_hours or "N/A",
            "sleep_quality": classify_sleep(sleep_hours),
            "hrv": hrv or "N/A",
            "hrv_avg": hrv_avg or "N/A",
            "hrv_status": classify_hrv(hrv, hrv_avg),
            "resting_hr": resting_hr or "N/A",
            "resting_hr_baseline": resting_hr_baseline or "N/A",
            "calories": calories or "N/A",
            "protein_g": protein_g or "N/A",
            "carbs_g": carbs_g or "N/A",
            "fat_g": fat_g or "N/A",
        }

    except Exception as e:
        print(f"⚠️  Google Sheets error: {e}. Using mock data.")
        return get_mock_data()

def get_mock_data() -> dict:
    """Mock data for testing before Google Sheets is connected."""
    return {
        "sleep_hours": 6.5,
        "sleep_quality": "Average",
        "hrv": 58,
        "hrv_avg": 62,
        "hrv_status": "🔶 Suppressed",
        "resting_hr": 54,
        "resting_hr_baseline": 52,
        "calories": 2100,
        "protein_g": 145,
        "carbs_g": 210,
        "fat_g": 75,
    }
