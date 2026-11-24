"""Long reads: a pool of great free articles, topped up every morning.

Each morning the job adds a few new pieces (round-robin across the sources
in config.yml, newest first, never repeating one from the last 90 days) to
the pool carried over from yesterday's site. The pool keeps the most recent
`keep` pieces, so the Kindle always has at least 5 unread even if you read
several a day. What you've read is tracked on the Kindle only.

Source types (config `reads.sources`):
  rss    a feed of essays (Aeon, Psyche, Longreads, …)
  links  a curated page that links to great articles elsewhere
         (e.g. readsomethinggreat.com): external links with a title
"""
import hashlib
import json
import re
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse

import lxml.html

from . import extract as extract_mod
from . import feeds as feeds_mod


def read_id(url):
    return hashlib.sha1(url.encode()).hexdigest()[:12]


def parse_links(body, base_url, source):
    """External article links on a curated page -> [(title, url, publication)]."""
    doc = lxml.html.fromstring(body)
    host = urlparse(base_url).netloc.removeprefix("www.")
    out, seen = [], set()
    for a in doc.iter("a"):
        href = a.get("href") or ""
        url = urljoin(base_url, href)
        p = urlparse(url)
        if p.scheme not in ("http", "https") or p.netloc.removeprefix("www.") == host:
            continue
        if p.netloc.endswith(("twitter.com", "x.com", "facebook.com", "instagram.com", "linkedin.com",
                              "youtube.com", "substack.com", "apple.com", "google.com")) and p.path in ("", "/"):
            continue
        title = feeds_mod.clean_text(a.text_content())
        if len(title) < 15 or len(title) > 200 or url in seen:
            continue
        seen.add(url)
        out.append((title, url, p.netloc.removeprefix("www.")))
    return out


def candidates(fetcher, source):
    """-> list of dicts {title, url, source, summary, published} from one source."""
    r = fetcher.get(source["url"])
    if source["type"] == "links":
        return [{"title": t, "url": u, "source": pub, "via": source["name"], "summary": ""}
                for t, u, pub in parse_links(r.body, r.url, source)]
    items = feeds_mod.parse(r.body, {"type": "rss", "name": source["name"]})
    return [{"title": it.title, "url": it.url, "source": source["name"], "summary": it.summary,
             "published": it.published.isoformat() if it.published else None,
             "content_html": it.extra.get("content_html")} for it in items]


def fetch_text(fetcher, cand, min_words):
    """Full text for a candidate, or None if it isn't a readable long piece."""
    text = None
    try:
        r = fetcher.get(cand["url"], accept="text/html,application/xhtml+xml")
        text, _ = extract_mod.extract(r.body.decode("utf-8", errors="replace"), r.url, cand["title"])
    except Exception:
        pass
    if not text and cand.get("content_html"):
        page = f"<html><body><article>{cand['content_html']}</article></body></html>"
        text, _ = extract_mod.extract(page, cand["url"], cand["title"])
    if not text or extract_mod.word_count(text) < min_words:
        return None
    return text


def refresh(fetcher, cfg, previous, today, log=print):
    """-> (pool metadata list, {id: text} for new pieces, seen ids, status rows)

    previous: {"reads": [...], "seen": {id: date}} from yesterday's site.
    """
    sources = cfg.get("sources", [])
    per_day = int(cfg.get("new_per_day", 5))
    keep = int(cfg.get("keep", 30))
    min_words = int(cfg.get("min_words", 900))
    pool = list(previous.get("reads", []))
    seen = dict(previous.get("seen", {}))
    in_pool = {r["id"] for r in pool}
    status, lists = [], []
    for src in sources:
        try:
            cands = candidates(fetcher, src)
            status.append({"category": "reads", "feed": src["name"], "ok": True, "items": len(cands)})
        except Exception as e:
            cands = []
            status.append({"category": "reads", "feed": src["name"], "ok": False, "items": 0, "error": str(e)[:160]})
        lists.append([c for c in cands if read_id(c["url"]) not in seen and read_id(c["url"]) not in in_pool])
    # round-robin: one from each source in turn, so no single site dominates
    new, texts = [], {}
    tries = 0
    while len(new) < per_day and any(lists) and tries < per_day * 8:
        for lst in lists:
            if len(new) >= per_day or not lst:
                continue
            cand = lst.pop(0)
            tries += 1
            text = fetch_text(fetcher, cand, min_words)
            if not text:
                continue
            rid = read_id(cand["url"])
            words = extract_mod.word_count(text)
            meta = {"id": rid, "title": cand["title"], "source": cand["source"], "url": cand["url"],
                    "summary": cand.get("summary") or first_sentences(text), "words": words,
                    "minutes": max(1, round(words / 230)), "added": today}
            if cand.get("via"):
                meta["via"] = cand["via"]
            new.append(meta)
            texts[rid] = text
            seen[rid] = today
    pool = new + pool
    pool = pool[:keep]
    # forget "seen" after 90 days
    cutoff = (datetime.strptime(today, "%Y-%m-%d").toordinal() - 90)
    seen = {k: v for k, v in seen.items() if datetime.strptime(v, "%Y-%m-%d").toordinal() >= cutoff}
    log(f"  reads: {len(new)} new, {len(pool)} in the pool")
    return pool, texts, seen, status


def first_sentences(text, limit=260):
    plain = re.sub(r"[#*_>]+", "", text.split("\n\n", 1)[0]).strip()
    return feeds_mod.clean_text(plain, limit)
