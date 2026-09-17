"""
webhook.py — Flask server for Telegram messages and Apple Health data.
"""

import logging
import re
import secrets
import json
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

    # The block review lands here, the first morning after a block rolls
    # over, ahead of the briefing: a rest morning, never inside or straight
    # after a session. Prepared once; answered in chat.
    review_text = None
    try:
        from block_review import prepare_if_due, render_review  # local: keeps import order flat
        from coach import get_anthropic_client
        row = prepare_if_due(memory, load_system_prompt_for_review(), get_anthropic_client())
        if row:
            review_text = render_review(row)
    except Exception:
        traceback.print_exc()

    result = {
        "response": (f"BLOCK REVIEW\n\n{review_text}\n\n———\n\n{response}" if review_text else response),
        "mesocycle_day": _int_or_default(memory.get("mesocycle_day"), 1),
        "mesocycle_week": _int_or_default(memory.get("mesocycle_week"), 1),
        "style": style,
    }
    if review_text:
        result["block_review"] = review_text
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

def load_system_prompt_for_review() -> str:
    from coach import load_system_prompt  # local: keeps import order flat
    return load_system_prompt()


@app.route("/api/block-review", methods=["GET"])
def api_block_review():
    """The latest block review as the athlete reads it, with its status, so
    the app can show it on Home until it is answered.

    Home is where it is prepared, too. It used to be prepared by the briefing
    route alone, and the athlete never opens the briefing — so the first
    review would never have been written. Same guards as before: the morning
    after rollover, never inside a session, once per block.
    """
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    from block_review import latest_block_review, prepare_if_due, render_review  # local: import order
    try:
        from coach import get_anthropic_client
        prepare_if_due(load_memory(), load_system_prompt_for_review(), get_anthropic_client())
    except Exception:
        traceback.print_exc()
    row = latest_block_review()
    if not row:
        return jsonify({"status": "none"})
    return jsonify(_block_review_payload(row, render_review(row)))


def _block_review_payload(row: dict, text: str) -> dict:
    return {"status": row.get("status"), "block_start": str(row.get("block_start")),
            "dry_run": bool(row.get("dry_run")), "text": text,
            "proposals": row.get("proposals_list") or []}


@app.route("/api/block-review/answer", methods=["POST"])
def api_block_review_answer():
    """Answer the open review from the Home card: {"text": "yes to 1 and 3"}.
    The same grammar and the same recording path as an answer typed in chat."""
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    text = str((request.get_json(silent=True) or {}).get("text") or "").strip()
    if not text:
        return jsonify({"error": "text required"}), 400
    from block_review import answer_block_review, latest_block_review  # local: keeps import order flat
    row = latest_block_review()
    if not row or row.get("status") != "shown":
        return jsonify({"status": row.get("status") if row else "none",
                        "message": "There is no review waiting for an answer."}), 409
    try:
        message = answer_block_review(row, text, load_system_prompt_for_review())
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": "answer_failed", "message": f"{type(e).__name__}: {e}"}), 502
    return jsonify({"status": "answered", "message": message})


# Short phase names for a widget line: "WEEK 4 · DELOAD".
_PHASE_SHORT = {1: "BASELINE", 2: "VOLUME", 3: "PEAK", 4: "DELOAD"}
WIDGET_STRENGTH_KEY = "widget_strength"


def widget_verdict(level: str, session_type: str, done: bool) -> str:
    """The Home tab's verdict line, naming today's session so the widget
    carries the day as well as the score."""
    session = (session_type or "").upper()
    if level == "green":
        return "READY — SESSION DONE" if done else f"READY — {session} TODAY"
    if level == "yellow":
        return "STEADY — SESSION DONE" if done else f"STEADY — {session}, AS PLANNED"
    if level == "red":
        return "RUN DOWN — REST TONIGHT" if done else f"RUN DOWN — {session}, GO EASY"
    return "NO RECOVERY DATA YET"


def _session_done_today() -> bool:
    from data import FINISHED_SESSION_STATUSES, now_local
    supabase = get_supabase()
    if not supabase:
        return False
    try:
        today = now_local().strftime("%Y-%m-%d")
        rows = (supabase.table("workout_sessions").select("status").eq("date", today).execute().data or [])
        return any((r.get("status") or "").strip().lower() in FINISHED_SESSION_STATUSES for r in rows)
    except Exception:
        traceback.print_exc()
        return False


def widget_payload(memory: dict, readiness: dict, done: bool) -> dict:
    """Everything the widget draws, computed once here so it and Home agree."""
    from data import SESSION_OVERRIDE_KEY, session_type_for
    week = _safe_int_or(memory.get("mesocycle_week"), 1)
    day = _safe_int_or(memory.get("mesocycle_day"), 1)
    session = session_type_for(day, override=memory.get(SESSION_OVERRIDE_KEY))
    strength = None
    raw = memory.get(WIDGET_STRENGTH_KEY)
    if raw:
        try:
            strength = json.loads(raw) if isinstance(raw, str) else dict(raw)
        except (ValueError, TypeError):
            strength = None
    today = now_local().strftime("%Y-%m-%d")
    read_date = readiness.get("date")
    return {
        "date": today,
        "read_date": read_date,
        "stale": bool(read_date) and read_date != today,
        "score": readiness.get("score"),
        "level": readiness.get("level"),
        "verdict": widget_verdict(readiness.get("level"), session, done),
        "session_type": session,
        "done": done,
        "week": week,
        "day": day,
        "phase": _PHASE_SHORT.get(week, ""),
        "hrv": readiness.get("hrv"),
        "hrv_delta": readiness.get("hrv_delta"),
        "sleep_hours": readiness.get("sleep_hours"),
        "resting_hr": readiness.get("resting_hr"),
        "rhr_delta": readiness.get("rhr_delta"),
        "strength": strength,
    }


def _safe_int_or(value, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


@app.route("/api/widget", methods=["GET"])
def api_widget():
    """The home-screen widget's one read: readiness, the day, the verdict,
    and the strength number the app last computed. No model call."""
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    from readiness import readiness_today  # local: keeps import order flat
    try:
        memory = load_memory()
        readiness = readiness_today()
        done = _session_done_today()
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": "widget_failed", "message": f"{type(e).__name__}: {e}"}), 502
    return jsonify(widget_payload(memory, readiness, done))


@app.route("/api/widget/strength", methods=["POST"])
def api_widget_strength():
    """The Strength tab's block number, posted by the app when it computes
    it: {"median_gain_pct": 8.1, "lifts": 11, "block": 6, "week": 4}. Stored
    as-is so the widget shows the tab's number and never a second opinion."""
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    body = request.get_json(silent=True) or {}
    try:
        payload = {
            "median_gain_pct": None if body.get("median_gain_pct") is None else round(float(body["median_gain_pct"]), 1),
            "lifts": _safe_int_or(body.get("lifts"), 0),
            "block": _safe_int_or(body.get("block"), 0),
            "week": _safe_int_or(body.get("week"), 0),
            "computed_at": now_local().isoformat(),
        }
    except (TypeError, ValueError) as e:
        return jsonify({"error": "bad_request", "message": str(e)}), 400
    from memory import set_memory_value  # local: keeps import order flat
    set_memory_value(WIDGET_STRENGTH_KEY, json.dumps(payload))
    return jsonify({"status": "stored", "strength": payload})


@app.route("/api/decision/pending", methods=["GET"])
def api_decision_pending():
    """Proposals waiting for an answer, for the Home card."""
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    from decisions import open_captures  # local: keeps import order flat
    rows = open_captures()
    return jsonify({"captures": [{"id": r.get("id"), "line": r.get("line"), "kind": r.get("kind"),
                                  "text": r.get("text"), "proposed_at": str(r.get("proposed_at") or ""),
                                  "session_id": r.get("session_id")} for r in rows]})


@app.route("/api/decision/answer", methods=["POST"])
def api_decision_answer():
    """{"id": 12, "answer": "record" | "decline"} from the Home card. Record
    applies the line through the same path a chat `Decision:` line takes."""
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    body = request.get_json(silent=True) or {}
    verdict = str(body.get("answer") or "").strip().lower()
    if verdict not in ("record", "decline"):
        return jsonify({"error": "answer must be record or decline"}), 400
    from decisions import answer, open_captures  # local: keeps import order flat
    row = next((r for r in open_captures() if str(r.get("id")) == str(body.get("id"))), None)
    if not row:
        return jsonify({"status": "none", "message": "That proposal is no longer open."}), 409
    try:
        message = answer(row, verdict, load_system_prompt_for_review(), f"card: {verdict}")
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": "answer_failed", "message": f"{type(e).__name__}: {e}"}), 502
    return jsonify({"status": "recorded" if verdict == "record" else "declined", "message": message})


def _app_authorised() -> bool:
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    expected = get_settings().app_api_token
    return bool(expected) and secrets.compare_digest(token, expected)


@app.route("/api/session/open", methods=["POST"])
def api_session_open():
    """START pressed: the programme's card at once, the coach's review on a
    thread. Body: {session_type, message, recovery?, session_id?}. Returns
    {status: reviewing, response} or {status: unavailable} — the app then
    opens through /api/chat as before."""
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    data = request.get_json(force=True) or {}
    session_type = (data.get("session_type") or "").strip()
    message = (data.get("message") or "").strip()
    if not session_type or not message:
        return jsonify({"error": "session_type and message are required"}), 400
    try:
        from session_open import open_session  # local: keeps import order flat
        memory = load_memory()
        result = open_session(session_type, memory, message,
                              recovery_override=_recovery_override_from(data),
                              session_id=data.get("session_id"))
        result["mesocycle_day"] = int(memory.get("mesocycle_day") or 1)
        result["mesocycle_week"] = int(memory.get("mesocycle_week") or 1)
        return jsonify(result)
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": "open_failed", "message": f"{type(e).__name__}: {e}"}), 502


@app.route("/api/session/status", methods=["GET"])
def api_session_status():
    """What the review is doing: none | reviewing | reviewed (+response,
    changes) | failed."""
    if not _app_authorised():
        return jsonify({"error": "Unauthorized"}), 401
    from session_open import session_status  # local: keeps import order flat
    return jsonify(session_status(load_memory()))


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
      { "step": "orphans"|"dupsets"|"sessions"|"sets"|"memory"|"hygiene"|"all",
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

    allowed_steps = {"orphans", "dupsets", "sessions", "sets", "memory", "hygiene", "all"}
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
        "hygiene":  lambda: cleanup_module.cleanup_session_hygiene(supabase, execute),
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
