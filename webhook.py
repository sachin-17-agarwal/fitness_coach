"""
webhook.py — Flask server for WhatsApp messages and Apple Health data.
"""

import os
import json
from flask import Flask, request, jsonify
from twilio.twiml.messaging_response import MessagingResponse
from coach import handle_incoming_message
from memory import load_memory, save_recovery_data

app = Flask(__name__)

# ── WhatsApp ──────────────────────────────────────────────────────────────────

@app.route("/webhook", methods=["POST"])
def webhook():
    """Receives incoming WhatsApp messages from Twilio."""
    incoming_msg = request.values.get("Body", "").strip()
    sender = request.values.get("From", "")

    print(f"📨 Message from {sender}: {incoming_msg}")

    if not incoming_msg:
        return str(MessagingResponse())

    memory = load_memory()
    coach_reply = handle_incoming_message(incoming_msg, memory)

    resp = MessagingResponse()
    resp.message(coach_reply)
    return str(resp)

# ── Apple Health ──────────────────────────────────────────────────────────────

@app.route("/apple-health", methods=["POST"])
def apple_health():
    """
    Receives daily Apple Health data from Make.com.
    
    Expected JSON payload:
    {
        "date": "2026-03-09",
        "sleep_hours": 7.2,
        "hrv": 58.0,
        "resting_hr": 52.0,
        "heart_rate": 71.0,
        "steps": 8400,
        "active_energy_kcal": 520.0,
        "weight_kg": 80.1,
        "body_fat_pct": 18.2,
        "exercise_minutes": 62,
        "respiratory_rate": 14.2,
        "vo2_max": 48.5
    }
    """
    # Validate secret token to prevent random people posting to this endpoint
    token = request.headers.get("X-Health-Token", "")
    expected_token = os.environ.get("HEALTH_WEBHOOK_TOKEN", "")
    if expected_token and token != expected_token:
        return jsonify({"error": "Unauthorized"}), 401

    try:
        data = request.get_json(force=True)
        if not data:
            return jsonify({"error": "No JSON body"}), 400

        print(f"🍎 Apple Health data received: {json.dumps(data, indent=2)}")

        # Calculate HRV status vs 7-day baseline (stored in Supabase)
        hrv = data.get("hrv")
        hrv_status = _get_hrv_status(hrv)

        recovery_data = {
            "date":                  data.get("date"),
            "sleep_hours":           data.get("sleep_hours"),
            "hrv":                   hrv,
            "hrv_status":            hrv_status,
            "resting_hr":            data.get("resting_hr"),
            "heart_rate":            data.get("heart_rate"),
            "steps":                 data.get("steps"),
            "active_energy_kcal":    data.get("active_energy_kcal"),
            "weight_kg":             data.get("weight_kg"),
            "body_fat_pct":          data.get("body_fat_pct"),
            "exercise_minutes":      data.get("exercise_minutes"),
            "respiratory_rate":      data.get("respiratory_rate"),
            "vo2_max":               data.get("vo2_max"),
        }

        save_recovery_data(recovery_data)
        return jsonify({"status": "ok", "date": data.get("date")}), 200

    except Exception as e:
        print(f"❌ Apple Health webhook error: {e}")
        return jsonify({"error": str(e)}), 500

def _get_hrv_status(hrv: float) -> str:
    """Compare today's HRV against 7-day rolling average from Supabase."""
    if not hrv:
        return "Unknown"
    try:
        from memory import get_supabase
        from datetime import datetime, timedelta
        supabase = get_supabase()
        seven_days_ago = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d")
        result = supabase.table("recovery")\
            .select("hrv")\
            .gte("date", seven_days_ago)\
            .execute()
        readings = [r["hrv"] for r in result.data if r.get("hrv")]
        if not readings:
            return "Baseline building"
        avg = sum(readings) / len(readings)
        diff_pct = ((hrv - avg) / avg) * 100
        if diff_pct >= 10:
            return "✅ Elevated — push hard"
        elif diff_pct >= -10:
            return "🟢 Normal — train as planned"
        elif diff_pct >= -20:
            return "🔶 Suppressed — reduce RPE"
        else:
            return "🔴 Very low — consider recovery session"
    except Exception:
        return "Unknown"

# ── Status ────────────────────────────────────────────────────────────────────

@app.route("/status", methods=["GET"])
def status():
    return jsonify({"status": "running", "service": "fitness-coach"}), 200

# ── Run ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"🚀 Server starting on port {port}")
    app.run(host="0.0.0.0", port=port)