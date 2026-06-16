import re
import unicodedata

# Tokeny, které u merchantů znamenají lokalitu/právní formu → zahodit.
_NOISE = {"AS", "SRO", "ZS", "CZ", "COM", "PRAHA", "BRNO", "OSTRAVA", "S", "A"}


def normalize_merchant(name):
    if not name:
        return ""
    # odstraň diakritiku
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.upper()
    # nahraď nealfanumerické mezerou
    s = re.sub(r"[^A-Z0-9]+", " ", s).strip()
    tokens = [t for t in s.split() if t]
    # vezmi první "smysluplný" token (ne číslo, ne noise)
    for t in tokens:
        if t.isdigit() or t in _NOISE:
            continue
        return t
    return tokens[0] if tokens else ""
