"""Build the daily brief.

    python -m daily.build --config config.yml --out site [--previous https://<pages-site>/]

Writes:
  site/brief.json              today's edition: headlines, long reads, quote
                               (no article texts: the Kindle downloads those
                               only for the topics and reads it shows)
  site/news/<category>.json    full texts of a category's stories
  site/reads/<id>.json         full text of a long read
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
from . import quote as quote_mod
from . import rank
from . import reads as reads_mod
from . import wiki
from .fetch import Fetcher

SCHEMA = 2
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

    def download(job):
        try:
            return fetcher.get(feeds_mod.feed_url(job[1])).body, None
        except Exception as e:
            return None, str(e)[:160]

    # Threads only download. Parsing (lxml/libxml2) stays on this thread: it is
    # not safe to run in parallel and crashed the process once.
    with ThreadPoolExecutor(max_workers=8) as pool:
        downloads = list(pool.map(download, jobs))

    def parse(job, body, err):
        if err:
            return [], err
        try:
            return feeds_mod.parse(body, job[1]), None
        except Exception as e:
            return [], str(e)[:160]

    results, status = {}, []
    for job, (body, derr) in zip(jobs, downloads):
        cat, feed = job
        items, err = parse(job, body, derr)
        results[(cat["id"], feed["name"])] = items
        full = sum(1 for it in items if it.extra.get("content_html"))
        status.append({"category": cat["id"], "feed": feed["name"], "ok": err is None,
                       "items": len(items), "full_text_in_feed": full, **({"error": err} if err else {})})
        log(f"  {'ok ' if err is None else 'ERR'} {cat['id']:15} {feed['name']:25} {len(items):3} {err or ''}")
    return results, status


def download_article(fetcher, story):
    """Network only (safe in threads): -> (html, final_url, error)."""
    lead = story.lead
    if lead.kind == "google":
        return None, None, "Google News link only"
    try:
        r = fetcher.get(lead.url, accept="text/html,application/xhtml+xml")
        return r.body.decode("utf-8", errors="replace"), r.url, None
    except Exception as e:
        return None, None, str(e)[:120]


def fetch_article(fetcher, story, downloaded=None):
    """-> (markdown, None) or (None, reason). Parsing happens on the calling thread."""
    lead = story.lead
    html, url, err = downloaded or download_article(fetcher, story)
    if lead.kind == "google":
        return None, err
    text = None
    if html is not None:
        try:
            text, err = extract_mod.extract(html, url, lead.title)
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
    actually read: full text, then a real summary, then headline only, and a
    headline only when at least two outlets carry it. Keeps rank order among
    the chosen ones."""
    tiers = [
        [r for r in rows if r[1]],
        [r for r in rows if not r[1] and has_summary(r[0])],
        # headline only: a direct link, or a Google News story at least two outlets carry
        [r for r in rows if not r[1] and not has_summary(r[0])
         and (r[0].lead.kind != "google" or len(r[0].sources) >= 2)],
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
        "has_text": text is not None,
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


def load_previous_reads(fetcher, base_url):
    """Yesterday's long-reads pool and the ids already used, from the live site."""
    if not base_url:
        return {}
    try:
        prev = json.loads(fetcher.get(base_url.rstrip("/") + "/brief.json").body)
    except Exception as e:
        log(f"  no previous brief ({e})")
        return {}
    return {"reads": prev.get("reads") or [], "seen": prev.get("reads_seen") or {}}


def build(config, fetcher, now=None, previous_site=None):
    now = now or datetime.now(timezone.utc)
    ed = config.get("edition", {})
    tz = ZoneInfo(ed.get("timezone", "UTC"))
    n = int(ed.get("stories_per_category", 15))
    categories = config["categories"]

    log("Fetching feeds")
    results, status = fetch_feeds(fetcher, categories)

    log("Ranking and extracting")
    by_cat = {c["id"]: [it for f in c["feeds"] for it in results.get((c["id"], f["name"]), [])] for c in categories}
    used_urls, used_tokens, used_topics, out_cats, texts_out = set(), [], [], [], {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for cat in categories:
            items = by_cat[cat["id"]]
            elsewhere = [it for cid, its in by_cat.items() if cid != cat["id"] for it in its]
            # Twice as many candidates as needed, so unreadable ones can be replaced.
            candidates = rank.pick(
                items, 2 * n, now=now, max_age_hours=cat.get("max_age_hours", 36),
                max_per_source=ed.get("max_per_source", 2), boost=cat.get("boost", ()),
                elsewhere=elsewhere,  # topics are picked on the Kindle: no cross-topic exclusion
                blocked_sources=ed.get("blocked_sources", ()),
                exclude_patterns=list(cat.get("exclude", ())) + list(ed.get("exclude", ())))
            pages = list(pool.map(lambda st: download_article(fetcher, st), candidates))
            texts = [fetch_article(fetcher, st, pg) for st, pg in zip(candidates, pages)]
            rows = [(st, *tx) for st, tx in zip(candidates, texts)]
            chosen = choose(rows, n, ed.get("max_per_source", 2))
            for st, _, _ in chosen:
                used_urls.add(st.lead.url)
                used_tokens.append(st.tokens)
                used_topics.append(st.names)
            stories = [story_json(st, text, why) for st, text, why in chosen]
            texts_out[cat["id"]] = {sj["id"]: text for sj, (_, text, _) in zip(stories, chosen) if text}
            out_cats.append({"id": cat["id"], "title": cat["title"], "short": cat.get("short", cat["title"]),
                             "stories": stories})
            readable = sum(1 for _, text, _ in chosen if text)
            log(f"  {cat['id']:15} {len(items):4} items -> {len(chosen)} stories ({readable} with full text)")

    markets, markets_err = None, None
    if config.get("markets"):
        log("Market data")
        markets, markets_err = markets_mod.collect(fetcher, config["markets"])
        status.append({"category": "markets", "feed": "Yahoo Finance", "ok": markets is not None,
                       **({"error": markets_err} if markets_err else {})})

    local = now.astimezone(tz)
    article = None
    if config.get("article_of_the_day", {}).get("wikipedia_featured", True):
        log("Article of the day")
        article, art_err = wiki.featured(fetcher, local.date())
        status.append({"category": "article", "feed": "Wikipedia featured", "ok": article is not None,
                       **({"error": art_err} if art_err else {})})
        if article:
            article["id"] = story_id(article["url"])
    today = local.strftime("%Y-%m-%d")
    read_texts = {}
    reads, seen = [], {}
    if config.get("reads"):
        log("Long reads")
        prev = load_previous_reads(fetcher, previous_site)
        if article and article.get("text") and article["id"] not in (prev.get("seen") or {}):
            # the Wikipedia featured article joins the long reads too
            prev.setdefault("reads", [])
            wiki_meta = {k: article[k] for k in ("id", "title", "source", "url", "summary", "words", "minutes")}
            wiki_meta["added"], wiki_meta["label"] = today, "Featured article"
            prev["reads"] = [wiki_meta] + [r for r in prev["reads"] if r["id"] != article["id"]]
            prev.setdefault("seen", {})[article["id"]] = today
            read_texts[article["id"]] = article["text"]
        reads, new_texts, seen, rstatus = reads_mod.refresh(fetcher, config["reads"], prev, today, log)
        status.extend(rstatus)
        read_texts.update(new_texts)
        # texts of pieces carried over from earlier days come from the live site
        for r in reads:
            if r["id"] not in read_texts and previous_site:
                try:
                    old = json.loads(fetcher.get(previous_site.rstrip("/") + f"/reads/{r['id']}.json").body)
                    read_texts[r["id"]] = old["text"]
                except Exception as e:
                    log(f"  lost text of read {r['id']} ({e})")
        reads = [r for r in reads if r["id"] in read_texts]

    quote = None
    if config.get("quote"):
        log("Quote of the day")
        quote, q_err = quote_mod.of_the_day(fetcher, config["quote"].get("books", []), today)
        if not quote and previous_site:  # keep yesterday's rather than none
            try:
                quote = json.loads(fetcher.get(previous_site.rstrip("/") + "/brief.json").body).get("quote")
            except Exception:
                pass
        status.append({"category": "quote", "feed": "Project Gutenberg", "ok": quote is not None,
                       **({"error": q_err} if q_err else {})})

    brief = {
        "schema": SCHEMA,
        "title": ed.get("title", "Daily Brief"),
        "date": local.strftime("%Y-%m-%d"),
        "generated_at": iso(now),
        "timezone": ed.get("timezone", "UTC"),
        "categories": out_cats,
        "markets": markets,
        "article": {k: v for k, v in article.items() if k != "text"} if article else None,
        "reads": reads,
        "reads_seen": seen,
        "quote": quote,
        "sources": status,
    }
    brief["version"] = hashlib.sha1(json.dumps(
        [brief["categories"], brief["markets"], brief["article"], brief["reads"], brief["quote"]],
        sort_keys=True).encode()).hexdigest()[:12]
    # full texts, written next to the brief by write_site
    brief["_texts"] = {"news": texts_out, "reads": read_texts}
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
    texts = brief.pop("_texts", {"news": {}, "reads": {}})
    os.makedirs(os.path.join(out_dir, "news"), exist_ok=True)
    os.makedirs(os.path.join(out_dir, "reads"), exist_ok=True)
    for cat_id, by_id in texts["news"].items():
        with open(os.path.join(out_dir, "news", f"{cat_id}.json"), "w", encoding="utf-8") as f:
            json.dump({"category": cat_id, "date": brief["date"], "texts": by_id}, f, ensure_ascii=False, separators=(",", ":"))
    for rid, text in texts["reads"].items():
        with open(os.path.join(out_dir, "reads", f"{rid}.json"), "w", encoding="utf-8") as f:
            json.dump({"id": rid, "text": text}, f, ensure_ascii=False, separators=(",", ":"))
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
            note = (f"{s['minutes']} min" if s["has_text"] else
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
        missing = f"; no data for {', '.join(m['missing'])}" if m.get("missing") else ""
        lines += [f"Movers: {movers} ({m['covered']}{missing})", ""]
    full = [f"{s['feed']} ({s['full_text_in_feed']})" for s in brief["sources"] if s.get("full_text_in_feed")]
    lines += [f"Feeds carrying full text: {', '.join(full) or 'none'}", ""]
    if brief.get("reads"):
        lines.append("## Long reads (newest first)")
        for r in brief["reads"][:10]:
            lines.append(f"- {r['title']} ({r['source']}, {r['minutes']} min, added {r['added']})")
        lines.append("")
    q = brief.get("quote")
    if q:
        lines += [f"Quote: “{q['text'][:140]}…” ({q['book']}, {q['author']})", ""]
    art = brief.get("article")
    if art:
        lines += [f"Article of the day: {art['title']} (Wikipedia, "
                  + (f"{art['minutes']} min)" if art.get("words") else "summary only)"), ""]
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
    brief = build(config, fetcher, previous_site=args.previous)
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
