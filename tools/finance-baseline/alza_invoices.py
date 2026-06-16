#!/usr/bin/env python3
"""Naparsuje Alza PDF faktury, zařadí položky (kategorie + subkat), spáruje na bankovní
Alza platby (částka+datum) a vyrobí line-item overlay (Tier 2) do transaction-items.json.

Usage:
  python alza_invoices.py <pdf_dir> <bank-transactions.json> [--write <transaction-items.json>]
Bez --write jen report (kategorie, nejisté položky, nespárované).
"""
import sys
import os
import re
import glob
import json
from datetime import date as D
from collections import defaultdict

import pypdf

NUM = r"-?[\d ]*\d,\d{2}"
ITEM = re.compile(rf"(\d+)\s+({NUM})\s+({NUM})\s+(\d+)\s+({NUM})\s+\d+")
TOTAL = re.compile(r"Celkem:\s*([\d ]+,\d{2})\s*Kč")


def money(s):
    return round(float(s.replace(" ", "").replace(",", ".")), 2)


def _has_letters(s):
    return bool(re.search(r"[A-Za-zÁ-ž]", s))


def parse_pdf(path):
    txt = "\n".join((p.extract_text() or "") for p in pypdf.PdfReader(path).pages)
    lines = txt.splitlines()
    date = None
    for i, l in enumerate(lines):
        if "Datum vystavení" in l:
            for j in range(i, min(i + 8, len(lines))):
                m = re.search(r"(\d{2})\.(\d{2})\.(\d{4})", lines[j])
                if m:
                    date = f"{m.group(3)}-{m.group(2)}-{m.group(1)}"
                    break
            break
    # tabulka: od hlavičky "Kód ... Popis" po "Celkem:"
    items, buf, in_table = [], [], False
    for l in lines:
        if "Kód" in l and "Popis" in l:
            in_table = True
            continue
        if l.strip().startswith("Celkem:"):
            break
        if not in_table:
            continue
        m = ITEM.search(l)
        if m:
            price = money(m.group(5))
            pre = re.sub(r"^[\d,]+[A-Za-z0-9]*\s*", "", l[:m.start()]).strip()
            desc = (pre + " " + " ".join(buf)).strip()
            items.append((price, re.sub(r"\s+", " ", desc)))   # plný popis (kvůli kategorizaci)
            buf = []
        else:
            s = l.strip()
            if s and _has_letters(s) and not re.match(r"^\d", s) and (" " in s or len(s) >= 5):
                buf.append(s)
    totals = TOTAL.findall(txt)
    return date, (money(totals[-1]) if totals else None), items


# ---- kategorizér: (regex klíčová slova) -> (kategorie, subkat) ----
def categorize(desc):
    d = desc.lower()

    def has(*ws):
        return any(w in d for w in ws)

    # doprava / sleva (overhead) → Nákupy
    if has("doprava", "alzabox", "sleva na dopravné", "dopravné", "showroom", "doručení"):
        return "Nákupy", "Doprava/sleva"
    # AlzaPlus+ členství
    if has("alzaplus"):
        return "Předplatné", "AlzaPlus+"
    # pojištění/služba (prodloužení záruky)
    if has("pojištění", "prodloužení záruky", "rozšířená záruka"):
        return "Pojištění", None
    # zvířata + tag (pet keywords často na KONCI popisu)
    pet = has("pro psy", "pro kočky", "pro kocky", "stelivo", "granule", "konzerva pro",
              "krmivo", "menforsan", "asan cat", "brit mono", "pamls", "obojek", "pelíšek",
              "royal canin", "kočk", "kočič", "pro mazlíč", "králík", "kralik", "psy", "pejsk",
              "kočičí toaleta", "akvarij", "pro zvířata", "antiparazit")
    if pet:
        if has("kočk", "kočič", "kocky", "stelivo", "kočičí", "cat"):
            return "Zvířata", "Kočka"
        if has("pro psy", "psy", "pes", "psa", "dog", "pejsk"):
            return "Zvířata", "Pes"
        return "Zvířata", None
    # drogerie / kosmetika / ústní hygiena
    if has("toaletní papír", "barva na vlasy", "šampon", "sampon", "mýdlo", "mydlo",
           "prací", "praci", "čisticí", "cistici", "garnier", "linteo", "zubní", "kapesník",
           "ubrousky", "aviváž", "drogerie", "sprchový", "deodorant", "vata", "jar ", "savo",
           "krém", "krem", "sérum", "serum", "řasenka", "pleťov", "pletov", "ústní voda",
           "kosmetik", "l'oréal", "loréal", "loreal", "weleda", "medicube", "curaprox",
           "gel na dásně", "parfém", "parfem", "make-up", "rtěnka", "tělové", "telove",
           "vlasy", "holení", "holeni", "pleť"):
        return "Drogerie", None
    # elektronika / spotřebiče
    if has("cartridge", "toner", "oura", "kabel", "nabíječka", "nabijecka", "ssd", "hdd",
           "myš ", "klávesnice", "monitor", "sluchátka", "reproduktor", "baterie", "žárovka",
           "usb", "powerbank", "telefon", "router", "tiskárna", "canon", "adaptér", "adapter",
           "disk", "paměť", "pamet", "nabíjení", "vysavač", "mixér", "mixer", "chůvička",
           "nannycam", "robot vacuum", "fén", "fen ", "žehlička", "kuchyňský robot", "varná",
           "rychlovarná", "holicí", "epilátor", "kamera", "tablet ", "notebook", "konvice",
           "inkoust", "pigmentová", "náplň do tiskárny", "sáčky do vysavače"):
        return "Elektronika", None
    # sport
    if has("běžecký pás", "činka", "posilov", "fitness", "jóga", "yoga", "běžeck",
           "elektrolyt", "myprotein", "vilgain", "protein"):
        return "Sport", None
    # zdraví / léky / doplňky
    if has("doplněk stravy", "vitamin", "daosin", "probiot", "magnézium",
           "magnesium", "kolagen", "léčiv", "kloubní výživa", "oční kapky", "ústní sprej",
           "zdravotnický prostředek", "dávkovač léků", "hemagel", "anginal", "ocuflash",
           "lékárn", "mast ", "náplast", "obvaz", "tablet"):
        return "Zdraví", None
    # zábava / hračky
    if has("hra", "lego", "heartlake", "puzzle", "kniha", "komiks", "stavebnice", "plyšák",
           "balonk", "balonek", "vodní pistole", "hračka", "panenka"):
        return "Zábava", None
    # děti / miminko
    if has("přebalovací", "miminko", "kočárek", "plenky", "plínky", "dudlík", "babyono"):
        return "Rodina", "Děti"
    # potraviny
    if has("káva", "kava", "alzacafé", "espresso", "čaj", "čokoláda", "cukr", "müsli",
           "musli", "ořechy", "ořech", "orechy", "sladidlo", "lyofilizované", "pistác",
           "kešu", "mango", "nápoj", "müsli"):
        return "Potraviny", None
    # papírnictví / kancl
    if has("stabilo", "liner", "propiska", "tužka", "sešit", "blok ", "fix "):
        return "Nákupy", "Papírnictví"
    return "Nákupy", None  # neznámé → Nákupy (flag)


def dd(s):
    return D(int(s[:4]), int(s[5:7]), int(s[8:10]))


def main(pdf_dir, bt_path, write_path=None):
    sys.stdout.reconfigure(encoding="utf-8")
    invoices = []
    for f in sorted(glob.glob(os.path.join(pdf_dir, "*.pdf"))):
        no = os.path.basename(f).replace(".pdf", "")
        date, total, items = parse_pdf(f)
        invoices.append((no, date, total, items))

    txs = json.load(open(bt_path, encoding="utf-8"))["transactions"]
    alza = [t for t in txs if "ALZA" in (t.get("counterparty") or "").upper()
            and t["date"][:4] == "2026" and t["amountCzk"] < 0]

    overlay = {}
    used = set()
    cat_totals = defaultdict(float)
    uncertain = []
    matched = 0
    for no, date, total, items in invoices:
        if not date or total is None:
            continue
        cand = [x for x in alza if id(x) not in used
                and abs(abs(x["amountCzk"]) - total) < 0.5
                and abs((dd(x["date"][:10]) - dd(date)).days) <= 6]
        if not cand:
            continue
        cand.sort(key=lambda x: abs((dd(x["date"][:10]) - dd(date)).days))
        tx = cand[0]
        used.add(id(tx))
        matched += 1
        line_items = []
        for price, desc in items:
            cat, sub = categorize(desc)
            line_items.append({"category": cat, "subcategory": sub, "amountCzk": -price})
            cat_totals[cat] += price
            if cat == "Nákupy" and sub is None and price > 0:
                uncertain.append((no, price, desc))
        overlay[tx["id"]] = line_items

    print(f"Faktur: {len(invoices)} | spárováno na platby: {matched}/{len(alza)}")
    print("\n=== rozpad podle kategorií (spárované faktury) ===")
    for c, v in sorted(cat_totals.items(), key=lambda kv: -kv[1]):
        print(f"  {c:14s} {int(v):>8,} Kč".replace(",", " "))
    print(f"\n=== NEJISTÉ položky → spadly do Nákupy ({len(uncertain)}) ===")
    for no, price, desc in sorted(uncertain, key=lambda x: -x[1])[:40]:
        print(f"  {price:>8.2f}  {desc[:68]}")

    if write_path:
        existing = json.load(open(write_path, encoding="utf-8")) if os.path.exists(write_path) else {"version": 1, "items": {}}
        existing.setdefault("items", {}).update(overlay)
        json.dump(existing, open(write_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        open(write_path, "a", encoding="utf-8").write("\n")
        print(f"\nZapsáno {len(overlay)} faktur do {write_path}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--write"]
    write_idx = sys.argv.index("--write") if "--write" in sys.argv else None
    write_path = sys.argv[write_idx + 1] if write_idx else None
    if write_path and write_path in args:
        args.remove(write_path)
    main(args[0], args[1], write_path)
