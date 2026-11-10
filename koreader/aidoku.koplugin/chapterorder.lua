--[[--
Chapter ordering & display sorting helpers:
1. Canonical reading order (orderedByReading / after) for auto-advance,
   prefetch, and sequential batch downloads.
2. Flexible display sorting (sortForDisplay) supporting:
   - Source default order (newest-first / oldest-first)
   - Chapter name order (natural alphanumeric/UTF-8 A->Z and Z->A)
   - Update time order (DateUploaded newest-first and oldest-first)
]]

local ChapterOrder = {}

function ChapterOrder.number(chapter)
    return type(chapter.ChapterNumber) == "number" and chapter.ChapterNumber or nil
end

-- Exact proleptic Gregorian days since 1970-01-01 (Howard Hinnant's algorithm),
-- avoiding os.time()'s local-timezone / DST / 32-bit quirks when parsing UTC
-- or offset-qualified RFC3339 timestamps emitted by Go's encoding/json.
local function daysFromCivil(y, m, d)
    if m <= 2 then
        y = y - 1
    end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local m_adj = m > 2 and (m - 3) or (m + 9)
    local doy = math.floor((153 * m_adj + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- parseTimestamp converts a Chapter's DateUploaded field (RFC3339 string,
-- YYYY-MM-DD string, or numeric Unix timestamp) into integer Unix seconds,
-- or nil when absent/unparseable (including KOReader json's null function sentinel).
function ChapterOrder.parseTimestamp(val)
    if type(val) == "number" then
        return val > 0 and val or nil
    end
    if type(val) ~= "string" or val == "" then
        return nil
    end
    local y, m, d, hh, mm, ss, rest = val:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d):(%d%d)(.*)$")
    if y then
        local days = daysFromCivil(tonumber(y), tonumber(m), tonumber(d))
        local epoch = days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
        if rest and rest ~= "" then
            -- Strip fractional seconds if present (".123456")
            local tz = rest:gsub("^%.[%d]+", "")
            if tz ~= "" and tz ~= "Z" and tz ~= "z" then
                local sign, tzh, tzm = tz:match("^([%+%-])(%d%d):?(%d%d)$")
                if sign then
                    local offset = tonumber(tzh) * 3600 + tonumber(tzm) * 60
                    if sign == "+" then
                        epoch = epoch - offset
                    else
                        epoch = epoch + offset
                    end
                end
            end
        end
        return epoch
    end
    local dy, dm, dd = val:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if dy then
        return daysFromCivil(tonumber(dy), tonumber(dm), tonumber(dd)) * 86400
    end
    return nil
end

function ChapterOrder.chapterTimestamp(chapter)
    if not chapter then
        return nil
    end
    return ChapterOrder.parseTimestamp(chapter.DateUploaded)
end

function ChapterOrder.formatTimestamp(ts, include_time)
    if not ts or ts <= 0 then
        return nil
    end
    local ok, formatted = pcall(os.date, include_time and "%Y-%m-%d %H:%M" or "%Y-%m-%d", ts)
    return ok and formatted or nil
end

-- naturalCompare compares two strings with natural numeric chunk awareness so
-- "第2话" < "第10话" and "Chapter 2" < "Chapter 10", while non-numeric segments
-- compare case-insensitively then bytewise (UTF-8 codepoint order).
local function tokenizeNatural(s)
    s = tostring(s or "")
    local tokens = {}
    local i, len = 1, #s
    while i <= len do
        local ds, de = s:find("^%d+%.?%d*", i)
        if ds then
            local raw = s:sub(ds, de)
            table.insert(tokens, { is_num = true, num = tonumber(raw) or 0, raw = raw })
            i = de + 1
        else
            local ts, te = s:find("^[^%d]+", i)
            local raw = s:sub(ts, te)
            table.insert(tokens, { is_num = false, lower = raw:lower(), raw = raw })
            i = te + 1
        end
    end
    return tokens
end

function ChapterOrder.naturalCompare(a, b)
    if a == b then
        return 0
    end
    local ta, tb = tokenizeNatural(a), tokenizeNatural(b)
    local n = math.min(#ta, #tb)
    for i = 1, n do
        local x, y = ta[i], tb[i]
        if x.is_num and y.is_num then
            if x.num ~= y.num then
                return x.num < y.num and -1 or 1
            end
            if #x.raw ~= #y.raw then
                return #x.raw < #y.raw and -1 or 1
            end
        elseif x.is_num ~= y.is_num then
            -- Numbers sort before non-numbers at the same prefix position
            return x.is_num and -1 or 1
        else
            if x.lower ~= y.lower then
                return x.lower < y.lower and -1 or 1
            end
            if x.raw ~= y.raw then
                return x.raw < y.raw and -1 or 1
            end
        end
    end
    if #ta ~= #tb then
        return #ta < #tb and -1 or 1
    end
    return 0
end

-- sortForDisplay returns a new array of chapters ordered according to mode:
--   "source_desc" (default source order, newest first)
--   "source_asc"  (reversed source order, oldest first)
--   "name_asc"    (chapter name A -> Z)
--   "name_desc"   (chapter name Z -> A)
--   "date_desc"   (DateUploaded newest -> oldest; undated last)
--   "date_asc"    (DateUploaded oldest -> newest; undated last)
function ChapterOrder.sortForDisplay(chapters, mode, label_fn)
    mode = mode or "source_desc"
    if mode == "source_desc" then
        local copy = {}
        for i, c in ipairs(chapters) do
            copy[i] = c
        end
        return copy
    elseif mode == "source_asc" then
        local rev = {}
        for i = #chapters, 1, -1 do
            table.insert(rev, chapters[i])
        end
        return rev
    end

    local decorated = {}
    for i, c in ipairs(chapters) do
        local label = label_fn and label_fn(c) or (type(c.Title) == "string" and c.Title ~= "" and c.Title or c.Key)
        table.insert(decorated, {
            chapter = c,
            pos = i,
            label = label,
            ts = ChapterOrder.chapterTimestamp(c),
        })
    end

    if mode == "name_asc" then
        table.sort(decorated, function(a, b)
            local cmp = ChapterOrder.naturalCompare(a.label, b.label)
            if cmp ~= 0 then
                return cmp < 0
            end
            return a.pos < b.pos
        end)
    elseif mode == "name_desc" then
        table.sort(decorated, function(a, b)
            local cmp = ChapterOrder.naturalCompare(a.label, b.label)
            if cmp ~= 0 then
                return cmp > 0
            end
            return a.pos < b.pos
        end)
    elseif mode == "date_desc" then
        table.sort(decorated, function(a, b)
            if a.ts and b.ts then
                if a.ts ~= b.ts then
                    return a.ts > b.ts
                end
                return a.pos < b.pos
            elseif a.ts or b.ts then
                return a.ts ~= nil
            end
            return a.pos < b.pos
        end)
    elseif mode == "date_asc" then
        table.sort(decorated, function(a, b)
            if a.ts and b.ts then
                if a.ts ~= b.ts then
                    return a.ts < b.ts
                end
                return a.pos > b.pos
            elseif a.ts or b.ts then
                return a.ts ~= nil
            end
            return a.pos > b.pos
        end)
    end

    local out = {}
    for i, d in ipairs(decorated) do
        out[i] = d.chapter
    end
    return out
end

function ChapterOrder.orderedByReading(chapters)
    local positional = {}
    for i = #chapters, 1, -1 do
        table.insert(positional, chapters[i])
    end

    local numbered, pos = {}, {}
    for i, c in ipairs(positional) do
        if ChapterOrder.number(c) then
            table.insert(numbered, c)
            pos[c] = i
        end
    end
    table.sort(numbered, function(a, b)
        if a.ChapterNumber ~= b.ChapterNumber then
            return a.ChapterNumber < b.ChapterNumber
        end
        return pos[a] < pos[b]
    end)

    local ordered = {}
    local ni = 1
    for _, c in ipairs(positional) do
        if ChapterOrder.number(c) then
            table.insert(ordered, numbered[ni])
            ni = ni + 1
        else
            table.insert(ordered, c)
        end
    end
    return ordered
end

function ChapterOrder.fromEntry(entry)
    return {
        Key = entry.chapterKey,
        Title = entry.chapterTitle,
        ChapterNumber = type(entry.chapterNumber) == "number" and entry.chapterNumber or nil,
        VolumeNumber = type(entry.volumeNumber) == "number" and entry.volumeNumber or nil,
        DateUploaded = type(entry.dateUploaded) == "number" and entry.dateUploaded or nil,
    }
end

function ChapterOrder.fromEntries(entries, source_key, manga_key)
    local DownloadsEngine = require("downloadsengine")
    local chapters = {}
    for i, entry in ipairs(entries or {}) do
        if DownloadsEngine.entryMatchesManga(entry, source_key, manga_key) then
            local chapter = ChapterOrder.fromEntry(entry)
            chapter._order = i
            table.insert(chapters, chapter)
        end
    end
    table.sort(chapters, function(a, b)
        local na, nb = ChapterOrder.number(a), ChapterOrder.number(b)
        if na and nb then
            if na ~= nb then
                return na > nb
            end
        elseif na or nb then
            return na ~= nil
        end
        return a._order < b._order
    end)
    for _, chapter in ipairs(chapters) do
        chapter._order = nil
    end
    return chapters
end

local function scanlatorsOf(chapter)
    if type(chapter.Scanlators) == "table" and #chapter.Scanlators > 0 then
        return table.concat(chapter.Scanlators, "\0")
    end
    return nil
end

function ChapterOrder.after(chapters, current_key, count, is_local)
    local ordered = ChapterOrder.orderedByReading(chapters)
    local idx
    for i, c in ipairs(ordered) do
        if c.Key == current_key then
            idx = i
            break
        end
    end
    if not idx then
        return {}
    end
    local current_num = ChapterOrder.number(ordered[idx])
    local prefer = scanlatorsOf(ordered[idx])
    local function rank(c)
        local r = 0
        if is_local and is_local(c) then
            r = r + 2
        end
        if prefer and scanlatorsOf(c) == prefer then
            r = r + 1
        end
        return r
    end
    local result, last_num, last_rank = {}, nil, 0
    for i = idx + 1, #ordered do
        local c = ordered[i]
        local n = ChapterOrder.number(c)
        if n ~= nil and n == current_num then -- luacheck: ignore 542
            -- another release of the chapter just finished
        elseif n ~= nil and n == last_num then
            local r = rank(c)
            if r > last_rank then
                result[#result], last_rank = c, r
            end
        else
            if #result >= count then
                break
            end
            table.insert(result, c)
            last_num, last_rank = n, rank(c)
        end
    end
    return result
end

return ChapterOrder
