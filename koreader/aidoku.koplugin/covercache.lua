--[[--
CoverCache manages manga cover thumbnails for LibraryBrowser's List and Grid views:
- Deterministic on-disk thumbnail cache under <data_dir>/aidoku/covers/<hash>.jpg
- Bounded in-memory LRU cache of aspect-fill-scaled Blitbuffers for instant page turns
- Non-blocking background batch fetching via `aidoku-run - covers <payload.json>`,
  repainting each cover widget incrementally as soon as its thumbnail finishes.
]]

local Blitbuffer = require("ffi/blitbuffer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local ok_sha2, sha2 = pcall(require, "ffi/sha2")
local ok_bit, bit = pcall(require, "bit")

local MAX_MEM_COVERS = 36
local POLL_INTERVAL = 0.22
local FAIL_COOLDOWN_SEC = 120
local THUMB_MAX_W = 320
local THUMB_MAX_H = 480

local CoverCache = {
    mem_cache = {},      -- cache_key -> { bb = Blitbuffer, disk_path = string, seq = number }
    mem_count = 0,
    seq = 0,
    failed_until = {},   -- entry_id -> unix timestamp
    active_batch = nil,
    poll_scheduled = false,
    queued_after = nil,
}

function CoverCache.entryId(source_key, manga_key)
    return tostring(source_key or "") .. "\0" .. tostring(manga_key or "")
end

local function fallbackHexHash(str)
    local seeds = { 0x811c9dc5, 0x9e3779b9, 0x85ebca6b, 0xc2b2ae35 }
    local parts = {}
    for s_idx, h in ipairs(seeds) do
        for i = 1, #str do
            local b = str:byte(i) + s_idx * 17
            if ok_bit and bit then
                h = bit.bxor(h, b)
                h = bit.band(h * 16777619, 0xffffffff)
            else
                h = ((h + b) * 1099511628211) % 4294967296
            end
        end
        if h < 0 then
            h = h + 4294967296
        end
        parts[s_idx] = string.format("%08x", h)
    end
    return table.concat(parts):sub(1, 24)
end

function CoverCache.hashKey(str)
    str = tostring(str or "")
    if ok_sha2 and sha2 and type(sha2.sha256) == "function" then
        local ok, digest = pcall(sha2.sha256, str)
        if ok and type(digest) == "string" and #digest >= 24 then
            return digest:lower():sub(1, 24)
        end
    end
    return fallbackHexHash(str)
end

function CoverCache.diskPath(covers_dir, source_key, manga_key)
    local dir = tostring(covers_dir or ""):gsub("/+$", "")
    local id = CoverCache.entryId(source_key, manga_key)
    return dir .. "/" .. CoverCache.hashKey(id) .. ".jpg"
end

function CoverCache:hasDiskCover(covers_dir, source_key, manga_key)
    if not covers_dir or covers_dir == "" then
        return false
    end
    local p = CoverCache.diskPath(covers_dir, source_key, manga_key)
    local attr = lfs.attributes(p)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 0
end

function CoverCache:evictOldest()
    local oldest_key, oldest_seq = nil, math.huge
    for k, v in pairs(self.mem_cache) do
        if v.seq < oldest_seq then
            oldest_seq = v.seq
            oldest_key = k
        end
    end
    if oldest_key then
        local victim = self.mem_cache[oldest_key]
        self.mem_cache[oldest_key] = nil
        self.mem_count = math.max(0, self.mem_count - 1)
        if victim and victim.bb and type(victim.bb.free) == "function" then
            pcall(function() victim.bb:free() end)
        end
    end
end

function CoverCache:invalidateEntry(covers_dir, source_key, manga_key)
    local disk_path = CoverCache.diskPath(covers_dir, source_key, manga_key)
    for k, v in pairs(self.mem_cache) do
        if v.disk_path == disk_path then
            self.mem_cache[k] = nil
            self.mem_count = math.max(0, self.mem_count - 1)
            if v.bb and type(v.bb.free) == "function" then
                pcall(function() v.bb:free() end)
            end
        end
    end
end

function CoverCache:clearMemoryCache()
    for k, v in pairs(self.mem_cache) do
        self.mem_cache[k] = nil
        if v.bb and type(v.bb.free) == "function" then
            pcall(function() v.bb:free() end)
        end
    end
    self.mem_count = 0
end

function CoverCache:resetFailures()
    self.failed_until = {}
end

local function scaleAspectFill(raw_bb, target_w, target_h)
    local src_w, src_h = raw_bb:getWidth(), raw_bb:getHeight()
    if not src_w or not src_h or src_w <= 0 or src_h <= 0 then
        pcall(function() raw_bb:free() end)
        return nil
    end
    if src_w == target_w and src_h == target_h then
        return raw_bb
    end

    local scale = math.max(target_w / src_w, target_h / src_h)
    local scaled_w = math.max(target_w, math.floor(src_w * scale + 0.5))
    local scaled_h = math.max(target_h, math.floor(src_h * scale + 0.5))

    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    local ok_sc, scaled_bb = pcall(function()
        if ok_ri and RenderImage and type(RenderImage.scaleBlitBuffer) == "function" then
            return RenderImage:scaleBlitBuffer(raw_bb, scaled_w, scaled_h)
        end
        return raw_bb:scale(scaled_w, scaled_h)
    end)
    if scaled_bb ~= raw_bb then
        pcall(function() raw_bb:free() end)
    end
    if not ok_sc or not scaled_bb then
        return nil
    end
    if scaled_w == target_w and scaled_h == target_h then
        return scaled_bb
    end

    local ok_crop, crop_bb = pcall(Blitbuffer.new, target_w, target_h, scaled_bb:getType())
    if not ok_crop or not crop_bb then
        return scaled_bb
    end
    local x_off = math.floor((scaled_w - target_w) / 2)
    local y_off = math.floor((scaled_h - target_h) / 2)
    pcall(crop_bb.blitFrom, crop_bb, scaled_bb, 0, 0, x_off, y_off, target_w, target_h)
    pcall(function() scaled_bb:free() end)
    return crop_bb
end

function CoverCache:getScaledBB(covers_dir, source_key, manga_key, target_w, target_h)
    if not covers_dir or covers_dir == "" then
        return nil
    end
    target_w = math.max(1, math.floor(tonumber(target_w) or 1))
    target_h = math.max(1, math.floor(tonumber(target_h) or 1))
    local disk_path = CoverCache.diskPath(covers_dir, source_key, manga_key)
    local cache_key = disk_path .. "|" .. tostring(target_w) .. "x" .. tostring(target_h)

    local hit = self.mem_cache[cache_key]
    if hit and hit.bb then
        self.seq = self.seq + 1
        hit.seq = self.seq
        return hit.bb
    end

    local attr = lfs.attributes(disk_path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) <= 0 then
        return nil
    end

    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then
        return nil
    end
    local ok_dec, raw_bb = pcall(RenderImage.renderImageFile, RenderImage, disk_path, false, nil, nil)
    if not ok_dec or not raw_bb then
        return nil
    end

    local final_bb = scaleAspectFill(raw_bb, target_w, target_h)
    if not final_bb then
        return nil
    end

    while self.mem_count >= MAX_MEM_COVERS do
        self:evictOldest()
    end
    self.seq = self.seq + 1
    self.mem_cache[cache_key] = {
        bb = final_bb,
        disk_path = disk_path,
        seq = self.seq,
    }
    self.mem_count = self.mem_count + 1
    return final_bb
end

function CoverCache:cancelPending()
    self.queued_after = nil
    local batch = self.active_batch
    self.active_batch = nil
    if batch and batch.handle then
        batch.handle:cancel()
    end
end

local function fireCallbacks(list)
    if not list then
        return
    end
    for _idx, fn in ipairs(list) do
        pcall(fn)
    end
end

function CoverCache:schedulePoll()
    if self.poll_scheduled or not self.active_batch then
        return
    end
    self.poll_scheduled = true
    UIManager:scheduleIn(POLL_INTERVAL, function()
        self.poll_scheduled = false
        self:onPollTick()
    end)
end

function CoverCache:notifyBatchIndex(batch, idx)
    if batch.notified[idx] then
        return
    end
    local item = batch.items[idx]
    if not item then
        return
    end
    batch.notified[idx] = true
    self.failed_until[item.id] = nil
    fireCallbacks(batch.callbacks[item.id])
end

function CoverCache:onPollTick()
    local batch = self.active_batch
    if not batch or not batch.handle then
        return
    end

    local state, out = batch.handle:poll()
    local ready = batch.handle:drainReadyCovers()
    if ready then
        for _i, idx in ipairs(ready) do
            self:notifyBatchIndex(batch, idx)
        end
    end

    if state == "running" then
        self:schedulePoll()
        return
    end

    self.active_batch = nil

    if state == "done" and type(out) == "string" and out ~= "" then
        local ok_dec, decoded = pcall(json.decode, out)
        local results = ok_dec and type(decoded) == "table" and type(decoded.results) == "table" and decoded.results or nil
        if results then
            local now = os.time()
            for idx, res in ipairs(results) do
                local item = batch.items[idx]
                if item and type(res) == "table" then
                    if type(res.resolvedCover) == "string" and res.resolvedCover ~= "" then
                        if item.entry then
                            item.entry.cover = res.resolvedCover
                        end
                        if batch.ctx and batch.ctx.store then
                            batch.ctx.store:updateBookmarkCover(item.source_key, item.manga_key, res.resolvedCover)
                        end
                    end
                    if res.ok then
                        self:notifyBatchIndex(batch, idx)
                    else
                        self.failed_until[item.id] = now + FAIL_COOLDOWN_SEC
                    end
                end
            end
        end
    else
        local now = os.time()
        for idx, item in ipairs(batch.items) do
            if not batch.notified[idx] then
                if self:hasDiskCover(batch.ctx.covers_dir, item.source_key, item.manga_key) then
                    self:notifyBatchIndex(batch, idx)
                else
                    self.failed_until[item.id] = now + FAIL_COOLDOWN_SEC
                end
            end
        end
    end

    if self.queued_after then
        local next_req = self.queued_after
        self.queued_after = nil
        self:requestBatch(next_req.requests, next_req.ctx)
    end
end

function CoverCache:requestBatch(requests, ctx)
    if not requests or #requests == 0 or not ctx or not ctx.engine or not ctx.covers_dir or ctx.covers_dir == "" then
        return
    end
    util.makePath(ctx.covers_dir)

    local now = os.time()
    local dedup_order = {}
    local by_id = {}

    for _idx, req in ipairs(requests) do
        local id = CoverCache.entryId(req.source_key, req.manga_key)
        if self:hasDiskCover(ctx.covers_dir, req.source_key, req.manga_key) then
            if req.on_ready then
                pcall(req.on_ready)
            end
        elseif not (self.failed_until[id] and self.failed_until[id] > now) then
            local slot = by_id[id]
            if not slot then
                slot = {
                    id = id,
                    source_key = req.source_key or "",
                    source_path = req.source_path or "",
                    manga_key = req.manga_key or "",
                    cover_url = type(req.cover_url) == "string" and req.cover_url or "",
                    dest_path = CoverCache.diskPath(ctx.covers_dir, req.source_key, req.manga_key),
                    entry = req.entry,
                    callbacks = {},
                }
                by_id[id] = slot
                table.insert(dedup_order, slot)
            end
            if req.on_ready then
                table.insert(slot.callbacks, req.on_ready)
            end
        end
    end

    if #dedup_order == 0 then
        return
    end

    if not NetworkMgr:isConnected() then
        return
    end

    -- If an existing batch is already fetching a subset/superset of this page
    -- (e.g. DownloadQueue triggered a UI refresh mid-fetch), rebind live widget
    -- callbacks in place rather than restarting the subprocess.
    if self.active_batch then
        local overlap = false
        for _i, slot in ipairs(dedup_order) do
            if self.active_batch.by_id[slot.id] then
                overlap = true
                break
            end
        end
        if overlap then
            local leftover = {}
            for _i, slot in ipairs(dedup_order) do
                if self.active_batch.by_id[slot.id] then
                    self.active_batch.callbacks[slot.id] = slot.callbacks
                else
                    for _j, cb in ipairs(slot.callbacks) do
                        table.insert(leftover, {
                            source_key = slot.source_key,
                            source_path = slot.source_path,
                            manga_key = slot.manga_key,
                            cover_url = slot.cover_url,
                            entry = slot.entry,
                            on_ready = cb,
                        })
                    end
                end
            end
            self.queued_after = #leftover > 0 and { requests = leftover, ctx = ctx } or nil
            return
        end
        self:cancelPending()
    end

    local payload_items = {}
    local callbacks_map = {}
    local batch_by_id = {}
    for idx, slot in ipairs(dedup_order) do
        payload_items[idx] = {
            id = slot.id,
            sourceKey = slot.source_key,
            sourcePath = slot.source_path,
            mangaKey = slot.manga_key,
            coverUrl = slot.cover_url,
            destPath = slot.dest_path,
        }
        callbacks_map[slot.id] = slot.callbacks
        batch_by_id[slot.id] = slot
    end

    local handle = ctx.engine:spawnCovers({
        sourcesDir = ctx.sources_dir or "",
        maxWidth = THUMB_MAX_W,
        maxHeight = THUMB_MAX_H,
        items = payload_items,
    })
    if not handle then
        return
    end

    self.active_batch = {
        handle = handle,
        items = dedup_order,
        by_id = batch_by_id,
        callbacks = callbacks_map,
        notified = {},
        ctx = ctx,
    }
    self:schedulePoll()
end

return CoverCache
