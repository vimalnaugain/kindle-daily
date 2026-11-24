-- Daily settings. Copy to config.lua (the installer does this) and edit.
-- Everything here stays on the Kindle.
return {
    -- Where the morning job publishes the news (your GitHub Pages site).
    brief_url = "https://vimalnaugain.github.io/kindle-daily/",

    -- City for weather and air quality. One of the built-in Indian cities
    -- (Delhi, Noida, Gurugram, Mumbai, Bengaluru, …), or your own:
    --   city = { name = "Home", lat = 28.55, lon = 77.25 },
    city = "Delhi",
    timezone = "Asia/Kolkata",
    utc_offset_minutes = 330,   -- India: UTC+5:30

    -- To-do list from your phone: create a bot by messaging @BotFather in
    -- Telegram (/newbot), paste its token here, then send your bot any
    -- message and confirm the pairing on the Kindle.
    -- telegram_token = "123456789:ABC...",

    -- Google Calendar: on a computer, Google Calendar > Settings > your
    -- calendar > "Secret address in iCal format". Several calendars:
    -- calendar_urls = { "https://…/basic.ics", "https://…/basic.ics" }
    -- calendar_url = "https://calendar.google.com/calendar/ical/…/basic.ics",

    -- The "DAY" progress bar on the clock card runs between these hours.
    day_starts_at = 7,
    day_ends_at = 23,

    -- Minutes without a tap before the Kindle sleeps (0 = never).
    -- While asleep, the screen keeps showing today's dashboard.
    sleep_after_minutes = 10,

    -- Old Kindle firmware can have outdated root certificates. If downloads
    -- fail with a certificate error, copy a current cacert.pem (from
    -- curl.se/ca/cacert.pem) to the Kindle and point to it:
    -- ca_bundle = "/mnt/us/daily/cacert.pem",

    -- log_file = "/mnt/us/daily/daily.log",
}
