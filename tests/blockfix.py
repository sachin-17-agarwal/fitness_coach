"""The suite describes the programme's rules with the block it was written
against: three loading weeks and a deload (block_weeks = 4). From 24 Sep 2026
the live default is five (four loading weeks and a deload, the bulk's block)
and the length is a setting the app writes. Importing this module pins the
legacy suite to four; tests of the five-week wave and of the switch patch
data.block_weeks themselves (tests/test_block_length.py).

Imported by every test module: `unittest discover -s tests` loads modules
top-level, so tests/__init__.py never runs."""
import data

data._block_cache.update(at=float("inf"), weeks=4)
