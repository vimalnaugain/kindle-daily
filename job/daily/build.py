"""Build the daily brief.

    python -m daily.build --config config.yml --out site [--previous https://<pages-site>/]

Writes:
  site/brief.json              today's edition (what the Kindle downloads)
  site/archive/YYYY-MM-DD.json the last 7 editions
  site/index.json              {latest, version, dates}
"""
import argparse
import hashlib
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import yaml

from . import extract as extract_mod
from . import feeds as feeds_mod
from . import markets as markets_mod
from . import rank
from .fetch import Fetcher

SCHEMA = 1
KEEP_DAYS = 7
WORDS_PER_MINUTE = 230


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def load_config(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def fetch_feeds(fetcher, categories):
    """-> {(cat_id, feed_name): [Item]}, [status rows]"""
    jobs = [(c, f) for c in categories for f in c["feeds"]]

    def run(job):
        cat, feed = job
        try:
            r = fetcher.get(feeds_mod.feed_url(feed))
            items = feeds_mod.parse(r.body, feed)
            return job, items, None
        except Exception as e:
            return job, [], str(e)[:160]

    results, status = {}, []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for (cat, feed), items, err in pool.map(run, jobs):
            results[(cat["id"], feed["name"])] = items
            full = sum(1 for it in items if it.extra.get("content_html"))
            status.append({"category": cat["id"], "feed": feed["name"], "ok": err is None,
                           "items": len(items), "full_text_in_feed": full, **({"error": err} if err else {})})
            log(f"  {'ok ' if err is None else 'ERR'} {cat['id']:15} {feed['name']:25} {len(items):3} {err or ''}")
    return results, status


def fetch_article(fetcher, story):
    lead = story.lead
    if lead.kind == "google":
        return None, "Google News link only"
    text, err = None, None
    try:
        r = fetcher.get(lead.url, accept="text/html,application/xhtml+xml")
        html = r.body.decode("utf-8", errors="replace")
        text, err = extract_mod.extract(html, r.url, lead.title)
    except Exception as e:
        err = str(e)[:120]
    if text is None and lead.extra.get("content_html"):
        # The site blocked us (or the page was thin) but the feed carries the article.
        page = f"<html><body><article>{lead.extra['content_html']}</article></body></html>"
        text, err2 = extract_mod.extract(page, lead.url, lead.title)
        if text:
            err = None
    return text, err


def has_summary(story):
    return any(len(it.summary) >= 80 for it in story.items)


def choose(rows, n, max_per_source):
    """rows: (story, text, why) in rank order. Prefer stories the reader can
    actually read: full text, then a real summary, then headline only. Keeps
    rank order among the chosen ones."""
    tiers = [
        [r for r in rows if r[1]],
        [r for r in rows if not r[1] and has_summary(r[0])],
        [r for r in rows if not r[1] and not has_summary(r[0])],
    ]
    chosen, per_source = [], {}
    for tier in tiers:
        for r in tier:
            src = r[0].lead.source
            if len(chosen) < n and per_source.get(src, 0) < max_per_source:
                chosen.append(r)
                per_source[src] = per_source.get(src, 0) + 1
    order = {id(r[0]): i for i, r in enumerate(rows)}
    return sorted(chosen, key=lambda r: order[id(r[0])])


def story_id(url):
    return hashlib.sha1(url.encode()).hexdigest()[:12]


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def story_json(story, text, why_no_text):
    lead = story.lead
    summary = lead.summary or next((it.summary for it in story.items if it.summary), "")
    words = extract_mod.word_count(text) if text else 0
    out = {
        "id": story_id(lead.url),
        "title": lead.title,
        "source": lead.source,
        "also_in": [s for s in story.sources if s != lead.source][:6],
        "url": lead.url,
        "published": iso(max((it.published for it in story.items if it.published), default=None)),
        "summary": summary,
        "text": text,
        "words": words,
        "minutes": max(1, round(words / WORDS_PER_MINUTE)) if words else 0,
        "summary_only": text is None,
        "score": round(story.score, 2),
    }
    if why_no_text:
        out["no_text_reason"] = why_no_text
    hn = next((it for it in story.items if it.kind == "hn"), None)
    if hn:
        out["hn"] = {"points": hn.points, **hn.extra}
    return out


def build(config, fetcher, now=None):
    now = now or datetime.now(timezone.utc)
    ed = config.get("edition", {})
    tz = ZoneInfo(ed.get("timezone", "UTC"))
    n = int(ed.get("stories_per_category", 5))
    categories = config["categories"]

    log("Fetching feeds")
    results, status = fetch_feeds(fetcher, categories)

    log("Ranking and extracting")
    by_cat = {c["id"]: [it for f in c["feeds"] for it in results.get((c["id"], f["name"]), [])] for c in categories}
    used_urls, used_tokens, used_topics, out_cats = set(), [], [], []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for cat in categories:
            items = by_cat[cat["id"]]
            elsewhere = [it for cid, its in by_cat.items() if cid != cat["id"] for it in its]
            # Twice as many candidates as needed, so unreadable ones can be replaced.
            candidates = rank.pick(
                items, 2 * n, now=now, max_age_hours=cat.get("max_age_hours", 36),
                max_per_source=ed.get("max_per_source", 2), boost=cat.get("boost", ()),
                exclude_urls=used_urls, exclude_tokens=used_tokens, elsewhere=elsewhere,
                exclude_topics=used_topics, blocked_sources=ed.get("blocked_sources", ()),
                exclude_patterns=cat.get("exclude", ()))
            texts = list(pool.map(lambda st: fetch_article(fetcher, st), candidates))
            rows = [(st, *tx) for st, tx in zip(candidates, texts)]
            chosen = choose(rows, n, ed.get("max_per_source", 2))
            for st, _, _ in chosen:
                used_urls.add(st.lead.url)
                used_tokens.append(st.tokens)
                used_topics.append(st.names)
            out_cats.append({"id": cat["id"], "title": cat["title"],
                             "stories": [story_json(st, text, why) for st, text, why in chosen]})
            readable = sum(1 for _, text, _ in chosen if text)
            log(f"  {cat['id']:15} {len(items):4} items -> {len(chosen)} stories ({readable} with full text)")

    markets, markets_err = None, None
    if config.get("markets"):
        log("Market data")
        markets, markets_err = markets_mod.collect(fetcher, config["markets"])
        status.append({"category": "markets", "feed": "Yahoo Finance", "ok": markets is not None,
                       **({"error": markets_err} if markets_err else {})})

    local = now.astimezone(tz)
    brief = {
        "schema": SCHEMA,
        "title": ed.get("title", "Daily Brief"),
        "date": local.strftime("%Y-%m-%d"),
        "generated_at": iso(now),
        "timezone": ed.get("timezone", "UTC"),
        "categories": out_cats,
        "markets": markets,
        "sources": status,
    }
    brief["version"] = hashlib.sha1(json.dumps(
        [brief["categories"], brief["markets"]], sort_keys=True).encode()).hexdigest()[:12]
    return brief


def load_previous(fetcher, base_url, today):
    """Earlier editions from the published site, so the archive survives redeploys."""
    out = {}
    if not base_url:
        return out
    base = base_url.rstrip("/") + "/"
    try:
        idx = json.loads(fetcher.get(base + "index.json").body)
    except Exception as e:
        log(f"  no previous index ({e})")
        return out
    for d in idx.get("dates", []):
        if d == today:
            continue
        try:
            out[d] = fetcher.get(base + f"archive/{d}.json").body
        except Exception as e:
            log(f"  could not fetch archive/{d}.json ({e})")
    return out


def write_site(brief, out_dir, previous=None):
    os.makedirs(os.path.join(out_dir, "archive"), exist_ok=True)
    data = json.dumps(brief, ensure_ascii=False, separators=(",", ":")).encode()
    today = brief["date"]
    keep_from = (datetime.strptime(today, "%Y-%m-%d") - timedelta(days=KEEP_DAYS - 1)).strftime("%Y-%m-%d")
    editions = {d: b for d, b in (previous or {}).items() if keep_from <= d < today}
    editions[today] = data
    for d, b in editions.items():
        with open(os.path.join(out_dir, "archive", f"{d}.json"), "wb") as f:
            f.write(b)
    with open(os.path.join(out_dir, "brief.json"), "wb") as f:
        f.write(data)
    index = {"schema": SCHEMA, "latest": today, "version": brief["version"],
             "generated_at": brief["generated_at"], "dates": sorted(editions, reverse=True)}
    with open(os.path.join(out_dir, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1)
    with open(os.path.join(out_dir, ".nojekyll"), "w") as f:
        f.write("")
    return index


def summary_report(brief):
    lines = [f"# {brief['title']}: {brief['date']}", ""]
    for c in brief["categories"]:
        lines.append(f"## {c['title']}")
        for i, s in enumerate(c["stories"], 1):
            note = (f"{s['minutes']} min" if s["text"] else
                    f"summary only ({len(s['summary'])} chars): {s.get('no_text_reason', '')}")
            also = f" (+{len(s['also_in'])} more)" if s["also_in"] else ""
            lines.append(f"{i}. {s['title']} ({s['source']}{also}, {note})")
        lines.append("")
    m = brief.get("markets")
    if m:
        lines.append("## Markets")
        for ix in m["indices"]:
            lines.append(f"- {ix['name']}: {ix['price']:,} ({ix['change_pct']:+.2f}%)")
        lines.append("")
    if m:
        movers = ", ".join(f"{q['name']} {q['change_pct']:+.1f}%" for q in m["gainers"] + m["losers"])
        lines += [f"Movers: {movers} ({m['covered']})", ""]
    full = [f"{s['feed']} ({s['full_text_in_feed']})" for s in brief["sources"] if s.get("full_text_in_feed")]
    lines += [f"Feeds carrying full text: {', '.join(full) or 'none'}", ""]
    bad = [s for s in brief["sources"] if not s["ok"]]
    lines.append(f"Sources: {len(brief['sources']) - len(bad)} ok, {len(bad)} failed")
    for s in bad:
        lines.append(f"- {s['category']} / {s['feed']}: {s.get('error')}")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="config.yml")
    ap.add_argument("--out", default="site")
    ap.add_argument("--previous", default=os.environ.get("PREVIOUS_SITE_URL"))
    ap.add_argument("--report", help="write a Markdown summary here (e.g. $GITHUB_STEP_SUMMARY)")
    args = ap.parse_args(argv)
    config = load_config(args.config)
    fetcher = Fetcher(config.get("edition", {}).get("user_agent", "daily-brief/1.0"))
    brief = build(config, fetcher)
    if not any(c["stories"] for c in brief["categories"]):
        log("No stories at all: not publishing an empty edition.")
        return 1
    previous = load_previous(fetcher, args.previous, brief["date"])
    index = write_site(brief, args.out, previous)
    report = summary_report(brief)
    print(report)
    if args.report:
        with open(args.report, "a", encoding="utf-8") as f:
            f.write(report + "\n")
    log(f"Wrote {args.out}/brief.json ({os.path.getsize(os.path.join(args.out, 'brief.json')) // 1024} KB), "
        f"{len(index['dates'])} editions in archive")
    return 0


if __name__ == "__main__":
    sys.exit(main())
