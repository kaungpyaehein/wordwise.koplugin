"""Build a Word Wise wordwise.db with Burmese glosses from an extracted
English->Myanmar Kindle dictionary (mobi7 book.html).

usage: python3 build_myanmar_db.py book.html ../wordwise.db

book.html: mobi7/book.html extracted from "Myanmar Kindle Dictionary-Unicode.prc"
(pip install mobi wordfreq; python3 -c "import mobi; print(mobi.extract(PRC))")
"""
import html
import re
import sqlite3
import sys

from wordfreq import zipf_frequency

ZIPF_MAX, ZIPF_MIN = 4.3, 2.0


def band(z):
    if z >= ZIPF_MAX:
        return None
    for lim, d in ((2.8, 1), (3.2, 2), (3.6, 3), (4.0, 4)):
        if z < lim:
            return d
    return 5


POS = {"n": "noun", "v": "verb", "adj": "adjective", "adv": "adverb",
       "prep": "preposition", "pron": "pronoun", "conj": "conjunction",
       "interj": "interjection"}

ENTRY = re.compile(r'<idx:orth value="([^"]*)"></idx:orth>(.*?)</idx:entry>', re.S)
TAG = re.compile(r"<[^>]+>")
MY = re.compile(r"[က-႟]")

# Text was typed in visual (Zawgyi-style) order: E-vowel (U+1031) and
# medial RA (U+103C) precede the consonant. Move them to Unicode order.
CONS = "က-အဣ-ဧဩဪဿ၎"
REORDER = re.compile(
    "(ေ?)(ြ?)([" + CONS + "])((?:္[" + CONS + "])?)([ျွှ]*)")


def fix_order(s):
    def sub(m):
        e, ra, c, stack, med = m.groups()
        # canonical medial order: YA(103B) RA(103C) WA(103D) HA(103E)
        meds = sorted(med + ra)
        return c + stack + "".join(meds) + e
    s = s.replace("​", "").replace("‌", "").replace("﻿", "")
    s = REORDER.sub(sub, s)
    s = s.replace("\u1036\u102F", "\u102F\u1036")   # anusvara after U
    s = s.replace("\u103A\u1037", "\u1037\u103A")   # dot below before asat
    # stray pre-base marks left in front of a non-consonant
    return s


def shorten(g, limit=30):
    g = g.split("၊")[0].strip()   # first clause before Burmese comma
    if len(g) <= limit:
        return g
    out = ""
    for part in g.split(" "):
        if out and len(out) + 1 + len(part) > limit:
            break
        out = (out + " " + part).strip()
    return out.strip(" (")


def gloss_of(body):
    text = html.unescape(TAG.sub(" ", body))
    for z in "\u200B\u200C\u200D\uFEFF":
        text = text.replace(z, "")
    pos = None
    m = re.search(r"■\s*([a-z]+)", text)
    if m:
        pos = POS.get(m.group(1))
    if "●" not in text:
        return None, pos
    defn = text.split("●", 1)[1]
    defn = re.sub(r"[၀-၉]+\s*။", " ", defn)        # ၁။ numbering
    defn = re.sub(r"\(\s*[က-အ]\s*\)", " ", defn)    # (က) lettering
    defn = defn.replace("[", "").replace("]", "")
    for seg in defn.split("။"):
        seg = re.sub(r"\([^)]*[A-Za-z][^)]*\)", " ", seg)     # English notes
        seg = re.sub(r"[A-Za-z~=][^က-႟]*", " ", seg)  # English text
        seg = re.sub(r"[^က-႟()\s]", " ", seg)
        seg = re.sub(r"\(\s*\)", " ", seg)
        seg = re.sub(r"\s+", " ", seg).strip(" ()")
        if seg.count("(") != seg.count(")"):
            seg = seg.replace("(", "").replace(")", "")
        if MY.search(seg) and len(seg) >= 2:
            return shorten(fix_order(seg)), pos
    return None, pos


def main(src, out):
    data = open(src, encoding="utf-8", errors="replace").read()
    rows = {}
    for word, body in ENTRY.findall(data):
        w = html.unescape(word).strip()
        if not (w.isalpha() and w.islower() and w.isascii() and len(w) >= 3):
            continue
        if w in rows or w in POS:
            continue
        d = band(zipf_frequency(w, "en")) if zipf_frequency(w, "en") >= ZIPF_MIN else None
        if d is None:
            continue
        g, pos = gloss_of(body)
        if g:
            rows[w] = (g, d, pos)
    db = sqlite3.connect(out)
    db.executescript("""DROP TABLE IF EXISTS entries;
        CREATE TABLE entries (word TEXT PRIMARY KEY COLLATE NOCASE,
        short_def TEXT NOT NULL, difficulty INTEGER NOT NULL, pos TEXT);""")
    db.executemany("INSERT INTO entries VALUES (?,?,?,?)",
                   [(w, *v) for w, v in sorted(rows.items())])
    db.commit()
    db.execute("VACUUM")
    print(len(rows), "entries")


if __name__ == "__main__":
    main(*sys.argv[1:3])
