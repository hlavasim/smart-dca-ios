#!/usr/bin/env python3
"""Výpis 2026 transakcí v kategorii KRevizi, seskupený podle normalizovaného merchanta.
Usage: python inspect_review.py <bank-transactions.json>"""
import sys
import json
from collections import defaultdict
from normalize import normalize_merchant


def main(path):
    sys.stdout.reconfigure(encoding="utf-8")
    txs = json.load(open(path, encoding="utf-8"))["transactions"]
    rev = [t for t in txs if t.get("category") == "KRevizi" and t["date"][:4] == "2026"]
    groups = defaultdict(lambda: {"count": 0, "sum": 0.0, "raw": set()})
    for t in rev:
        g = groups[normalize_merchant(t.get("counterparty"))]
        g["count"] += 1
        g["sum"] += t["amountCzk"]
        g["raw"].add(t.get("counterparty", "") or "")
    print(f"KRevizi 2026: {len(rev)} transakcí, {len(groups)} merchantů\n")
    for key, g in sorted(groups.items(), key=lambda kv: kv[1]["sum"]):
        ex = sorted(g["raw"])[0][:42]
        print(f"{key:18s} {g['count']:3d}x  {g['sum']:11.0f} Kč   např. {ex}")


if __name__ == "__main__":
    main(sys.argv[1])
