#!/usr/bin/env python3
"""Regenerate muscle_map.py from the iOS ExerciseCatalog.

The exercise -> muscle-group mapping is authored once, in Swift
(Vaux/Vaux/Services/ExerciseCatalog.swift), because that is where the
Volume and Strength tabs consume it. The coach needs the same mapping
server-side to report weekly volume, and hand-copying ~200 entries is a
guaranteed source of drift — so it is generated instead.

Run after editing builtinGroups in the Swift catalog:

    python tools/generate_muscle_map.py
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "Vaux/Vaux/Services/ExerciseCatalog.swift"
OUT = ROOT / "muscle_map.py"

ENTRY = re.compile(r'"([^"]+)"\s*:\s*"([^"]+)"')


def extract_block(source: str, declaration: str) -> str:
    """Return the bracketed literal assigned to `declaration`.

    Skips past the type annotation — `let x: [String: String] = [` has a
    bracket before the one we want.
    """
    start = source.index(declaration)
    open_bracket = source.index("= [", start) + 2
    depth = 0
    for i in range(open_bracket, len(source)):
        if source[i] == "[":
            depth += 1
        elif source[i] == "]":
            depth -= 1
            if depth == 0:
                return source[open_bracket : i + 1]
    raise ValueError(f"unterminated literal after {declaration!r}")


def main() -> None:
    source = SWIFT.read_text()

    # Anchor on `let <name>` — the bare name also appears where the map is
    # referenced, which is earlier in the file than its declaration.
    groups = dict(ENTRY.findall(extract_block(source, "let builtinGroups")))
    bodyweight = re.findall(r'"([^"]+)"', extract_block(source, "let bodyweightMovements"))

    if not groups:
        raise SystemExit("no entries parsed — did the Swift literal change shape?")

    lines = [
        '"""Exercise name -> muscle group, for server-side volume reporting.',
        "",
        "GENERATED FILE — do not edit by hand.",
        "Source: Vaux/Vaux/Services/ExerciseCatalog.swift",
        "Regenerate: python tools/generate_muscle_map.py",
        '"""',
        "",
        "MUSCLE_GROUPS: dict[str, str] = {",
    ]
    for name in sorted(groups):
        lines.append(f'    "{name}": "{groups[name]}",')
    lines.append("}")
    lines.append("")
    lines.append("BODYWEIGHT_MOVEMENTS: tuple[str, ...] = (")
    for name in sorted(set(bodyweight)):
        lines.append(f'    "{name}",')
    lines.append(")")
    lines.append("")

    OUT.write_text("\n".join(lines))
    print(f"wrote {OUT.name}: {len(groups)} exercises, {len(set(bodyweight))} bodyweight movements")


if __name__ == "__main__":
    main()
