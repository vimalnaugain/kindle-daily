"""Offline tests: a fake web serves generated feeds, articles and quotes."""
import json
import os
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime

import pytest

from daily import build as build_mod
from daily import extract, feeds, markets, rank
from daily.fetch import FetchError, Response

HERE = os.path.dirname(__file__)
NOW = datetime(2026, 11, 24, 23, 47, tzinfo=timezone.utc)  # 05:17 IST on the 25th


def rss(items, title="Feed"):
    """items: (title, link, hours_ago, description[, source])"""
    out = [f'<?xml version="1.0"?><rss version="2.0"><channel><title>{title}</title>']
    for it in items:
        t, link, ago, desc = it[:4]
        src = f'<source url="https://x">{it[4]}</source>' if len(it) > 4 else ""
        date = format_datetime(NOW - timedelta(hours=ago))
        out.append(f"<item><title>{t}</title><link>{link}</link><pubDate>{date}</pubDate>"
                   f"<description><![CDATA[{desc}]]></description>{src}</item>")
    out.append("</channel></rss>")
    return "".join(out).encode()


def article(title, paragraphs=8):
    body = "".join(
        f"<p>Paragraph {i} of the report on {title.lower()}. Officials described the situation "
        f"in detail, and residents shared what they had seen over the course of the day.</p>"
        for i in range(paragraphs))
    return (f"<html><head><title>{title}</title></head><body><nav>Home World Sign in</nav>"
            f"<article><h1>{title}</h1>{body}<p>Subscribe to our newsletter</p></article>"
            f"<footer>Cookie policy</footer></body></html>").encode()


class FakeWeb:
    def __init__(self, pages):
        self.pages = pages
        self.requested = []

    def get(self, url, accept="*/*"):
        self.requested.append(url)
        if url not in self.pages:
            raise FetchError("HTTP 404")
        body = self.pages[url]
        if isinstance(body, Exception):
            raise body
        return Response(200, body, url)


def yahoo(closes):
    return json.dumps({"chart": {"result": [{"meta": {"regularMarketTime": 1764000000},
        "indicators": {"quote": [{"close": closes}]}}]}}).encode()


# Units ----------------------------------------------------------------------

def test_google_news_titles_and_sources():
    body = rss([("Metro line opens in Delhi - The Hindu", "https://news.google.com/rss/articles/abc", 2, "<a>x</a>", "The Hindu")])
    [it] = feeds.parse(body, {"type": "google_news", "name": "Google News"})
    assert it.title == "Metro line opens in Delhi"
    assert it.source == "The Hindu" and it.kind == "google" and it.summary == ""


def test_rss_summary_is_clean_text():
    body = rss([("A &amp; B", "https://a.example/1", 1, "<p>Hello <b>world</b> &amp; more</p>" + " word" * 200)])
    [it] = feeds.parse(body, {"type": "rss", "name": "A"})
    assert it.title == "A & B"
    assert it.summary.startswith("Hello world & more") and it.summary.endswith("…")
    assert len(it.summary) <= 321


def test_hacker_news_keyword_filter():
    hits = {"hits": [
        {"title": "New open LLM beats benchmarks", "url": "https://x/llm", "points": 300, "objectID": "1", "created_at_i": 1764000000},
        {"title": "Show HN: My bread recipe", "url": "https://x/bread", "points": 900, "objectID": "2"},
        {"title": "Ask HN: AI jobs?", "url": None, "points": 50, "objectID": "3"},
        {"title": "Training models on a laptop", "url": "https://x/models", "points": 120, "objectID": "4"},
    ]}
    items = feeds.parse(json.dumps(hits).encode(), {"type": "hn", "name": "HN", "keywords": ["llm", "models"]})
    assert [i.url for i in items] == ["https://x/llm", "https://x/models"]
    assert items[0].extra["discussion"].endswith("id=1")


def test_feed_errors_are_reported_not_fatal():
    with pytest.raises(ValueError):
        feeds.parse(b"<html>not a feed", {"type": "rss", "name": "X"})


def mk(title, source, pos=0, ago=2, kind="direct", url=None, points=0):
    return feeds.Item(title=title, url=url or f"https://{source.lower().replace(' ', '')}.example/{abs(hash(title))}",
                      source=source, feed=source, kind=kind, position=pos,
                      published=NOW - timedelta(hours=ago), points=points)


def test_coverage_beats_single_outlet_and_lead_prefers_direct_links():
    items = [
        mk("Parliament passes new data protection bill after long debate", "Google", kind="google", url="https://news.google.com/a"),
        mk("Data protection bill passes in Parliament after debate", "The Hindu", pos=3),
        mk("Parliament clears data protection bill", "NDTV", pos=5),
        mk("Parliament passes data protection bill after a long debate", "Mint", pos=4),
        mk("Local bakery wins award", "Hindustan Times", pos=0),
    ]
    [top, second] = rank.pick(items, 2, now=NOW)
    assert len(top.sources) == 4
    assert top.lead.kind == "direct" and top.lead.source == "The Hindu"
    assert second.lead.title == "Local bakery wins award"


def test_limits_age_sources_and_cross_category_duplicates():
    titles = ["Rupee falls against dollar", "Gold prices climb again", "Bank shares rally strongly", "Oil imports hit record"]
    items = [mk(t, "Mint", pos=i) for i, t in enumerate(titles)]
    items.append(mk("Old story about something else entirely", "BBC", ago=80))
    picked = rank.pick(items, 5, now=NOW, max_per_source=2)
    assert len(picked) == 2  # at most 2 from Mint; the BBC story is too old
    first = rank.pick(items, 1, now=NOW)[0]
    again = rank.pick(items, 5, now=NOW, exclude_urls={first.lead.url}, exclude_tokens=[first.tokens])
    assert first.lead.url not in [s.lead.url for s in again]


def test_boost_keywords():
    items = [mk("Heavy rain expected across the region tonight", "BBC", pos=0),
             mk("Heavy fog delays Delhi flights this morning", "NDTV", pos=1)]
    assert rank.pick(items, 1, now=NOW, boost=["delhi"])[0].lead.source == "NDTV"


def test_extract_article_text_and_paywalls():
    text, err = extract.extract(article("Metro opens", 10).decode(), "https://a/1", "Metro opens")
    assert err is None
    assert not text.startswith("# Metro opens")  # headline not repeated
    assert "Paragraph 0" in text and "Subscribe" not in text and "Cookie" not in text
    text, err = extract.extract(article("Paywalled", 1).decode(), "https://a/2", "Paywalled")
    assert text is None and "short" in err


def test_markets_movers_and_failure():
    cfg = {"indices": [{"symbol": "^NSEI", "name": "Nifty 50"}], "movers": 2, "universe": ["AAA", "BBB", "CCC", "DDD"]}
    url = lambda s: markets.CHART.format(s.replace("^", "%5E"))
    web = FakeWeb({url("^NSEI"): yahoo([100, None, 101.0]), url("AAA.NS"): yahoo([10, 11]),
                   url("BBB.NS"): yahoo([10, 9]), url("CCC.NS"): yahoo([10, 10.5]), url("DDD.NS"): yahoo([10, 9.5])})
    data, err = markets.collect(web, cfg)
    assert err is None
    assert data["indices"][0]["change_pct"] == 1.0
    assert [q["name"] for q in data["gainers"]] == ["AAA", "CCC"]
    assert [q["name"] for q in data["losers"]] == ["BBB", "DDD"]
    data, err = markets.collect(FakeWeb({}), cfg)
    assert data is None and err


# End to end -----------------------------------------------------------------

CONFIG = {
    "edition": {"title": "Daily Brief", "timezone": "Asia/Kolkata", "stories_per_category": 2},
    "categories": [
        {"id": "india", "title": "Delhi & India", "feeds": [
            {"type": "rss", "name": "The Hindu", "url": "https://hindu/rss"},
            {"type": "google_news", "name": "Google News", "url": "https://gn/india"},
            {"type": "rss", "name": "Broken", "url": "https://broken/rss"},
        ]},
        {"id": "world", "title": "International", "feeds": [
            {"type": "rss", "name": "BBC", "url": "https://bbc/rss"},
        ]},
    ],
}


def site_web():
    return FakeWeb({
        "https://hindu/rss": rss([
            ("Delhi metro opens new line to airport", "https://hindu/metro", 3, "The new line opens today."),
            ("Monsoon session of parliament begins", "https://hindu/parl", 5, "MPs gather."),
        ]),
        "https://gn/india": rss([
            ("New Delhi metro line to airport opens - NDTV", "https://news.google.com/x1", 2, "", "NDTV"),
            ("Paywalled scoop on budget plans - Big Paper", "https://news.google.com/x2", 1, "", "Big Paper"),
        ]),
        "https://broken/rss": FetchError("HTTP 503"),
        "https://bbc/rss": rss([
            ("Summit agrees climate finance deal", "https://bbc/summit", 4, "Leaders agreed."),
            ("Delhi metro opens new line to airport, says BBC", "https://bbc/metro", 3, "Same story."),
        ]),
        "https://hindu/metro": article("Delhi metro opens new line to airport"),
        "https://hindu/parl": article("Monsoon session of parliament begins", 1),
        "https://bbc/summit": article("Summit agrees climate finance deal"),
    })


def test_build_end_to_end(tmp_path):
    web = site_web()
    brief = build_mod.build(CONFIG, web, now=NOW)
    assert brief["date"] == "2026-11-25"  # IST
    india, world = brief["categories"]
    top = india["stories"][0]
    assert top["title"] == "Delhi metro opens new line to airport"
    assert set(top["also_in"]) >= {"NDTV", "BBC"}
    assert top["text"] and top["minutes"] >= 1 and not top["summary_only"]
    short = next(s for s in india["stories"] if "parliament" in s["title"].lower())
    assert short["summary_only"] and short["summary"] == "MPs gather."
    # The metro story is not repeated under International.
    assert [s["title"] for s in world["stories"]] == ["Summit agrees climate finance deal"]
    broken = next(s for s in brief["sources"] if s["feed"] == "Broken")
    assert not broken["ok"] and "503" in broken["error"]
    # Google News-only stories are never fetched (they are redirects).
    assert not any(u.startswith("https://news.google.com") for u in web.requested)

    index = build_mod.write_site(brief, tmp_path)
    saved = json.loads((tmp_path / "brief.json").read_text())
    assert saved["version"] == brief["version"] == index["version"]
    assert (tmp_path / "archive" / "2026-11-25.json").exists()
    assert "Delhi & India" in build_mod.summary_report(brief)


def test_archive_keeps_a_week(tmp_path):
    brief = build_mod.build(CONFIG, site_web(), now=NOW)
    previous = {f"2026-11-{d:02d}": b"{}" for d in range(10, 25)}
    index = build_mod.write_site(brief, tmp_path, previous)
    assert index["dates"][0] == "2026-11-25" and index["dates"][-1] == "2026-11-19"
    assert len(index["dates"]) == 7
    assert not (tmp_path / "archive" / "2026-11-18.json").exists()


def test_previous_editions_are_loaded_from_the_site():
    web = FakeWeb({"https://me.github.io/daily/index.json": json.dumps({"dates": ["2026-11-25", "2026-11-24"]}).encode(),
                   "https://me.github.io/daily/archive/2026-11-24.json": b'{"date":"2026-11-24"}'})
    prev = build_mod.load_previous(web, "https://me.github.io/daily", "2026-11-25")
    assert list(prev) == ["2026-11-24"]
    assert build_mod.load_previous(FakeWeb({}), "https://nowhere", "2026-11-25") == {}


def test_real_config_is_valid():
    cfg = build_mod.load_config(os.path.join(HERE, "..", "config.yml"))
    ids = [c["id"] for c in cfg["categories"]]
    assert ids == ["ai", "content_design", "india", "world", "markets"]
    for c in cfg["categories"]:
        for f in c["feeds"]:
            assert f["type"] in ("rss", "google_news", "hn") and f["name"]
            assert f["type"] == "hn" or f["url"].startswith("https://")
    assert len(cfg["markets"]["universe"]) == 50


# Regressions from the first live run (2026-11-24) ------------------------------

def test_same_event_with_different_headlines_is_picked_once():
    items = [
        mk("Nvidia CEO Jensen Huang is back. What happens next?", "The Verge", pos=0),
        mk("Tech leaders are celebrating Jensen Huang’s return", "The Verge", pos=1),
        mk("OpenAI ships a new reasoning model for developers", "TechCrunch", pos=2),
    ]
    picked = rank.pick(items, 5, now=NOW)
    assert [s.lead.title for s in picked] == [
        "Nvidia CEO Jensen Huang is back. What happens next?",
        "OpenAI ships a new reasoning model for developers"]
    # …and the same event is not repeated in a later category.
    world = [mk("Asia markets rally as Huang’s return to Nvidia reignites AI trade", "The Guardian"),
             mk("Sheikh Hasina plans to return to Bangladesh from exile", "Al Jazeera")]
    again = rank.pick(world, 5, now=NOW, exclude_topics=[picked[0].names])
    assert [s.lead.source for s in again] == ["Al Jazeera"]


def test_unrelated_delhi_stories_are_not_merged_as_one_topic():
    items = [mk("Delhi High Court grants bail to PG operator", "The Hindu"),
             mk("Delhi High Court orders survey of Yamuna floodplain", "NDTV")]
    assert len(rank.pick(items, 5, now=NOW)) == 2


def test_blocked_sources_and_clickbait_patterns():
    items = [mk("Nvidia news: here is my top stock to buy before it is too late", "Big Blog"),
             mk("Model release notes from a research lab", "The Motley Fool"),
             mk("Anthropic publishes new interpretability research paper", "MIT Technology Review")]
    picked = rank.pick(items, 5, now=NOW, blocked_sources=["the motley fool"], exclude_patterns=["stocks? to buy"])
    assert [s.lead.source for s in picked] == ["MIT Technology Review"]


def test_google_only_stories_rank_below_readable_ones():
    items = [mk("Court stops activist at airport before UK trip", "The Hindu", kind="google", url="https://news.google.com/1"),
             mk("Court stops activist at airport ahead of UK trip", "NDTV", kind="google", url="https://news.google.com/2"),
             mk("Metro fares to rise from next month", "Hindustan Times")]
    assert rank.pick(items, 1, now=NOW)[0].lead.source == "Hindustan Times"


def test_full_text_from_the_feed_when_the_site_blocks_us():
    body = "".join(f"<p>Paragraph {i}: designers debated whether the field is about people or technology.</p>" for i in range(30))
    feed = (f'<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>'
            f"<item><title>Is product design a people industry?</title><link>https://uxdesign.cc/a</link>"
            f"<pubDate>{format_datetime(NOW)}</pubDate><description>Short teaser</description>"
            f"<content:encoded><![CDATA[{body}]]></content:encoded></item></channel></rss>").encode()
    [it] = feeds.parse(feed, {"type": "rss", "name": "UX Collective"})
    assert "content_html" in it.extra
    story = rank.Story(items=[it])
    web = FakeWeb({"https://uxdesign.cc/a": FetchError("HTTP 403")})
    text, err = build_mod.fetch_article(web, story)
    assert err is None and "Paragraph 29" in text
