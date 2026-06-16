from normalize import normalize_merchant


def test_strips_diacritics_case_and_location():
    assert normalize_merchant("KAUFLAND PRAHA 5") == "KAUFLAND"
    assert normalize_merchant("Rohlík.cz") == "ROHLIK"
    assert normalize_merchant("  alza.cz  a.s. ") == "ALZA"


def test_empty_and_none():
    assert normalize_merchant("") == ""
    assert normalize_merchant(None) == ""
