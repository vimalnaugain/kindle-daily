# Daily: the Kindle app

A dashboard of cards that opens on a jailbroken Kindle:

- **Clock** (12-hour) and date, with how far through the day, month and year you are
- **Weather** and air quality for your city (Open-Meteo, no key)
- **News**: the morning edition, 5 stories each for AI, Content Design,
  Delhi & India, International and Stocks, with Nifty, Sensex and Nifty Bank.
  Tap a headline to read it; the last page has a QR code for the original
- **Article of the day**: Wikipedia's featured article, in full
- **To-do**: sent from your phone through your own Telegram bot; tap to tick off
- **Calendar**: this month, with dots on busy days, and today's and tomorrow's
  events from Google Calendar's private iCal address

It refreshes when it opens, when the Kindle wakes, and every 30 minutes
(Telegram every 2 minutes) while it's on. Everything is cached, so it works
offline, and while the Kindle sleeps the screen keeps today's dashboard.

## Telegram to-do

1. In Telegram, message **@BotFather**, send `/newbot`, pick a name. It
   gives you a token like `123456789:ABC…`.
2. Put it in `/mnt/us/daily/config.lua`: `telegram_token = "123456789:ABC…"`.
3. Open Daily, send your bot any message, and tap **Pair** on the Kindle.

Then message the bot: `buy milk`, `call bank tomorrow`, `done 2`, `undo`,
`del 2`, `list`, `clear done`, `help`. The Kindle checks for messages while
it's awake; Telegram keeps them for 24 hours while it sleeps.

## Google Calendar

In Google Calendar on a computer: **Settings → your calendar → Secret
address in iCal format**. Put it in `/mnt/us/daily/config.lua` as
`calendar_url = "https://…/basic.ics"`. Repeating events, edited and
cancelled occurrences and other time zones are handled.

## Install

See the [landing page](https://vimalnaugain.github.io/kindle-daily/). The
easiest way is the USB zip: unzip it at the root of the Kindle drive, then tap
**Install Daily** in the library once. With KPM, use its full path in kterm
(`/var/local/kmc/bin/kpm`), since kterm doesn't have `kpm` on its PATH. Settings live in `/mnt/us/daily/config.lua`; the **Menu** on the
dashboard changes the city, article text size and auto-sleep.

## How it's built

The runtime in `core/` and `native/` is Tome's (MIT, see `LICENSE.tome`):
a static LuaJIT with a small C module for the screen and touch input, the
UI manager, widgets, HTTP through the Kindle's `curl`, and baked bitmap
fonts. Daily's own code is in `daily/`:

| File | |
|---|---|
| `app.lua` | app shell: refreshing, menu, sleep screen |
| `dashboard.lua` | the home screen |
| `article.lua` | the story reader and QR page |
| `todo.lua` | the to-do list and its commands |
| `telegram.lua` | Telegram bot polling, pairing and replies |
| `calendar.lua` | iCalendar parsing and repeating events |
| `data.lua` | downloading and caching the edition and weather |
| `weather.lua` | Open-Meteo forecast and air quality |
| `clock.lua` | local time at a fixed UTC offset (IST) |

## Develop

```bash
make -C native
```

```bash
luajit tests/run_tests.lua
```

```bash
luajit main.lua --sdl
```

The tests run the app in a desktop emulator against `tests/fixtures`
(a real edition and sample weather) and save screenshots to `tests/out/`.
The Kindle binary: `ZIG="python3 -m ziglang" tools/build_kindle.sh`, then
`tools/package_kpm.sh` and `tools/package_kindle.sh`.
