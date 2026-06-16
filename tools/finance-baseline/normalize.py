import re
import unicodedata

# Tokeny, které u merchantů znamenají lokalitu/právní formu/zdvořilost → zahodit.
_NOISE = {"AS", "SRO", "ZS", "CZ", "COM", "PRAHA", "BRNO", "OSTRAVA", "S", "A", "DEKUJEME", "WWW"}


def _fold(s):
    """Diakritika pryč + UPPER."""
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c)).upper()


def _clean_token(t):
    """Ořež generický prefix WWW a koncové CZ/COM u slepených názvů (WWWROHLIKCZ → ROHLIK)."""
    if t.startswith("WWW") and len(t) > 5:
        t = t[3:]
    for suf in ("CZ", "COM"):
        if t.endswith(suf) and len(t) > len(suf) + 2:
            t = t[:-len(suf)]
    return t


def normalize_merchant(name):
    """Heuristika: první smysluplný token. Ořeže platební bránu (GOPAY *X → X),
    zdvořilostní prefix (Děkujeme, X → X) a WWW/CZ šum. Fallback, když nesedí pravidlo."""
    if not name:
        return ""
    s = _fold(name)
    if "*" in s:                      # platební brána: vezmi za poslední *
        s = s.rsplit("*", 1)[1]
    s = re.sub(r"[^A-Z0-9]+", " ", s).strip()
    tokens = [t for t in s.split() if t]
    for t in tokens:
        if t.isdigit() or t in _NOISE:
            continue
        return _clean_token(t)
    return _clean_token(tokens[0]) if tokens else ""


def build_patterns(rules):
    """Z category-rules.json udělá seznam normalizovaných patternů (nejdelší první)."""
    pats = set()
    for r in rules:
        p = re.sub(r"[^A-Z0-9]+", " ", _fold(r.get("matchCounterparty") or "")).strip()
        if p:
            pats.add(p)
    return sorted(pats, key=len, reverse=True)


def canonical_merchant(name, patterns):
    """Merchant podle kurátorovaných patternů (substring, např. 'ROHLIK' v 'Děkujeme,ROHLIK.CZ').
    Když nic nesedí, spadne na heuristiku normalize_merchant."""
    if not name:
        return ""
    up = re.sub(r"[^A-Z0-9]+", " ", _fold(name)).strip()
    for p in patterns:
        if p and p in up:
            return p.replace(" ", "")
    return normalize_merchant(name)
