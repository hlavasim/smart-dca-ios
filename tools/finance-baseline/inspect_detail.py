#!/usr/bin/env python3
"""Detail KRevizi 2026 transakcí pro dané merchanty (substringy v counterparty).
Usage: python inspect_detail.py <bank-transactions.json> <accounts.json> <substr1> [substr2 ...]"""
import sys
import json


def main(bt_path, acc_path, needles):
    sys.stdout.reconfigure(encoding="utf-8")
    txs = json.load(open(bt_path, encoding="utf-8"))["transactions"]
    accs = json.load(open(acc_path, encoding="utf-8"))
    accs = accs["accounts"] if isinstance(accs, dict) and "accounts" in accs else accs
    acc_name = {a["id"]: f"{a.get('name')} ({a.get('accountNumber')})" for a in accs}
    needles = [n.lower() for n in needles]
    rows = [t for t in txs
            if t.get("category") == "KRevizi" and t["date"][:4] == "2026"
            and any(n in (t.get("counterparty") or "").lower() for n in needles)]
    rows.sort(key=lambda t: t["date"])
    for t in rows:
        print(f"{t['date'][:10]}  {t['amountCzk']:>11,.0f} Kč".replace(",", " "))
        print(f"    z účtu: {acc_name.get(t.get('accountId'), t.get('accountId'))}")
        print(f"    protistrana: {t.get('counterparty')}")
        print(f"    popis: {(t.get('description') or '')[:90]}")
        print()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
