# Daily: a morning dashboard for your Kindle

Daily turns a jailbroken Kindle into a calm home screen for your day:

**Today:** the time and date, weather and air quality, your to-do list, and
your Google Calendar.
**Reading:** great long reads (new ones every morning), a quote of the day
from a classic book, and news on the topics you choose.

Everything is free and needs no accounts or API keys (a Telegram bot for
sending to-dos from your phone is optional and free).

## Install (5 minutes)

1. **Jailbreak your Kindle.** Follow the guide at
   [kindlemodding.org](https://kindlemodding.org/) (Jailbreaking section) and pick the
   method for your Kindle's firmware. Install the hotfix it offers: that's what
   lets the library run apps like Daily. You don't need KUAL or KPM.
2. **Download** [daily-kindle.zip](https://vimalnaugain.github.io/kindle-daily/app/daily-kindle.zip)
   on your computer and unzip it. You get three folders: `daily`,
   `documents` and `extensions`.
3. **Connect the Kindle** to the computer with a USB cable. It shows up as a
   drive named Kindle.
4. **Copy the three folders** onto the Kindle drive, at the top level (next to
   the Kindle's own `documents` folder). When asked, choose to **merge** the
   folders, not replace them, so your books stay where they are.
5. **Eject** the Kindle and unplug it.
6. On the Kindle, tap the **search bar**, type `Daily`, and tap **Daily**.
   (It's also in your library.)

Daily opens. Connect to Wi-Fi if you aren't already: the news, long reads and
weather download in a few seconds. From then on, Daily updates itself.

To leave Daily: **Menu → Exit to Kindle**. To open it again: library or
search, **Daily**.

### Settings

Most things are in Daily's **Menu**: city, news topics, article text size,
auto-sleep, updates. Two optional extras are set in `daily/config.lua` on the
Kindle drive (open it with any text editor while the Kindle is connected):

- **Google Calendar:** in Google Calendar on a computer, open
  **Settings → your calendar → Secret address in iCal format**, copy it, and
  add `calendar_url = "https://…/basic.ics",`
- **Telegram to-dos:** in Telegram, message **@BotFather**, send `/newbot`,
  and copy the token it gives you. Add `telegram_token = "123456789:ABC…",`,
  then open Daily, send your bot any message and tap **Pair** on the Kindle.

Both stay on your Kindle; nothing personal goes anywhere else.

### Already installed with KPM?

Nothing to do: KPM installs update themselves too. The USB install is just
easier for a new Kindle.

## Using Daily

| | |
|---|---|
| **To-do** | **+ ADD** opens a keyboard; type "call bank tomorrow" to set a day. Tap an item to tick it off. Tap the card's title for the full list (hold an item to delete it). From Telegram: `buy milk`, `done 2`, `undo`, `list`, `help` |
| **Calendar** | This month with your busy days marked, and your next events. Tap for the next six weeks |
| **Long reads** | At least 5 unread pieces at all times, from Aeon, Psyche, The Marginalian, Longreads, Nautilus, Paul Graham, Read Something Great's picks and Wikipedia's featured article. New ones arrive every morning. Tap to read; the last page has **Mark as read** (or long-press a piece on the home screen) and a QR code for the original |
| **Quote of the day** | A passage from a public-domain classic on Project Gutenberg. Tap to read it in full |
| **News** | Nothing until you pick topics: **Menu → News topics** (or tap the News card). Then every story of those topics shows, up to 15 per topic: Top stories, Business, Technology, Science, Health, Sports, Entertainment, AI, Content Design, Delhi & India, International, Stocks |

While the Kindle sleeps, the screen keeps showing today's dashboard.

## How it works

```
 GitHub Actions, 05:17 IST                 GitHub Pages (public)            Kindle
 ┌────────────────────────────────┐       ┌──────────────────────────┐   ┌─────────────────────────┐
 │ news: RSS, Google News, HN     │──────▶│ brief.json (headlines,   │──▶│ news (your topics)      │
 │ long reads: essays, curated    │       │   reads, quote)          │   │ long reads, quote       │
 │ quote: Project Gutenberg       │       │ news/<topic>.json        │   │                         │
 │ full texts extracted           │       │ reads/<id>.json          │   │ weather  ◀ Open-Meteo   │
 └────────────────────────────────┘       │ app/ (Kindle app, zip)   │   │ calendar ◀ your link    │
                                          └──────────────────────────┘   │ to-do    ◀ you/Telegram │
                                                                         └─────────────────────────┘
```

**Privacy:** the Pages site is public, so only public content goes through
it. Your city, calendar link, Telegram token, to-dos and what you've read stay
on the Kindle, which talks to those services directly.

## The morning job (`job/`)

`job/config.yml` lists the news topics and their feeds, the long-read
sources and the books for the quote. Stories are ranked without AI:

- **Coverage:** how many different outlets carry the story (the best free
  stand-in for "most read").
- **Prominence:** how high it sits in each feed.
- **Freshness**, and Hacker News points for AI stories.

Duplicates within a topic are merged, no more than 2 stories per topic come
from one outlet, and headlines that only Google News carries need at least two
outlets behind them. Non-news pages (live scores, IPO price bands, price
forecasts) are skipped.

**Long reads:** each morning adds up to 5 new pieces, one source at a time,
never repeating one from the last 90 days, plus Wikipedia's featured article.
The pool keeps the latest 30; the Kindle hides the ones you've read.

**Quote of the day:** the job picks a book from the list by date, downloads it
from Project Gutenberg (or its mirrors) and chooses a reflective,
self-contained passage, avoiding dialogue.

| File | |
|---|---|
| `brief.json` | Today's edition: topics → stories (headline, source, summary, reading time), long reads, quote, and a per-source status list |
| `news/<topic>.json` | Full texts of a topic's stories (the Kindle downloads only the topics you pick) |
| `reads/<id>.json` | Full text of a long read |
| `index.json` | `{latest, version, dates}`: the Kindle checks `version` and only downloads what changed |
| `archive/YYYY-MM-DD.json` | The last 7 editions |
| `app/` | The Kindle app: `daily-kindle.zip`, the KPM repository and `latest.json` for updates |

If a source fails, it's skipped and listed in the run summary. If every feed
fails, nothing is published and the Kindle keeps yesterday's edition.

### Run it yourself

The workflow `.github/workflows/daily-brief.yml` runs every morning at 05:17
IST, and on every push. To set it up in your own copy of this repo:
**Settings → Pages → Build and deployment → Source: GitHub Actions**, then
**Actions → Daily brief → Run workflow**.

```bash
cd job
```

```bash
python3 -m venv ../.venv && . ../.venv/bin/activate && pip install -r requirements.txt
```

```bash
python -m pytest -q
```

```bash
python -m daily.build --config config.yml --out ../site
```

## The Kindle app (`app/`)

Built on Tome's runtime (static LuaJIT, screen, touch input, HTTP through the
Kindle's `curl`). See [app/README.md](app/README.md) for the code layout,
tests and building the Kindle binary.

## Limits

- "Most read" is approximate: only Wikipedia publishes real readership for
  free, so ranking uses how widely a story is covered.
- Paywalled articles show their headline and summary only.
- GitHub can start the morning run a few minutes late. A tiny commit on the
  1st of each month keeps the schedule from being paused.
