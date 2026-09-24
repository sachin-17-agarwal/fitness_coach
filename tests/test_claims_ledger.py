"""docs/CLAIMS.md has teeth: a claim marked `assumed` that is neither
verified nor marked wrong within 14 days fails the suite, so an unchecked
belief cannot quietly age into a fact."""
import re
import unittest
from datetime import date, datetime, timedelta
from pathlib import Path

LEDGER = Path(__file__).resolve().parent.parent / "docs" / "CLAIMS.md"
GRACE_DAYS = 14
_MONTHS = {m: i for i, m in enumerate(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}


def _rows():
    out = []
    for line in LEDGER.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|") or line.startswith("| date") or line.startswith("|---"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 5:
            out.append({"date": cells[0], "claim": cells[1], "basis": cells[2], "verified": cells[3], "outcome": cells[4]})
    return out


def _parse(day: str, year: int) -> date | None:
    m = re.match(r"(\d{1,2}) (\w{3})", day)
    if not m or m.group(2) not in _MONTHS:
        return None
    return date(year, _MONTHS[m.group(2)], int(m.group(1)))


class LedgerTests(unittest.TestCase):
    def test_the_ledger_has_rows_and_every_row_states_a_basis(self):
        rows = _rows()
        self.assertGreater(len(rows), 5)
        for r in rows:
            self.assertTrue(re.search(r"measured|inferred|assumed|wrong", r["basis"], re.I), r)

    def test_an_assumed_claim_is_verified_or_marked_wrong_within_the_grace_period(self):
        today = datetime.now().date()
        overdue = []
        for r in _rows():
            if "assumed" not in r["basis"].lower():
                continue
            if r["verified"] not in ("", "—", "-"):
                continue
            made = _parse(r["date"], today.year) or today
            if made > today:  # a January row read in December
                made = made.replace(year=today.year - 1)
            if (today - made).days > GRACE_DAYS:
                overdue.append(f"{r['date']}: {r['claim'][:80]}")
        self.assertEqual(overdue, [], "assumed claims past their grace period — verify them or mark them wrong:\n"
                         + "\n".join(overdue))
