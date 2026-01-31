---------------------------------------------------------------------------------------------
--                                         EXAMINER                                        --
-- Deep-inspection, snapshotting, informer/promise helper, and reactive tools for debug  --
---------------------------------------------------------------------------------------------

-- Usage examples:
-- local Examiner = require(path.to.Examiner)
--
-- -- Snapshot a table and later diff it against live state
-- local id = Examiner.Snapshot(myTable)
-- -- ... mutate myTable ...
-- local diffs = Examiner.DiffSnapshots(id, myTable)
--
-- -- Create an Informer for an async operation
-- local inf = Examiner.Informer(function()
--     error("fail")
-- end, { logger = require(path.to.Modules).default })
-- -- attach a catcher
-- inf:catch(function(err) print("caught", err) end)
--
-- -- Examine an object and print via logger
-- local report, ctx = Examiner.ExamineWithLogger(require(path.to.Modules).default, someTable, "Expected number, got nil")
-- print(report)


local Examiner = {}
Examiner.__index = Examiner

-- Runtime-safe Roblox helpers
local HAS_ROBLOX, ROBLOX_GAME, ROBLOX_INSTANCE, ROBLOX_RUNSERVICE, HttpService
do
    local ok, g = pcall(function() return game end)
    if ok and g then
        HAS_ROBLOX = true
        ROBLOX_GAME = g
        pcall(function() ROBLOX_INSTANCE = Instance end)
        pcall(function() ROBLOX_RUNSERVICE = ROBLOX_GAME:GetService("RunService") end)
        local okH, hs = pcall(function() return ROBLOX_GAME:GetService("HttpService") end)
        if okH then HttpService = hs end
    else
        HAS_ROBLOX = false
    end
end

-- Internal storage
local Snapshots = {} -- id -> {time, data, source}
local SnapshotCounter = 0
local Informers = {} -- persistent tracking of informer records
local RequireWatchers = {} -- moduleName -> {callbacks}
local VarObservers = {} -- name -> {callbacks, running}
local Pipes = {} -- middleware chain

-- Utility: shallow+deep copying limited for safety
-- #{deepCopy}
-- Internal: deep copy with cycle-safety and instance descriptors
local function deepCopy(value, seen, depth)
    seen = seen or {}
    depth = (depth or 0) + 1
    if depth > 12 then return tostring(value) end
    if type(value) ~= "table" then
        -- For Instances, produce lightweight descriptor
        if HAS_ROBLOX and typeof(value) == "Instance" then
            return { __instance = true, ClassName = value.ClassName or "Instance", Name = value.Name or "" }
        end
        return value
    end
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local out = {}
    for k,v in pairs(value) do
        pcall(function() out[k] = deepCopy(v, seen, depth) end)
    end
    return out
end

-- Snapshot: save a ghost copy of the object/table and return id
-- Public: create a ghost snapshot of `target` and return an id
-- Examiner.html#snapshots
function Examiner.Snapshot(target, meta)
    SnapshotCounter = SnapshotCounter + 1
    local id = SnapshotCounter
    local ok, copy = pcall(function() return deepCopy(target) end)
    Snapshots[id] = { time = os.time(), data = ok and copy or tostring(target), source = meta }
    return id
end

-- Diff two snapshots or a snapshot and a live object (basic)
-- Internal: produce a simple diff between two tables
local function tableDiff(a,b,prefix,acc)
    acc = acc or {}
    prefix = prefix or ""
    if type(a) ~= "table" or type(b) ~= "table" then
        if tostring(a) ~= tostring(b) then
            acc[#acc+1] = string.format("%s: %s -> %s", prefix, tostring(a), tostring(b))
        end
        return acc
    end
    local keys = {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do
        local ka = a[k]
        local kb = b[k]
        local name = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
        if type(ka) == "table" and type(kb) == "table" then
            tableDiff(ka,kb,name,acc)
        else
            if tostring(ka) ~= tostring(kb) then
                acc[#acc+1] = string.format("%s: %s -> %s", name, tostring(ka), tostring(kb))
            end
        end
    end
    return acc
end

-- #ex-diff
-- #{DiffSnapshots}
-- Public: diff a saved snapshot `id` against `live` state
function Examiner.DiffSnapshots(id, live)
    local s = Snapshots[id]
    if not s then return nil, "missing snapshot" end
    local ok, copy = pcall(function() return deepCopy(live) end)
    if not ok then return nil, "failed to copy live" end
    local diffs = tableDiff(s.data, copy)
    return diffs
end

-- Helper: produce centered header bar text
-- #{examHeader}
-- Internal: build a centered header for reports
local function examHeader(title)
    local width = 93
    local pad = math.max(0, math.floor((width - #title) / 2))
    local line = string.rep("-", width)
    local centered = string.rep(" ", pad) .. title
    return table.concat({line, centered, line}, "\n")
end

-- Extract modules/files from traceback (filter for src/)
-- #{moduleTracePath}
-- Internal: extract project `src/` paths from a traceback
local function moduleTracePath(tb)
    if type(tb) ~= "string" then return nil end
    local result = {}
    for line in tb:gmatch("[^\n]+") do
        local file, ln = line:match("([^:]+):(%d+):")
        if file and file:match("src/") then
            result[#result+1] = string.format("%s:%s", file, ln)
        end
    end
    return result
end

-- Format examine report
-- #ex-report
-- #{Report}
-- Public: format a detailed examine report for `target`
-- #core
function Examiner.Report(target, unexpected, opts)
    opts = opts or {}
    local tb = debug.traceback("", 3)
    local modules = moduleTracePath(tb) or {}
    local header = examHeader("EXAMINER")
    local lines = {header}
    table.insert(lines, string.format("[Source]: %s", (opts.source or "<unknown>")))
    table.insert(lines, string.format("[TracePath]: %s", table.concat(modules, " -> ")))
    table.insert(lines, string.format("[Target]: %s", type(target)))
    if unexpected then
        table.insert(lines, string.format("[Unexpected]: %s", tostring(unexpected)))
    end
    -- deep inspect summary for some types
    if type(target) == "table" then
        table.insert(lines, "[Deep Inspect]:")
        local n = 0
        for k,v in pairs(target) do
            n = n + 1
            if n > 20 then break end
            table.insert(lines, string.format("    - %s: %s", tostring(k), type(v)))
        end
    elseif HAS_ROBLOX and typeof(target) == "Instance" then
        table.insert(lines, string.format("[Instance]: %s (%s)", target.Name or "", target.ClassName or ""))
    end
    -- snapshot/diff if available
    if opts.snapshotId then
        local diffs = Examiner.DiffSnapshots(opts.snapshotId, target)
        if diffs and #diffs > 0 then
            table.insert(lines, "[Diff]:")
            for _,d in ipairs(diffs) do table.insert(lines, "    " .. d) end
        else
            table.insert(lines, "[Diff]: No differences detected")
        end
    end
    if opts.showMissingCatcher then
        table.insert(lines, "The error catcher wasn't used.")
    end
    table.insert(lines, string.rep("-", 93))
    return table.concat(lines, "\n")
end

-- Informer: promise-like wrapper for operations
local Informer = {}
Informer.__index = Informer

-- #{makeInformerRecord}
-- Internal: create an Informer record (backing object)
local function makeInformerRecord(fn, ctx)
    local record = setmetatable({ fn = fn, ctx = ctx, caught = false, final = false, ran = false, lastErr = nil }, Informer)
    return record
end

-- #ex-informer
-- #{Informer.new}
-- Method: create and run an Informer for `fn`
-- #informer
function Informer:new(fn, ctx)
    local self = makeInformerRecord(fn, ctx)
    -- run immediately in protected call
    task.spawn(function()
        local ok, res = pcall(function() return fn() end)
        self.ran = true
        if not ok then
            self.lastErr = res
            -- attach to persistent store
            Informers[#Informers+1] = self
            -- wait a short time to see if catcher attached
            task.delay(0.05, function()
                if not self.caught and not self.final then
                    -- warn about missing catcher
                    if ctx and ctx.logger and ctx.logger.warn then
                        ctx.logger:warn("The error catcher wasn't used.")
                    else
                        print("The error catcher wasn't used.")
                    end
                end
            end)
        end
    end)
    return self
end

-- #{Informer.catch}
-- Method: attach an error catcher to the Informer
function Informer:catch(fn)
    if type(fn) == "function" then
        self.caught = true
        pcall(fn, self.lastErr)
    end
    return self
end

-- #{Informer.finally}
-- Method: attach a finalizer to run after the Informer
function Informer:finally(fn)
    if type(fn) == "function" then
        self.final = true
        pcall(fn)
    end
    return self
end

-- #{Informer.Retry}
-- Method: retry the Informer's function by creating a new Informer
function Informer:Retry()
    if type(self.fn) == "function" then
        return Informer:new(self.fn, self.ctx)
    end
end

-- Public: create an Informer from a function
-- #{Informer}
-- Public: convenience factory to create an Informer
function Examiner.Informer(fn, ctx)
    return Informer:new(fn, ctx)
end

-- Bind a Part's color to a logger Signal: expects a logger with .Signal (Signal:Connect)
-- #ex-bindpart
-- #{BindPartToLogger}
-- Public: bind a Part's color to logger Signal events
function Examiner.BindPartToLogger(part, logger, map)
    if not HAS_ROBLOX or typeof(part) ~= "Instance" or not logger or not logger.Signal then return end
    map = map or { info = Color3.fromRGB(200,200,200), warn = Color3.fromRGB(255,180,0), error = Color3.fromRGB(220,40,40) }
    logger.Signal:Connect(function(level, message)
        pcall(function()
            local c = map[level] or map.info
            if part and part:IsA("BasePart") then
                part.Color = c
            end
        end)
    end)
end

-- Simple observer: poll a global variable and call callback on change
-- #ex-observe
-- #{ObserveVariable}
-- Public: poll a global variable and call `callback` on change
-- #reactive
function Examiner.ObserveVariable(name, callback, interval)
    if not name or type(callback) ~= "function" then return end
    local int = tonumber(interval) or 0.5
    if VarObservers[name] then return end
    local current = _G[name]
    local running = true
    local handle = task.spawn(function()
        while running do
            task.wait(int)
            local now = _G[name]
            if now ~= current then
                pcall(callback, current, now)
                current = now
            end
        end
    end)
    VarObservers[name] = { stop = function() running = false end }
end

-- #ex-unobserve
-- #{UnobserveVariable}
-- Public: stop observing a previously observed global variable
function Examiner.UnobserveVariable(name)
    local rec = VarObservers[name]
    if rec and rec.stop then pcall(rec.stop) end
    VarObservers[name] = nil
end

-- Inject a value into a table via path (e.g., {"a","b",3})
-- #ex-inject
-- #{Inject}
-- Public: inject `value` into `target` following `path` (array keys)
function Examiner.Inject(target, path, value)
    if type(path) ~= "table" or #path == 0 then return false end
    local cur = target
    for i=1,#path-1 do
        local k = path[i]
        if type(cur) ~= "table" then return false end
        cur = cur[k]
    end
    if type(cur) == "table" then
        cur[path[#path]] = value
        return true
    end
    return false
end

-- Pipe middleware for Examine reports
-- #ex-pipe
-- #{pipe}
-- Public: register a middleware pipe to transform reports
function Examiner.pipe(fn)
    if type(fn) == "function" then Pipes[#Pipes+1] = fn end
end

-- #{applyPipes}
-- Internal: apply registered pipes to `report`
local function applyPipes(report)
    for _,p in ipairs(Pipes) do
        local ok, res = pcall(p, report)
        if ok and type(res) == "string" then report = res end
    end
    return report
end

-- Convert a report to JSON if possible
-- #ex-json
-- #{ReportToJSON}
-- Public: attempt to encode a report to JSON (uses HttpService if available)
function Examiner.ReportToJSON(report)
    if HttpService and HttpService.JSONEncode then
        local ok, js = pcall(function() return HttpService:JSONEncode({ report = report }) end)
        if ok then return js end
    end
    return nil
end

-- WatchRequires: API to register when a module is required (manual instrument)
-- #{RecordRequire}
-- Public: notify watchers that a module was required
-- #requires
function Examiner.RecordRequire(moduleName, by)
    local list = RequireWatchers[moduleName]
    if list then
        for _,cb in ipairs(list) do pcall(cb, moduleName, by) end
    end
end

-- #{WatchRequire}
-- Public: subscribe to manual require notifications for `moduleName`
function Examiner.WatchRequire(moduleName, cb)
    RequireWatchers[moduleName] = RequireWatchers[moduleName] or {}
    table.insert(RequireWatchers[moduleName], cb)
end

-- Small helper for printing/storing examine output (consumer can subscribe)
Examiner.Signal = { _c = {} }
-- #{Signal.Connect}
-- Public: connect a subscriber to the Examiner signal
function Examiner.Signal:Connect(fn)
    table.insert(self._c, fn)
    return { Disconnect = function() end }
end
-- #{Signal.Fire}
-- Public: fire the Examiner signal to all subscribers
function Examiner.Signal:Fire(...) for _,c in ipairs(self._c) do pcall(c, ...) end end

-- Main API: Examine a target and optionally snapshot/diff
-- #ex-examine
-- #{Examine}
-- Public: produce, publish, and return an examine report for `target`
function Examiner.Examine(target, unexpected, opts)
    opts = opts or {}
    local report = Examiner.Report(target, unexpected, opts)
    report = applyPipes(report)
    -- publish
    Examiner.Signal:Fire(report, target, opts)
    -- return object with helper methods (Retry, toJSON, snapshot)
    local ctx = {}
    -- #context
    function ctx:toJSON()
        return Examiner.ReportToJSON(report)
    end
    function ctx:snapshot()
        local id = Examiner.Snapshot(target, { note = opts.note })
        return id
    end
    function ctx:retry(func)
        if type(func) == "function" then
            return Examiner.Informer(func, { logger = opts.logger })
        end
    end
    return report, ctx
end

-- Small convenience: examine and print via a logger instance if provided
-- #ex-logger
-- #{ExamineWithLogger}
-- Public: convenience: examine and print via provided `logger`
function Examiner.ExamineWithLogger(logger, target, unexpected, opts)
    local r, ctx = Examiner.Examine(target, unexpected, opts)
    if logger and logger.info then pcall(logger.info, logger, r) else print(r) end
    return r, ctx
end

-- Export
return Examiner
---------------------------------------------------------------------------------------------
--                                         EXAMINER                                        --
---------------------------------------------------------------------------------------------
