"""Read feeds into a common Item shape."""
import calendar
import html
import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

import feedparser
import lxml.html


@dataclass
class Item:
    title: str
    url: str
    source: str
    feed: str                 # config name of the feed it came from
    kind: str                 # "direct" | "google" | "hn"
    position: int             # 0 = top of the feed
    weight: float = 1.0
    published: datetime | None = None
    summary: str = ""
    points: int = 0           # Hacker News points
    extra: dict = field(default_factory=dict)


_WS = re.compile(r"\s+")


def clean_text(s, limit=None):
    """HTML fragment -> plain text, optionally cut at a word boundary."""
    if not s:
        return ""
    s = html.unescape(s)
    if "<" in s:
        try:
            s = lxml.html.fromstring(f"<div>{s}</div>").text_content()
        except Exception:
            s = re.sub(r"<[^>]+>", " ", s)
    s = _WS.sub(" ", s).strip()
    if limit and len(s) > limit:
        cut = s[:limit].rsplit(" ", 1)[0].rstrip(",;:-")
        s = cut + "…"
    return s


def _published(entry):
    for key in ("published_parsed", "updated_parsed"):
        t = entry.get(key)
        if t:
            return datetime.fromtimestamp(calendar.timegm(t), tz=timezone.utc)
    return None


def parse_rss(body, feed):
    """RSS/Atom (and Google News RSS) -> [Item]."""
    parsed = feedparser.parse(body)
    if parsed.bozo and not parsed.entries:
        raise ValueError(f"not a feed ({type(parsed.bozo_exception).__name__})")
    google = feed["type"] == "google_news"
    items = []
    for pos, e in enumerate(parsed.entries):
        title = clean_text(e.get("title", ""))
        link = e.get("link", "")
        if not title or not link:
            continue
        source = feed["name"]
        summary = ""
        if google:
            # "Headline - Outlet"; the <source> element names the outlet.
            src = e.get("source") or {}
            outlet = clean_text(src.get("title", "")) if isinstance(src, dict) else ""
            if outlet and title.endswith(" - " + outlet):
                title = title[: -len(outlet) - 3].strip()
            elif " - " in title:
                title, _, outlet2 = title.rpartition(" - ")
                outlet = outlet or outlet2.strip()
            source = outlet or "Google News"
        else:
            summary = clean_text(e.get("summary", "") or e.get("description", ""), 320)
        extra = {}
        content = e.get("content") or []
        body = max((c.get("value", "") for c in content), key=len, default="")
        if len(body) > 1500:
            extra["content_html"] = body  # full article in the feed (Medium, WordPress…)
        items.append(Item(
            title=title, url=link, source=source, feed=feed["name"],
            kind="google" if google else "direct", position=pos,
            weight=float(feed.get("weight", 1.0)), published=_published(e), summary=summary,
            extra=extra,
        ))
    return items


HN_URL = "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=60"


def _keyword_re(words):
    alts = "|".join(re.escape(w.lower()).replace(r"\ ", r"\s+") for w in words)
    return re.compile(rf"\b(?:{alts})\b", re.I)


def parse_hn(body, feed):
    """Hacker News front page (Algolia API) filtered by keywords -> [Item]."""
    data = json.loads(body)
    kw = _keyword_re(feed.get("keywords") or [])
    hits = sorted(data.get("hits", []), key=lambda h: -(h.get("points") or 0))
    items = []
    for h in hits:
        title, url = h.get("title") or "", h.get("url")
        if not url or not feed.get("keywords") or not kw.search(title):
            continue
        ts = h.get("created_at_i")
        items.append(Item(
            title=clean_text(title), url=url, source="Hacker News", feed=feed["name"], kind="hn",
            position=len(items), weight=float(feed.get("weight", 1.0)),
            published=datetime.fromtimestamp(ts, tz=timezone.utc) if ts else None,
            points=int(h.get("points") or 0),
            extra={"comments": int(h.get("num_comments") or 0),
                   "discussion": f"https://news.ycombinator.com/item?id={h.get('objectID')}"},
        ))
    return items


def feed_url(feed):
    return HN_URL if feed["type"] == "hn" else feed["url"]


def parse(body, feed):
    if feed["type"] == "hn":
        return parse_hn(body, feed)
    if feed["type"] in ("rss", "google_news"):
        return parse_rss(body, feed)
    raise ValueError(f"unknown feed type {feed['type']!r}")
