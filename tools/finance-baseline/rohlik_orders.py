#!/usr/bin/env python3
"""Z Rohlík MCP order dumpů (fetch_orders výstupy) udělá Tier 2 overlay: většina Potraviny,
vykrojí pet (Zvířata), drogerii (Drogerie) a pár Nákupy/Zdraví. Spáruje na bankovní Rohlík
platby (částka + datum) a zapíše do transaction-items.json.

Usage: python rohlik_orders.py <orders_glob> <bank-transactions.json> <categories.json> [--write <items.json>]
  <orders_glob> = cesta s * na fetch_orders .txt soubory (JSON {result:{orders:[...]}})
"""
import sys
import os
import re
import glob
import json
from datetime import date as D
from collections import defaultdict
from normalize import canonical_merchant, build_patterns


def categorize(name):
    n = name.lower()

    def has(*ws):
        return any(w in n for w in ws)

    if has("for cats", "for dogs", "stelivo", "pro psy", "pro kočky", "pro kocky",
           "granule", "krmivo", "pamls", "pro mazlíč", "kočkolit"):
        if has("cats", "kočk", "kocky", "stelivo"):
            return "Zvířata", "Kočka"
        if has("dogs", "psy", "pes"):
            return "Zvířata", "Pes"
        return "Zvířata", None
    if has("kuchyňské utěrky", "utěrky", "vlhčené ubrousky", "dezinfekč", "ubrousky",
           "toaletní papír", "prací", "čistič", "savo", "mýdlo", "šampon", "aviváž",
           "jar ", "drogerie", "tekuté mýdlo", "osvěžovač", "wc "):
        return "Drogerie", None
    if has("repelent", "klíšťat", "pinzeta", "léčiv", "doplněk stravy", "vitamín",
           "vitamin", "náplast", " mast", "lékárn"):
        return "Zdraví", None
    if has("kreslicí karton", "karton a4", "motouz", "sodastream", " co2",
           "alobal", "houbičk", "žárovk", "pytle na", "svíčk"):
        return "Nákupy", None
    return "Potraviny", None  # default: jídlo/pití


def dd(s):
    return D(int(s[:4]), int(s[5:7]), int(s[8:10]))


def main(orders_glob, bt_path, cat_path, write_path=None):
    sys.stdout.reconfigure(encoding="utf-8")
    orders = []
    for f in sorted(glob.glob(orders_glob)):
        data = json.load(open(f, encoding="utf-8"))
        for o in data.get("result", {}).get("orders", []):
            orders.append({
                "id": o["id"],
                "date": o["orderTime"][:10],
                "total": round(o["priceComposition"]["total"]["amount"], 2),
                "items": [(it["name"], round(it["totalPrice"], 2)) for it in o.get("items", [])],
            })
    # dedup objednávek dle id (měsíce se můžou překrývat)
    uniq = {o["id"]: o for o in orders}
    orders = list(uniq.values())

    txs = json.load(open(bt_path, encoding="utf-8"))["transactions"]
    rules = json.load(open(os.path.join(os.path.dirname(cat_path), "category-rules.json"),
                            encoding="utf-8")).get("rules", [])
    patterns = build_patterns(rules)
    rohlik = [t for t in txs if canonical_merchant(t.get("counterparty"), patterns) == "ROHLIK"
              and t["date"][:4] == "2026" and t["amountCzk"] < 0]

    overlay = {}
    used = set()
    cat_totals = defaultdict(float)
    matched = 0
    for o in sorted(orders, key=lambda x: x["date"]):
        cand = [x for x in rohlik if id(x) not in used
                and abs(abs(x["amountCzk"]) - o["total"]) < 1.0
                and abs((dd(x["date"][:10]) - dd(o["date"])).days) <= 4]
        if not cand:
            continue
        cand.sort(key=lambda x: abs((dd(x["date"][:10]) - dd(o["date"])).days))
        tx = cand[0]
        used.add(id(tx))
        matched += 1
        line_items, isum = [], 0.0
        for name, price in o["items"]:
            cat, sub = categorize(name)
            line_items.append({"category": cat, "subcategory": sub, "amountCzk": -price})
            cat_totals[cat] += price
            isum += price
        overhead = round(o["total"] - isum, 2)   # tip + balení − kredity
        if abs(overhead) >= 0.01:
            line_items.append({"category": "Nákupy", "subcategory": "Servis/doprava", "amountCzk": -overhead})
            cat_totals["Nákupy"] += overhead
        overlay[tx["id"]] = line_items

    print(f"Objednávek: {len(orders)} | Rohlík plateb (2026): {len(rohlik)} | spárováno: {matched}")
    print("\n=== rozpad podle kategorií (spárované) ===")
    for c, v in sorted(cat_totals.items(), key=lambda kv: -kv[1]):
        print(f"  {c:12s} {int(v):>8,} Kč".replace(",", " "))

    if write_path:
        existing = json.load(open(write_path, encoding="utf-8")) if os.path.exists(write_path) else {"version": 1, "items": {}}
        existing.setdefault("items", {}).update(overlay)
        json.dump(existing, open(write_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        open(write_path, "a", encoding="utf-8").write("\n")
        print(f"\nZapsáno {len(overlay)} objednávek do {write_path}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--write"]
    wi = sys.argv.index("--write") if "--write" in sys.argv else None
    write_path = sys.argv[wi + 1] if wi else None
    if write_path and write_path in args:
        args.remove(write_path)
    main(args[0], args[1], args[2], write_path)
