"""
webhook.py — Flask server for Telegram messages and Apple Health data.
"""

import os
from flask import Flask, request, jsonify
from coach import handle_incoming_message
from memory import load_memory, save_recovery_data
from parse_health import parse_health_export
from parse_workouts import is_workout_payload, parse_workouts, save_workouts

app = Flask(__name__)

# ── Telegram ──────────────────────────────────────────────────────────────────

@app.route("/webhook", methods=["POST"])
def webhook():
    """Receives incoming Telegram messages via webhook."""
    data = request.get_json(force=True)
    if not data:
        return jsonify({"ok": True})

    message = data.get("message", {})
    text = message.get("text", "").strip()
    chat_id = str(message.get("chat", {}).get("id", ""))
    username = message.get("from", {}).get("first_name", "unknown")

    # Only respond to the authorised chat ID
    allowed_chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
    if allowed_chat_id and chat_id != allowed_chat_id:
        print(f"⛔ Unauthorised message from chat_id {chat_id}")
        return jsonify({"ok": True})

    if not text:
        return jsonify({"ok": True})

    print(f"📨 Message from {username}: {text}")

    memory = load_memory()
    handle_incoming_message(text, memory)

    return jsonify({"ok": True})

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
    if not expected_token:
        print("WARNING: HEALTH_WEBHOOK_TOKEN not set — rejecting health webhook")
        return jsonify({"error": "Webhook token not configured"}), 503
    if token != expected_token:
        return jsonify({"error": "Unauthorized"}), 401

    try:
        data = request.get_json(force=True)
        if not data:
            return jsonify({"error": "No JSON body"}), 400

        print(f"🍎 Apple Health data received")

        # Route workout payloads separately
        if is_workout_payload(data):
            workouts = parse_workouts(data)
            save_workouts(workouts)
            return jsonify({"status": "ok", "type": "workouts", "count": len(workouts)}), 200

        # Parse Health Auto Export v2 format (nested metrics) or flat format
        recovery_data = parse_health_export(data)
        print(f"Parsed: {recovery_data}")

        hrv = recovery_data.get("hrv")
        hrv_status = _get_hrv_status(hrv)
        recovery_data["hrv_status"] = hrv_status

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
        from data import get_supabase, now_local, today_local_str
        from datetime import timedelta
        supabase = get_supabase()
        seven_days_ago = (now_local() - timedelta(days=7)).strftime("%Y-%m-%d")
        today = today_local_str()
        result = supabase.table("recovery")\
            .select("hrv")\
            .gte("date", seven_days_ago)\
            .lte("date", today)\
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
