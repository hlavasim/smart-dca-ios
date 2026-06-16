#!/usr/bin/env python3
"""Top merchanti 2026 podle celkové útraty (výdaje krom investic/převodů).
Ukáže i kategorie, ve kterých merchant vystupuje (multi-kategorie = kandidát na line-item detail).
Usage: python top_merchants.py <bank-transactions.json> <categories.json> [N]"""
import sys
import os
import json
from collections import defaultdict
from normalize import canonical_merchant, build_patterns


def main(bt_path, cat_path, n):
    sys.stdout.reconfigure(encoding="utf-8")
    txs = json.load(open(bt_path, encoding="utf-8"))["transactions"]
    meta = {c["name"]: c for c in json.load(open(cat_path, encoding="utf-8"))["categories"]}
    rules_path = os.path.join(os.path.dirname(cat_path), "category-rules.json")
    rules = json.load(open(rules_path, encoding="utf-8")).get("rules", []) if os.path.exists(rules_path) else []
    patterns = build_patterns(rules)

    agg = defaultdict(lambda: {"sum": 0.0, "count": 0, "cats": defaultdict(float), "raw": ""})
    for t in txs:
        if t["date"][:4] != "2026" or t["amountCzk"] >= 0:
            continue
        c = meta.get(t.get("category"))
        if not c or c.get("isPrivate") or c.get("excludeFromCashflow") or c.get("scope") == "Převod":
            continue
        m = canonical_merchant(t.get("counterparty"), patterns)
        if not m:
            continue
        a = agg[m]
        a["sum"] += -t["amountCzk"]
        a["count"] += 1
        a["cats"][t["category"]] += -t["amountCzk"]
        if not a["raw"]:
            a["raw"] = t.get("counterparty", "")

    ranked = sorted(agg.items(), key=lambda kv: -kv[1]["sum"])[:n]
    print(f"TOP {n} merchantů 2026 (od 1.1.) podle útraty:\n")
    print(f"{'#':>2} {'merchant':16s} {'celkem':>10}  {'×':>3}  kategorie (rozpad)")
    for i, (m, a) in enumerate(ranked, 1):
        cats = sorted(a["cats"].items(), key=lambda kv: -kv[1])
        multi = "  ⟵ DETAIL?" if len(cats) >= 2 else ""
        cat_str = ", ".join(f"{k} {int(v):,}".replace(",", " ") for k, v in cats[:3])
        print(f"{i:>2} {m[:16]:16s} {int(a['sum']):>9,} Kč".replace(",", " ")
              + f"  {a['count']:>3}  {cat_str}{multi}")


if __name__ == "__main__":
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    main(sys.argv[1], sys.argv[2], n)
