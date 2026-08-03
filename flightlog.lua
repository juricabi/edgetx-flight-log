local toolName = "TNS|Flight log|TNE"

-- Reads the CSV files EdgeTX writes to /LOGS and shows what actually happened
-- on the flight: how long, what the battery did, where the link struggled, how
-- far and how high, and where the model ended up.
--
-- It does not know anything about CRSF, GHST or FrSky. The log header names
-- every column and its unit, so the columns are matched to roles by name and
-- anything unrecognised is simply left alone. A protocol nobody has thought of
-- yet still works, as long as its sensors are named sensibly.

-- This firmware reaches globals through an __index hook that walks a list of
-- read only tables, so every `tonumber` in the parsing loop costs a metatable
-- miss and a call into C. There are some eighty of them per row of a full
-- telemetry log, so the ones on the hot path are pulled in as locals here.
local sub, find, match, gsub = string.sub, string.find, string.match, string.gsub
local format, concat, sort = string.format, table.concat, table.sort
local tonumber, tostring, type, pcall = tonumber, tostring, type, pcall
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local rad, sin, cos, asin, sqrt = math.rad, math.sin, math.cos, math.asin, math.sqrt

------------------------------------------------------------------------------
-- screen metrics
------------------------------------------------------------------------------

local COLOUR = LCD_H >= 100
local LH = COLOUR and 17 or 8
local PAD = COLOUR and 6 or 2
local TITLE = COLOUR and 24 or 9

local function rgb(r, g, b, mono)
    if COLOUR and lcd.RGB then return lcd.RGB(r, g, b) end
    return mono or 0
end

local C_BG, C_TEXT, C_DIM, C_GOOD, C_WARN, C_BAD, C_LINE, C_ACC, C_OFF

local function initColours()
    C_BG   = rgb(18, 20, 24)
    C_TEXT = rgb(235, 235, 235)
    C_DIM  = rgb(150, 150, 150)
    C_GOOD = rgb(90, 200, 120)
    C_WARN = rgb(240, 190, 80)
    C_BAD  = rgb(235, 100, 100)
    C_LINE = rgb(60, 62, 70)
    C_ACC  = rgb(80, 190, 245)
    C_OFF  = rgb(46, 42, 38)        -- behind the stretches flown by nobody
end

------------------------------------------------------------------------------
-- which column means what
------------------------------------------------------------------------------

-- first match wins, so the preferred name for each role comes first
local ROLES = {
    volt   = { "RxBt", "VFAS", "Batt", "A1", "A2", "Vbat" },
    cell   = { "Cels", "Cell", "A4" },
    curr   = { "Curr", "Cur" },
    used   = { "Capa", "Fuel" },
    lq     = { "RQly", "TQly", "LQly", "LQ" },
    rssi   = { "1RSS", "RSSI", "2RSS", "TRSS", "RSS" },
    snr    = { "RSNR", "TSNR", "SNR" },
    power  = { "TPWR" },
    alt    = { "Alt", "GAlt", "Galt" },
    speed  = { "GSpd", "ASpd", "Spd" },
    sats   = { "Sats" },
    gps    = { "GPS" },
    fm     = { "FM", "Fmod", "Mode" },
}

-- Betaflight reports height above the arming point while armed, but height
-- above sea level once disarmed, so a quad sitting on the ground claims to be
-- at the elevation of the field. It marks disarmed with a trailing star on the
-- flight mode, which is the only honest way to tell the two apart, so these
-- readings are counted only while the model is armed.
local GATED = { alt = true, speed = true }

-- EdgeTX writes a sensor that is not streaming as zero, so for these a zero is
-- absence rather than a reading. Only exactly zero is rejected: a CRSF log
-- reports signal in dBm, where every real value is negative.
local SKIP_ZERO = { lq = true, rssi = true }

-- the roles worth a graph, in the order they are offered
local GRAPHABLE = {
    { r = "volt",  label = "battery",      c = { 90, 200, 120 } },
    { r = "curr",  label = "current",      c = { 240, 150, 80 } },
    { r = "alt",   label = "altitude",     c = { 80, 190, 245 } },
    { r = "speed", label = "speed",        c = { 200, 160, 245 } },
    { r = "lq",    label = "link quality", c = { 120, 210, 255 } },
    { r = "rssi",  label = "signal",       c = { 240, 200, 100 } },
    { r = "sats",  label = "satellites",   c = { 150, 200, 150 } },
}

local KEEP = {}                     -- roles a series is kept for
for _, g in ipairs(GRAPHABLE) do KEEP[g.r] = true end

------------------------------------------------------------------------------
-- state
------------------------------------------------------------------------------

local BUCKETS = COLOUR and 96 or 56     -- downsampled points kept per series
local TRACK_MAX = COLOUR and 240 or 120 -- gps points kept for the track

-- This firmware's io has no line reading at all: io.read(file, n) returns n
-- bytes and file handles have no methods. So the file is pulled in blocks and
-- cut into lines here, carrying whatever is left of a split line to the next
-- block. Several blocks per frame keeps the progress bar moving.
local MAX_LISTED = COLOUR and 200 or 100
local BLOCK = 2048
local BLOCKS_PER_FRAME = 12

local screen = "list"               -- list | confirm | loading | view
local files = {}
local sizes = {}                    -- bytes, straight from fstat
local durs = {}                     -- seconds, probed from the ends of a log
local probeBudget = 0
local sel = 1
local top = 1
local err = nil
local confirmSel = 1
local eatEnter = false              -- swallow the ENTER that follows a long press

local pages, page = {}, 1
local gsel = 1                      -- selected graph on the graph page
local ssel, stop = 1, 1             -- scroll position on the sensor page

local fh, path, name
local pending, haveHeader = "", false
local cols, units, role = {}, {}, {}
local roleList = {}                 -- role work list, built once from the header
local timeCol, dataStart, ticksClock = 2, 3, false
local stat = {}                     -- per role: min, max, first, last, sum, n
local air = {}                      -- the same, but armed rows only
local armedRows = 0
local colStat, numCols = {}, {}     -- the same for every numeric column found
local colAir = {}                   -- and again, armed rows only
local sensorArmed = false           -- which of the two the page shows
local scanRows = 0
local series = {}                   -- per role: lo/hi/sum/n arrays per bucket
local bucketSpan, bucketCount, samples = 1, 0, 0
local firstTime, lastTime = nil, nil
local gps = { first = nil, last = nil, maxDist = 0, path = 0, fixAt = nil }
local trk = {}                      -- decimated track: lat/lon/val arrays
local lqDrops, inDrop = 0, false
local bytesRead, bytesTotal = 0, 0

------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------

local function trim(s)
    return (gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Split a csv line. It walks delimiter to delimiter rather than character by
-- character, which is four and a half times quicker on a row with seventy odd
-- columns, and only a field that actually opens with a quote takes the careful
-- path. A doubled quote inside a quoted field is one literal quote, the way
-- every other csv reader treats it.
local function split(line)
    local out, n, pos, len = {}, 0, 1, #line
    while true do
        n = n + 1
        if sub(line, pos, pos) == '"' then
            local p, buf = pos + 1, {}
            while true do
                local q = find(line, '"', p, true)
                if not q then
                    buf[#buf + 1] = sub(line, p)
                    p = len + 1
                    break
                end
                buf[#buf + 1] = sub(line, p, q - 1)
                if sub(line, q + 1, q + 1) == '"' then
                    buf[#buf + 1] = '"'
                    p = q + 2
                else
                    p = q + 1
                    break
                end
            end
            out[n] = concat(buf)
            local c = find(line, ",", p, true)
            if not c then break end
            pos = c + 1
        else
            local c = find(line, ",", pos, true)
            if not c then
                out[n] = sub(line, pos)
                break
            end
            out[n] = sub(line, pos, c - 1)
            pos = c + 1
        end
    end
    return out
end

-- "12:34:56.789" as seconds
local function clockToSeconds(s)
    local h, m, sec = match(s, "(%d+):(%d+):([%d%.]+)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
end

local function haversine(a, b)
    local R = 6371000
    local dLat = rad(b[1] - a[1])
    local dLon = rad(b[2] - a[2])
    local la = rad(a[1])
    local lb = rad(b[1])
    local h = sin(dLat / 2) ^ 2 + cos(la) * cos(lb) * sin(dLon / 2) ^ 2
    return 2 * R * asin(min(1, sqrt(h)))
end

-- Open Location Code, the "plus code" Google Maps accepts in its search box.
-- Ten digits is about 14 metres, close enough to walk to and short enough to
-- read out over the phone to whoever is standing in the field.
local OLC_ALPHABET = "23456789CFGHJMPQRVWX"
local OLC_LAST = 0.000125           -- degrees covered by the last pair

local function plusCode(lat, lon)
    if lat < -90 then lat = -90 end
    if lat > 90 then lat = 90 end
    while lon < -180 do lon = lon + 360 end
    while lon >= 180 do lon = lon - 360 end
    -- the north pole itself has no cell above it, so it belongs to the last
    if lat >= 90 then lat = 90 - OLC_LAST end

    -- One eight thousandth of a degree is exactly the width of the last pair,
    -- so the whole code comes out of integer arithmetic. Dividing degrees down
    -- in floating point put anything sitting on a cell boundary in the cell
    -- next door: -89.9 + 90 is 0.09999999999999432, not 0.1.
    local la = floor((lat + 90) * 8000 + 1e-6)
    local lo = floor((lon + 180) * 8000 + 1e-6)

    local dla, dlo = {}, {}
    for i = 5, 1, -1 do
        dla[i] = la % 20
        dlo[i] = lo % 20
        la = floor(la / 20)
        lo = floor(lo / 20)
    end

    local out = {}
    for i = 1, 5 do
        out[#out + 1] = sub(OLC_ALPHABET, dla[i] + 1, dla[i] + 1)
        out[#out + 1] = sub(OLC_ALPHABET, dlo[i] + 1, dlo[i] + 1)
        if #out == 8 then out[#out + 1] = "+" end
    end
    return concat(out)
end

------------------------------------------------------------------------------
-- streaming statistics
------------------------------------------------------------------------------

-- A log starts before telemetry is live, so the first rows hold placeholder
-- readings. Taking those as the minimum would report a flat battery on every
-- flight, so ignore values that cannot be real.
local FLOOR = { volt = 1.0, cell = 0.5 }

local function note(into, r, v)
    local least = FLOOR[r]
    if least and v < least then return end
    local st = into[r]
    if not st then
        st = { min = v, max = v, first = v, last = v, sum = 0, n = 0 }
        into[r] = st
    end
    if v < st.min then st.min = v end
    if v > st.max then st.max = v end
    st.last = v
    st.sum = st.sum + v
    st.n = st.n + 1
end

-- Buckets are flat arrays rather than a table per point: a table each would be
-- a few hundred allocations per series, which the smaller radios cannot spare.
local function push(r, v)
    local s = series[r]
    if not s then s = { lo = {}, hi = {}, sum = {}, n = {} }; series[r] = s end
    local i = floor(samples / bucketSpan) + 1
    if s.lo[i] == nil then
        s.lo[i], s.hi[i], s.sum[i], s.n[i] = v, v, v, 1
    else
        if v < s.lo[i] then s.lo[i] = v end
        if v > s.hi[i] then s.hi[i] = v end
        s.sum[i] = s.sum[i] + v
        s.n[i] = s.n[i] + 1
    end
    if i > bucketCount then bucketCount = i end
end

-- Keep a fixed number of buckets whatever the log length: once they are full,
-- merge them in pairs and take twice as many samples per bucket from then on.
-- Buckets can be empty, when a sensor only started reporting part way in, so
-- everything walks bucketCount and steps over the holes.
local function compact()
    -- round up: with an odd count the old halving threw the last bucket away,
    -- which is the newest data and, after a crash, the part you came for
    local m = floor((bucketCount + 1) / 2)
    for _, s in pairs(series) do
        for i = 1, m do
            local a, b = i * 2 - 1, i * 2
            local lo, hi, sum, n = s.lo[a], s.hi[a], s.sum[a], s.n[a]
            if b <= bucketCount and s.lo[b] then
                if lo == nil or s.lo[b] < lo then lo = s.lo[b] end
                if hi == nil or s.hi[b] > hi then hi = s.hi[b] end
                sum = (sum or 0) + s.sum[b]
                n = (n or 0) + s.n[b]
            end
            s.lo[i], s.hi[i], s.sum[i], s.n[i] = lo, hi, sum, n
        end
        for i = m + 1, bucketCount do
            s.lo[i], s.hi[i], s.sum[i], s.n[i] = nil, nil, nil, nil
        end
    end
    bucketCount = m
    bucketSpan = bucketSpan * 2
end

-- the track thins itself the same way, so a long flight costs no more than a
-- short one and the shape survives
local function pushTrack(lat, lon, val)
    trk.seen = trk.seen + 1
    if (trk.seen - 1) % trk.stride ~= 0 then return end
    local n = trk.n + 1
    trk.lat[n], trk.lon[n], trk.val[n] = lat, lon, val
    trk.n = n
    if n >= TRACK_MAX then
        local m = 0
        for i = 1, n, 2 do
            m = m + 1
            trk.lat[m], trk.lon[m], trk.val[m] = trk.lat[i], trk.lon[i], trk.val[i]
        end
        for i = m + 1, n do trk.lat[i], trk.lon[i], trk.val[i] = nil, nil, nil end
        trk.n = m
        trk.stride = trk.stride * 2
    end
    if not trk.minLat or lat < trk.minLat then trk.minLat = lat end
    if not trk.maxLat or lat > trk.maxLat then trk.maxLat = lat end
    if not trk.minLon or lon < trk.minLon then trk.minLon = lon end
    if not trk.maxLon or lon > trk.maxLon then trk.maxLon = lon end
    if val then
        if not trk.minVal or val < trk.minVal then trk.minVal = val end
        if not trk.maxVal or val > trk.maxVal then trk.maxVal = val end
    end
end

------------------------------------------------------------------------------
-- parsing
------------------------------------------------------------------------------

-- Sticks, switches and the 32 channel outputs are in the log too, but they are
-- not sensors. Skipping them keeps the sensor page to things you would call a
-- sensor, and saves fifty tonumber calls on every row of the file.
local function isControl(n)
    return match(n, "^CH%d+$") or match(n, "^S[A-J]$") or match(n, "^SW%d+$")
        or match(n, "^P%d$") or n == "Rud" or n == "Ele" or n == "Thr"
        or n == "Ail" or n == "LSW" or n == "S1" or n == "S2"
        or n == "LS" or n == "RS"
end

local function parseHeader(line)
    local names = split(line)
    for i, raw in ipairs(names) do
        local n = trim(raw)
        local base, unit = match(n, "^(.-)%((.-)%)$")
        base = base or n
        cols[i] = base
        units[base] = unit
    end

    -- Roles are resolved alias first, not column first. Walking the columns
    -- and taking whatever matched earliest let the leftmost column win, so on
    -- a log carrying both GAlt and a baro Alt the preference order in ROLES
    -- was decided by the order the sensors happened to be discovered in.
    for r, aliases in pairs(ROLES) do
        for _, a in ipairs(aliases) do
            if role[r] then break end
            for i = 1, #cols do
                if cols[i] == a then role[r] = i; break end
            end
        end
    end

    -- With an RTC the log opens "Date,Time,..."; without one it is "Time,..."
    -- and that column counts hundredths of a second since the radio started.
    if cols[1] == "Date" then
        timeCol, dataStart = 2, 3
    else
        timeCol, dataStart = 1, 2
    end
    ticksClock = (cols[1] ~= "Date")

    -- What to do with each column, worked out once, so the row loop walks an
    -- array instead of re-deciding from four hash tables for every column of
    -- every row.
    roleList = {}
    for r, idx in pairs(role) do
        if r ~= "gps" and r ~= "fm" then
            roleList[#roleList + 1] = {
                r = r, idx = idx,
                gated = GATED[r], keep = KEEP[r], skipZero = SKIP_ZERO[r],
            }
        end
    end
end

local function parseRow(line)
    local f = split(line)
    if #f < 2 then return end

    local raw = f[timeCol]
    local t = raw and clockToSeconds(raw)
    if not t and ticksClock and raw then
        local n = tonumber(raw)
        if n then t = n / 100 end       -- a radio with no clock counts 10 ms ticks
    end
    if t then
        if not firstTime then firstTime = t end
        -- Only a real wrap past midnight, not any step backwards: an RTC
        -- correction mid log used to subtract a whole day and turn a six
        -- minute flight into twenty four hours.
        if lastTime and (lastTime - t) > 43200 then
            firstTime = firstTime - 86400
        end
        lastTime = t
    end

    -- Betaflight puts a star on the mode when it is disarmed. An empty field
    -- is not a disarmed model, it is no telemetry at all, and counting those
    -- rows as armed handed the altitude gating back the ground readings it
    -- exists to exclude. No flight mode column means every row counts, which
    -- is right for a log that simply does not carry one.
    local armed = true
    if role.fm then
        local m = f[role.fm]
        armed = (m ~= nil and m ~= "" and sub(m, -1) ~= "*")
    end
    if armed then armedRows = armedRows + 1 end

    -- Every numeric column is tracked, not only the ones with a known role, so
    -- a sensor this script has never heard of still turns up on the sensor
    -- page. Which columns are numeric is learned from the first rows and then
    -- reused, because testing every field of every row of a long log is not
    -- free.
    if scanRows < 8 then
        scanRows = scanRows + 1
        local added = false
        for i = dataStart, #f do
            if colStat[i] == nil and tonumber(f[i])
                and not isControl(cols[i] or "") then
                colStat[i] = { min = 0, max = 0, sum = 0, n = 0 }
                colAir[i] = { min = 0, max = 0, sum = 0, n = 0 }
                numCols[#numCols + 1] = i
                added = true
            end
        end
        if added then sort(numCols) end
    end
    for k = 1, #numCols do
        local i = numCols[k]
        local v = tonumber(f[i])
        if v then
            local cs = colStat[i]
            if cs.n == 0 then
                cs.min, cs.max = v, v
            else
                if v < cs.min then cs.min = v end
                if v > cs.max then cs.max = v end
            end
            cs.sum = cs.sum + v
            cs.n = cs.n + 1
            -- and the same again over the armed rows, so the sensor page can
            -- be made to agree with the summary rather than quietly disagree
            if armed then
                local ca = colAir[i]
                if ca.n == 0 then
                    ca.min, ca.max = v, v
                else
                    if v < ca.min then ca.min = v end
                    if v > ca.max then ca.max = v end
                end
                ca.sum = ca.sum + v
                ca.n = ca.n + 1
            end
        end
    end

    -- ride the same bucket machinery as the sensors, so the armed fraction is
    -- downsampled and merged along with everything else and the graphs can say
    -- why a stretch of them is empty
    if role.fm then push("armed", armed and 1 or 0) end

    for k = 1, #roleList do
        local e = roleList[k]
        local v = tonumber(f[e.idx])
        if v and not (e.skipZero and v == 0) then
            local r = e.r
            note(stat, r, v)
            if armed and e.gated then note(air, r, v) end
            if e.keep and (armed or not e.gated) then
                local least = FLOOR[r]
                if not least or v >= least then push(r, v) end
            end
        end
    end

    -- A sensor that is not streaming is written as zero, and a log always
    -- starts before the model is powered and runs on after it is switched off.
    -- Counting those as a dropout reported "2 link drops" and "link worst 0 %"
    -- on flights where the link never faltered, so a reading of zero is read
    -- as no telemetry rather than as a dead link.
    local lq = role.lq and tonumber(f[role.lq])
    if lq and lq > 0 then
        if lq < 50 then
            if not inDrop then lqDrops = lqDrops + 1; inDrop = true end
        else
            inDrop = false
        end
    end

    -- A receiver reports a position before it has really locked on, and those
    -- early coordinates can be a continent away. Trust the fix only once there
    -- are enough satellites; if the log has no satellite count, accept it.
    local satsOk = true
    if role.sats then
        local sv = tonumber(f[role.sats])
        satsOk = (sv ~= nil and sv >= 4)
    end

    if role.gps and satsOk then
        local g = f[role.gps]
        if g and #g > 3 then
            local la, lo = match(g, "([%-%d%.]+)%s+([%-%d%.]+)")
            la, lo = tonumber(la), tonumber(lo)
            -- both coordinates must be real: a half fix with one still zero
            -- would otherwise become home and put the model continents away
            if la and lo and la ~= 0 and lo ~= 0
                and la >= -90 and la <= 90 and lo >= -180 and lo <= 180 then
                local p = { la, lo }
                if not gps.first then
                    gps.first = p
                    gps.fixAt = t
                else
                    -- Ground jitter while disarmed adds up: a few hundred
                    -- rows of a stationary quad wandering half a metre would
                    -- otherwise appear as track that was never flown. How far
                    -- it got is still taken from every fix, so a model that
                    -- ends up somewhere on its own is not missed.
                    if armed then
                        local step = haversine(gps.last or p, p)
                        if step < 500 then gps.path = gps.path + step end
                    end
                    local d = haversine(gps.first, p)
                    if d > gps.maxDist then gps.maxDist = d end
                end
                gps.last = p
                local v = nil
                if role.alt then v = tonumber(f[role.alt]) end
                if v == nil and role.lq then v = tonumber(f[role.lq]) end
                pushTrack(la, lo, v)
            end
        end
    end

    samples = samples + 1
    if samples >= BUCKETS * bucketSpan then compact() end
end

------------------------------------------------------------------------------
-- loading, a slice per frame so the radio stays responsive
------------------------------------------------------------------------------

-- take every complete line out of the pending block, keeping the tail
local function consume(eof)
    local start = 1
    while true do
        local nl = find(pending, "\n", start, true)
        if not nl then break end
        local line = sub(pending, start, nl - 1)
        start = nl + 1
        line = (gsub(line, "\r$", ""))
        if #line > 0 then
            if haveHeader then parseRow(line) else parseHeader(line); haveHeader = true end
        end
    end
    pending = sub(pending, start)
    -- a log that does not end in a newline still has one last row in it
    if eof and #pending > 0 then
        local line = (gsub(pending, "\r$", ""))
        pending = ""
        if #line > 0 then
            if haveHeader then parseRow(line) else parseHeader(line); haveHeader = true end
        end
    end
end

local function startLoad(file)
    path = "/LOGS/" .. file
    name = file
    cols, units, role, stat, series = {}, {}, {}, {}, {}
    roleList = {}
    timeCol, dataStart, ticksClock = 2, 3, false
    air, armedRows = {}, 0
    colStat, numCols, scanRows = {}, {}, 0
    colAir, sensorArmed = {}, false
    bucketSpan, bucketCount, samples = 1, 0, 0
    firstTime, lastTime = nil, nil
    gps = { first = nil, last = nil, maxDist = 0, path = 0, fixAt = nil }
    trk = { lat = {}, lon = {}, val = {}, n = 0, stride = 1, seen = 0 }
    lqDrops, inDrop = 0, false
    bytesRead = 0
    pending, haveHeader = "", false
    pages, page, gsel = {}, 1, 1
    ssel, stop = 1, 1
    err = nil

    fh = io.open(path, "r")
    if not fh then
        err = "cannot open " .. file
        screen = "list"
        return
    end
    bytesTotal = 0
    if type(fstat) == "function" then
        local okst, st = pcall(fstat, path)
        if okst and type(st) == "table" and st.size then bytesTotal = st.size end
    end
    screen = "loading"
end

-- Height and speed are read from the armed rows when there are any; anything
-- else, and any log with no flight mode column, comes from every row.
local function statFor(r)
    if GATED[r] and armedRows > 0 and air[r] then return air[r] end
    return stat[r]
end

-- what a graph needs to be worth drawing: two points and something to see
local function graphable(r)
    local s, st = series[r], statFor(r)
    if not s or not st or st.max == st.min then return false end
    local pts = 0
    for i = 1, bucketCount do
        if s.n[i] then pts = pts + 1 end
        if pts >= 2 then return true end
    end
    return false
end

local function buildPages()
    pages = { "summary" }
    for _, g in ipairs(GRAPHABLE) do
        if graphable(g.r) then pages[#pages + 1] = "graph"; break end
    end
    if gps.first then pages[#pages + 1] = "track" end
    if #numCols > 0 then pages[#pages + 1] = "sensors" end
    page = 1
    gsel = 1
    ssel, stop = 1, 1
end

local function finish()
    consume(true)
    io.close(fh)
    fh = nil
    if not haveHeader then
        err = "empty log"
        screen = "list"
    else
        buildPages()
        screen = "view"
    end
end

local function loadSlice()
    if not fh then return end
    for _ = 1, BLOCKS_PER_FRAME do
        local chunk = io.read(fh, BLOCK)
        if not chunk or #chunk == 0 then
            finish()
            return
        end
        bytesRead = bytesRead + #chunk
        pending = pending .. chunk
        consume(false)
    end
end

------------------------------------------------------------------------------
-- drawing
------------------------------------------------------------------------------

local function text(x, y, s, colour, size)
    lcd.drawText(x, y, s, (size or SMLSIZE) + (COLOUR and (colour or C_TEXT) or 0))
end

-- Highlighting a row. On colour that is a filled bar behind the text; on a
-- black and white radio a filled rectangle is solid black and the text drawn
-- over it is black too, so the selected line was an unreadable slab. The mono
-- idiom is INVERS on the text itself.
local function rowHighlight(y)
    if COLOUR then
        lcd.drawFilledRectangle(0, y - 1, LCD_W, LH, C_LINE)
    end
end

local function rowText(x, y, s, selected, colour)
    if COLOUR then
        lcd.drawText(x, y, s, SMLSIZE + (colour or C_TEXT))
    else
        lcd.drawText(x, y, s, SMLSIZE + (selected and INVERS or 0))
    end
end

local function rightText(x, y, s, colour, size)
    lcd.drawText(x, y, s, (size or SMLSIZE) + RIGHT + (COLOUR and (colour or C_TEXT) or 0))
end

-- The theme's own background is light, and this screen is light text on dark,
-- so lay the background down rather than inherit whatever the theme cleared to.
local function background()
    if COLOUR then
        lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, C_BG)
    end
end

-- the small radios have no room for "battery low", so they get "batt"
local function lbl(long, short)
    if COLOUR or not short then return long end
    return short
end

-- The first samples of a log can hold a nonsense voltage while the radio is
-- still starting up. A pack never falls below about half its charged voltage
-- in use, so take the low point from the readings that are plausible.
local function battery()
    local st = stat.volt
    if not st then return nil end
    local s = series.volt
    if not s then return { start = st.first, low = st.min, max = st.max } end
    local floor = st.max * 0.55
    local low, start = nil, nil
    for i = 1, bucketCount do
        local hi, lo = s.hi[i], s.lo[i]
        if hi and hi >= floor then
            if not start then start = hi end
            if lo >= floor and (not low or lo < low) then low = lo end
        end
    end
    return { start = start or st.first, low = low or st.min, max = st.max }
end

local function fmt(v, dp)
    if not v then return "-" end
    return format("%." .. (dp or 0) .. "f", v)
end

-- Two decimals where the reading actually carries them, none where it does
-- not: an altitude logged as whole metres reads better as 64 than 64.00, but
-- a current of 58.9 should not be rounded away to 59.
local function fmtAuto(v)
    if not v then return "-" end
    if v == floor(v) then return format("%d", v) end
    return format("%.2f", v)
end

-- Precision belongs to the column, not to each figure in it. Deciding per
-- value put "0" next to "74.10" in the same row, which reads as two different
-- kinds of number rather than as one sensor's range.
local function precisionOf(a, b)
    if (a and a ~= floor(a)) or (b and b ~= floor(b)) then return 2 end
    return 0
end

local function duration()
    if not firstTime or not lastTime then return nil end
    local d = lastTime - firstTime
    if d < 0 then d = 0 end
    return d
end

local function durationText()
    local d = duration()
    if not d then return "-" end
    return format("%d:%02d", floor(d / 60), floor(d % 60))
end

-- How long the model was actually up, where the log knows. Rows come at a
-- fixed interval, so the armed share of them is the armed share of the time.
local function flightSeconds()
    local d = duration()
    if not d then return nil end
    if role.fm and armedRows > 0 and samples > 0 then
        return d * armedRows / samples
    end
    return d
end

local function unitOf(r)
    local i = role[r]
    if not i then return nil end
    return units[cols[i]]
end

-- which page you are on, set by the header and drawn by the footer: a log name
-- is two dozen characters and wants the whole title row to itself
local pageTag = ""

local function footer(s)
    text(PAD, LCD_H - LH, s, C_DIM)
    if screen == "view" and pageTag ~= "" then
        rightText(LCD_W - PAD, LCD_H - LH, pageTag, C_DIM)
    end
end

-- the last line a two column row may occupy without running into the footer
local function lastRow()
    return LCD_H - LH * 2
end

------------------------------------------------------------------------------

local function sizeText(n)
    if not n then return "" end
    if n < 1024 then return n .. " B" end
    if n < 1024 * 1024 then return floor(n / 1024 + 0.5) .. " kB" end
    return format("%.1f MB", n / 1048576)
end

-- How long the flight was, without reading the whole file: the first data row
-- is at the top and the last one is at the end, so two short reads is all it
-- takes. Only rows actually on screen are probed, a couple per frame, so a
-- folder full of logs does not stall the list.
local function probe(file)
    local size = sizes[file]
    if not size or size < 8 then durs[file] = false; return end

    -- A row is as long as the number of sensors makes it, a few hundred bytes
    -- with a full telemetry set, and the reads have to be comfortably longer
    -- than one row or the tail can land inside a single row and find no clock
    -- at all.
    local CHUNK = 2048
    local f = io.open("/LOGS/" .. file, "r")
    if not f then durs[file] = false; return end
    local head = io.read(f, CHUNK)
    local tail = head
    if size > CHUNK then
        io.seek(f, size - CHUNK)
        tail = io.read(f, CHUNK)
    end
    io.close(f)

    -- With an RTC the clock is the second field; without one it is the first
    -- and counts hundredths of a second since the radio started. The header
    -- says which, and it is right at the top of the chunk just read.
    local ticks = (sub(head, 1, 5) ~= "Date,")
    local pat = ticks and "^([^,]*)" or "^[^,]*,([^,]*)"

    -- the header's own clock field is the word "Time", and a chunk that starts
    -- mid row begins with a sensor value, so both fail to parse and skip
    local function timeIn(str, last)
        local found = nil
        for line in string.gmatch(str, "[^\n]+") do
            local f2 = match(line, pat)
            local v = nil
            if f2 then
                v = clockToSeconds(f2)
                if not v and ticks then
                    local n = tonumber(f2)
                    if n then v = n / 100 end
                end
            end
            if v then
                found = v
                if not last then return v end
            end
        end
        return found
    end

    local a = timeIn(head, false)
    local b = timeIn(tail, true)
    if a and b then
        local d = b - a
        if d < 0 then d = d + 86400 end     -- a flight over midnight
        durs[file] = d
    else
        durs[file] = false
    end
end

local function drawList()
    text(PAD, PAD, "Flight logs", C_ACC, MIDSIZE)
    local y = PAD + TITLE
    if #files == 0 then
        text(PAD, y, err or "no logs on the card", C_DIM)
        footer("RTN exit")
        return
    end
    local rows = floor((LCD_H - y - LH) / LH)
    if sel < top then top = sel end
    if sel > top + rows - 1 then top = sel - rows + 1 end
    local cw = COLOUR and 7 or 5
    for i = top, min(top + rows - 1, #files) do
        local f = files[i]
        if durs[f] == nil and probeBudget > 0 then
            probeBudget = probeBudget - 1
            probe(f)
        end

        local d = durs[f]
        local info = sizeText(sizes[f])
        if d then
            info = format("%d:%02d   ", floor(d / 60), floor(d % 60)) .. info
        end

        local label = (gsub(f, "%.[cC][sS][vV]$", ""))
        local room = floor((LCD_W - PAD * 2) / cw) - #info - 1
        if room > 4 and #label > room then label = sub(label, 1, room) end

        if i == sel then rowHighlight(y) end
        rowText(PAD, y, label, i == sel, i == sel and C_ACC or C_TEXT)
        -- a log too short to hold a flight is dimmed, so the ones worth
        -- opening stand out
        rightText(LCD_W - PAD, y, info, (d and d >= 60) and C_TEXT or C_DIM)
        y = y + LH
    end
    if err then
        -- its own line: right aligning it onto the footer put it on top of
        -- the key hints
        text(PAD, LCD_H - LH * 2, err, C_WARN)
    end
    footer(lbl("ENT open   hold ENT delete   RTN exit", "ENT open  hold ENT del"))
end

local function drawConfirm()
    text(PAD, PAD, "Delete", C_BAD, MIDSIZE)
    local y = PAD + TITLE

    -- the name gets its own line: on a 128 pixel screen it does not fit beside
    -- the word and was running off the edge
    local one = (gsub(files[sel] or "", "%.[cC][sS][vV]$", ""))
    local room = floor((LCD_W - PAD * 2) / (COLOUR and 6 or 5))
    if #one > room then one = sub(one, 1, room) end
    text(PAD, y, one, C_TEXT)
    y = y + LH + (COLOUR and 4 or 2)

    local opts = {
        { t = "Delete this log" },
        { t = "Delete all " .. #files .. " logs" },
    }
    for i, o in ipairs(opts) do
        if i == confirmSel then rowHighlight(y) end
        rowText(PAD, y, o.t, i == confirmSel, i == confirmSel and C_TEXT or C_DIM)
        y = y + LH
    end
    y = y + LH
    if confirmSel == 2 then
        text(PAD, y, lbl("Hold ENT to delete every log. This cannot be undone.",
                         "hold ENT: deletes all"), C_BAD)
    else
        text(PAD, y, lbl("ENT deletes this log. This cannot be undone.",
                         "ENT deletes this log"), C_WARN)
    end
    footer("RTN cancel")
end

local function drawLoading()
    text(PAD, PAD, "Reading", C_ACC, MIDSIZE)
    text(PAD, PAD + TITLE, name or "", C_TEXT)
    local w = LCD_W - PAD * 2
    local y = floor(LCD_H / 2)
    local pct = 0
    if bytesTotal > 0 then pct = min(1, bytesRead / bytesTotal) end
    lcd.drawRectangle(PAD, y, w, LH, COLOUR and C_LINE or 0)
    lcd.drawFilledRectangle(PAD + 1, y + 1, floor((w - 2) * pct), LH - 2,
                            COLOUR and C_ACC or 0)
    text(PAD, y + LH + 4, samples .. " samples", C_DIM)
end

-- every page carries the log name and where you are in the set of pages
local function drawHeader(what)
    if #pages > 1 then
        -- the small screens have no room in the footer for the word as well
        pageTag = (COLOUR and (what .. "  ") or "") .. page .. "/" .. #pages
    else
        pageTag = ""
    end
    local title = (gsub(name or "", "%.[cC][sS][vV]$", ""))
    local room = floor((LCD_W - PAD * 2) / (COLOUR and 11 or 5))
    if #title > room then title = sub(title, 1, room) end
    text(PAD, PAD, title, C_ACC, COLOUR and MIDSIZE or SMLSIZE)
end

local function drawSummary()
    drawHeader("summary")
    local y = PAD + TITLE

    if samples == 0 then
        text(PAD, y, "no data rows in this log", C_DIM)
        footer("RTN back")
        return
    end

    -- the one line worth reading first
    local parts = { durationText() }
    local b = battery()
    if COLOUR then
        if stat.used then parts[#parts + 1] = fmt(stat.used.max, 0) .. " " .. (unitOf("used") or "mAh") end
        if b then parts[#parts + 1] = fmt(b.low, 2) .. " V low" end
        if lqDrops > 0 then parts[#parts + 1] = lqDrops .. " link drops" end
    else
        -- a 128 pixel screen fits about 25 characters of this font, and the
        -- long form ran off the edge taking the numbers with it
        if stat.used then parts[#parts + 1] = fmt(stat.used.max, 0) .. (unitOf("used") or "mAh") end
        if b then parts[#parts + 1] = fmt(b.low, 1) .. "V" end
    end
    text(PAD, y, concat(parts, "  "), C_TEXT, COLOUR and MIDSIZE or SMLSIZE)
    y = y + (COLOUR and 26 or 10)

    local colW = floor((LCD_W - PAD * 2) / 2)
    local left, right = PAD, PAD + colW

    -- rows are simply dropped once the column reaches the footer, which is how
    -- the same layout survives a screen a quarter of the size
    local bottom = lastRow()
    local function row(x, yy, k, v, colour)
        if yy > bottom then return end
        text(x, yy, k, C_DIM)
        rightText(x + colW - PAD - 2, yy, v, colour)
    end

    local ry = y
    row(left, ry, lbl("duration", "time"), durationText()); ry = ry + LH
    -- rows come at a fixed interval, so the share of them that were armed is
    -- the share of the log that was actually flown
    if role.fm and armedRows > 0 then
        local air0 = flightSeconds()
        if air0 then
            row(left, ry, lbl("armed", "armed"),
                format("%d:%02d", floor(air0 / 60), floor(air0 % 60)))
            ry = ry + LH
        end
    end
    if COLOUR then
        row(left, ry, "samples", tostring(samples)); ry = ry + LH
    end
    local bat = battery()
    if bat then
        row(left, ry, lbl("battery start", "start"), fmt(bat.start, 2) .. " V"); ry = ry + LH
        local lowC = (bat.low <= bat.start * 0.8) and C_BAD or C_GOOD
        row(left, ry, lbl("battery low", "low"), fmt(bat.low, 2) .. " V", lowC); ry = ry + LH
    end
    local usedUnit = unitOf("used") or "mAh"
    if stat.used then
        row(left, ry, "used", fmtAuto(stat.used.max) .. " " .. usedUnit); ry = ry + LH
    end
    if stat.curr then
        row(left, ry, lbl("peak current", "peak A"), fmtAuto(stat.curr.max) .. " A"); ry = ry + LH
        if stat.curr.n > 0 and COLOUR then
            row(left, ry, "average current", fmt(stat.curr.sum / stat.curr.n, 2) .. " A")
            ry = ry + LH
        end
    end
    -- over the time actually flown where that is known: dividing by the whole
    -- log, most of which can be the model sitting on the ground, understates
    -- both of these badly
    local d = flightSeconds()
    if stat.used and d and d > 30 and COLOUR and usedUnit == "mAh" then
        row(left, ry, "drain", fmt(stat.used.max / (d / 60), 0) .. " mAh/min"); ry = ry + LH
    end

    ry = y
    if stat.lq then
        local c = stat.lq.min < 50 and C_BAD or (stat.lq.min < 80 and C_WARN or C_GOOD)
        row(right, ry, lbl("link worst", "link"), fmt(stat.lq.min, 0) .. " %", c); ry = ry + LH
    end
    -- link quality says the same thing better, so the small screens keep only it
    if stat.rssi and (COLOUR or not stat.lq) then
        row(right, ry, lbl("signal worst", "sig"), fmt(stat.rssi.min, 0) .. " dB"); ry = ry + LH
    end
    if stat.snr and COLOUR then
        row(right, ry, "snr worst", fmt(stat.snr.min, 0) .. " dB"); ry = ry + LH
    end
    if lqDrops > 0 then
        row(right, ry, lbl("link drops", "drops"), tostring(lqDrops), C_WARN); ry = ry + LH
    end
    local sAlt, sSpd = statFor("alt"), statFor("speed")
    local neverArmed = (role.fm ~= nil and armedRows == 0)
    if neverArmed then
        row(right, ry, lbl("never armed", "no arm"), "-", C_WARN); ry = ry + LH
        sAlt, sSpd = nil, nil
    end
    if sAlt then
        row(right, ry, lbl("max altitude", "alt"),
            fmtAuto(sAlt.max) .. " " .. (unitOf("alt") or "m")); ry = ry + LH
    end
    if sSpd then
        row(right, ry, lbl("max speed", "spd"),
            fmtAuto(sSpd.max) .. " " .. (unitOf("speed") or "kmh")); ry = ry + LH
    end
    if gps.first then
        row(right, ry, lbl("max distance", "dist"), fmtAuto(gps.maxDist) .. " m"); ry = ry + LH
        row(right, ry, "track", fmt(gps.path / 1000, 2) .. " km"); ry = ry + LH
        if stat.sats and COLOUR then
            row(right, ry, "satellites", fmt(stat.sats.max, 0)); ry = ry + LH
        end
    elseif role.gps then
        row(right, ry, "gps", "no fix", C_DIM); ry = ry + LH
    end

    if #pages > 1 then
        footer(lbl("PAGE< >  screens   RTN back", "ENT page  RTN back"))
    else
        footer("RTN back")
    end
end

------------------------------------------------------------------------------

-- One series, as big as the page allows: a dim min/max band for the moments
-- between samples and a bright line through the average of each bucket.
local function drawGraph()
    local list = {}
    for _, g in ipairs(GRAPHABLE) do
        if graphable(g.r) then list[#list + 1] = g end
    end
    if #list == 0 then
        drawHeader("graph")
        text(PAD, PAD + TITLE, "nothing to graph", C_DIM)
        footer("RTN back")
        return
    end
    if gsel > #list then gsel = 1 end
    if gsel < 1 then gsel = #list end

    local g = list[gsel]
    local s, st = series[g.r], statFor(g.r)
    local colour = rgb(g.c[1], g.c[2], g.c[3])
    local band = rgb(floor(g.c[1] * 0.32), floor(g.c[2] * 0.32),
                     floor(g.c[3] * 0.32))

    drawHeader("graph")

    local unit = unitOf(g.r)
    local y = PAD + TITLE
    text(PAD, y, g.label .. (unit and ("  " .. unit) or ""), colour,
         COLOUR and MIDSIZE or SMLSIZE)
    if #list > 1 then
        rightText(LCD_W - PAD, y + (COLOUR and 6 or 0), gsel .. "/" .. #list, C_DIM)
    end
    y = y + (COLOUR and 26 or 9)

    -- The battery graph is scaled the way the summary reads it: the startup
    -- glitch is not a real low, and letting it set the bottom of the axis
    -- squashes the whole flight into the top of the plot.
    local lo, hi = st.min, st.max
    if g.r == "volt" then
        local bat = battery()
        if bat then lo, hi = bat.low, bat.max end
    end

    local dp = precisionOf(lo, hi)

    -- The average has to come from the same readings the plot shows. Taking it
    -- from the unfiltered statistics let the bench period before the pack was
    -- plugged in drag it below the stated minimum, so a header could read
    -- "min 21.0  avg 12.3  max 25.2".
    -- weighted by how many readings each bucket holds, not an average of the
    -- bucket averages: a bucket half of which was disarmed carries half the
    -- samples, and counting it equally with a full one tilts the figure
    local asum, an = 0, 0
    for i = 1, bucketCount do
        local c = s.n[i]
        if c then
            local mean = s.sum[i] / c
            if mean >= lo and mean <= hi then
                asum = asum + s.sum[i]
                an = an + c
            end
        end
    end
    local avg = an > 0 and (asum / an) or lo
    -- the average is the one figure here that is not a reading the model ever
    -- took, so rounding it to whole numbers threw away what it is for
    text(PAD, y, lbl("min " .. fmt(lo, dp) .. "   avg " .. fmt(avg, 2) ..
                     "   max " .. fmt(hi, dp),
                     fmt(lo, dp) .. " / " .. fmt(avg, 2) .. " / " .. fmt(hi, dp)),
         C_DIM)
    y = y + LH + 2

    local gx = PAD
    local gw = LCD_W - PAD * 2
    local gy = y
    local gh = LCD_H - y - LH * 2 - 2
    if gh < 10 then gh = 10 end

    lcd.drawRectangle(gx, gy, gw, gh, COLOUR and C_LINE or 0)
    if COLOUR then
        for q = 1, 3 do
            local ly = gy + floor(gh * q / 4)
            for px = gx + 2, gx + gw - 2, 6 do
                lcd.drawPoint(px, ly, C_LINE)
            end
        end
    end

    local span = hi - lo
    if span <= 0 then span = 1 end
    local function py(v)
        if v < lo then v = lo elseif v > hi then v = hi end
        return gy + gh - 1 - floor((v - lo) / span * (gh - 2))
    end
    local function px(i)
        if bucketCount < 2 then return gx + floor(gw / 2) end
        return gx + floor((i - 1) * (gw - 1) / (bucketCount - 1))
    end

    -- Behind everything, the stretches the model spent disarmed. Height and
    -- speed mean something else then and are not counted, so the line has a
    -- gap there; this says why instead of leaving it looking broken. A lost
    -- link never makes a gap, because the radio keeps logging the last value,
    -- so disarmed is the only thing it can be.
    local off = GATED[g.r] and series.armed or nil
    if COLOUR and off then
        local function idle(k)
            return off.n[k] and (off.sum[k] / off.n[k]) < 0.5
        end
        local bands, i = {}, 1
        while i <= bucketCount do
            if idle(i) then
                local j = i
                while j < bucketCount and idle(j + 1) do j = j + 1 end
                bands[#bands + 1] = { px(i), px(j) }
                i = j + 1
            else
                i = i + 1
            end
        end
        local widest = nil
        for k = 1, #bands do
            local b = bands[k]
            lcd.drawFilledRectangle(b[1], gy + 1, max(1, b[2] - b[1] + 1),
                                    gh - 2, C_OFF)
            if not widest or (b[2] - b[1]) > (widest[2] - widest[1]) then
                widest = b
            end
        end
        -- One label, on the longest stretch, rather than the same word over
        -- and over. It goes in the middle of the band, both because that is
        -- where the line has its gap anyway and because the top corner already
        -- carries the top of the range.
        if widest and (widest[2] - widest[1] + 1) >= 44 then
            local mid = floor((widest[1] + widest[2]) / 2) - 20
            if mid < gx + 2 then mid = gx + 2 end
            text(mid, gy + floor(gh / 2) - 4, "disarmed", C_DIM)
        end
    end

    -- the band first, so the line sits on top of it
    local function shown(i)
        if not s.n[i] then return false end
        local mean = s.sum[i] / s.n[i]
        return mean >= lo and mean <= hi
    end

    if COLOUR then
        for i = 1, bucketCount do
            if shown(i) then
                local x = px(i)
                lcd.drawLine(x, py(s.hi[i]), x, py(s.lo[i]), SOLID, band)
            end
        end
    end

    -- A gap means there was no reading at all through there, most often
    -- because the model was disarmed. Joining across it would draw a speed or
    -- a height that was never recorded, so the line stops and picks up again.
    local lx, ly, li = nil, nil, nil
    for i = 1, bucketCount do
        if shown(i) then
            local x = px(i)
            local yv = py(s.sum[i] / s.n[i])
            if lx and li == i - 1 then
                lcd.drawLine(lx, ly, x, yv, SOLID, COLOUR and colour or 0)
            else
                lcd.drawPoint(x, yv, COLOUR and colour or 0)
            end
            lx, ly, li = x, yv, i
        end
    end

    -- the range is already spelled out above the plot, and on a small screen
    -- repeating it inside would sit on top of the line
    if COLOUR then
        text(gx + 2, gy + 1, fmt(hi, dp), C_DIM)
        text(gx + 2, gy + gh - LH - 1, fmt(lo, dp), C_DIM)
        rightText(gx + gw - 2, gy + gh - LH - 1, durationText(), C_DIM)
    end

    if #list > 1 then
        footer(lbl("scroll: series   PAGE< > screens   RTN back",
                   "scrl series  ENT page"))
    else
        footer(lbl("PAGE< >  screens   RTN back", "ENT page  RTN back"))
    end
end

------------------------------------------------------------------------------

-- Where it flew and, more usefully after a crash, where it stopped reporting.
local function drawTrack()
    drawHeader("track")
    local y = PAD + TITLE

    if trk.n < 1 or not trk.minLat then
        text(PAD, y, "no gps fix in this log", C_DIM)
        footer("RTN back")
        return
    end

    -- how much room the text below needs
    local lines = COLOUR and 3 or 2
    local gy = y
    local gh = LCD_H - y - LH * (lines + 1) - 4
    local gx = PAD
    local gw = LCD_W - PAD * 2
    if gh < 16 then gh = 16 end

    local midLat = (trk.minLat + trk.maxLat) / 2
    local midLon = (trk.minLon + trk.maxLon) / 2
    local k = cos(rad(midLat))
    local spanLat = trk.maxLat - trk.minLat
    local spanLon = (trk.maxLon - trk.minLon) * k
    if spanLat < 1e-7 then spanLat = 1e-7 end
    if spanLon < 1e-7 then spanLon = 1e-7 end

    -- one scale for both axes, so the shape of the flight is not distorted
    local scale = min((gw - 8) / spanLon, (gh - 8) / spanLat)
    local cx = gx + gw / 2
    local cy = gy + gh / 2

    local function point(i)
        local x = cx + (trk.lon[i] - midLon) * k * scale
        local yy = cy - (trk.lat[i] - midLat) * scale
        return floor(x + 0.5), floor(yy + 0.5)
    end

    -- colour the path by whatever was pushed with it, altitude if it was there
    local vMin, vMax = trk.minVal, trk.maxVal
    local vSpan = (vMin and vMax and vMax > vMin) and (vMax - vMin) or nil

    lcd.drawRectangle(gx, gy, gw, gh, COLOUR and C_LINE or 0)
    local lx, ly = point(1)
    for i = 2, trk.n do
        local x, yy = point(i)
        local colour = C_ACC
        if COLOUR and vSpan and trk.val[i] then
            local f = (trk.val[i] - vMin) / vSpan
            colour = rgb(floor(70 + 165 * f), floor(200 - 60 * f),
                         floor(245 - 145 * f))
        end
        lcd.drawLine(lx, ly, x, yy, SOLID, COLOUR and colour or 0)
        lx, ly = x, yy
    end

    local hx, hy = point(1)
    lcd.drawFilledRectangle(hx - 2, hy - 2, 5, 5, COLOUR and C_GOOD or 0)
    lcd.drawFilledRectangle(lx - 2, ly - 2, 5, 5, COLOUR and C_BAD or 0)
    if COLOUR then
        text(gx + 3, gy + 1, "home", C_GOOD)
        if vSpan and role.alt then
            rightText(gx + gw - 3, gy + 1, "by altitude", C_DIM)
        end
    end

    local ty = gy + gh + 2
    local last = gps.last
    text(PAD, ty, lbl("last position", "last"), C_DIM)
    if COLOUR then
        rightText(LCD_W - PAD, ty, format("%.6f  %.6f", last[1], last[2]), C_TEXT)
    else
        -- four decimals is about eleven metres, and it fits
        rightText(LCD_W - PAD, ty, format("%.4f %.4f", last[1], last[2]), C_TEXT)
    end
    ty = ty + LH
    text(PAD, ty, lbl("plus code", "code"), C_DIM)
    rightText(LCD_W - PAD, ty, plusCode(last[1], last[2]), C_ACC,
              COLOUR and MIDSIZE or SMLSIZE)
    ty = ty + (COLOUR and LH + 4 or LH)
    if COLOUR then
        text(PAD, ty, "distance from home", C_DIM)
        rightText(LCD_W - PAD, ty,
                  fmt(haversine(gps.first, last), 0) .. " m   track " ..
                  fmt(gps.path / 1000, 2) .. " km", C_TEXT)
    end

    footer(lbl("PAGE< >  screens   RTN back", "ENT page  RTN back"))
end

------------------------------------------------------------------------------

-- Everything numeric the log contains, named the way the header named it.
-- Nothing is hidden for not being understood, so a sensor this script has
-- never heard of is still readable here.
local function drawSensors()
    drawHeader("sensors")
    local y = PAD + TITLE

    -- the average column carries two more characters than the others, so it
    -- is given the room rather than left to run into the minimum beside it
    local w = LCD_W - PAD * 2
    local c1 = PAD + floor(w * 0.46)
    local c2 = PAD + floor(w * 0.73)
    local c3 = PAD + w

    local canToggle = (role.fm ~= nil and armedRows > 0)
    local armedOnly = canToggle and sensorArmed
    text(PAD, y, armedOnly and "sensor (armed)" or "sensor", C_DIM)
    rightText(c1, y, "min", C_DIM)
    rightText(c2, y, "avg", C_DIM)
    rightText(c3, y, "max", C_DIM)
    y = y + LH + 1
    if COLOUR then
        lcd.drawLine(PAD, y - 2, PAD + w, y - 2, SOLID, C_LINE)
    end

    local rows = floor((LCD_H - y - LH) / LH)
    if rows < 1 then rows = 1 end
    if ssel < 1 then ssel = 1 end
    if ssel > #numCols then ssel = #numCols end
    if ssel < stop then stop = ssel end
    if ssel > stop + rows - 1 then stop = ssel - rows + 1 end

    for k = stop, min(stop + rows - 1, #numCols) do
        local i = numCols[k]
        local cs = armedOnly and colAir[i] or colStat[i]
        local nm = cols[i] or ("col " .. i)
        local u = units[nm]
        if u and u ~= "" and COLOUR then nm = nm .. " " .. u end
        if k == ssel then rowHighlight(y) end
        local dp = precisionOf(cs.min, cs.max)
        rowText(PAD, y, nm, k == ssel, k == ssel and C_ACC or C_TEXT)
        rightText(c1, y, fmt(cs.min, dp), C_DIM)
        rightText(c2, y, fmt(cs.n > 0 and cs.sum / cs.n or 0, 2), C_TEXT)
        rightText(c3, y, fmt(cs.max, dp), C_DIM)
        y = y + LH
    end

    if canToggle then
        footer(lbl("hold ENT: " .. (armedOnly and "all rows" or "armed only") ..
                   "   PAGE< > screens", "hold ENT: armed"))
    else
        footer(lbl("scroll: sensors   PAGE< > screens   RTN back",
                   "scroll  ENT page"))
    end
end

------------------------------------------------------------------------------
-- tool entry points
------------------------------------------------------------------------------

-- dir(), fstat() and del() are plain globals in EdgeTX, not members of a table
local function listLogs()
    files, sizes, durs = {}, {}, {}
    err = nil
    if type(dir) ~= "function" then
        err = "this firmware has no dir()"
        return
    end
    local seen = 0
    local ok, iter = pcall(dir, "/LOGS")
    if not ok or not iter then
        err = "cannot open /LOGS"
        return
    end
    for f in iter do
        seen = seen + 1
        if match(f, "%.[cC][sS][vV]$") then
            files[#files + 1] = f
        end
    end
    sort(files, function(a, b) return a > b end)   -- newest first
    -- A card that has never been cleared out can hold hundreds of logs, and
    -- the smaller radios have no Lua memory ceiling to catch a list that long,
    -- they simply abort with out of memory. The newest are the ones anyone
    -- opens, so the tail is dropped and the user is told.
    local found = #files
    if found > MAX_LISTED then
        for i = MAX_LISTED + 1, found do files[i] = nil end
        err = "newest " .. MAX_LISTED .. " of " .. found
    end
    if type(fstat) == "function" then
        for _, f in ipairs(files) do
            local ok2, st = pcall(fstat, "/LOGS/" .. f)
            if ok2 and type(st) == "table" and st.size then sizes[f] = st.size end
        end
    end
    if #files == 0 then
        if seen > 0 then
            err = seen .. " files in /LOGS, none are csv"
        else
            err = "/LOGS is empty"
        end
    end
    if sel > #files then sel = max(1, #files) end
end

local function removeLog(file)
    if type(del) ~= "function" then return false end
    local ok, res = pcall(del, "/LOGS/" .. file)
    return ok and (res == 0 or res == nil)
end

local function deleteSelected()
    local f = files[sel]
    if not f then return end
    local gone = removeLog(f)
    listLogs()
    if not gone then err = "could not delete" end
end

local function deleteAll()
    local failed = 0
    for _, f in ipairs(files) do
        if not removeLog(f) then failed = failed + 1 end
    end
    sel, top = 1, 1
    listLogs()
    if failed > 0 then err = failed .. " could not be deleted" end
end

local function init()
    initColours()
    listLogs()
end

local function nextPage()
    if #pages < 2 then return end
    page = page + 1
    if page > #pages then page = 1 end
end

local function prevPage()
    if #pages < 2 then return end
    page = page - 1
    if page < 1 then page = #pages end
end

local function run(event)
    probeBudget = 2                 -- how many logs may be measured this frame

    -- Releasing a long press delivers ENTER straight after ENTER_LONG, and
    -- killEvents cannot stop it: the firmware refuses to mask ENTER at all
    -- (IS_MASKABLE in api_general.cpp excludes it on every radio) and pushes
    -- the break deliberately, with a comment saying scripts depend on it.
    -- Without swallowing that one event, the release of the press that opens
    -- the delete confirmation answers it, and the log is gone.
    if eatEnter then
        eatEnter = false
        if event == EVT_VIRTUAL_ENTER then event = 0 end
    end

    if screen == "list" then
        if event == EVT_VIRTUAL_EXIT then
            return 1
        elseif event == EVT_VIRTUAL_NEXT then
            if sel < #files then sel = sel + 1 end
        elseif event == EVT_VIRTUAL_PREV then
            if sel > 1 then sel = sel - 1 end
        elseif event == EVT_VIRTUAL_ENTER_LONG and files[sel] then
            eatEnter = true
            confirmSel = 1
            screen = "confirm"
        elseif event == EVT_VIRTUAL_ENTER and files[sel] then
            startLoad(files[sel])
        end

    elseif screen == "confirm" then
        if event == EVT_VIRTUAL_EXIT then
            screen = "list"
        elseif event == EVT_VIRTUAL_NEXT then
            confirmSel = 2
        elseif event == EVT_VIRTUAL_PREV then
            confirmSel = 1
        elseif event == EVT_VIRTUAL_ENTER and confirmSel == 1 then
            deleteSelected()
            screen = "list"
        elseif event == EVT_VIRTUAL_ENTER_LONG and confirmSel == 2 then
            eatEnter = true
            deleteAll()
            screen = "list"
        end

    elseif screen == "loading" then
        if event == EVT_VIRTUAL_EXIT then
            if fh then io.close(fh); fh = nil end
            screen = "list"
        else
            loadSlice()
        end

    else
        -- PAGE< and PAGE> step through the screens, the rotary stays free for
        -- moving about inside whichever screen is showing. ENTER pages too, so
        -- a radio without page keys can still get everywhere.
        if event == EVT_VIRTUAL_EXIT then
            screen = "list"
        elseif event == EVT_VIRTUAL_ENTER then
            nextPage()
        elseif EVT_VIRTUAL_NEXT_PAGE and event == EVT_VIRTUAL_NEXT_PAGE then
            nextPage()
        elseif EVT_VIRTUAL_PREV_PAGE and event == EVT_VIRTUAL_PREV_PAGE then
            prevPage()
        elseif pages[page] == "graph" then
            if event == EVT_VIRTUAL_NEXT then
                gsel = gsel + 1
            elseif event == EVT_VIRTUAL_PREV then
                gsel = gsel - 1
            end
        elseif pages[page] == "sensors" then
            if event == EVT_VIRTUAL_ENTER_LONG then
                sensorArmed = not sensorArmed
                eatEnter = true
            elseif event == EVT_VIRTUAL_NEXT then
                if ssel < #numCols then ssel = ssel + 1 end
            elseif event == EVT_VIRTUAL_PREV then
                if ssel > 1 then ssel = ssel - 1 end
            end
        end
    end

    lcd.clear()
    background()
    if screen == "list" then
        drawList()
    elseif screen == "confirm" then
        drawConfirm()
    elseif screen == "loading" then
        drawLoading()
    elseif pages[page] == "graph" then
        drawGraph()
    elseif pages[page] == "track" then
        drawTrack()
    elseif pages[page] == "sensors" then
        drawSensors()
    else
        drawSummary()
    end
    return 0
end

return { init = init, run = run }
