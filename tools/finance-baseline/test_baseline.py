import json
import subprocess
import sys
import os
import tempfile


def _run(tx, cats, items, as_of="2026-06-16"):
    d = tempfile.mkdtemp()
    json.dump({"transactions": tx}, open(f"{d}/bt.json", "w", encoding="utf-8"))
    json.dump({"categories": cats}, open(f"{d}/cat.json", "w", encoding="utf-8"))
    json.dump({"version": 1, "items": items}, open(f"{d}/it.json", "w", encoding="utf-8"))
    out = subprocess.check_output(
        [sys.executable, "baseline.py", f"{d}/bt.json", f"{d}/cat.json", f"{d}/it.json", "--as-of", as_of],
        cwd=os.path.dirname(__file__) or ".")
    return json.loads(out)


CATS = [
    {"name": "Potraviny", "type": "Expense", "excludeFromCashflow": False, "isPrivate": False, "scope": "Domácnost"},
    {"name": "Zvířata", "type": "Expense", "excludeFromCashflow": False, "isPrivate": False, "scope": "Domácnost"},
    {"name": "Investice", "type": "Expense", "excludeFromCashflow": False, "isPrivate": True, "scope": "Investice"},
    {"name": "InternalTransfer", "type": "Transfer", "excludeFromCashflow": True, "isPrivate": False, "scope": "Převod"},
    {"name": "Business", "type": "Income", "excludeFromCashflow": False, "isPrivate": False, "scope": "Byznys"},
]


def test_median_per_category_excludes_partial_month_and_investments_and_transfers():
    tx = []
    for m, amt in [("01", 1000), ("02", 3000), ("03", 2000)]:
        tx.append({"id": f"p{m}", "date": f"2026-{m}-10T00:00:00", "amountCzk": -amt,
                   "category": "Potraviny", "counterparty": "KAUFLAND"})
    tx.append({"id": "p06", "date": "2026-06-05T00:00:00", "amountCzk": -9999,
               "category": "Potraviny", "counterparty": "KAUFLAND"})
    tx.append({"id": "inv", "date": "2026-01-10T00:00:00", "amountCzk": -50000,
               "category": "Investice", "counterparty": "COINMATE"})
    tx.append({"id": "tr", "date": "2026-01-10T00:00:00", "amountCzk": -20000,
               "category": "InternalTransfer", "counterparty": "FIO"})
    out = _run(tx, CATS, {})
    pot = next(c for c in out["categories"] if c["name"] == "Potraviny")
    assert pot["monthlyMedianCzk"] == 2000
    assert all(c["name"] not in ("Investice", "InternalTransfer") for c in out["categories"])


def test_income_median_from_income_categories():
    tx = [
        {"id": "s1", "date": "2026-01-27T00:00:00", "amountCzk": 100000, "category": "Business", "counterparty": "SOFTIM"},
        {"id": "s2", "date": "2026-02-27T00:00:00", "amountCzk": 120000, "category": "Business", "counterparty": "SOFTIM"},
        {"id": "s3", "date": "2026-03-27T00:00:00", "amountCzk": 80000, "category": "Business", "counterparty": "SOFTIM"},
        {"id": "now", "date": "2026-06-05T00:00:00", "amountCzk": 999999, "category": "Business", "counterparty": "SOFTIM"},
        {"id": "p1", "date": "2026-01-10T00:00:00", "amountCzk": -500, "category": "Potraviny", "counterparty": "K"},
    ]
    out = _run(tx, CATS, {})
    assert out["incomeMedianCzk"] == 100000  # median(100k,120k,80k), aktuální měsíc vynechán


def test_tier1_merchant_and_payday():
    tx = [
        {"id": "a1", "date": "2026-01-10T00:00:00", "amountCzk": -1200, "category": "Potraviny", "counterparty": "KAUFLAND PRAHA"},
        {"id": "a2", "date": "2026-02-10T00:00:00", "amountCzk": -1200, "category": "Potraviny", "counterparty": "KAUFLAND PRAHA"},
        {"id": "sal1", "date": "2026-01-27T00:00:00", "amountCzk": 100000, "category": "Business", "counterparty": "SOFTIM.CZ"},
        {"id": "sal2", "date": "2026-02-25T00:00:00", "amountCzk": 100000, "category": "Business", "counterparty": "SOFTIM.CZ"},
    ]
    out = _run(tx, CATS, {})
    pot = next(c for c in out["categories"] if c["name"] == "Potraviny")
    kauf = next(m for m in pot["merchants"] if m["name"] == "KAUFLAND")
    assert kauf["monthlyMedianCzk"] == 1200
    assert out["payday"]["dayOfMonth"] == 26


def test_includes_expense_regardless_of_scope_but_excludes_investments_and_transfers():
    cats = CATS + [{"name": "Jiné", "type": "Expense", "excludeFromCashflow": False, "isPrivate": False, "scope": "Cosi"}]
    tx = [
        {"id": "j1", "date": "2026-01-10T00:00:00", "amountCzk": -500, "category": "Jiné", "counterparty": "XYZ"},
        {"id": "j2", "date": "2026-02-10T00:00:00", "amountCzk": -700, "category": "Jiné", "counterparty": "XYZ"},
        {"id": "inv", "date": "2026-01-10T00:00:00", "amountCzk": -50000, "category": "Investice", "counterparty": "C"},
    ]
    out = _run(tx, cats, {})
    jine = next(c for c in out["categories"] if c["name"] == "Jiné")
    assert jine["monthlyMedianCzk"] == 600
    assert all(c["name"] != "Investice" for c in out["categories"])


def test_excludes_prevod_scope_even_if_not_excludeFromCashflow():
    # Čerpání úvěru: scope Převod, excludeFromCashflow=false → NESMÍ se počítat jako výdaj.
    cats = CATS + [{"name": "Čerpání úvěru", "type": "Transfer", "excludeFromCashflow": False, "isPrivate": False, "scope": "Převod"}]
    tx = [
        {"id": "u1", "date": "2026-01-10T00:00:00", "amountCzk": -170000, "category": "Čerpání úvěru", "counterparty": "PREUVER"},
        {"id": "p1", "date": "2026-01-10T00:00:00", "amountCzk": -500, "category": "Potraviny", "counterparty": "KAUFLAND"},
    ]
    out = _run(tx, cats, {})
    assert all(c["name"] != "Čerpání úvěru" for c in out["categories"])


def test_tier2_lineitems_reattribute_without_double_count():
    tx = [
        {"id": "alza1", "date": "2026-01-10T00:00:00", "amountCzk": -1200, "category": "Nákupy", "counterparty": "ALZA"},
    ]
    cats = CATS + [{"name": "Nákupy", "type": "Expense", "excludeFromCashflow": False, "isPrivate": False, "scope": "Domácnost"}]
    items = {"alza1": [
        {"category": "Zvířata", "subcategory": "Granule pes", "amountCzk": -800},
        {"category": "Nákupy", "subcategory": None, "amountCzk": -400},
    ]}
    out = _run(tx, cats, items)
    zv = next(c for c in out["categories"] if c["name"] == "Zvířata")
    sub = next(s for s in zv["subcategories"] if s["name"] == "Granule pes")
    assert sub["monthlyMedianCzk"] == 800
    nak = next(c for c in out["categories"] if c["name"] == "Nákupy")
    assert nak["monthlyMedianCzk"] == 400


def test_tier2_discount_line_subtracts():
    # objednávka 1000: produkt 1100 (Elektronika) + sleva -100 (Nákupy, kladná částka = kredit)
    tx = [{"id": "o1", "date": "2026-01-10T00:00:00", "amountCzk": -1000, "category": "Nákupy", "counterparty": "ALZA"}]
    cats = CATS + [
        {"name": "Nákupy", "type": "Expense", "excludeFromCashflow": False, "isPrivate": False, "scope": "Domácnost"},
        {"name": "Elektronika", "type": "Expense", "excludeFromCashflow": False, "isPrivate": False, "scope": "Domácnost"},
    ]
    items = {"o1": [
        {"category": "Elektronika", "subcategory": None, "amountCzk": -1100},
        {"category": "Nákupy", "subcategory": None, "amountCzk": 100},
    ]}
    out = _run(tx, cats, items)
    el = next(c for c in out["categories"] if c["name"] == "Elektronika")
    assert el["monthlyMedianCzk"] == 1100
    nak = next(c for c in out["categories"] if c["name"] == "Nákupy")
    assert nak["monthlyMedianCzk"] == -100   # sleva odečte (znaménkově)
