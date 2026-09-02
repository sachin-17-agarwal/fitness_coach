"""
webhook.py — Flask server for Telegram messages and Apple Health data.
"""

import logging
import re
import secrets
import traceback
from flask import Flask, Response, request, jsonify

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
    Receives Apple Health data from the external exporter.

    NOT the only writer of the `recovery` table, and worth knowing before you
    reason about how often that table changes: the iOS app upserts it directly
    via the Supabase REST API (RecoveryService.saveHealthKitSync), driven by
    HealthKit observer queries that fire continuously while a workout streams
    from the Watch. This endpoint still carries the workout payloads.

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
        # Same reasoning as /api/chat: an iOS caller persists its own sets, and
        # the briefing prompt is generated text that must never be mined for
        # weight x reps patterns.
        response = handle_incoming_message(prompt, memory, send_reply=False, out_prs=prs,
                                           recovery_override=recovery_override,
                                           allow_set_logging=False)
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
        # allow_set_logging=False: the iOS app persists every set to Supabase
        # itself before sending this message. Letting the backend parse it too
        # double-logs structured entries and invents sets out of ordinary chat.
        response = handle_incoming_message(text, memory, send_reply=False, out_prs=prs,
                                           recovery_override=recovery_override,
                                           allow_set_logging=False)
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

    # No `prescription` key. It used to carry a server-side parse of the first
    # exercise block, and the app merged it as `[serverRx] + clientParsed
    # .dropFirst()` — so exercise 1 came from this parser and the rest from
    # PrescriptionParser.swift. The two count sets differently: this one scans
    # the whole line with finditer, the Swift one splits on commas and takes
    # only the first match per segment, so `Back-off: 100kg x12 and 90kg x12`
    # is two sets here and one there. Same reply, different number of chips on
    # the card, decided by which parser happened to supply the block.
    #
    # Dropping this half is safe and needs no app release: ChatService declares
    # `prescription` optional and WorkoutViewModel already falls back to the
    # client parse when it is absent. `Revised:` survives too — the Swift
    # parser detects it itself (PrescriptionParser.swift:163).
    result = {
        "response": response,
        "mesocycle_day": _int_or_default(memory.get("mesocycle_day"), 1),
        "mesocycle_week": _int_or_default(memory.get("mesocycle_week"), 1),
    }
    if prs:
        result["prs"] = prs

    return jsonify(result)

# ── Prescription parser ──────────────────────────────────────────────────────
#
# The implementation now lives in coach_parsing so coach.py can reach it too —
# coach.py validates the reply's set counts against the session template before
# returning, and it cannot import webhook (webhook imports coach). Re-exported
# under the original private names so existing callers and tests are unchanged.

from coach_parsing import (  # noqa: E402
    _canonicalise_phase_label,
    _parse_block,
    _parse_loose_sets,
    _parse_prescription,
    _parse_set_list,
    _parse_set_list_with_rpe,
)


# ── Status ────────────────────────────────────────────────────────────────────

@app.route("/status", methods=["GET"])
def status():
    return jsonify({"status": "running", "service": "fitness-coach"}), 200


# ── Admin ─────────────────────────────────────────────────────────────────────

@app.route("/admin/replay", methods=["GET"])
def admin_replay():
    """Replay the Pull-day programme against real history, as plain text.

    This exists because the analysis and the database are not reachable from the
    same place. This server talks to Supabase all day; the environment the
    replay was written in is refused at the egress proxy. Rather than move
    credentials to the code, the code runs where the credentials already are.

    GET, and the token may travel as ?token= instead of a header, so the whole
    thing is one tappable link from a phone. That is a deliberate, bounded
    trade: query strings land in server logs and browser history where a header
    would not. What limits it is that the route is READ-ONLY — it issues selects
    and returns text — so a leaked URL exposes training data already visible on
    the athlete's own history screen, and nothing can be written through it.

        /admin/replay?token=<APP_API_TOKEN>&days=180

    Auth: Authorization: Bearer <APP_API_TOKEN>, or ?token=<APP_API_TOKEN>.
    """
    token = (request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
             or request.args.get("token", "").strip())
    expected_token = get_settings().app_api_token
    if not expected_token:
        return jsonify({"error": "APP_API_TOKEN not configured"}), 503
    if not secrets.compare_digest(token, expected_token):
        return jsonify({"error": "Unauthorized"}), 401

    def _int_arg(name: str, default: int) -> int:
        try:
            return int(request.args.get(name, default))
        except (TypeError, ValueError):
            return default

    try:
        from replay import run_pull_replay
        report = run_pull_replay(days=_int_arg("days", 90),
                                 default_week=_int_arg("week", 1))
    except Exception as e:
        # Never a 500. This is a diagnostic, and why it failed is the thing
        # worth reading.
        traceback.print_exc()
        report = f"Replay failed: {type(e).__name__}: {e}"

    return Response(report, mimetype="text/plain; charset=utf-8")


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
