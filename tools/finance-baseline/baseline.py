#!/usr/bin/env python3
"""Spočítá dvouúrovňový finance baseline (Tier1 kategorie×merchant, Tier2 kategorie×subkategorie)
z finančních dat. Medián měsíčně, bez částečného aktuálního měsíce, bez investic a transferů.
Usage: python baseline.py <bank-transactions.json> <categories.json> [transaction-items.json] [--as-of YYYY-MM-DD]
Výstup: finance-baseline.json na stdout."""
import sys
import json
import statistics
from collections import defaultdict
from datetime import date
from normalize import normalize_merchant

YEAR = 2026
ALLOWED_SCOPES = {"Domácnost", "Byznys"}


def _median0(values):
    return round(statistics.median(values)) if values else 0


def main(bt_path, cat_path, items_path, as_of):
    sys.stdout.reconfigure(encoding="utf-8")
    txs = json.load(open(bt_path, encoding="utf-8"))["transactions"]
    cats = json.load(open(cat_path, encoding="utf-8"))["categories"]
    items = json.load(open(items_path, encoding="utf-8")).get("items", {}) if items_path else {}
    meta = {c["name"]: c for c in cats}
    cur_ym = (as_of.year, as_of.month)

    def included(t):
        c = meta.get(t.get("category"))
        if not c or c.get("excludeFromCashflow") or c.get("isPrivate"):
            return False
        if c.get("scope") not in ALLOWED_SCOPES:
            return False
        if t["amountCzk"] >= 0:           # jen výdaje
            return False
        d = t["date"]
        if d[:4] != str(YEAR):
            return False
        if (int(d[:4]), int(d[5:7])) == cur_ym:   # částečný aktuální měsíc pryč
            return False
        return True

    cat_m = defaultdict(lambda: defaultdict(float))            # cat -> month -> sum
    merch_m = defaultdict(lambda: defaultdict(float))          # (cat, merchant) -> month -> sum
    sub_m = defaultdict(lambda: defaultdict(float))            # (cat, sub, fromMerchant) -> month -> sum
    months = set()

    for t in txs:
        if not included(t):
            continue
        ym = t["date"][:7]
        months.add(ym)
        merchant = normalize_merchant(t.get("counterparty"))
        line_items = items.get(t["id"])
        if line_items:
            for li in line_items:
                amt = abs(li["amountCzk"])
                lc = li["category"]
                cat_m[lc][ym] += amt
                if li.get("subcategory"):
                    sub_m[(lc, li["subcategory"], merchant)][ym] += amt
                else:
                    merch_m[(lc, merchant)][ym] += amt
        else:
            c = t["category"]
            cat_m[c][ym] += abs(t["amountCzk"])
            merch_m[(c, merchant)][ym] += abs(t["amountCzk"])

    def med(month_map):
        return _median0(list(month_map.values()))

    categories_out = []
    all_names = set(cat_m) | {k[0] for k in merch_m} | {k[0] for k in sub_m}
    for name in sorted(all_names):
        merchants = [
            {"name": m, "monthlyMedianCzk": med(mm),
             "hasDetail": any(k[0] == name and k[2] == m for k in sub_m)}
            for (cc, m), mm in merch_m.items() if cc == name
        ]
        subs = [
            {"name": s, "monthlyMedianCzk": med(sm), "fromMerchant": fm}
            for (cc, s, fm), sm in sub_m.items() if cc == name
        ]
        entry = {"name": name, "monthlyMedianCzk": med(cat_m.get(name, {}))}
        if merchants:
            entry["merchants"] = sorted(merchants, key=lambda x: -x["monthlyMedianCzk"])
        if subs:
            entry["subcategories"] = sorted(subs, key=lambda x: -x["monthlyMedianCzk"])
        categories_out.append(entry)

    paydays = [int(t["date"][8:10]) for t in txs
               if "SOFTIM" in (t.get("counterparty") or "").upper()
               and t["amountCzk"] > 0 and t["date"][:4] == str(YEAR)]
    payday = round(sum(paydays) / len(paydays)) if paydays else 27

    out = {
        "version": 1,
        "generatedAt": as_of.isoformat() + "T00:00:00Z",
        "sourceYear": YEAR,
        "monthsCounted": len(months),
        "scope": "household",
        "payday": {"dayOfMonth": payday, "source": "avg(SOFTIM dates)"},
        "categories": categories_out,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    args = sys.argv[1:]
    as_of = date.today()
    if "--as-of" in args:
        i = args.index("--as-of")
        as_of = date.fromisoformat(args[i + 1])
        args = args[:i] + args[i + 2:]
    bt, cat = args[0], args[1]
    it = args[2] if len(args) > 2 else None
    main(bt, cat, it, as_of)
