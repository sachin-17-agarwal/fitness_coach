"""
webhook.py — Flask server for Telegram messages and Apple Health data.
"""

import os
import re
import secrets
import traceback
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
    if not secrets.compare_digest(token, expected_token):
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

def _get_hrv_status(hrv) -> str:
    """Compare today's HRV against 7-day rolling average from Supabase."""
    if hrv is None:
        return "Unknown"
    try:
        hrv_f = float(hrv)
    except (TypeError, ValueError):
        return "Unknown"
    try:
        from data import get_supabase, now_local, today_local_str
        from datetime import timedelta
        supabase = get_supabase()
        if not supabase:
            return "Unknown"
        seven_days_ago = (now_local() - timedelta(days=7)).strftime("%Y-%m-%d")
        today = today_local_str()
        result = supabase.table("recovery")\
            .select("hrv")\
            .gte("date", seven_days_ago)\
            .lte("date", today)\
            .execute()
        readings = [
            r["hrv"] for r in (result.data or [])
            if isinstance(r, dict) and r.get("hrv") is not None
        ]
        if not readings:
            return "Baseline building"
        avg = sum(readings) / len(readings)
        if avg <= 0:
            return "Baseline building"
        diff_pct = ((hrv_f - avg) / avg) * 100
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

# ── iOS App Chat API ─────────────────────────────────────────────────────────

@app.route("/api/chat", methods=["POST"])
def api_chat():
    """
    REST endpoint for the iOS app. Returns Claude's response directly
    instead of sending to Telegram.
    """
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    expected_token = os.environ.get("APP_API_TOKEN", "")
    if not expected_token:
        return jsonify({"error": "APP_API_TOKEN not configured"}), 503
    if not secrets.compare_digest(token, expected_token):
        return jsonify({"error": "Unauthorized"}), 401

    data = request.get_json(force=True)
    text = (data or {}).get("message", "").strip()
    if not text:
        return jsonify({"error": "empty message"}), 400

    try:
        memory = load_memory()
        response = handle_incoming_message(text, memory, send_reply=False)
    except Exception as e:
        # Log full traceback to Railway/Flask logs for debugging, but return
        # a clean JSON error so the iOS app surfaces something useful instead
        # of a generic HTML 500 page.
        traceback.print_exc()
        return jsonify({
            "error": "coach_failed",
            "message": f"{type(e).__name__}: {e}",
        }), 502

    def _int_or_default(val, default=1):
        try:
            return int(val)
        except (TypeError, ValueError):
            return default

    prescription = _parse_prescription(response)

    result = {
        "response": response,
        "mesocycle_day": _int_or_default(memory.get("mesocycle_day"), 1),
        "mesocycle_week": _int_or_default(memory.get("mesocycle_week"), 1),
    }
    if prescription:
        result["prescription"] = prescription

    return jsonify(result)

# ── Prescription parser (server-side) ────────────────────────────────────────

def _parse_prescription(text: str) -> dict | None:
    """Extract structured prescription data from Claude's workout response."""
    # Find bold exercise names: *Exercise Name*
    name_pattern = re.compile(r'^\s*\*{1,2}([^*\n]+)\*{1,2}\s*$', re.MULTILINE)
    matches = list(name_pattern.finditer(text))
    if not matches:
        return None

    # Take the first exercise block that has actual set data
    for i, match in enumerate(matches):
        name = match.group(1).strip()
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        block = text[start:end]

        rx = _parse_block(name, block)
        if rx and (rx.get("warmup") or rx.get("working") or rx.get("backoff")):
            return rx

    return None


def _parse_block(name: str, block: str) -> dict | None:
    """Parse a single exercise block into structured data."""
    result = {"exercise": name}
    warmup = []
    working = []
    backoff = []
    form = None
    tempo = None
    rest = None

    for line in block.split("\n"):
        line = line.strip()
        lower = line.lower()

        if lower.startswith(("warm-up:", "warmup:", "warm up:")):
            content = line.split(":", 1)[1].strip()
            warmup = _parse_set_list(content)
        elif lower.startswith(("working set:", "working sets:", "work:")):
            content = line.split(":", 1)[1].strip()
            parts = [p.strip() for p in content.split("|")]
            if parts:
                working = _parse_set_list_with_rpe(parts[0])
            for part in parts[1:]:
                pl = part.lower()
                if pl.startswith("tempo"):
                    tempo = part.split(":", 1)[1].strip() if ":" in part else part[6:].strip()
                elif pl.startswith("rest"):
                    rest = part.split(":", 1)[1].strip() if ":" in part else part[5:].strip()
        elif lower.startswith(("back-off:", "backoff:", "back off:")):
            content = line.split(":", 1)[1].strip()
            parts = [p.strip() for p in content.split("|")]
            if parts:
                backoff = _parse_set_list_with_rpe(parts[0])
        elif lower.startswith(("form:", "form cue:", "cue:")):
            form = line.split(":", 1)[1].strip()
        elif lower.startswith("tempo:"):
            tempo = line.split(":", 1)[1].strip()
        elif lower.startswith("rest:"):
            rest = line.split(":", 1)[1].strip()

    if warmup:
        result["warmup"] = warmup
    if working:
        result["working"] = working
    if backoff:
        result["backoff"] = backoff
    if form:
        result["form"] = form
    if tempo:
        result["tempo"] = tempo
    if rest:
        result["rest"] = rest

    return result


def _parse_set_list(text: str) -> list:
    """Parse '60kg x10, 80kg x6' into [{"weight": 60, "reps": 10}, ...]"""
    pattern = re.compile(r'(\d+(?:\.\d+)?)\s*(?:kg)?\s*[xX×]\s*(\d+)')
    return [{"weight": float(m.group(1)), "reps": int(m.group(2))}
            for m in pattern.finditer(text)]


def _parse_set_list_with_rpe(text: str) -> list:
    """Parse '120kg x6-8 RPE8-9' into [{"weight": 120, "reps": 6, "rpe": 8}]"""
    pattern = re.compile(r'(\d+(?:\.\d+)?)\s*(?:kg)?\s*[xX×]\s*(\d+)')
    rpe_pattern = re.compile(r'(?:RPE\s*|@)(\d+(?:\.\d+)?)', re.IGNORECASE)
    results = []
    for m in pattern.finditer(text):
        entry = {"weight": float(m.group(1)), "reps": int(m.group(2))}
        rpe_match = rpe_pattern.search(text[m.end():m.end() + 30])
        if not rpe_match:
            rpe_match = rpe_pattern.search(text)
        if rpe_match:
            entry["rpe"] = float(rpe_match.group(1))
        results.append(entry)
    return results


# ── Status ────────────────────────────────────────────────────────────────────

@app.route("/status", methods=["GET"])
def status():
    return jsonify({"status": "running", "service": "fitness-coach"}), 200

# ── Run ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"🚀 Server starting on port {port}")
    app.run(host="0.0.0.0", port=port)
