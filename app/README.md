# Daily: the Kindle app

A dashboard that opens on a jailbroken Kindle and shows:

- the time and date
- weather and air quality for your city (Open-Meteo, no key)
- Nifty 50, Sensex and Nifty Bank (tap for the top gainers and losers)
- the morning edition: 5 stories each for AI, Content Design, Delhi & India,
  International and Stocks. Tap a headline to read it, page by page, with a
  QR code at the end to open the original on your phone

It downloads the edition and weather when it opens, when the Kindle wakes,
and every 30 minutes while it's on. Everything is cached, so it works
offline. While the Kindle sleeps, the screen keeps showing today's dashboard.

## Install

See the [landing page](https://vimalnaugain.github.io/kindle-daily/): KPM
(`;kpm install daily` after adding the repository once) or a USB zip for
KUAL. Settings live in `/mnt/us/daily/config.lua`; the **Menu** on the
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
