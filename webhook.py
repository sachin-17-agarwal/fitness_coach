"""
webhook.py — Flask server for Telegram messages and Apple Health data.
"""

import logging
import re
import secrets
import traceback
from flask import Flask, request, jsonify

from settings import get_settings

logging.basicConfig(
    level=get_settings().log_level.upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger(__name__)
from coach import handle_incoming_message
from data import get_supabase, now_local
from memory import load_memory, save_recovery_data
from parse_health import parse_health_export
from parse_workouts import is_workout_payload, parse_workouts, save_workouts

app = Flask(__name__)

# ── Telegram ──────────────────────────────────────────────────────────────────

def _is_duplicate_update(update_id) -> bool:
    """Return True if this Telegram update_id has been processed before.

    Telegram retries on 5xx and timeouts; without this guard the same message
    can trigger duplicate mesocycle advances and double replies. Uses the
    memory key/value table with a `tg_update_<id>` key; the upsert's
    on_conflict=key acts as the unique constraint.
    """
    if update_id is None:
        return False
    supabase = get_supabase()
    if not supabase:
        return False
    key = f"tg_update_{update_id}"
    try:
        existing = supabase.table("memory").select("key").eq("key", key).limit(1).execute()
        if existing.data:
            return True
        supabase.table("memory").upsert(
            {"key": key, "value": "1", "updated_at": now_local().isoformat()},
            on_conflict="key",
        ).execute()
        return False
    except Exception:
        log.exception("Telegram dedup check failed")
        return False


@app.route("/webhook", methods=["POST"])
def webhook():
    """Receives incoming Telegram messages via webhook."""
    data = request.get_json(force=True)
    if not data:
        return jsonify({"ok": True})

    if _is_duplicate_update(data.get("update_id")):
        print(f"Skipping duplicate Telegram update_id={data.get('update_id')}")
        return jsonify({"ok": True})

    message = data.get("message", {})
    text = message.get("text", "").strip()
    chat_id = str(message.get("chat", {}).get("id", ""))
    username = message.get("from", {}).get("first_name", "unknown")

    # Only respond to the authorised chat ID
    allowed_chat_id = get_settings().telegram_chat_id
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
    expected_token = get_settings().health_webhook_token
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
        log.exception("Apple Health webhook error")
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

def _recovery_override_from(payload) -> dict | None:
    """Extract the optional authoritative recovery snapshot from a request body.

    The iOS app sends the recovery snapshot it already shows on the dashboard so
    the coach reasons over the exact numbers the athlete sees. Returns None for
    any caller that doesn't supply one (Telegram, older app builds), which keeps
    the database-derived fallback in place.
    """
    if not isinstance(payload, dict):
        return None
    recovery = payload.get("recovery")
    return recovery if isinstance(recovery, dict) and recovery else None


@app.route("/api/briefing", methods=["POST"])
def api_briefing():
    """Run the morning briefing using the user's saved `briefing_style`.

    Replaces the iOS app having to construct its own prompt — keeps a single
    source of truth so the Telegram morning auto and the in-app Briefing
    button always speak the same style.
    """
    from coach import build_briefing_prompt, handle_incoming_message

    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    expected_token = get_settings().app_api_token
    if not expected_token:
        return jsonify({"error": "APP_API_TOKEN not configured"}), 503
    if not secrets.compare_digest(token, expected_token):
        return jsonify({"error": "Unauthorized"}), 401

    recovery_override = _recovery_override_from(request.get_json(silent=True))

    try:
        memory = load_memory()
        style = str(memory.get("briefing_style", "detailed")).strip().lower()
        prompt = build_briefing_prompt(style)
        prs: list = []
        response = handle_incoming_message(prompt, memory, send_reply=False, out_prs=prs,
                                           recovery_override=recovery_override)
    except Exception as e:
        traceback.print_exc()
        return jsonify({
            "error": "briefing_failed",
            "message": f"{type(e).__name__}: {e}",
        }), 502

    def _int_or_default(val, default=1):
        try:
            return int(val)
        except (TypeError, ValueError):
            return default

    result = {
        "response": response,
        "mesocycle_day": _int_or_default(memory.get("mesocycle_day"), 1),
        "mesocycle_week": _int_or_default(memory.get("mesocycle_week"), 1),
        "style": style,
    }
    if prs:
        result["prs"] = prs
    return jsonify(result)


@app.route("/api/chat", methods=["POST"])
def api_chat():
    """
    REST endpoint for the iOS app. Returns Claude's response directly
    instead of sending to Telegram.
    """
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    expected_token = get_settings().app_api_token
    if not expected_token:
        return jsonify({"error": "APP_API_TOKEN not configured"}), 503
    if not secrets.compare_digest(token, expected_token):
        return jsonify({"error": "Unauthorized"}), 401

    data = request.get_json(force=True)
    text = (data or {}).get("message", "").strip()
    if not text:
        return jsonify({"error": "empty message"}), 400

    recovery_override = _recovery_override_from(data)

    try:
        memory = load_memory()
        prs: list = []
        response = handle_incoming_message(text, memory, send_reply=False, out_prs=prs,
                                           recovery_override=recovery_override)
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
    if prs:
        result["prs"] = prs

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


_WARMUP_PREFIXES = ("warm-up:", "warmup:", "warm up:", "warm-up sets:",
                    "warmup sets:", "warm up sets:", "warm sets:", "warm:")
_WORKING_PREFIXES = ("working set:", "working sets:", "work:", "working:",
                     "top set:", "top sets:", "primary set:", "primary:",
                     "main set:", "main:")
_BACKOFF_PREFIXES = ("back-off:", "backoff:", "back off:", "back-off set:",
                     "back off set:", "backoff set:", "drop set:", "drop:",
                     "light set:", "light:")

# Matches loose phrasings like "3 sets: 90kg x12 RPE7" or "3x 90kg x 12 RPE7".
_LOOSE_SET_PATTERN = re.compile(
    r'(?:^|\s)(?:\d+\s*(?:sets?|x)\s*:?\s*)'
    r'(\d+(?:\.\d+)?)\s*(?:kg|lbs?)?\s*[xX×]\s*(\d+)'
    r'(?:\s*(?:rpe|@)\s*(\d+(?:\.\d+)?))?',
    re.IGNORECASE,
)


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

        if any(lower.startswith(p) for p in _WARMUP_PREFIXES):
            content = line.split(":", 1)[1].strip()
            warmup = _parse_set_list(content)
        elif any(lower.startswith(p) for p in _WORKING_PREFIXES):
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
        elif any(lower.startswith(p) for p in _BACKOFF_PREFIXES):
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

    # Fallback: Claude sometimes drops the `Working Set:` / `Back-off:` prefixes
    # and writes loose lines like "3 sets: 90kg x12 RPE7" + "3 sets: 60kg x15 RPE7".
    # Scan the block for those whenever a phase is missing — including the case
    # where the strict `Working Set:` line was sent but the back-off was only
    # mentioned narratively, which would otherwise drop silently and leave the
    # card with a working chip and no back-off.
    if not working or not backoff:
        loose = _parse_loose_sets(block)
        # Don't double-count anything the strict prefixes already captured.
        already = {(s["weight"], s["reps"]) for s in working + backoff}
        loose = [s for s in loose if (s["weight"], s["reps"]) not in already]
        if loose:
            if not working:
                working = [loose.pop(0)]
            # Straight-set prescriptions (abs) enumerate 2+ sets on the
            # `Working Set:` line and legitimately have no back-off — don't
            # promote stray narrative numbers into a phantom back-off.
            if not backoff and loose and len(working) <= 1:
                backoff = [loose[0]]

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


def _parse_loose_sets(block: str) -> list:
    """Extract sets from loose phrasings inside an exercise block.

    Handles lines like:
      "3 sets: 90kg x12 RPE7"
      "3x 90kg x 12 RPE7"
    Returns a list of {weight, reps, rpe?} dicts in source order.
    """
    seen = []
    for match in _LOOSE_SET_PATTERN.finditer(block):
        try:
            weight = float(match.group(1))
            reps = int(match.group(2))
        except (TypeError, ValueError):
            continue
        entry = {"weight": weight, "reps": reps}
        if match.group(3):
            try:
                entry["rpe"] = float(match.group(3))
            except ValueError:
                pass
        seen.append(entry)
    return seen


def _parse_set_list(text: str) -> list:
    """Parse '60kg x10, 80kg x6' (or 'BW x10, BW x6') into structured sets.

    Bodyweight phrasings ('BW', 'Bodyweight', 'BW + 10kg') resolve to weight 0
    so swaps to assisted/pull-up style exercises still render a card."""
    pattern = re.compile(
        r'(BW|bodyweight|body\s*weight|\d+(?:\.\d+)?)\s*(?:kg)?\s*[xX×]\s*(\d+)',
        re.IGNORECASE,
    )
    sets = []
    for m in pattern.finditer(text):
        raw_weight = m.group(1)
        weight = 0.0 if not raw_weight[0].isdigit() else float(raw_weight)
        sets.append({"weight": weight, "reps": int(m.group(2))})
    return sets


def _parse_set_list_with_rpe(text: str) -> list:
    """Parse '120kg x6-8 RPE8-9' (or 'BW x6 RPE8') into structured sets."""
    pattern = re.compile(
        r'(BW|bodyweight|body\s*weight|\d+(?:\.\d+)?)\s*(?:kg)?\s*[xX×]\s*(\d+)',
        re.IGNORECASE,
    )
    rpe_pattern = re.compile(r'(?:RPE\s*|@)(\d+(?:\.\d+)?)', re.IGNORECASE)
    results = []
    for m in pattern.finditer(text):
        raw_weight = m.group(1)
        weight = 0.0 if not raw_weight[0].isdigit() else float(raw_weight)
        entry = {"weight": weight, "reps": int(m.group(2))}
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


# ── Admin ─────────────────────────────────────────────────────────────────────

@app.route("/admin/cleanup", methods=["POST"])
def admin_cleanup():
    """One-shot DB cleanup runner exposed for Railway-hosted deploys.

    Body (JSON, optional):
      { "step": "orphans"|"dupsets"|"sessions"|"sets"|"memory"|"all",
        "execute": false }

    Defaults: step="orphans", execute=false (dry-run). Returns the captured
    cleanup log so you can review before re-posting with execute=true.

    Auth: Authorization: Bearer <APP_API_TOKEN>.
    """
    import io
    from contextlib import redirect_stdout

    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    expected_token = get_settings().app_api_token
    if not expected_token:
        return jsonify({"error": "APP_API_TOKEN not configured"}), 503
    if not secrets.compare_digest(token, expected_token):
        return jsonify({"error": "Unauthorized"}), 401

    body = request.get_json(silent=True) or {}
    step = (body.get("step") or "orphans").lower()
    execute = bool(body.get("execute", False))
    relabel_to = body.get("relabel_to", "") or ""

    allowed_steps = {"orphans", "dupsets", "sessions", "sets", "memory", "all"}
    if step not in allowed_steps:
        return jsonify({"error": f"step must be one of {sorted(allowed_steps)}"}), 400

    supabase = get_supabase()
    if not supabase:
        return jsonify({"error": "Supabase not configured"}), 503

    import cleanup as cleanup_module

    runners = {
        "sessions": lambda: cleanup_module.cleanup_stale_sessions(supabase, execute),
        "sets":     lambda: cleanup_module.cleanup_bad_exercise_sets(supabase, execute, relabel_to),
        "memory":   lambda: cleanup_module.cleanup_duplicate_memory_keys(supabase, execute),
        "orphans":  lambda: cleanup_module.cleanup_orphan_duplicate_sessions(supabase, execute),
        "dupsets":  lambda: cleanup_module.cleanup_duplicate_sets(supabase, execute),
    }
    selected = list(runners.values()) if step == "all" else [runners[step]]

    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            for run in selected:
                run()
    except Exception as exc:
        log.exception("Admin cleanup failed")
        return jsonify({
            "error": "cleanup_failed",
            "message": f"{type(exc).__name__}: {exc}",
            "log": buf.getvalue(),
        }), 500

    return jsonify({
        "step": step,
        "execute": execute,
        "log": buf.getvalue(),
    })


# ── Run ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = get_settings().port
    print(f"🚀 Server starting on port {port}")
    app.run(host="0.0.0.0", port=port)
