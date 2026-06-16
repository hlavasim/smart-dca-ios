from normalize import normalize_merchant, build_patterns, canonical_merchant


def test_strips_diacritics_case_and_location():
    assert normalize_merchant("KAUFLAND PRAHA 5") == "KAUFLAND"
    assert normalize_merchant("Rohlík.cz") == "ROHLIK"
    assert normalize_merchant("  alza.cz  a.s. ") == "ALZA"


def test_empty_and_none():
    assert normalize_merchant("") == ""
    assert normalize_merchant(None) == ""


def test_strips_courtesy_and_gateway_prefixes():
    # "Děkujeme," prefix terminálu skrývá skutečný obchod
    assert normalize_merchant("DEKUJEME, ROHLIK.CZ") == "ROHLIK"
    assert normalize_merchant("Dekujeme, foodora.cz") == "FOODORA"
    # platební brána GOPAY *<merchant>
    assert normalize_merchant("GOPAY *ISPORTSYSTEM.CZ") == "ISPORTSYSTEM"
    assert normalize_merchant("GOPAY  *CANARIATRAVEL.") == "CANARIATRAVEL"


def test_strips_www_and_cz_suffix():
    assert normalize_merchant("WWW.ROHLIK.CZ") == "ROHLIK"
    assert normalize_merchant("WWWROHLIKCZ") == "ROHLIK"


def test_canonical_uses_rule_patterns_then_falls_back():
    rules = [{"matchCounterparty": "Rohlik", "category": "Potraviny"},
             {"matchCounterparty": "Alza", "category": "Nákupy"}]
    pats = build_patterns(rules)
    # pattern chytne i přes zdvořilostní prefix a slepený tvar
    assert canonical_merchant("DEKUJEME, ROHLIK.CZ", pats) == "ROHLIK"
    assert canonical_merchant("WWWROHLIKCZ", pats) == "ROHLIK"
    assert canonical_merchant("ALZA.CZ A.S.", pats) == "ALZA"
    # bez pravidla → fallback na heuristiku (ořez brány)
    assert canonical_merchant("GOPAY *ISPORTSYSTEM.CZ", pats) == "ISPORTSYSTEM"
