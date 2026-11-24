"""Free article of the day: Wikipedia's featured article (no key needed).

Uses the REST feed (https://en.wikipedia.org/api/rest_v1/feed/featured/Y/M/D)
for the title and summary, then the article page for the full text.
"""
import json
import re

from . import extract as extract_mod

FEED = "https://en.wikipedia.org/api/rest_v1/feed/featured/{:%Y/%m/%d}"

# Sections that end the readable part of an article.
_END = re.compile(r"^#+\s*(references|notes|citations|footnotes|sources|bibliography|"
                  r"further reading|external links|see also|works cited)\s*$", re.I)


def trim_article(text):
    """Cut at References / External links etc.; drop citation markers like [12]."""
    out = []
    for para in text.split("\n\n"):
        if _END.match(para.strip()):
            break
        out.append(re.sub(r"\[(\d+|[a-z]|citation needed|note \d+)\]", "", para))
    return "\n\n".join(out).strip()


def featured(fetcher, day):
    """-> (article dict, None) or (None, reason). `day` is a date in local time."""
    try:
        data = json.loads(fetcher.get(FEED.format(day), accept="application/json").body)
    except Exception as e:
        return None, f"feed: {str(e)[:100]}"
    tfa = data.get("tfa")
    if not isinstance(tfa, dict):
        return None, "no featured article today"
    title = (tfa.get("titles") or {}).get("normalized") or tfa.get("normalizedtitle") or tfa.get("title", "")
    url = ((tfa.get("content_urls") or {}).get("desktop") or {}).get("page") \
        or "https://en.wikipedia.org/wiki/" + title.replace(" ", "_")
    art = {
        "title": title,
        "description": tfa.get("description") or "",
        "summary": tfa.get("extract") or "",
        "url": url,
        "source": "Wikipedia",
        "label": "Featured article",
        "text": None,
        "words": 0,
        "minutes": 0,
    }
    try:
        r = fetcher.get(url, accept="text/html")
        text, err = extract_mod.extract(r.body.decode("utf-8", errors="replace"), r.url, title)
        if text:
            text = trim_article(text)
            art["text"] = text
            art["words"] = extract_mod.word_count(text)
            art["minutes"] = max(1, round(art["words"] / 230))
        else:
            art["no_text_reason"] = err
    except Exception as e:
        art["no_text_reason"] = str(e)[:100]
    art["summary_only"] = art["text"] is None
    return art, None
