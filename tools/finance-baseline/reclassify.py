#!/usr/bin/env python3
"""Aplikuje review-mapping.json (NORMALIZED merchant -> kategorie) na KRevizi 2026 transakce.
Cílová textová náhrada: změní jen category řádek u 67 cílových transakcí (podle id),
zbytek souboru zůstane byte-identický (zachová formát/escaping C# serializeru).
Usage: python reclassify.py <bank-transactions.json> <review-mapping.json>"""
import sys
import json
import os
from normalize import normalize_merchant

OLD = '"category": "KRevizi"'


def main(bt_path, map_path):
    sys.stdout.reconfigure(encoding="utf-8")
    mapping = json.load(open(map_path, encoding="utf-8"))
    data = json.load(open(bt_path, encoding="utf-8"))

    targets = {}      # id -> nová kategorie
    unmatched = {}
    for t in data["transactions"]:
        if t.get("category") != "KRevizi" or t["date"][:4] != "2026":
            continue
        cat = mapping.get(normalize_merchant(t.get("counterparty")))
        if cat:
            targets[t["id"]] = cat
        else:
            k = normalize_merchant(t.get("counterparty"))
            unmatched[k] = unmatched.get(k, 0) + 1

    raw = open(bt_path, encoding="utf-8", newline="").read()
    changed = 0
    for tid, cat in targets.items():
        idx = raw.find(f'"id": "{tid}"')
        if idx == -1:
            continue
        cidx = raw.find(OLD, idx)
        if cidx == -1:
            continue
        newval = '"category": ' + json.dumps(cat, ensure_ascii=True)
        raw = raw[:cidx] + newval + raw[cidx + len(OLD):]
        changed += 1

    tmp = bt_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(raw)
    os.replace(tmp, bt_path)
    print(f"Přepsáno {changed} transakcí (cíleno {len(targets)}).")
    if unmatched:
        print("Nepřiřazeno:", unmatched)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
