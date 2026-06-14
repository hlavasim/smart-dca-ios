import json
import subprocess
import sys
import pathlib

BASE = pathlib.Path(__file__).parent


def test_golden():
    out = subprocess.check_output([sys.executable, str(BASE / "convert.py"), str(BASE / "sample")])
    got = json.loads(out)
    expected = json.loads((BASE / "sample" / "expected_snapshot.json").read_text(encoding="utf-8"))
    got.pop("exportedAt", None)
    expected.pop("exportedAt", None)
    assert got == expected
