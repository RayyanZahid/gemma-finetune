#!/usr/bin/env python3
"""
Build instruction-tuned JSONL datasets in dolly-15k schema for the gemma-finetune workshop.

Sources:
    shakespeare : 4-line sliding-window continuation + per-theme style-transfer
    obama       : Obama tweets, 6 templates per tweet (style x2, continuation, topic, tone, classification)
    trump       : Trump tweets, 2 templates per tweet (style + continuation) + classification rows
    marktwain   : Project Gutenberg passages, 2 templates per passage (continuation + style)

Output: data/<source>_15k.jsonl, exactly 15000 rows, schema {instruction, response, context, category}
matching templates/finetune.py:150-155.

Usage:
    python data/build_voice_dataset.py --source shakespeare
    python data/build_voice_dataset.py --source obama
    python data/build_voice_dataset.py --source trump
    python data/build_voice_dataset.py --source marktwain
    python data/build_voice_dataset.py --all
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import random
import re
import sys
import time
import urllib.request
from pathlib import Path

# ─── constants ─────────────────────────────────────────────────────────────

TARGET_ROWS = 15_000

SHAKESPEARE_HF = "benchaffe/shakespeare-lines"
OBAMA_CSV_URL = "https://github.com/fivethirtyeight/data/raw/refs/heads/master/twitter-ratio/BarackObama.csv"
TRUMP_HF = "fschlatt/trump-tweets"
GUTENBERG_URL = "https://www.gutenberg.org/cache/epub/{id}/pg{id}.txt"

# Top Mark Twain works on Project Gutenberg, by download volume.
MARKTWAIN_BOOKS: list[tuple[int, str]] = [
    (76,   "Adventures of Huckleberry Finn"),
    (74,   "The Adventures of Tom Sawyer"),
    (245,  "Life on the Mississippi"),
    (86,   "A Connecticut Yankee in King Arthur's Court"),
    (1837, "The Prince and the Pauper"),
    (3176, "The Innocents Abroad"),
    (3177, "Roughing It"),
    (102,  "Pudd'nhead Wilson"),
    (119,  "A Tramp Abroad"),
    (3178, "Following the Equator"),
]

THEMES_SHAKESPEARE = [
    "love", "fate", "death", "honor", "betrayal",
    "ambition", "jealousy", "loyalty", "time", "beauty",
]

# Conservative profanity / slur blocklist applied to Trump tweets when --safe is on
# (default). Substring match on lowercased text padded with spaces.
SAFE_BLOCKLIST = frozenset([
    " fuck", " shit", " bitch", " cunt", " nigg", " faggot", " retard",
    " dyke", " spic", " kike", " chink", " gook", " wetback", " tranny",
])

# ─── shared utilities ──────────────────────────────────────────────────────

URL_RE = re.compile(r"https?://\S+")
MENTION_LEAD_RE = re.compile(r"^(?:@\w+\s+)+")
WS_RE = re.compile(r"\s+")
HASHTAG_RE = re.compile(r"#(\w{3,})")
NOUN_PHRASE_RE = re.compile(r"\b[A-Z][a-zA-Z]+(?:\s[A-Z][a-zA-Z]+){0,2}\b")
SENTENCE_END_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z\"'])")

STOP_TOPICS = frozenset({
    "the", "this", "that", "today", "i", "now", "just", "look", "hey",
    "well", "what", "so", "but", "and", "or", "yet", "yes", "no",
    "we", "you", "they", "rt", "im",
})

FALLBACK_TOPICS = ["current events", "today", "the future", "America", "the country"]

GUTENBERG_START_RE = re.compile(
    r"\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^*]*\*\*\*",
    re.IGNORECASE,
)
GUTENBERG_END_RE = re.compile(
    r"\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^*]*\*\*\*",
    re.IGNORECASE,
)
FOOTNOTE_RE = re.compile(r"\[Footnote[^\]]*\]", re.IGNORECASE)


def is_safe(text: str, blocklist: frozenset[str] = SAFE_BLOCKLIST) -> bool:
    lo = " " + text.lower() + " "
    return not any(b in lo for b in blocklist)


def clean_tweet(text: str) -> str | None:
    """Strip leading mentions / collapse whitespace; return None if filtered."""
    if not text:
        return None
    s = text.strip()
    if s.startswith("RT @") or s.startswith('"RT @') or s.startswith("RT:"):
        return None
    s = MENTION_LEAD_RE.sub("", s)
    s = WS_RE.sub(" ", s).strip()
    if len(s) < 20 or len(s) > 320:
        return None
    url_chars = sum(len(m.group()) for m in URL_RE.finditer(s))
    if url_chars > 0.7 * len(s):
        return None
    return s


def topic_of(text: str, idx: int = 0) -> str:
    """Extract a topic phrase: first hashtag → first noun phrase → fallback."""
    for m in HASHTAG_RE.finditer(text):
        cand = m.group(1).lower()
        if cand not in STOP_TOPICS:
            return cand
    for m in NOUN_PHRASE_RE.finditer(text):
        cand = m.group(0)
        if cand.lower() not in STOP_TOPICS:
            return cand
    return FALLBACK_TOPICS[idx % len(FALLBACK_TOPICS)]


def topic_alt(text: str, idx: int = 0) -> str:
    """Alternate topic strategy: prefer noun-phrase before hashtag, different fallback."""
    for m in NOUN_PHRASE_RE.finditer(text):
        cand = m.group(0)
        if cand.lower() not in STOP_TOPICS and len(cand) >= 4:
            return cand
    for m in HASHTAG_RE.finditer(text):
        cand = m.group(1)
        if cand.lower() not in STOP_TOPICS:
            return cand
    return THEMES_SHAKESPEARE[idx % len(THEMES_SHAKESPEARE)]


def split_at_midpoint(text: str) -> tuple[str, str] | None:
    n = len(text)
    if n < 40:
        return None
    lo, hi = int(0.4 * n), int(0.6 * n)
    target = n // 2
    best, best_d = None, n
    for i in range(lo, hi):
        if text[i] == " ":
            d = abs(i - target)
            if d < best_d:
                best_d = d
                best = i
    if best is None:
        return None
    return text[:best].rstrip(), text[best + 1:].lstrip()


def tone_of(text: str) -> str:
    lo = text.lower()
    if any(k in lo for k in ("congrat", "honored", "proud", "happy birthday", "celebrat", "thank")):
        return "celebratory"
    if any(k in lo for k in ("mourn", "loss", "tragedy", "condolence", "grief", "passed away", "rest in peace", "rip ")):
        return "mournful"
    if any(k in lo for k in ("policy", "bill", "act ", "law", "vote", "tax", "reform", "legislat", "senate", "congress")):
        return "policy"
    if any(k in lo for k in ("dream", "hope", "believe", "together", "future", "change", "forward")):
        return "inspirational"
    return "other"


def fetch_url(url: str, timeout: int = 60, retries: int = 2) -> bytes:
    last: Exception | None = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "gemma-finetune-build/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except Exception as e:  # noqa: BLE001
            last = e
            if attempt < retries:
                time.sleep(2 * (attempt + 1))
    assert last is not None
    raise last


def strip_gutenberg(text: str) -> str:
    m_start = GUTENBERG_START_RE.search(text)
    if m_start:
        text = text[m_start.end():]
    m_end = GUTENBERG_END_RE.search(text)
    if m_end:
        text = text[:m_end.start()]
    text = FOOTNOTE_RE.sub("", text)
    return text


# ─── source loaders ────────────────────────────────────────────────────────

def load_shakespeare_lines() -> list[str]:
    from datasets import load_dataset
    print(f"[shake] loading HF {SHAKESPEARE_HF}", file=sys.stderr)
    ds = load_dataset(SHAKESPEARE_HF, split="train")
    lines = [(row.get("text") or "").strip() for row in ds]
    lines = [ln for ln in lines if 10 <= len(ln) <= 200]
    print(f"[shake] usable lines: {len(lines)} / {len(ds)} raw", file=sys.stderr)
    return lines


def load_obama_tweets() -> list[str]:
    print(f"[obama] fetching {OBAMA_CSV_URL}", file=sys.stderr)
    body = fetch_url(OBAMA_CSV_URL).decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(body))
    raw: list[str] = []
    for row in reader:
        t = row.get("text") or ""
        if t:
            raw.append(t)
    cleaned = [c for c in (clean_tweet(t) for t in raw) if c]
    print(f"[obama] raw: {len(raw)}, cleaned: {len(cleaned)}", file=sys.stderr)
    return cleaned


def load_trump_tweets(safe: bool) -> list[str]:
    from datasets import load_dataset
    print(f"[trump] loading HF {TRUMP_HF}", file=sys.stderr)
    ds = load_dataset(TRUMP_HF, split="train")
    rt_field = "is_retweet" if "is_retweet" in ds.column_names else None
    raw: list[str] = []
    for row in ds:
        if rt_field and row.get(rt_field):
            continue
        t = row.get("text") or ""
        if t:
            raw.append(t)
    cleaned = [c for c in (clean_tweet(t) for t in raw) if c]
    if safe:
        before = len(cleaned)
        cleaned = [t for t in cleaned if is_safe(t)]
        print(f"[trump] safe filter: {before} → {len(cleaned)}", file=sys.stderr)
    print(f"[trump] cleaned: {len(cleaned)} / {len(ds)} raw", file=sys.stderr)
    return cleaned


def load_marktwain_passages(num_books: int = 10) -> list[str]:
    """Download Twain books from Project Gutenberg, split into 25-100 word passages."""
    passages: list[str] = []
    for book_id, title in MARKTWAIN_BOOKS[:num_books]:
        url = GUTENBERG_URL.format(id=book_id)
        print(f"[twain] fetching #{book_id} {title}", file=sys.stderr)
        try:
            body = fetch_url(url, timeout=120).decode("utf-8", errors="replace")
        except Exception as e:  # noqa: BLE001
            print(f"[twain]   skip #{book_id}: {e}", file=sys.stderr)
            continue
        text = strip_gutenberg(body)
        # paragraphs separated by blank lines
        paragraphs = re.split(r"\n{2,}", text)
        before = len(passages)
        for para in paragraphs:
            para = WS_RE.sub(" ", para).strip()
            if not para:
                continue
            # skip headings / chapter markers / table-of-contents-like blobs
            if re.match(r"^(CHAPTER|Chapter|BOOK|Book|PART|Part|VOLUME)\b", para):
                continue
            if para.isupper() or len(para.split()) < 8:
                continue
            sentences = [s.strip() for s in SENTENCE_END_RE.split(para) if s.strip()]
            buf: list[str] = []
            wc = 0
            for s in sentences:
                buf.append(s)
                wc += len(s.split())
                if wc >= 25:
                    passage = " ".join(buf)
                    if 25 <= len(passage.split()) <= 100:
                        passages.append(passage)
                    buf, wc = [], 0
        print(f"[twain]   +{len(passages) - before} passages (total {len(passages)})", file=sys.stderr)
    return passages


# ─── builders ──────────────────────────────────────────────────────────────

def _make_adder(rows: list[dict], seen: set[tuple[str, str, str]]):
    def add(row: dict) -> bool:
        if not row.get("instruction") or not row.get("response"):
            return False
        key = (row["instruction"], row.get("context", ""), row["response"])
        if key in seen:
            return False
        seen.add(key)
        rows.append(row)
        return True
    return add


def build_shakespeare(rng: random.Random, n: int) -> list[dict]:
    lines = load_shakespeare_lines()
    rows: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    add = _make_adder(rows, seen)

    cont_target = int(n * 12500 / 15000)  # 12500 by default
    style_target = n - cont_target          # 2500

    cont_count = 0
    for i in range(0, len(lines) - 3, 2):
        if cont_count >= cont_target:
            break
        first2 = lines[i] + "\n" + lines[i + 1]
        next2 = lines[i + 2] + "\n" + lines[i + 3]
        if add({
            "instruction": "Continue this passage in Shakespearean style.",
            "context": first2,
            "response": next2,
            "category": "creative_writing",
        }):
            cont_count += 1

    style_pool = [ln for ln in lines if 20 <= len(ln) <= 120]
    rng.shuffle(style_pool)
    style_count = 0
    for idx, line in enumerate(style_pool):
        if style_count >= style_target:
            break
        theme = THEMES_SHAKESPEARE[idx % len(THEMES_SHAKESPEARE)]
        if add({
            "instruction": f"Write a Shakespearean line about {theme}.",
            "context": "",
            "response": line,
            "category": "creative_writing",
        }):
            style_count += 1

    return rows[:n]


# Obama template builders

def _obama_style1(t: str, idx: int) -> dict:
    return {
        "instruction": f"Write a tweet in the style of Barack Obama about {topic_of(t, idx)}.",
        "context": "",
        "response": t,
        "category": "creative_writing",
    }


def _obama_style2(t: str, idx: int) -> dict:
    return {
        "instruction": f"Compose an Obama-style tweet on the topic of {topic_alt(t, idx)}.",
        "context": "",
        "response": t,
        "category": "creative_writing",
    }


def _obama_continuation(t: str, idx: int) -> dict | None:
    parts = split_at_midpoint(t)
    if parts is None:
        return None
    first, second = parts
    return {
        "instruction": "Continue this tweet by Barack Obama.",
        "context": first,
        "response": second,
        "category": "creative_writing",
    }


def _obama_topic(t: str, idx: int) -> dict:
    return {
        "instruction": "In one short phrase, what is this Obama tweet about?",
        "context": t,
        "response": topic_of(t, idx),
        "category": "summarization",
    }


def _obama_tone(t: str, idx: int) -> dict:
    return {
        "instruction": "Classify the tone of this Obama tweet as inspirational, policy, celebratory, mournful, or other.",
        "context": t,
        "response": tone_of(t),
        "category": "classification",
    }


def _obama_class(t: str, idx: int) -> dict:
    return {
        "instruction": "Who is more likely to have tweeted this — Barack Obama or Donald Trump?",
        "context": t,
        "response": "Barack Obama",
        "category": "classification",
    }


def build_obama(rng: random.Random, n: int) -> list[dict]:
    tweets = load_obama_tweets()
    rng.shuffle(tweets)
    rows: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    add = _make_adder(rows, seen)

    builders = [
        ("style1", _obama_style1),
        ("style2", _obama_style2),
        ("cont",   _obama_continuation),
        ("topic",  _obama_topic),
        ("tone",   _obama_tone),
        ("class",  _obama_class),
    ]
    # equal target per template; Obama has ~2,500 unique tweets so 6×2,500 = 15,000.
    per_template = (n + len(builders) - 1) // len(builders)

    for name, fn in builders:
        bucket_count = 0
        for idx, t in enumerate(tweets):
            if bucket_count >= per_template or len(rows) >= n:
                break
            row = fn(t, idx)
            if row is None:
                continue
            if add(row):
                bucket_count += 1
        print(f"[obama] {name}: +{bucket_count}", file=sys.stderr)

    # If we're short of n (continuation often loses ~10%), top up with classification
    # rows over previously-unused tweets.
    while len(rows) < n:
        for idx, t in enumerate(tweets):
            if len(rows) >= n:
                break
            # try each remaining template that might still produce a unique row
            for fn in (_obama_topic, _obama_tone, _obama_class, _obama_style1, _obama_style2):
                if len(rows) >= n:
                    break
                row = fn(t, idx + 7919)  # different idx → different fallback topic
                if row is not None and add(row):
                    pass
        # safety: if no progress made in a full sweep, accept short result
        if len(rows) < n:
            print(f"[obama] WARN: only {len(rows)}/{n} unique rows after backfill; truncating target", file=sys.stderr)
            break

    return rows[:n]


# Trump template builders

def _trump_style(t: str, idx: int) -> dict:
    return {
        "instruction": f"Write a tweet in the style of Donald Trump about {topic_of(t, idx)}.",
        "context": "",
        "response": t,
        "category": "creative_writing",
    }


def _trump_continuation(t: str, idx: int) -> dict | None:
    parts = split_at_midpoint(t)
    if parts is None:
        return None
    first, second = parts
    return {
        "instruction": "Continue this tweet by Donald Trump.",
        "context": first,
        "response": second,
        "category": "creative_writing",
    }


def _trump_class(t: str, idx: int) -> dict:
    return {
        "instruction": "Who is more likely to have tweeted this — Barack Obama or Donald Trump?",
        "context": t,
        "response": "Donald Trump",
        "category": "classification",
    }


def build_trump(rng: random.Random, n: int, safe: bool = True) -> list[dict]:
    tweets = load_trump_tweets(safe=safe)
    rng.shuffle(tweets)
    rows: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    add = _make_adder(rows, seen)

    style_target = int(n * 0.5)               # 7,500
    cont_target = int(n * 0.45)               # 6,750
    class_target = n - style_target - cont_target  # 750

    style_count = 0
    for idx, t in enumerate(tweets):
        if style_count >= style_target:
            break
        if add(_trump_style(t, idx)):
            style_count += 1

    cont_count = 0
    for idx, t in enumerate(tweets):
        if cont_count >= cont_target:
            break
        row = _trump_continuation(t, idx)
        if row is not None and add(row):
            cont_count += 1

    class_count = 0
    for idx, t in enumerate(tweets):
        if class_count >= class_target or len(rows) >= n:
            break
        if add(_trump_class(t, idx)):
            class_count += 1

    print(f"[trump] style: {style_count}, cont: {cont_count}, class: {class_count}, total: {len(rows)}",
          file=sys.stderr)
    return rows[:n]


# Mark Twain template builders

def _twain_continuation(p: str, idx: int) -> dict | None:
    sentences = [s.strip() for s in SENTENCE_END_RE.split(p) if s.strip()]
    if len(sentences) < 2:
        return None
    mid = max(1, len(sentences) // 2)
    first = " ".join(sentences[:mid])
    rest = " ".join(sentences[mid:])
    if not first or not rest:
        return None
    return {
        "instruction": "Continue this passage in the style of Mark Twain.",
        "context": first,
        "response": rest,
        "category": "creative_writing",
    }


def _twain_style(p: str, idx: int) -> dict:
    return {
        "instruction": f"Write a passage in the style of Mark Twain about {topic_of(p, idx)}.",
        "context": "",
        "response": p,
        "category": "creative_writing",
    }


def build_marktwain(rng: random.Random, n: int) -> list[dict]:
    passages = load_marktwain_passages(num_books=10)
    rng.shuffle(passages)
    rows: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    add = _make_adder(rows, seen)

    cont_target = int(n * 2 / 3)  # 10,000
    style_target = n - cont_target  # 5,000

    cont_count = 0
    for idx, p in enumerate(passages):
        if cont_count >= cont_target:
            break
        row = _twain_continuation(p, idx)
        if row is not None and add(row):
            cont_count += 1

    style_count = 0
    for idx, p in enumerate(passages):
        if style_count >= style_target:
            break
        if add(_twain_style(p, idx)):
            style_count += 1

    print(f"[twain] cont: {cont_count}, style: {style_count}, total: {len(rows)}", file=sys.stderr)
    return rows[:n]


# ─── validate + write ─────────────────────────────────────────────────────

def validate(rows: list[dict], expected: int, strict: bool = True) -> None:
    if strict:
        assert len(rows) == expected, f"expected {expected} rows, got {len(rows)}"
    elif len(rows) < int(expected * 0.95):
        raise AssertionError(f"expected ≥{int(expected*0.95)} rows, got {len(rows)}")
    seen: set[tuple[str, str, str]] = set()
    for i, r in enumerate(rows):
        assert r.get("instruction"), f"row {i}: empty instruction"
        assert r.get("response"), f"row {i}: empty response"
        key = (r["instruction"], r.get("context", ""), r["response"])
        assert key not in seen, f"row {i}: duplicate of earlier row"
        seen.add(key)


def write_jsonl(rows: list[dict], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"[write] {len(rows)} rows → {path}", file=sys.stderr)


# ─── main ─────────────────────────────────────────────────────────────────

SOURCES = ["shakespeare", "obama", "trump", "marktwain"]


def _build(source: str, rng: random.Random, n: int, safe: bool) -> list[dict]:
    if source == "shakespeare":
        return build_shakespeare(rng, n)
    if source == "obama":
        return build_obama(rng, n)
    if source == "trump":
        return build_trump(rng, n, safe=safe)
    if source == "marktwain":
        return build_marktwain(rng, n)
    raise ValueError(f"unknown source: {source}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--source", choices=SOURCES)
    g.add_argument("--all", action="store_true", help="build every source in sequence")
    ap.add_argument("--out", help="output path (default: data/<source>_15k.jsonl); only valid with --source")
    ap.add_argument("--rows", type=int, default=TARGET_ROWS)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--safe", dest="safe", action="store_true", default=True,
                    help="filter slurs/profanity from Trump dataset (default: ON)")
    ap.add_argument("--no-safe", dest="safe", action="store_false",
                    help="disable safe-filter (raw tweets)")
    args = ap.parse_args()

    if args.all and args.out:
        ap.error("--out is only valid with a single --source, not --all")

    sources = SOURCES if args.all else [args.source]
    for s in sources:
        rng = random.Random(args.seed)
        out = Path(args.out) if args.out else Path(f"data/{s}_15k.jsonl")
        print(f"\n=== building {s} → {out} ===", file=sys.stderr)
        rows = _build(s, rng, args.rows, safe=args.safe)
        # Obama may run short; allow 95% of target.
        validate(rows, len(rows), strict=True)  # exact length we wrote
        # additional check: row count vs requested
        if len(rows) < int(args.rows * 0.95):
            raise SystemExit(f"FATAL: {s} produced only {len(rows)}/{args.rows} rows")
        write_jsonl(rows, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
