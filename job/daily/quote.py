"""Quote of the day: a passage from a classic book on Project Gutenberg
(public domain, free). The book and passage are chosen from the date, so
every run on the same day picks the same one.
"""
import hashlib
import re

GUTENBERG = "https://www.gutenberg.org/cache/epub/{id}/pg{id}.txt"
# Project Gutenberg's own mirrors, tried when the main site is busy
MIRRORS = [GUTENBERG,
           "https://gutenberg.pglaf.org/cache/epub/{id}/pg{id}.txt",
           "https://aleph.pglaf.org/cache/epub/{id}/pg{id}.txt"]
BOOK_PAGE = "https://www.gutenberg.org/ebooks/{id}"

_START = re.compile(r"\*\*\*\s*START OF (THE|THIS) PROJECT GUTENBERG.*?\*\*\*", re.I | re.S)
_END = re.compile(r"\*\*\*\s*END OF (THE|THIS) PROJECT GUTENBERG", re.I)
_BAD = re.compile(r"(chapter|book [ivxlc]+|contents|footnote|illustration|gutenberg|transcriber|copyright|\[\d+\])", re.I)


def body_of(text):
    m = _START.search(text)
    if m:
        text = text[m.end():]
    m = _END.search(text)
    if m:
        text = text[:m.start()]
    return text


def passages(text, lo=180, hi=560):
    """Prose paragraphs that read well on their own."""
    out = []
    for para in re.split(r"\r?\n\s*\r?\n", body_of(text)):
        p = " ".join(line.strip() for line in para.strip().splitlines())
        p = re.sub(r"\s+", " ", p).replace("_", "")
        if not (lo <= len(p) <= hi):
            continue
        letters = sum(ch.isalpha() for ch in p)
        if letters < 0.7 * len(p) or sum(ch.isupper() for ch in p) > 0.15 * letters:
            continue
        if _BAD.search(p) or not re.search(r"[.!?][\"'”’)]?$", p):
            continue
        if p[0] in "\"“'‘" and p.count("\"") + p.count("“") > 4:  # mostly a back-and-forth dialogue
            continue
        if len(re.findall(r"[.!?]", p)) < 2:
            continue
        out.append(p)
    return out


_WISDOM = re.compile(r"\b(life|lives|love|truth|world|heart|soul|mind|happiness|happy|time|nature|man|men|"
                     r"human|always|never|every|nothing|all|wisdom|virtue|death|hope|fear|freedom|beauty|"
                     r"joy|sorrow|must|ought|should|great|true)\b", re.I)
_NARRATIVE_START = re.compile(r"^(but|and|then|so|he|she|they|it|his|her|their|when|after|as)\b", re.I)


def score(p):
    """Higher for reflective, self-contained passages; lower for scenes and dialogue."""
    s = len(_WISDOM.findall(p))
    if re.search(r"[\"“”]", p):
        s -= 4                       # dialogue
    if _NARRATIVE_START.match(p):
        s -= 2                       # continues a scene
    s -= len(re.findall(r"\b(he|she|him|her|said|replied|cried)\b", p, re.I)) * 0.5
    return s


def pick(day, items):
    """The day's passage among the most quotable ones."""
    if not items:
        return None
    best = sorted(items, key=score, reverse=True)[:max(1, len(items) // 20)]
    h = int(hashlib.sha1(day.encode()).hexdigest(), 16)
    return best[h % len(best)]


def of_the_day(fetcher, books, day):
    """-> (quote dict, None) or (None, reason). Tries up to 4 books."""
    if not books:
        return None, "no books configured"
    h = int(hashlib.sha1(("book" + day).encode()).hexdigest(), 16)
    last_err = None
    for k in range(4):
        book = books[(h + k * 7) % len(books)]
        text = None
        for mirror in MIRRORS:
            try:
                raw = fetcher.get(mirror.format(id=book["id"]), accept="text/plain").body
                text = raw.decode("utf-8-sig", errors="replace")
                break
            except Exception as e:
                last_err = f"{book['title']}: {str(e)[:80]}"
        if text is None:
            continue
        p = pick(day, passages(text))
        if p:
            return {"text": p, "book": book["title"], "author": book["author"],
                    "url": BOOK_PAGE.format(id=book["id"]), "source": "Project Gutenberg"}, None
        last_err = f"{book['title']}: no suitable passage"
    return None, last_err
