--[[
Weather and air quality from Open-Meteo: free, no key, non-commercial use.
The city's coordinates stay on the Kindle.
--]]
local Weather = {}

Weather.FORECAST = "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s"
    .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"
    .. "&hourly=temperature_2m,precipitation_probability,weather_code"
    .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"
    .. "&timezone=%s&forecast_days=2"
Weather.AIR = "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%s&longitude=%s"
    .. "&current=us_aqi,pm2_5&timezone=%s"

-- WMO weather codes -> label, day icon, night icon
local SUN, MOON, CLOUD, RAIN, SNOW, STORM, FOG = "\226\152\128", "\226\152\190", "\226\152\129",
    "\226\152\148", "\226\157\132", "\226\154\161", "\226\137\136"
local CODES = {
    [0] = { "Clear", SUN, MOON }, [1] = { "Mostly clear", SUN, MOON }, [2] = { "Partly cloudy", CLOUD },
    [3] = { "Cloudy", CLOUD }, [45] = { "Fog", FOG }, [48] = { "Fog", FOG },
    [51] = { "Light drizzle", RAIN }, [53] = { "Drizzle", RAIN }, [55] = { "Heavy drizzle", RAIN },
    [56] = { "Freezing drizzle", RAIN }, [57] = { "Freezing drizzle", RAIN },
    [61] = { "Light rain", RAIN }, [63] = { "Rain", RAIN }, [65] = { "Heavy rain", RAIN },
    [66] = { "Freezing rain", RAIN }, [67] = { "Freezing rain", RAIN },
    [71] = { "Light snow", SNOW }, [73] = { "Snow", SNOW }, [75] = { "Heavy snow", SNOW }, [77] = { "Snow", SNOW },
    [80] = { "Showers", RAIN }, [81] = { "Showers", RAIN }, [82] = { "Heavy showers", RAIN },
    [85] = { "Snow showers", SNOW }, [86] = { "Snow showers", SNOW },
    [95] = { "Thunderstorm", STORM }, [96] = { "Thunderstorm, hail", STORM }, [99] = { "Thunderstorm, hail", STORM },
}

function Weather.describe(code, is_day)
    local c = CODES[tonumber(code) or -1] or { "\u{2014}", CLOUD }
    local icon = (is_day == 0 and c[3]) or c[2]
    return c[1], icon
end

--- US AQI scale (Open-Meteo reports US AQI).
function Weather.aqi_label(aqi)
    aqi = tonumber(aqi)
    if not aqi then return nil end
    if aqi <= 50 then return "Good" end
    if aqi <= 100 then return "Moderate" end
    if aqi <= 150 then return "Unhealthy for some" end
    if aqi <= 200 then return "Unhealthy" end
    if aqi <= 300 then return "Very unhealthy" end
    return "Hazardous"
end

local function enc(s) return (tostring(s):gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end)) end

function Weather.urls(city, tz)
    return Weather.FORECAST:format(city.lat, city.lon, enc(tz)), Weather.AIR:format(city.lat, city.lon, enc(tz))
end

local function r(x) return type(x) == "number" and math.floor(x + 0.5) or nil end

--- Raw Open-Meteo responses -> the compact table the dashboard draws.
-- clock: daily.clock (for parsing local times); now: epoch.
function Weather.summarize(forecast, air, clock, now)
    if type(forecast) ~= "table" or type(forecast.current) ~= "table" then return nil end
    local cur, daily, hourly = forecast.current, forecast.daily or {}, forecast.hourly or {}
    local label, icon = Weather.describe(cur.weather_code, cur.is_day)
    local w = {
        temp = r(cur.temperature_2m), feels = r(cur.apparent_temperature),
        humidity = r(cur.relative_humidity_2m), wind = r(cur.wind_speed_10m),
        label = label, icon = icon, code = cur.weather_code,
        days = {}, hours = {},
    }
    for i, d in ipairs(daily.time or {}) do
        local dl, di = Weather.describe((daily.weather_code or {})[i], 1)
        w.days[i] = { date = d, label = dl, icon = di, max = r((daily.temperature_2m_max or {})[i]),
            min = r((daily.temperature_2m_min or {})[i]), rain = r((daily.precipitation_probability_max or {})[i]),
            sunrise = tostring((daily.sunrise or {})[i] or ""):match("T(%d+:%d+)"),
            sunset = tostring((daily.sunset or {})[i] or ""):match("T(%d+:%d+)") }
    end
    if w.days[1] then w.max, w.min, w.rain = w.days[1].max, w.days[1].min, w.days[1].rain end
    -- the next 12 hours, every 2 hours, starting with the coming hour
    now = now or clock:now()
    for i, t in ipairs(hourly.time or {}) do
        local at = clock:parse_iso(t)
        if at and at > now - 1800 and #w.hours < 6 then
            local p = clock:parts(at)
            if p.hour % 2 == 0 then
                local hl, hi = Weather.describe((hourly.weather_code or {})[i], (p.hour >= 6 and p.hour < 18) and 1 or 0)
                w.hours[#w.hours + 1] = { hour = p.hour, temp = r((hourly.temperature_2m or {})[i]),
                    rain = r((hourly.precipitation_probability or {})[i]), icon = hi, label = hl }
            end
        end
    end
    -- when rain is likely today: the first hour with >= 50%
    for _, h in ipairs(w.hours) do
        if (h.rain or 0) >= 50 then w.rain_from = h.hour; break end
    end
    if type(air) == "table" and type(air.current) == "table" then
        w.aqi = r(air.current.us_aqi)
        w.pm25 = r(air.current.pm2_5)
        w.aqi_label = Weather.aqi_label(w.aqi)
    end
    return w
end

--- Markdown for the detail screen.
function Weather.details(w, city_name)
    if not w then return "No weather yet. It loads when the Kindle is online." end
    local deg = "\194\176"
    local out = {
        string.format("## Now in %s", city_name),
        string.format("**%s%s** %s, feels like %s%s", w.temp or "?", deg, w.label, w.feels or "?", deg),
        string.format("Humidity %s%% \u{00B7} wind %s km/h", w.humidity or "?", w.wind or "?"),
    }
    if w.aqi then
        out[#out + 1] = string.format("Air quality: **AQI %d, %s** (PM2.5 %s \u{00B5}g/m\u{00B3}, US scale)",
            w.aqi, w.aqi_label, w.pm25 or "?")
    end
    if #w.hours > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "## Next hours"
        for _, h in ipairs(w.hours) do
            out[#out + 1] = string.format("- %02d:00  %s%s  %s%s", h.hour, h.temp or "?", deg, h.label,
                (h.rain or 0) > 0 and string.format(", rain %d%%", h.rain) or "")
        end
    end
    for i, d in ipairs(w.days) do
        out[#out + 1] = ""
        out[#out + 1] = i == 1 and "## Today" or "## Tomorrow"
        out[#out + 1] = string.format("%s, %s%s to %s%s, rain %s%%", d.label, d.min or "?", deg, d.max or "?", deg, d.rain or 0)
        if d.sunrise then out[#out + 1] = string.format("Sunrise %s \u{00B7} sunset %s", d.sunrise, d.sunset or "?") end
    end
    out[#out + 1] = ""
    out[#out + 1] = "Weather data by Open-Meteo.com"
    local text = table.concat(out, "\n\n"):gsub("\n\n\n\n", "\n\n"):gsub("\n\n(%- )", "\n%1")
    return text
end

Weather.CITIES = {
    { name = "Delhi", lat = 28.6139, lon = 77.2090 },
    { name = "Noida", lat = 28.5355, lon = 77.3910 },
    { name = "Gurugram", lat = 28.4595, lon = 77.0266 },
    { name = "Ghaziabad", lat = 28.6692, lon = 77.4538 },
    { name = "Faridabad", lat = 28.4089, lon = 77.3178 },
    { name = "Mumbai", lat = 19.0760, lon = 72.8777 },
    { name = "Bengaluru", lat = 12.9716, lon = 77.5946 },
    { name = "Hyderabad", lat = 17.3850, lon = 78.4867 },
    { name = "Chennai", lat = 13.0827, lon = 80.2707 },
    { name = "Kolkata", lat = 22.5726, lon = 88.3639 },
    { name = "Pune", lat = 18.5204, lon = 73.8567 },
    { name = "Ahmedabad", lat = 23.0225, lon = 72.5714 },
    { name = "Jaipur", lat = 26.9124, lon = 75.7873 },
    { name = "Lucknow", lat = 26.8467, lon = 80.9462 },
    { name = "Chandigarh", lat = 30.7333, lon = 76.7794 },
    { name = "Dehradun", lat = 30.3165, lon = 78.0322 },
}

return Weather
