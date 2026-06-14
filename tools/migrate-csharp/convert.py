#!/usr/bin/env python3
"""C# SmartDcaLeveraged JSON -> smart-dca-ios snapshot.json.

Usage: python convert.py <data_dir>
  <data_dir> obsahuje state.json, holdings.json, transactions.json a loans/.
Výstup: snapshot.json na stdout (commitni do private repa smart-dca-data).
"""
import json
import sys
import pathlib
from datetime import datetime, timezone


def day(s):  # "2021-04-21T02:00:00" -> "2021-04-21"
    return s[:10] if s else ""


def main(data_dir):
    d = pathlib.Path(data_dir)
    state = json.loads((d / "state.json").read_text(encoding="utf-8"))
    holdings = json.loads((d / "holdings.json").read_text(encoding="utf-8")).get("holdings", [])
    txs = json.loads((d / "transactions.json").read_text(encoding="utf-8")).get("transactions", [])
    ff_path = d / "loans" / "firefish-active.json"
    bank_path = d / "loans" / "bank-loans.json"
    ff = json.loads(ff_path.read_text(encoding="utf-8")).get("loans", []) if ff_path.exists() else []
    bank = json.loads(bank_path.read_text(encoding="utf-8")).get("loans", []) if bank_path.exists() else []
    s = state["strategy"]

    def g(obj, *keys, default=0):
        for k in keys:
            if k in obj:
                return obj[k]
        return default

    snap = {
        "version": 1,
        "exportedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "fiat": "CZK",
        "strategy": {
            "type": "NUPL",
            "nuplBottomValue": 0.0, "nuplCenterValue": 0.5,
            "nuplMinMultiplier": 0.5, "nuplMaxMultiplier": 3.0,
            "baseChunkCzk": str(s["baseChunkCzk"]),
            "baseChunkMultiplier": "0.8",
            "lastProcessedDate": day(s["lastProcessedDate"]),
            "availableCashCzk": str(s["availableCashCzk"]),
        },
        "holdings": [{
            "id": h["id"], "amount": str(h["amount"]),
            "acquisitionDate": day(h["acquisitionDate"]),
            "purchasePriceCzk": str(h["purchasePriceCzk"]),
            "isCollateralized": h["isCollateralized"],
            "loanId": (h.get("collateralForLoanIds") or [None])[0],
            "source": h["source"], "notes": h.get("notes", ""),
        } for h in holdings],
        "transactions": [{
            "date": day(t["date"]), "type": t["type"],
            "amountBtc": str(t["amountBtc"]), "amountCzk": str(t["amountCzk"]),
            "btcPriceCzk": str(t["btcPriceCzk"]), "exchangeOrderId": None,
        } for t in txs],
        "firefishLoans": [{
            "externalLoanId": g(l, "externalLoanId", "ExternalLoanId", default=""),
            "loanDate": day(g(l, "loanDate", "LoanDate", default="")),
            "maturityDate": day(g(l, "maturityDate", "MaturityDate", default="")),
            "loanAmountCzk": str(g(l, "loanAmountCzk", "LoanAmountCzk", "principalCzk", "PrincipalCzk")),
            "interestRate": str(g(l, "interestRate", "InterestRate")),
            "btcFeeRate": str(g(l, "btcFeeRate", "BtcFeeRate")),
            "btcPriceAtLoan": str(g(l, "btcPriceAtLoan", "BtcPriceAtLoan")),
            "collateralBtcAmount": str(g(l, "collateralBtcAmount", "CollateralBtc", "CollateralBtcAmount")),
            "isRepaid": g(l, "isRepaid", "IsRepaid", default=False),
        } for l in ff],
        "bankLoans": [{
            "principalCzk": str(g(l, "principalCzk", "PrincipalCzk")),
            "annualInterestRate": str(g(l, "annualInterestRate", "AnnualInterestRate")),
            "durationMonths": int(g(l, "durationMonths", "DurationMonths")),
            "remainingPrincipalCzk": str(g(l, "remainingPrincipalCzk", "RemainingPrincipalCzk")),
            "nextPaymentDate": day(g(l, "nextPaymentDate", "NextPaymentDate", default="")),
            "isFullyPaid": g(l, "isFullyPaid", "IsFullyPaid", default=False),
        } for l in bank],
    }
    print(json.dumps(snap, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main(sys.argv[1])
