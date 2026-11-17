"""Build wordwise.db with Burmese glosses from the Ornagai dictionary
(https://www.ornagai.com), macOS Dictionary bundle "Ornagai.dictionary".

usage: python3 build_ornagai_db.py Ornagai.dictionary ../wordwise.db
needs: pip install wordfreq
"""
import html
import os
import re
import sqlite3
import sys
import zlib

from wordfreq import zipf_frequency

ZIPF_MAX, ZIPF_MIN = 4.3, 2.0
GLOSS_LIMIT = 30


def band(z):
    if z >= ZIPF_MAX or z < ZIPF_MIN:
        return None
    for lim, d in ((2.8, 1), (3.2, 2), (3.6, 3), (4.0, 4)):
        if z < lim:
            return d
    return 5


POS = {"noun", "verb", "adjective", "adverb", "preposition", "pronoun",
       "conjunction", "interjection"}

ENTRY = re.compile(r'<d:entry[^>]*d:title="([^"]*)">(.*?)</d:entry>', re.S)
POS_RX = re.compile(r"<p><b>([^<]+)</b>")
SENSE = re.compile(r"<p>\s*\d+\.\s*(.*?)</p>", re.S)
TAG = re.compile(r"<[^>]+>")
# Myanmar + basic Latin/punctuation only; some source senses carry stray
# CJK/Hangul/Ethiopic/U+FFFD characters that would render as "?" on device.
CLEAN = re.compile("^[\\u1000-\\u109F\\u200C\\u200D A-Za-z0-9.,'()\\-/&+]+$")
MY = re.compile(r"[က-႟]")


def read_body(bundle):
    """Body.data = header + zlib-compressed chunks of <d:entry> XML."""
    data = open(os.path.join(bundle, "Contents", "Body.data"), "rb").read()
    out, i = [], 0x60
    while i < len(data):
        hits = [p for p in (data.find(b"\x78\xda", i), data.find(b"\x78\x9c", i)) if p != -1]
        if not hits:
            break
        p = min(hits)
        d = zlib.decompressobj()
        try:
            out.append(d.decompress(data[p:]))
            i = len(data) - len(d.unused_data)
        except zlib.error:
            i = p + 1
    return b"".join(out).decode("utf-8", "replace")


def shorten(g):
    g = re.split("[၊။;]", g)[0]          # first clause (၊ ။ ;)
    g = re.sub(r"\([^)]*\)", "", g)                  # drop parenthetical notes
    g = re.sub(r"\s+", " ", g).strip(" ,.")
    if len(g) <= GLOSS_LIMIT:
        return g
    out = ""
    for part in g.split(" "):
        if out and len(out) + 1 + len(part) > GLOSS_LIMIT:
            break
        out = (out + " " + part).strip()
    return out


def parse(body):
    m = POS_RX.search(body)
    pos = m.group(1).strip().lower() if m else None
    for raw in SENSE.findall(body):
        g = shorten(html.unescape(TAG.sub("", raw)))
        if MY.search(g) and CLEAN.match(g):  # skip glosses with stray scripts
            return g, (pos if pos in POS else None)
    return None, None


def main(bundle, out):
    rows = {}
    for title, body in ENTRY.findall(read_body(bundle)):
        w = html.unescape(title).strip()
        if not (w.isascii() and w.isalpha() and w.islower() and len(w) >= 3) or w in rows:
            continue
        d = band(zipf_frequency(w, "en"))
        if d is None:
            continue
        g, pos = parse(body)
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
