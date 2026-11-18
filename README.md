# Word Wise for KOReader

A KOReader plugin that displays Burmese meanings directly above difficult English words.
Dictionary data powered by [Ornagai](https://www.ornagai.com) — thank you, [Ko Saturngod](https://www.saturngod.net/)!

![Word Wise showing glosses above difficult words](screenshot.png)

## Installation & Setup

1. **Download:** grab `wordwise.koplugin.zip` from the [latest release](https://github.com/kaungpyaehein/wordwise.koplugin/releases/latest).
2. **Install:** unzip the file and move the `wordwise.koplugin` folder into your `koreader/plugins/` directory (Kobo: `.adds/koreader/plugins/`).
3. **Enable:** restart KOReader and open a book. Tap the top of the screen to open the menu, then tap the **🔧 Tools** icon → **More tools** (next page if you don't see it) → **Word Wise** → **Show inline hints**.
4. **Hint level:** in the same Word Wise menu, pick a level — 1 shows only the hardest words, 5 shows the most.

## မြန်မာ

ခက်ခဲတဲ့ အင်္ဂလိပ်စကားလုံးတွေရဲ့ အပေါ်မှာ မြန်မာအဓိပ္ပာယ်ကို တိုက်ရိုက်ပြပေးမယ့် KOReader plugin ဖြစ်ပါတယ်။
အဘိဓာန်ဒေတာကို [Ornagai](https://www.ornagai.com) မှ ရယူထားပါသည် — [ကို Saturngod](https://www.saturngod.net/) ကို ကျေးဇူးတင်ပါသည်။

**ထည့်သွင်းအသုံးပြုနည်း**

၁။ **ဒေါင်းလုဒ်ဆွဲပါ** – [Release စာမျက်နှာ](https://github.com/kaungpyaehein/wordwise.koplugin/releases/latest) မှ `wordwise.koplugin.zip` ဖိုင်ကို ဒေါင်းလုဒ်ဆွဲပါ။
၂။ **ဖိုင်ဖြည်ပြီး ထည့်ပါ** – Zip ဖိုင်ကို ဖြည်ပြီး ရလာတဲ့ `wordwise.koplugin` ဖိုင်တွဲကို `koreader/plugins/` ထဲသို့ ကူးထည့်ပါ (Kobo စက်များအတွက် `.adds/koreader/plugins/`)။
၃။ **ဖွင့်သုံးပါ** – KOReader ကို ပြန်ဖွင့်ပြီး စာအုပ်တစ်အုပ် ဖွင့်ပါ။ စခရင် အပေါ်ပိုင်းကို နှိပ်ပြီး Menu ဖွင့်ပါ → **🔧 Tools** icon → **More tools** (မတွေ့ရင် နောက်စာမျက်နှာ) → **Word Wise** → **Show inline hints** ကို နှိပ်ပါ။
၄။ **Hint level** – Word Wise menu ထဲမှာပဲ level ရွေးပါ။ 1 = အခက်ဆုံး စကားလုံးတွေပဲ၊ 5 = စကားလုံး အများဆုံး။

---

Font: Noto Sans Myanmar (SIL OFL 1.1) · Based on [asxelot/wordwise.koplugin](https://github.com/asxelot/wordwise.koplugin)

<details>
<summary>More (developers)</summary>

### Bring your own (optional)

Any database you drop into KOReader's data directory **overrides** the bundled
one, so you can supply a better/personal dictionary without deleting anything:

```
<koreader data dir>/wordwise/wordwise.db
```

(Any `*.db` in `wordwise/` is used; `wordwise.db` is preferred if present.)

### Running on a Kindle? It's auto-detected

If no override is present and the plugin finds Kindle's own Word Wise corpus
on disk (`/mnt/us/system/kll/kll.en.en.klld` — populated once Word Wise has
been used at least once), it converts that into `wordwise/wordwise.db`
automatically on first run (`wordwise_kindle.lua`) and uses it from then on.
This is Amazon/Merriam-Webster content read from *your own device*; the
conversion happens on-device and the result is never bundled/distributed —
same personal-use terms as the standalone conversion below.

Resolution order: `wordwise/wordwise.db` → first `*.db` in `wordwise/` →
auto-converted Kindle corpus (device only) → bundled.

### Canonical schema

Whatever the source, the engine reads exactly this shape:

```sql
CREATE TABLE entries (
    word       TEXT PRIMARY KEY COLLATE NOCASE,
    short_def  TEXT NOT NULL,      -- the gloss shown above the word
    difficulty INTEGER NOT NULL,   -- 1 rarest .. 5 most common
    pos        TEXT                -- part of speech (optional)
);
```

A word is glossed when `difficulty <= hint level`. Lookups fall back to a few
cheap English de-inflections (plurals, `-ed`, `-ing`, `-ly`) so inflected forms
in the text still match base-form entries.

## How the bundled dictionary is built

`wordwise.db` is built from the Ornagai English–Myanmar dictionary with
`tools/build_ornagai_db.py` (usage in the file header; needs `pip install wordfreq`):

```sh
cd tools
python3 build_ornagai_db.py Ornagai.dictionary ../wordwise.db
```

The original English-only open dictionary from the upstream plugin can still be
built with `tools/build_open_dict.py` and the editable glosses in
`tools/open_glosses.tsv`.

### Alternative sources

- **Kindle Word Wise (personal use).** If you're running the plugin on a
  (jailbroken) Kindle itself, this happens automatically — see *Running on a
  Kindle?* above. To convert a copy pulled off your own device for use
  elsewhere (e.g. testing in the emulator), use `tools/build_wordwise_db.py`
  on `kll.en.en.klld` (or the older `WordWise.kll.en.en.db`) and drop the
  result in `wordwise/`. This is Amazon/Merriam-Webster licensed content — for
  personal use only; **do not redistribute it.**
- **Wiktionary (CC BY-SA)** via the [Proficiency](https://github.com/xxyzz/Proficiency)
  `en_en` data, reshaped into the canonical schema.

</details>
