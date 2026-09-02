"""Command-line front end for the Pull-day replay.

The work lives in replay.py so the web process can import it without pulling in
a CLI script — see /admin/replay in webhook.py, which is how this runs when the
database is only reachable from the server.

    python tools/replay_pull.py                       # last 90 days
    python tools/replay_pull.py --days 180
    python tools/replay_pull.py --export history.json # no credentials in the file
    python tools/replay_pull.py --from-json history.json

Read the output for three things, most valuable first:

  !          what the programme does not determine at all. Every line is a
             decision the coach has been making with nothing to check it against.

  DIVERGE    where the algorithm and the logged session disagree. A question,
             not a verdict — it may be the programme on paper and the programme
             as performed having drifted apart.

  match      where they agree. This is the part that no longer needs a language
             model.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from replay import build_report, fetch_pull_sessions  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--week", type=int, default=1,
                        help="mesocycle week to assume for sessions that neither "
                             "record one nor can have one reconstructed")
    parser.add_argument("--export", metavar="FILE",
                        help="dump the fetched history to JSON and exit. Training "
                             "data only — no credentials — so it is safe to share.")
    parser.add_argument("--from-json", metavar="FILE", dest="from_json",
                        help="replay a file written by --export. Needs no "
                             "credentials and no database.")
    args = parser.parse_args()

    notes: list[str] = []
    if args.from_json:
        with open(args.from_json, encoding="utf-8") as handle:
            sessions = json.load(handle)
    else:
        try:
            sessions, notes = fetch_pull_sessions(args.days)
        except RuntimeError as e:
            raise SystemExit(str(e))

    if args.export:
        with open(args.export, "w", encoding="utf-8") as handle:
            json.dump(sessions, handle, indent=2, default=str)
        print(f"Wrote {len(sessions)} Pull sessions to {args.export}. "
              f"No credentials are in this file.")
        return

    print(build_report(sessions, default_week=args.week, notes=notes))


if __name__ == "__main__":
    main()
