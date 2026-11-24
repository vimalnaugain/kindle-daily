"""Group items about the same story and pick the top stories, without AI.

A story's score rewards:
  * coverage: how many different outlets carry it (the best free stand-in
    for "most read"),
  * prominence: how high it sits in each feed,
  * freshness, Hacker News points, and optional boost keywords.
"""
import math
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

STOPWORDS = set("""a an the and or but of to in on at for from by with as is are was were be been
it its this that these those after before over under into about amid against than then
says said say new how why what who when where will would can could may might not no
his her their our your my we you they he she them us after up down out off more most
vs via just now live updates update latest report reports""".split())

_TOKEN = re.compile(r"[a-z0-9]+")


def tokens(title):
    words = _TOKEN.findall(title.lower())
    return {w for w in words if len(w) > 2 and w not in STOPWORDS}


def similar(a, b):
    if not a or not b:
        return False
    shared = len(a & b)
    return shared >= 3 and shared / min(len(a), len(b)) >= 0.6


@dataclass
class Story:
    items: list
    tokens: set = field(default_factory=set)
    score: float = 0.0
    also: list = field(default_factory=list)  # outlets covering it in other categories' feeds

    @property
    def sources(self):
        seen = []
        for src in [it.source for it in self.items] + self.also:
            if src not in seen:
                seen.append(src)
        return seen

    @property
    def lead(self):
        """Item to show: a direct link (not a Google redirect) if any, best placed first."""
        def key(it):
            return (it.kind == "google", -it.weight, it.position)
        return sorted(self.items, key=key)[0]


def cluster(items):
    stories = []
    for it in items:
        t = tokens(it.title)
        for s in stories:
            if similar(t, s.tokens):
                s.items.append(it)
                s.tokens |= t
                break
        else:
            stories.append(Story(items=[it], tokens=set(t)))
    return stories


def score(story, now, boost=()):
    coverage = len(story.sources)
    prominence = max(it.weight / (1 + it.position / 3) for it in story.items)
    times = [it.published for it in story.items if it.published]
    age_h = (now - max(times)).total_seconds() / 3600 if times else 24
    freshness = math.exp(-max(age_h, 0) / 24)
    points = max((it.points for it in story.items), default=0)
    s = 2.0 * math.log2(1 + coverage) + prominence + freshness + math.log10(1 + points) / 2
    title = " ".join(it.title.lower() for it in story.items)
    if story.lead.kind == "google":
        s -= 0.5  # no direct link: we can only show the headline
    if boost and any(re.search(rf"\b{re.escape(b.lower())}\b", title) for b in boost):
        s += 0.75
    return s


def pick(items, n, now=None, max_age_hours=36, max_per_source=2, boost=(), exclude_urls=(), exclude_tokens=(),
         elsewhere=()):
    """Top `n` stories from `items`, most important first.

    `elsewhere`: items from other categories' feeds. They never become stories
    here, but an outlet covering the same story there still counts as coverage.
    """
    now = now or datetime.now(timezone.utc)

    def recent(it):
        return it.published is None or (now - it.published).total_seconds() <= max_age_hours * 3600

    fresh = [it for it in items if recent(it)]
    stories = cluster(fresh)
    others = [(tokens(it.title), it.source) for it in elsewhere if recent(it)]
    for s in stories:
        s.also = [src for t, src in others if similar(s.tokens, t)]
    for s in stories:
        s.score = score(s, now, boost)
    stories.sort(key=lambda s: -s.score)
    chosen, per_source = [], {}
    for s in stories:
        lead = s.lead
        if lead.url in exclude_urls or any(similar(s.tokens, t) for t in exclude_tokens):
            continue  # already in an earlier category
        if per_source.get(lead.source, 0) >= max_per_source:
            continue
        per_source[lead.source] = per_source.get(lead.source, 0) + 1
        chosen.append(s)
        if len(chosen) == n:
            break
    return chosen
