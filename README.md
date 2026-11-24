# Daily: a morning dashboard for a jailbroken Kindle

A separate app from Tome, built the same way. Each morning it shows:

- **News, top 5 per category:** New in AI, Content Design, Delhi & India,
  International, and Stocks (Nifty/Sensex and the biggest Nifty 50 movers).
  Tap a headline to read the full article on the Kindle.
- **Weather** for your city.
- **Today's Google Calendar.**
- **A to-do list** you manage from Telegram, and tick off on the Kindle.

Everything is free and needs no API keys, except a free Telegram bot token.

## How it works

```
 GitHub Actions, 05:17 IST            GitHub Pages (public)         Kindle
 ┌──────────────────────────┐        ┌────────────────────┐   ┌────────────────────────┐
 │ RSS · Google News · HN   │──────▶ │ brief.json         │──▶│ news + markets         │
 │ rank top 5, no AI        │        │ archive/ (7 days)  │   │                        │
 │ extract full text        │        └────────────────────┘   │ weather   ◀ Open-Meteo │
 │ market data              │                                 │ calendar  ◀ your link  │
 └──────────────────────────┘                                 │ to-do     ◀ Telegram   │
                                                              └────────────────────────┘
```

**Privacy rule:** the Pages site is public, so only news goes through it.
Your city, calendar link, Telegram token and to-dos stay on the Kindle. The
Kindle talks to those services directly.

## Status

| Phase | | |
|---|---|---|
| 1 | Morning news job (`job/`) | **built** |
| 2 | Kindle app (`app/`): dashboard, weather, markets, news, reading articles | **built** |
| 3 | To-do list and Telegram bot | next |
| 4 | Google Calendar | |
| 5 | Phone setup page, polish | |

## The morning job

`job/config.yml` lists the categories and their feeds. Edit it to add or
remove sources. Stories are ranked without AI:

- **Coverage:** how many different outlets carry the story. This is the best
  free stand-in for "most read".
- **Prominence:** how high it sits in each feed.
- **Freshness**, and Hacker News points for AI stories.
- Delhi stories get a small boost in "Delhi & India".

Duplicates are merged. A story never appears in two categories. No more than 2
of a category's 5 stories come from the same outlet.

Full text comes from the article page. Paywalled pages and Google News-only
stories show the headline and the summary, marked "summary only".

Output, published to GitHub Pages:

| File | |
|---|---|
| `brief.json` | Today's edition: categories → stories (title, source, other outlets, summary, full text as light Markdown, reading time), markets, and a per-feed status list |
| `index.json` | `{latest, version, dates}`. The Kindle checks `version` and only downloads when it changed |
| `archive/YYYY-MM-DD.json` | The last 7 editions |

If a feed fails, it's skipped and listed under `sources` with the error. If
every feed fails, nothing is published, and the Kindle keeps showing
yesterday's edition.

### Setup (once)

1. Push this repo to GitHub (it must be public for free Pages).
2. Go to **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. Open **Actions → Daily brief → Run workflow**. The run summary lists
   today's stories and any feeds that failed.
4. The brief is now at `https://<your-user>.github.io/<repo>/brief.json`, and
   refreshes every morning.

### Run locally

```bash
cd job
```

```bash
python3 -m venv ../.venv && . ../.venv/bin/activate
```

```bash
pip install -r requirements.txt
```

```bash
python -m pytest -q
```

```bash
python -m daily.build --config config.yml --out ../site
```

### Limits

- "Most read" is approximate. Only Wikipedia publishes real readership for
  free, so ranking uses how widely a story is covered.
- Market numbers use Yahoo Finance's public chart endpoint, which is
  unofficial. If it stops working, Stocks still shows market news, without
  the numbers.
- GitHub can start scheduled runs a few minutes late. A tiny commit on the
  1st of each month keeps the schedule from being paused.
