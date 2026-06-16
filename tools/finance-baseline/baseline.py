#!/usr/bin/env python3
"""Spočítá dvouúrovňový finance baseline (Tier1 kategorie×merchant, Tier2 kategorie×subkategorie)
z finančních dat. Medián měsíčně, bez částečného aktuálního měsíce, bez investic a transferů.
Usage: python baseline.py <bank-transactions.json> <categories.json> [transaction-items.json] [--as-of YYYY-MM-DD]
Výstup: finance-baseline.json na stdout."""
import sys
import os
import json
import statistics
from collections import defaultdict
from datetime import date
from normalize import canonical_merchant, build_patterns

YEAR = 2026


def _median0(values):
    return round(statistics.median(values)) if values else 0


def main(bt_path, cat_path, items_path, as_of):
    sys.stdout.reconfigure(encoding="utf-8")
    txs = json.load(open(bt_path, encoding="utf-8"))["transactions"]
    cats = json.load(open(cat_path, encoding="utf-8"))["categories"]
    items = json.load(open(items_path, encoding="utf-8")).get("items", {}) if items_path else {}
    meta = {c["name"]: c for c in cats}
    cur_ym = (as_of.year, as_of.month)

    # merchant grouping podle kurátorovaných pravidel (category-rules.json vedle categories.json)
    rules_path = os.path.join(os.path.dirname(cat_path), "category-rules.json")
    rules = json.load(open(rules_path, encoding="utf-8")).get("rules", []) if os.path.exists(rules_path) else []
    patterns = build_patterns(rules)

    def included(t):
        # Všechny výdaje KROMĚ investic (isPrivate) a převodů/čerpání úvěru
        # (scope "Převod" + excludeFromCashflow = interní přesuny / úvěrové operace, ne výdaj).
        c = meta.get(t.get("category"))
        if not c or c.get("isPrivate") or c.get("excludeFromCashflow") or c.get("scope") == "Převod":
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
    sub_m = defaultdict(lambda: defaultdict(float))            # (cat, sub) -> month -> sum (napříč merchanty)
    months = set()

    for t in txs:
        if not included(t):
            continue
        ym = t["date"][:7]
        months.add(ym)
        merchant = canonical_merchant(t.get("counterparty"), patterns)
        line_items = items.get(t["id"])
        if line_items:
            for li in line_items:
                amt = -li["amountCzk"]   # znaménkově: výdaj (záporný) → kladný, sleva (kladná) → odečte
                lc = li["category"]
                cat_m[lc][ym] += amt
                if li.get("subcategory"):
                    sub_m[(lc, li["subcategory"])][ym] += amt
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
            {"name": m, "monthlyMedianCzk": med(mm)}
            for (cc, m), mm in merch_m.items() if cc == name
        ]
        subs = [
            {"name": s, "monthlyMedianCzk": med(sm)}
            for (cc, s), sm in sub_m.items() if cc == name
        ]
        entry = {"name": name, "monthlyMedianCzk": med(cat_m.get(name, {}))}
        if merchants:
            entry["merchants"] = sorted(merchants, key=lambda x: -x["monthlyMedianCzk"])
        if subs:
            entry["subcategories"] = sorted(subs, key=lambda x: -x["monthlyMedianCzk"])
        categories_out.append(entry)

    # Příjem: median měsíčně z příjmových kategorií (type Income), bez částečného měsíce.
    income_m = defaultdict(float)
    for t in txs:
        c = meta.get(t.get("category"))
        if not c or c.get("type") != "Income" or c.get("excludeFromCashflow") or c.get("isPrivate"):
            continue
        if t["amountCzk"] <= 0 or t["date"][:4] != str(YEAR):
            continue
        if (int(t["date"][:4]), int(t["date"][5:7])) == cur_ym:
            continue
        income_m[t["date"][:7]] += t["amountCzk"]
    income_median = _median0(list(income_m.values()))

    # Skutečný deficit (výdaje − příjem) za poslední 3 uzavřené měsíce, průměr.
    # Kladné = pálíš víc, než vyděláš. Pro „runway na nulu" dle reálu, ne jen mediánu.
    month_exp = defaultdict(float)
    for mm in cat_m.values():
        for ym, v in mm.items():
            month_exp[ym] += v
    recent_months = sorted(months)[-3:]
    recent_deficits = [month_exp.get(ym, 0.0) - income_m.get(ym, 0.0) for ym in recent_months]
    recent_avg_deficit = round(sum(recent_deficits) / len(recent_deficits)) if recent_deficits else 0

    paydays = [int(t["date"][8:10]) for t in txs
               if "SOFTIM" in (t.get("counterparty") or "").upper()
               and t["amountCzk"] > 0 and t["date"][:4] == str(YEAR)]
    payday = round(sum(paydays) / len(paydays)) if paydays else 27

    out = {
        "version": 1,
        "generatedAt": as_of.isoformat() + "T00:00:00Z",
        "sourceYear": YEAR,
        "monthsCounted": len(months),
        "scope": "all-except-investments",
        "incomeMedianCzk": income_median,
        "recentCyclesAvgDeficitCzk": recent_avg_deficit,
        "recentCyclesCount": len(recent_months),
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
