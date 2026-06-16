#!/usr/bin/env python3
"""Aplikuje review-mapping.json na KRevizi 2026 transakce: nastaví kategorii a vloží
poznámku (pole "note" s důvodem kategorizace). Cílová textová náhrada podle id —
zbytek souboru zůstane byte-identický (zachová formát/escaping C# serializeru).
Idempotentní: lze pustit opakovaně (kategorii re-aplikuje, note vloží jen jednou).

Mapping: { "<NORMALIZED merchant>": {"category": "...", "note": "..."} }
         (podporuje i starý plochý tvar "merchant": "category").
Usage: python reclassify.py <bank-transactions.json> <review-mapping.json>"""
import sys
import json
import os
from normalize import normalize_merchant

KREVIZI = '"category": "KRevizi"'


def _entry(v):
    if isinstance(v, dict):
        return v.get("category"), v.get("note", "")
    return v, ""


def main(bt_path, map_path):
    sys.stdout.reconfigure(encoding="utf-8")
    mapping = json.load(open(map_path, encoding="utf-8"))
    data = json.load(open(bt_path, encoding="utf-8"))

    targets = {}      # id -> (category, note)
    unmatched = {}
    for t in data["transactions"]:
        if t["date"][:4] != "2026":
            continue
        m = normalize_merchant(t.get("counterparty"))
        if m not in mapping:
            if t.get("category") == "KRevizi":
                unmatched[m] = unmatched.get(m, 0) + 1
            continue
        cat, note = _entry(mapping[m])
        # cíl jen pokud je KRevizi (čeká na zařazení) nebo už má cílovou kategorii (re-run)
        if t.get("category") in ("KRevizi", cat):
            targets[t["id"]] = (cat, note)

    raw = open(bt_path, encoding="utf-8", newline="").read()
    cat_changed = note_added = 0
    for tid, (cat, note) in targets.items():
        idx = raw.find(f'"id": "{tid}"')
        if idx == -1:
            continue
        nxt = raw.find("\n    {", idx + 1)
        end = nxt if nxt != -1 else len(raw)
        block = raw[idx:end]

        cat_val = '"category": ' + json.dumps(cat, ensure_ascii=True)
        if KREVIZI in block:
            block = block.replace(KREVIZI, cat_val, 1)
            cat_changed += 1
        if note and '"note":' not in block:
            pos = block.find(cat_val)
            if pos != -1:
                eol = block.find("\n", pos)
                note_line = "\n      " + '"note": ' + json.dumps(note, ensure_ascii=True) + ","
                block = block[:eol] + note_line + block[eol:]
                note_added += 1

        raw = raw[:idx] + block + raw[end:]

    tmp = bt_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(raw)
    os.replace(tmp, bt_path)
    print(f"Kategorií změněno: {cat_changed} | poznámek vloženo: {note_added} | cílů: {len(targets)}")
    if unmatched:
        print("Nepřiřazeno:", unmatched)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
