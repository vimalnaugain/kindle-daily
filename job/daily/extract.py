"""Full article text as light Markdown (# headings, - bullets, **bold**)."""
import re

import trafilatura

MIN_CHARS = 600        # less than this is usually a paywall or cookie wall
MAX_CHARS = 40_000

_BOILERPLATE = re.compile(
    r"^(subscribe|sign up|sign in|log in|read more|also read|advertisement|"
    r"follow us|download the app|click here|share this|recommended)\b", re.I)


def extract(html, url, title=None):
    """Returns (markdown, None) or (None, reason)."""
    if not html:
        return None, "empty page"
    text = trafilatura.extract(
        html, url=url, output_format="markdown", include_formatting=True,
        include_comments=False, include_tables=False, include_images=False,
        favor_precision=True, deduplicate=True)
    if not text:
        return None, "no article text found"
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    # Drop a leading heading that repeats the headline, and promo lines.
    def norm(t):  # compare letters and digits only (quotes, NBSPs, punctuation differ)
        return re.sub(r"\W+", "", t).lower()

    if title:  # a heading repeating the headline, near the top
        paras = [p for i, p in enumerate(paras) if not (i < 4 and p.startswith("#") and norm(p) == norm(title))]
    paras = [p for p in paras if not (len(p) < 120 and _BOILERPLATE.match(p.lstrip("#-* ")))]
    paras = join_broken(paras)
    text = "\n\n".join(paras)
    if len(text) < MIN_CHARS:
        return None, "too short (paywall?)"
    if len(text) > MAX_CHARS:
        kept = text[:MAX_CHARS].split("\n\n")[:-1]
        while kept and kept[-1].startswith("#"):  # no heading without its text
            kept.pop()
        text = "\n\n".join(kept) + "\n\n*(Article shortened. The full version is online.)*"
    return text, None


_SENTENCE_END = re.compile(r"[.!?:;\"”’)\]*_]\s*$")


def join_broken(paras):
    """Re-join paragraphs split mid-sentence at inline markup (Wikipedia leads:
    "The **great white shark**, also known as the" / "**white pointer**, …")."""
    out = []
    for p in paras:
        p = re.sub(r"(?<!\*)\*\s+(?=\S)", "*", p)  # "* Carcharodon*" -> "*Carcharodon*"
        prev = out[-1] if out else None
        if (prev and not prev.startswith(("#", "- ", "* ", "> ")) and not p.startswith(("#", "- ", "> "))
                and not _SENTENCE_END.search(prev) and (p[:1].islower() or p.startswith("**") or p[:1] in ",;)")):
            out[-1] = prev.rstrip() + ("" if p[:1] in ",;)" else " ") + p.lstrip()
        else:
            out.append(p)
    return out


def word_count(text):
    return len(re.findall(r"\w+", text or ""))
