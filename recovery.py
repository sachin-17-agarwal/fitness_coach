"""Today's recovery, read the way the evidence says to read it.

The rules used to compare one day's HRV with the last seven days' mean and
act at 10% and 20% below. The Apple Watch reports SDNN from a handful of
daytime samples, not the overnight rMSSD the research uses, and its
day-to-day noise is large — a 10% dip is inside normal variation most
mornings, so RPE targets came down on noise, and a seven-day baseline that
contains the dip hides the trend it is meant to show. Sleep was judged on
one night against hard edges: fifteen minutes moved a session across the
six-hour line and cut every top set 5%. Nothing asked the athlete how he
felt, although self-report tracks training load better than any of the
readings (Saw 2016).

This module reads the same numbers differently:

- HRV on the natural log, as a 7-day rolling average against a 42-day
  baseline, with the smallest worthwhile change at half the baseline's
  standard deviation (Plews & Buchheit). The rolling average decides; a
  single day only flags.
- Resting HR the same way, unlogged.
- Sleep on a slide — no cut at 6.5h, 5% at 5h — and applied only when a
  second signal agrees. One short night alone is noted; the RPE targets
  autoregulate the rest (Craven 2022: strength is the least affected
  category, and the cost is real but modest).
- Readiness, 1-5, tapped at session start. Low readiness lowers effort on
  its own; a load cut needs readings AND the athlete to agree.

The levers are unchanged: RPE targets come down a point (one rep at the
same load), load comes down 5%, or the session becomes a recovery session.
What changed is when they fire.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import date, timedelta

ROLLING_DAYS = 7
BASELINE_DAYS = 42
MIN_ROLLING = 3
MIN_BASELINE = 10
SWC_SD = 0.5              # smallest worthwhile change, in baseline SDs
TODAY_FLAG_SD = 1.5       # a single day this far under is worth a mention
SLEEP_FULL = 6.5          # no load cut at or above this
SLEEP_FLOOR = 5.0         # the full 5% cut at this; under it, "very short"
SLEEP_MAX_CUT = 0.05
SHORT_NIGHT = 6.0


@dataclass(frozen=True)
class Trend:
    """A 7-day rolling mean against a longer baseline, in the metric's units
    (ln for HRV, bpm for RHR)."""
    today: float | None
    rolling: float | None
    baseline: float | None
    sd: float | None
    n_rolling: int
    n_baseline: int

    @property
    def swc(self) -> float | None:
        return None if self.sd is None else SWC_SD * self.sd

    @property
    def z(self) -> float | None:
        """Rolling mean minus baseline, in baseline SDs."""
        if self.rolling is None or self.baseline is None or not self.sd:
            return None
        return (self.rolling - self.baseline) / self.sd

    @property
    def today_z(self) -> float | None:
        if self.today is None or self.baseline is None or not self.sd:
            return None
        return (self.today - self.baseline) / self.sd


@dataclass(frozen=True)
class RecoveryRead:
    hrv: Trend | None
    rhr: Trend | None
    sleep_hours: float | None
    sleep_last_two: tuple = ()
    readiness: int | None = None

    # ── signals ──────────────────────────────────────────────────────────
    @property
    def hrv_below(self) -> bool:
        return self.hrv is not None and self.hrv.z is not None and self.hrv.z < -SWC_SD

    @property
    def hrv_well_below(self) -> bool:
        return self.hrv is not None and self.hrv.z is not None and self.hrv.z < -2 * SWC_SD

    @property
    def hrv_today_flag(self) -> bool:
        return self.hrv is not None and self.hrv.today_z is not None and self.hrv.today_z < -TODAY_FLAG_SD

    @property
    def rhr_elevated(self) -> bool:
        return self.rhr is not None and self.rhr.z is not None and self.rhr.z > SWC_SD

    @property
    def sleep_multiplier(self) -> float:
        return sleep_multiplier(self.sleep_hours)

    @property
    def sleep_short(self) -> bool:
        return self.sleep_hours is not None and self.sleep_hours < SLEEP_FULL

    @property
    def sleep_very_short(self) -> bool:
        return self.sleep_hours is not None and self.sleep_hours < SLEEP_FLOOR

    @property
    def two_short_nights(self) -> bool:
        return len(self.sleep_last_two) == 2 and all(h is not None and h < SHORT_NIGHT for h in self.sleep_last_two)

    @property
    def readiness_low(self) -> bool:
        return self.readiness is not None and self.readiness <= 2


def sleep_multiplier(hours: float | None) -> float:
    """1.0 at 6.5h and above, sliding to 0.95 at 5h and below."""
    if hours is None:
        return 1.0
    if hours >= SLEEP_FULL:
        return 1.0
    if hours <= SLEEP_FLOOR:
        return 1.0 - SLEEP_MAX_CUT
    frac = (SLEEP_FULL - hours) / (SLEEP_FULL - SLEEP_FLOOR)
    return round(1.0 - SLEEP_MAX_CUT * frac, 4)


def _mean(xs):
    return sum(xs) / len(xs) if xs else None


def _sd(xs):
    if len(xs) < 2:
        return None
    m = _mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def trend(series: dict, today: str, transform=lambda v: v) -> Trend | None:
    """`series` maps ISO date -> value. Rolling window is the 7 days ending
    today; the baseline is the 42 days before that window."""
    try:
        t = date.fromisoformat(today)
    except (TypeError, ValueError):
        return None
    vals = {}
    for d, v in (series or {}).items():
        try:
            if v is None:
                continue
            fv = float(v)
            if fv <= 0:
                continue
            vals[date.fromisoformat(str(d))] = transform(fv)
        except (TypeError, ValueError):
            continue
    if not vals:
        return None
    roll_start = t - timedelta(days=ROLLING_DAYS - 1)
    base_start = roll_start - timedelta(days=BASELINE_DAYS)
    rolling = [v for d, v in vals.items() if roll_start <= d <= t]
    baseline = [v for d, v in vals.items() if base_start <= d < roll_start]
    if len(baseline) < MIN_BASELINE:
        # Not enough history behind the window: use everything before the
        # window rather than nothing, and say how thin it is via n_baseline.
        baseline = [v for d, v in vals.items() if d < roll_start]
    today_v = vals.get(t)
    return Trend(today=today_v,
                 rolling=_mean(rolling) if len(rolling) >= MIN_ROLLING else None,
                 baseline=_mean(baseline) if len(baseline) >= MIN_BASELINE else None,
                 sd=_sd(baseline) if len(baseline) >= MIN_BASELINE else None,
                 n_rolling=len(rolling), n_baseline=len(baseline))


def build_read(rows: list[dict], today: str, today_row: dict | None = None,
               readiness: int | None = None) -> RecoveryRead:
    """From recovery rows (date, hrv, resting_hr, sleep_hours, readiness) to
    today's read. `today_row` overrides today's values (the app's live
    snapshot); `readiness` overrides the stored one."""
    hrv_series, rhr_series, sleep_series = {}, {}, {}
    stored_readiness = None
    for r in rows or []:
        d = str(r.get("date") or "")
        if not d:
            continue
        if r.get("hrv") is not None:
            hrv_series[d] = r["hrv"]
        if r.get("resting_hr") is not None:
            rhr_series[d] = r["resting_hr"]
        if r.get("sleep_hours") is not None:
            sleep_series[d] = r["sleep_hours"]
        if d == today and r.get("readiness") is not None:
            stored_readiness = r["readiness"]
    for key, series in (("hrv", hrv_series), ("resting_hr", rhr_series), ("sleep_hours", sleep_series)):
        v = (today_row or {}).get(key)
        if isinstance(v, (int, float)) and v > 0:
            series[today] = float(v)
    sleep_today = sleep_series.get(today)
    try:
        yday = (date.fromisoformat(today) - timedelta(days=1)).isoformat()
        last_two = (sleep_series.get(yday), sleep_today) if sleep_today is not None else ()
    except (TypeError, ValueError):
        last_two = ()
    r = readiness if readiness is not None else stored_readiness
    try:
        r = int(r) if r is not None else None
        if r is not None and not (1 <= r <= 5):
            r = None
    except (TypeError, ValueError):
        r = None
    return RecoveryRead(hrv=trend(hrv_series, today, math.log),
                       rhr=trend(rhr_series, today),
                       sleep_hours=float(sleep_today) if sleep_today is not None else None,
                       sleep_last_two=tuple(float(h) if h is not None else None for h in last_two),
                       readiness=r)


# ── The decision ─────────────────────────────────────────────────────────────

def decide(read: RecoveryRead) -> tuple[float, float, bool, list[str]]:
    """(rpe_delta, load_multiplier, recovery_session, reasons)."""
    reasons: list[str] = []
    hrv, rhr = read.hrv, read.rhr

    def hrv_words():
        z = hrv.z
        pct = (math.exp(hrv.rolling - hrv.baseline) - 1) * 100
        return (f"HRV 7-day average {abs(pct):.0f}% {'under' if pct < 0 else 'over'} your 6-week baseline "
                f"({z:+.1f} SD; the normal band is ±{SWC_SD:g} SD, n={hrv.n_baseline})")

    # Recovery session: two independent signals, at least one of them hard.
    if (read.hrv_well_below and (read.readiness_low or read.sleep_very_short)) or \
            (read.sleep_very_short and read.readiness_low):
        if read.hrv_well_below:
            reasons.append(hrv_words())
        if read.sleep_very_short:
            reasons.append(f"{read.sleep_hours:g}h sleep, under {SLEEP_FLOOR:g}")
        if read.readiness_low:
            reasons.append(f"readiness {read.readiness}/5")
        reasons.append("two signals agree, so today is a recovery session — it protects the block")
        return 0.0, 1.0, True, reasons

    rpe_delta = 0.0
    multiplier = 1.0
    primary = []
    if read.hrv_below:
        primary.append(hrv_words())
    if read.readiness_low:
        primary.append(f"readiness {read.readiness}/5 — you say you are not fresh, and that outranks the watch")
    if read.two_short_nights:
        primary.append(f"two short nights running ({', '.join(f'{h:g}h' for h in read.sleep_last_two)})")
    if primary:
        rpe_delta = -1.0
        reasons.extend(primary)
        reasons.append("RPE targets come down a point — one rep fewer at the same load")

    if read.sleep_short:
        second = (read.hrv_below or read.hrv_today_flag or read.readiness_low
                  or read.rhr_elevated or read.two_short_nights)
        if second:
            multiplier = read.sleep_multiplier
            reasons.append(f"{read.sleep_hours:g}h sleep with a second signal agreeing, so the top set comes "
                           f"down {(1 - multiplier) * 100:.0f}%")
        else:
            reasons.append(f"{read.sleep_hours:g}h sleep on its own: targets hold — the watch and how you "
                           f"feel say nothing else is off. If the first top set comes in a point hard, "
                           f"the next set comes down")
    elif read.hrv_today_flag and not read.hrv_below:
        reasons.append(f"today's single HRV reading is {abs(hrv.today_z):.1f} SD under baseline while the "
                       f"7-day average is normal — noted, not acted on; one day is noise on this watch")

    if read.rhr_elevated:
        reasons.append(f"resting HR 7-day average {rhr.rolling - rhr.baseline:+.1f} bpm over baseline "
                       f"({rhr.z:+.1f} SD) — possible overreaching, worth asking how he feels")
    if read.readiness is not None and read.readiness >= 4 and not primary and multiplier == 1.0:
        reasons.append(f"readiness {read.readiness}/5 and readings normal — full session")
    return rpe_delta, multiplier, False, reasons


def format_read(read: RecoveryRead | None) -> str:
    """The block the coach reads. States the signals and the decision so the
    coach does not re-derive either from raw percentages."""
    if read is None:
        return "TODAY'S RECOVERY READ: unavailable (no history)."
    lines = ["TODAY'S RECOVERY READ — computed; the PROGRAMME PROPOSAL already applies it. "
             "State it, do not re-derive it from the raw numbers above:"]
    if read.hrv and read.hrv.z is not None:
        pct = (math.exp(read.hrv.rolling - read.hrv.baseline) - 1) * 100
        lines.append(f"  HRV: 7-day average {pct:+.0f}% vs 6-week baseline ({read.hrv.z:+.1f} SD, band ±{SWC_SD:g}) "
                     f"— {'BELOW' if read.hrv_below else 'normal'}"
                     + (f"; today alone {read.hrv.today_z:+.1f} SD" if read.hrv.today_z is not None else ""))
    elif read.hrv:
        lines.append(f"  HRV: baseline still building ({read.hrv.n_baseline} days; needs {MIN_BASELINE}) — not judged")
    else:
        lines.append("  HRV: no readings")
    if read.rhr and read.rhr.z is not None:
        lines.append(f"  Resting HR: 7-day average {read.rhr.rolling - read.rhr.baseline:+.1f} bpm vs baseline "
                     f"({read.rhr.z:+.1f} SD) — {'ELEVATED' if read.rhr_elevated else 'normal'}")
    if read.sleep_hours is not None:
        lines.append(f"  Sleep: {read.sleep_hours:g}h last night"
                     + (f", {read.sleep_last_two[0]:g}h the night before" if read.two_short_nights or
                        (len(read.sleep_last_two) == 2 and read.sleep_last_two[0] is not None) else "")
                     + (" — TWO SHORT NIGHTS" if read.two_short_nights else
                        (" — short" if read.sleep_short else " — fine")))
    else:
        lines.append("  Sleep: not recorded (watch off or not synced) — not judged")
    lines.append(f"  Readiness: {read.readiness}/5" if read.readiness is not None
                 else "  Readiness: not tapped at START — the athlete's own report is missing, so only "
                      "the readings speak")
    rpe, mult, rec, reasons = decide(read)
    if rec:
        lines.append("  DECISION: RECOVERY SESSION — " + "; ".join(reasons))
    elif rpe or mult != 1.0:
        parts = []
        if rpe:
            parts.append(f"RPE targets {rpe:+.0f}")
        if mult != 1.0:
            parts.append(f"top-set load ×{mult:g}")
        lines.append("  DECISION: " + ", ".join(parts) + " — " + "; ".join(reasons))
    else:
        lines.append("  DECISION: full session as planned" + (" — " + "; ".join(reasons) if reasons else ""))
    return "\n".join(lines)


def read_as_dict(read: RecoveryRead) -> dict:
    """Carried inside the recovery dict for prescribe.recovery_adjustment."""
    rpe, mult, rec, reasons = decide(read)
    return {"rpe_delta": rpe, "load_multiplier": mult, "recovery_session": rec, "reasons": reasons,
            "hrv_z": None if not read.hrv else read.hrv.z, "readiness": read.readiness}
