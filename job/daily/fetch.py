"""HTTP GET with timeouts and retries (standard library only)."""
import time
import urllib.error
import urllib.request
from dataclasses import dataclass


@dataclass
class Response:
    status: int
    body: bytes
    url: str  # final URL after redirects


class FetchError(Exception):
    pass


class Fetcher:
    def __init__(self, user_agent, timeout=20, retries=2):
        self.user_agent = user_agent
        self.timeout = timeout
        self.retries = retries

    def get(self, url, accept="*/*"):
        last = None
        for attempt in range(self.retries + 1):
            req = urllib.request.Request(url, headers={
                "User-Agent": self.user_agent,
                "Accept": accept,
                "Accept-Language": "en-IN,en;q=0.9",
            })
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    return Response(r.status, r.read(5_000_000), r.geturl())
            except urllib.error.HTTPError as e:
                last = FetchError(f"HTTP {e.code}")
                if e.code < 500 and e.code != 429:
                    break
            except Exception as e:  # timeouts, DNS, TLS, resets
                last = FetchError(type(e).__name__ + ": " + str(e)[:120])
            if attempt < self.retries:
                time.sleep(2 * (attempt + 1))
        raise last
