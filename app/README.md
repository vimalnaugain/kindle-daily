# Daily: the Kindle app

A dashboard of cards in two parts. **Today:** a 12-hour clock with the date
and day/month/year progress, weather and air quality, the to-do list, and the
calendar (month and next events). **Reading:** long reads (always at least 5
unread, new every morning, mark as read), a quote of the day from a classic
book, and news on the topics you pick (Menu → News topics). Tap anything to
open it; long-press a long read to mark it read.

Installing: see the [main README](../README.md#install-5-minutes). The USB zip
(`tools/package_kindle.sh`) holds `daily/` (the app, which also keeps its
settings and cache), `documents/Daily.sh` (the library item, found by the
search bar too) and a KUAL entry.

## Updates

Daily updates itself. Once a day, when it's online, it checks the site for a
new version, downloads it in the background (checking its SHA-256), and asks
to restart. Choose **Later** and it installs the next time you open Daily.
**Menu → Check for updates** does it on demand. To turn it off:
`auto_update = false` in config.lua.

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
