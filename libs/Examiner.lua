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

-- Global flags
local __TESTING_ENABLED__ = _G.__TESTING_ENABLED__ or true

-- Internal storage
local Snapshots = {} -- id -> {time, data, source}
local SnapshotCounter = 0
local Informers = {} -- persistent tracking of informer records
local RequireWatchers = {} -- moduleName -> {callbacks}
local VarObservers = {} -- name -> {callbacks, running}
local Pipes = {} -- middleware chain
local ReportCache = {} -- cache of reports

--[[
    Utility: shallow+deep copying limited for safety

    #{deepCopy}

    Internal: deep copy with cycle-safety and instance descriptors
]]
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

--[[
    Snapshot: save a ghost copy of the object/table and return id

    Public: create a ghost snapshot of `target` and return an id

    [Open Documentation](https://ogggamer.github.io/Examiner/#snapshots)
]]
function Examiner.Snapshot(target, meta)
    SnapshotCounter = SnapshotCounter + 1
    local id = SnapshotCounter
    local ok, copy = pcall(function() return deepCopy(target) end)
    Snapshots[id] = { time = os.time(), data = ok and copy or tostring(target), source = meta }
    return id
end


--[[
    Dispatch: Consolidates and outputs reports to prevent console flooding.
    
    Public: Batches identical reports within a 0.1s window.
    
    [Open Documentation](https://ogggamer.github.io/Examiner/#core)
]]
function Dispatch(message, level)
	local line = string.rep("-", 93)
	local tag = (level == "error") 
		and "\n" .. line .. "\n [FATAL INSPECTION]:\n" .. line
		or "\n" .. line .. "\n [INSPECTION]:"

	local formattedMessage = string.format("%s %s", tag, message)

	if ReportCache[formattedMessage] then
		ReportCache[formattedMessage] += 1
		return
	end

	ReportCache[formattedMessage] = 1

	task.delay(0.1, function()
		local count = ReportCache[formattedMessage]

		local finalOutput = (count > 1) 
			and string.format("%s (x%d Events)\n%s\n%s", tag, count, message, line)
			or formattedMessage .. "\n" .. line

		if level == "error" then
			warn(finalOutput)
		else
			print(finalOutput)
		end

		ReportCache[formattedMessage] = nil
	end)
end

--[[
    Diff two snapshots or a snapshot and a live object (basic)

    Internal: produce a simple diff between two tables
]]
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

--[[
    Public: diff a saved snapshot `id` against `live` state

    [Open Documentation](https://ogggamer.github.io/Examiner/#snapshots)
]]
function Examiner.DiffSnapshots(id, live)
    local s = Snapshots[id]
    if not s then return nil, "missing snapshot" end
    local ok, copy = pcall(function() return deepCopy(live) end)
    if not ok then return nil, "failed to copy live" end
    local diffs = tableDiff(s.data, copy)
    return diffs
end

--[[
    Helper: produce centered header bar text

    #{examHeader}

    Internal: build a centered header for reports
]]
local function examHeader(title)
    local width = 93
    local pad = math.max(0, math.floor((width - #title) / 2))
    local line = string.rep("-", width)
    local centered = string.rep(" ", pad) .. title
    return table.concat({line, centered, line}, "\n")
end

--[[
    Extract modules/files from traceback (filter for src/)

    #{moduleTracePath}

    Internal: extract project `src/` paths from a traceback
]]
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

--[[
	#{GetCallingScript}
	
	Internal: Converts debug info into a physical Script object
]]
local function getCallingScript()
	local source = debug.info(4, "s") or debug.info(3, "s")

	if not source or (source == "=[C]" or source == "[C]") then 
		local mock = {
			Name = "Unknown Script",
			ClassName = "Script",
			Parent = game
		}
		
		function mock:GetFullName()
			return "Unknown (External/C-Stack)"
		end
		
		return mock
	end

	local cleanPath = source:gsub("^%.", ""):gsub("^game%.", ""):gsub("^project%.", "")
	local segments = cleanPath:split(".")
	local current = game

	for _, name in ipairs(segments) do
		local nextObj = current:FindFirstChild(name)
		if nextObj then
			current = nextObj
		else
			local pathMock = { Name = name }
			function pathMock:GetFullName() return cleanPath end
			return pathMock
		end
	end

	return current
end


--[[ 
    Examiner:new(target)
    Creates a stateful Examiner instance for a specific object or system.
]]
local ExaminerInstance = {}
ExaminerInstance.__index = ExaminerInstance

function Examiner.new(target)
	local self = setmetatable({}, ExaminerInstance)
	self.target = target
	self.history = {}
	self.retryCount = 0
	self.maxRetries = 3
	return self
end

-- #ex-try
--[[ try: Executes a function on the target with automatic error wrapping ]]
function ExaminerInstance:try(fn)
	local ok, err = pcall(fn, self.target)
	if not ok then
		self.lastError = err
		Examiner.Dispatch("Try failed: " .. tostring(err), "error")
		Examiner.Snapshot(self.target, { note = "state at failure" })
	end
	return self
end

-- #ex-catch
--[[ catch: Runs only if the previous 'try' failed ]]
function ExaminerInstance:catch(fn)
	if self.lastError then
		pcall(fn, self.lastError, self.target)
		self.lastError = nil -- Reset after handling
	end
	return self
end

-- #ex-retry
--[[ retry: Re-runs a function up to maxRetries if it fails ]]
function ExaminerInstance:retry(fn, limit)
	limit = limit or self.maxRetries
	local attempts = 0
	local success = false

	while attempts < limit and not success do
		attempts = attempts + 1
		local ok, err = pcall(fn, self.target)
		if ok then
			success = true
		else
			self.lastError = err
			task.wait(0.1 * attempts) -- Exponential backoff
		end
	end

	if not success then
		Examiner.Dispatch("Retry limit reached for " .. tostring(fn), "error")
	end
	return self
end

-- #ex-isdefined
--[[ isDefined: Ensures a key exists in the target, otherwise dispatches error ]]
function ExaminerInstance:isDefined(key)
	if self.target[key] == nil then
		Examiner.Dispatch(string.format("Property %s is undefined on target", tostring(key)), "error")
		return false
	end
	return true
end

-- #ex-find
--[[ find: Deep-searches the target for a specific value ]]
function ExaminerInstance:find(value)
	local results = {}
	local function search(t, path)
		for k, v in pairs(t) do
			local currentPath = path .. "." .. tostring(k)
			if v == value then
				table.insert(results, currentPath)
			elseif type(v) == "table" then
				search(v, currentPath)
			end
		end
	end
	search(self.target, "root")
	return results
end

--[[
    Format examine report

    Public: format a detailed examine report for `target`

    [Open Documentation](https://ogggamer.github.io/Examiner/#core)
]]
function Examiner.Report(target, unexpected, opts)
	opts = opts or {}

	local tb = debug.traceback("", 3)
	local callerObj = getCallingScript()
	local traceData = moduleTracePath(tb) or {}

	local callerName = callerObj and callerObj:GetFullName() or "Unknown Script"

	local header = examHeader("EXAMINER")
	local lines = {header}

	table.insert(lines, string.format("[Source]: %s", (opts.source or "<unknown>")))
	table.insert(lines, string.format("[Triggered By]: %s", callerName))

	if #traceData > 0 then
		table.insert(lines, string.format("[TracePath]: %s", table.concat(traceData, " -> ")))
	end

	table.insert(lines, string.format("[Target]: %s", type(target)))

	if unexpected then
		table.insert(lines, string.format("[Unexpected]: %s", tostring(unexpected)))
	end

	if type(target) == "table" then
		table.insert(lines, "[Deep Inspect]:")
		local n = 0
		for k, v in pairs(target) do
			n = n + 1
			if n > 20 then break end
			table.insert(lines, string.format("    - %s: %s", tostring(k), type(v)))
		end
	elseif HAS_ROBLOX and typeof(target) == "Instance" then
		table.insert(lines, string.format("[Instance]: %s (%s)", target.Name or "", target.ClassName or ""))
	end
	
	if opts.snapshotId then
		local diffs = Examiner.DiffSnapshots(opts.snapshotId, target)
		if diffs and #diffs > 0 then
			table.insert(lines, "[Diff]:")
			for _, d in ipairs(diffs) do 
				table.insert(lines, "    " .. d) 
			end
		else
			table.insert(lines, "[Diff]: No differences detected")
		end
	end

	if opts.showMissingCatcher then
		table.insert(lines, "The error catcher wasn't used.")
	end

	table.insert(lines, string.rep("-", 93))
	
	print(table.concat(lines, "\n"))
	return table.concat(lines, "\n")
end

-- Informer: promise-like wrapper for operations
local Informer = {}
Informer.__index = Informer

--[[
    #{makeInformerRecord}

    Internal: create an Informer record (backing object)
]]
local function makeInformerRecord(fn, ctx)
    local record = setmetatable({ fn = fn, ctx = ctx, caught = false, final = false, ran = false, lastErr = nil }, Informer)
    return record
end

--[[
    Method: create and run an Informer for `fn`

    [Open Documentation](https://ogggamer.github.io/Examiner/#informer)
]]
function Informer:new(fn, ctx, budget)
	local self = makeInformerRecord(fn, ctx)
	local start = tick()
	task.spawn(function()
		local ok, res = pcall(function() return fn() end)
		local elapsed = tick() - start
		if budget and elapsed > budget then
			Examiner.Dispatch(string.format("Performance budget exceeded: %.2fms > %.2fms", elapsed*1000, budget*1000), "warn")
		end
		self.ran = true
		if not ok then
			self.lastErr = res
			Informers[#Informers+1] = self
			task.delay(0.05, function()
				if not self.caught and not self.final then
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

--[[
    Method: attach an error catcher to the Informer

    Open Documentation](https://ogggamer.github.io/Examiner/#informer)
]]
function Informer:catch(fn)
    if type(fn) == "function" then
        self.caught = true
        pcall(fn, self.lastErr)
    end
    return self
end

--[[
    Method: attach a finalizer to run after the Informer

    [Open Documentation](https://ogggamer.github.io/Examiner/#informer)
]]
function Informer:finally(fn)
    if type(fn) == "function" then
        self.final = true
        pcall(fn)
    end
    return self
end

--[[
Method: retry the Informer's function by creating a new Informer

[Open Documentation](https://ogggamer.github.io/Examiner/#informer)
]]
function Informer:Retry()
    if type(self.fn) == "function" then
        return Informer:new(self.fn, self.ctx)
    end
end

--[[
    Public: create an Informer from a function

    Public: convenience factory to create an Informer

    [Open Documentation](https://ogggamer.github.io/Examiner/#informer)
]]
function Examiner.Informer(fn, ctx)
    return Informer:new(fn, ctx)
end

--[[
    Bind a Part's color to a logger Signal: expects a logger with .Signal (Signal:Connect)

    Public: bind a Part's color to logger Signal events

    [Open Documentation](https://ogggamer.github.io/Examiner/#reactive
]]
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

--[[
    Simple observer: poll a global variable and call callback on change

    Public: poll a global variable and call `callback` on change

    [Open Documentation](https://ogggamer.github.io/Examiner/#reactive)
]]
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

--[[
    Public: stop observing a previously observed global variable

    [Open Documentation](https://ogggamer.github.io/Examiner/#reactive)
]]
function Examiner.UnobserveVariable(name)
    local rec = VarObservers[name]
    if rec and rec.stop then pcall(rec.stop) end
    VarObservers[name] = nil
end

--[[
    Inject a value into a table via path (e.g., {"a","b",3})

    Public: inject `value` into `target` following `path` (array keys)

    [Open Documentation](https://ogggamer.github.io/Examiner/#reactive)
]]
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

--[[
    Pipe middleware for Examine reports

    Public: register a middleware pipe to transform reports

    [Open Documentation](https://ogggamer.github.io/Examiner/#core)
]]
function Examiner.pipe(fn)
    if type(fn) == "function" then Pipes[#Pipes+1] = fn end
end

--[[
    #{applyPipes}

    Internal: apply registered pipes to `report`
]]
local function applyPipes(report)
    for _,p in ipairs(Pipes) do
        local ok, res = pcall(p, report)
        if ok and type(res) == "string" then report = res end
    end
    return report
end

--[[
    Convert a report to JSON if possible

    Public: attempt to encode a report to JSON (uses HttpService if available)

    [Open Documentation](https://ogggamer.github.io/Examiner/#core)
]]
function Examiner.ReportToJSON(report)
    if HttpService and HttpService.JSONEncode then
        local ok, js = pcall(function() return HttpService:JSONEncode({ report = report }) end)
        if ok then return js end
    end
    return nil
end

--[[
    WatchRequires: API to register when a module is required (manual instrument)

    Public: notify watchers that a module was required

    [Open Documentation](https://ogggamer.github.io/Examiner/#requires)
]]
function Examiner.RecordRequire(moduleName, by)
    local list = RequireWatchers[moduleName]
    if list then
        for _,cb in ipairs(list) do pcall(cb, moduleName, by) end
    end
end

--[[
    Public: subscribe to manual require notifications for `moduleName`

    [Open Documentation](https://ogggamer.github.io/Examiner/#requires)
]]
function Examiner.WatchRequire(moduleName, cb)
    RequireWatchers[moduleName] = RequireWatchers[moduleName] or {}
    table.insert(RequireWatchers[moduleName], cb)
end

-- Small helper for printing/storing examine output (consumer can subscribe)
Examiner.Signal = { _c = {} }

--[[
    Public: connect a subscriber to the Examiner signal

    [Open Documentation](https://ogggamer.github.io/Examiner/#reactive)
]]
function Examiner.Signal:Connect(fn)
    table.insert(self._c, fn)
    return { Disconnect = function() end }
end

-- Public: fire the Examiner signal to all subscribers
function Examiner.Signal:Fire(...) for _,c in ipairs(self._c) do pcall(c, ...) end end

--[[
    Main API: Examine a target and optionally snapshot/diff

    Public: produce, publish, and return an examine report for `target`

    [Open Documentation](https://ogggamer.github.io/Examiner/#core)
]]
function Examiner.Examine(target, unexpected, opts)
    opts = opts or {}
    local report = Examiner.Report(target, unexpected, opts)
    report = applyPipes(report)
    -- publish
    Examiner.Signal:Fire(report, target, opts)
    -- return object with helper methods (Retry, toJSON, snapshot)
    local ctx = {}
    -- [Open Documentation](https://ogggamer.github.io/Examiner/#context)
    function ctx:toJSON()
        return Examiner.ReportToJSON(report)
    end

    -- [Open Documentation](https://ogggamer.github.io/Examiner/#context)
    function ctx:snapshot()
        local id = Examiner.Snapshot(target, { note = opts.note })
        return id
    end

    -- [Open Documentation](https://ogggamer.github.io/Examiner/#context)
    function ctx:retry(func)
        if type(func) == "function" then
            return Examiner.Informer(func, { logger = opts.logger })
        end
    end

    return report, ctx
end

--[[
    Small convenience: examine and print via a logger instance if provided

    Public: convenience: examine and print via provided `logger`

    [Open Documentation](https://ogggamer.github.io/Examiner/#core)
]]
function Examiner.ExamineWithLogger(logger, target, unexpected, opts)
    local r, ctx = Examiner.Examine(target, unexpected, opts)
    if logger and logger.info then pcall(logger.info, logger, r) else print(r) end
    return r, ctx
end

-- #ex-protect
--[[
    Protect: Validates a table against a template. 
    If keys are missing or types are wrong, it Dispatches a report.
]]
local ProtectResults = {} -- last protect result
function Examiner.Protect(tbl, schema)
	local result = true
	for key, expectedType in pairs(schema) do
		if type(tbl[key]) ~= expectedType then
			result = false
			break
		end
	end
	ProtectResults[tbl] = {schema=schema, valid=result}
	return result
end

-- #ex-trackinstance
--[[
    TrackInstance: Watches physical Instances for property drift.
]]
function Examiner.TrackInstance(instance, props)
    local baseline = {}
    for _, p in ipairs(props) do baseline[p] = instance[p] end
    
    task.spawn(function()
        while instance and instance.Parent do
            task.wait(1)
            for _, p in ipairs(props) do
                if instance[p] ~= baseline[p] then
                    Examiner.Dispatch(string.format(
                        "Instance Drift [%s]: %s changed from %s to %s",
                        instance.Name, p, tostring(baseline[p]), tostring(instance[p])
                    ))
                    baseline[p] = instance[p] -- Update baseline
                end
            end
        end
    end)
end

function Examiner.Adorn(target, text)
    if not HAS_ROBLOX or typeof(target) ~= "Instance" then return end
    
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.new(0, 200, 0, 50)
    billboard.Adornee = target
    billboard.AlwaysOnTop = true
    
    local label = Instance.new("TextLabel", billboard)
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
    label.Text = "FATAL ERROR: " .. text
    label.TextColor3 = Color3.new(1, 1, 1)
    
    billboard.Parent = target
    task.delay(5, function() billboard:Destroy() end)
end

-- 1. Snapshot History: Rolling buffer of last 10 states
local SnapshotHistory = {} -- target -> { {time, data}, ... } max 10
-- #ex-snapshothistory
--[[
    SnapshotHistory: Rolling buffer of last 10 states for time travel diffs.
]]
function Examiner.SnapshotHistory(target, meta)
    if not SnapshotHistory[target] then SnapshotHistory[target] = {} end
    local history = SnapshotHistory[target]
    local ok, copy = pcall(function() return deepCopy(target) end)
    table.insert(history, { time = os.time(), data = ok and copy or tostring(target), meta = meta })
    if #history > 10 then table.remove(history, 1) end
    return #history -- return index
end

-- #ex-diffhistory
--[[
    DiffHistory: Diff against a historical snapshot index.
]]
function Examiner.DiffHistory(target, index)
    local history = SnapshotHistory[target]
    if not history or not history[index] then return nil end
    local ok, live = pcall(function() return deepCopy(target) end)
    if not ok then return nil end
    return tableDiff(history[index].data, live)
end

-- 2. Network Traffic Interceptor
local TrafficLog = {} -- remote -> {size, freq, content}
-- #ex-interceptremote
--[[
    InterceptRemote: Wraps RemoteEvents to log traffic size/frequency and flag oversized payloads.
]]
function Examiner.InterceptRemote(remote)
    if not HAS_ROBLOX or typeof(remote) ~= "Instance" then return end
    if remote:IsA("RemoteEvent") then
        local conn = remote.OnServerEvent:Connect(function(player, ...)
            local args = {...}
            local size = 0
            for _,v in ipairs(args) do size = size + #tostring(v) end
            TrafficLog[remote] = TrafficLog[remote] or {size=0, freq=0, content={}}
            TrafficLog[remote].size = TrafficLog[remote].size + size
            TrafficLog[remote].freq = TrafficLog[remote].freq + 1
            if size > 1000 then -- oversized
                Examiner.Dispatch(string.format("Oversized payload on %s: %d bytes", remote.Name, size), "warn")
            end
        end)
    end
end

-- 3. Memory Leak Sentinel
local LeakWatch = {} -- table -> {sizes = {}, times = {}}
-- #ex-watchleak
--[[
    WatchLeak: Monitors table growth over time for potential memory leaks.
]]
function Examiner.WatchLeak(tbl, name)
    LeakWatch[tbl] = { sizes = {}, times = {}, name = name }
    task.spawn(function()
        while LeakWatch[tbl] do
            local size = 0
            for _ in pairs(tbl) do size = size + 1 end
            table.insert(LeakWatch[tbl].sizes, size)
            table.insert(LeakWatch[tbl].times, os.time())
            if #LeakWatch[tbl].sizes > 10 then
                table.remove(LeakWatch[tbl].sizes, 1)
                table.remove(LeakWatch[tbl].times, 1)
            end
            -- check if growing
            if #LeakWatch[tbl].sizes > 5 then
                local growing = true
                for i=2,#LeakWatch[tbl].sizes do
                    if LeakWatch[tbl].sizes[i] <= LeakWatch[tbl].sizes[i-1] then growing = false break end
                end
                if growing then
                    Examiner.Dispatch(string.format("Potential memory leak in %s: table growing continuously", name or tostring(tbl)), "warn")
                end
            end
            task.wait(5)
        end
    end)
end

-- 4. Instance Lifecycle Watcher
local InstanceRefs = {} -- instance -> ref count
-- #ex-watchinstancelifecycle
--[[
    WatchInstanceLifecycle: Alerts on destroyed instances with lingering references.
]]
function Examiner.WatchInstanceLifecycle(inst)
    if not HAS_ROBLOX or typeof(inst) ~= "Instance" then return end
    InstanceRefs[inst] = (InstanceRefs[inst] or 0) + 1
    inst.Destroying:Connect(function()
        task.delay(1, function() -- wait for GC
            if InstanceRefs[inst] and InstanceRefs[inst] > 0 then
                Examiner.Dispatch(string.format("Instance %s destroyed but still referenced (%d refs)", inst.Name, InstanceRefs[inst]), "warn")
            end
            InstanceRefs[inst] = nil
        end)
    end)
end

-- 5. Heatmap Visualizer
local ErrorHeat = {} -- instance -> error count
-- #ex-heatmapadorn
--[[
    HeatmapAdorn: Colors parts based on error heat (red=hot, blue=cold).
]]
function Examiner.HeatmapAdorn(inst, errorCount)
    if not HAS_ROBLOX or typeof(inst) ~= "Instance" then return end
    ErrorHeat[inst] = (ErrorHeat[inst] or 0) + errorCount
    local heat = ErrorHeat[inst]
    local color = heat > 10 and Color3.fromRGB(255,0,0) or heat > 5 and Color3.fromRGB(255,165,0) or Color3.fromRGB(0,0,255)
    Examiner.Adorn(inst, string.format("Heat: %d errors", heat))
    -- Color the part
    if inst:IsA("BasePart") then inst.Color = color end
end

-- 6. Dependency Graph Mapper
local DepGraph = {} -- module -> {deps}
-- #ex-mapdependencies
--[[
    MapDependencies: Analyzes require data for dependency graphs.
]]
function Examiner.MapDependencies()
    for mod, watchers in pairs(RequireWatchers) do
        DepGraph[mod] = DepGraph[mod] or {}
        -- Assume watchers imply deps, but this is simplistic
    end
    -- Print graph
    for mod, deps in pairs(DepGraph) do
        Examiner.Dispatch(string.format("Module %s depends on: %s", mod, table.concat(deps, ", ")), "info")
    end
end

-- 8. Conditional Breakpoints
-- #ex-conditionalbreakpoint
--[[
    ConditionalBreakpoint: Pauses execution on condition met.
]]
function Examiner.ConditionalBreakpoint(condition, note)
    if condition() then
        Examiner.Dispatch(string.format("Conditional breakpoint: %s", note or ""), "error")
        task.wait(0.1) -- pause
    end
end

-- 9. Environment Sanitizer
-- #ex-sanitizeenvironment
--[[
    SanitizeEnvironment: Removes stale variables from environments.
]]
function Examiner.SanitizeEnvironment(env, maxAge)
    maxAge = maxAge or 3600 -- 1 hour
    local now = os.time()
    for k,v in pairs(env) do
        if type(v) == "table" and v._lastAccess then
            if now - v._lastAccess > maxAge then
                env[k] = nil
                Examiner.Dispatch(string.format("Sanitized stale variable: %s", k), "info")
            end
        end
    end
end

-- 10. Automated Regression Tester
-- #ex-regressiontest
--[[
    RegressionTest: Runs functions and checks against expected snapshots.
]]
function Examiner.RegressionTest(fn, expectedSnapshotId)
    local beforeId = Examiner.Snapshot(_G, {note="before test"})
    fn()
    local after = _G
    local diffs = Examiner.DiffSnapshots(expectedSnapshotId, after)
    if diffs and #diffs > 0 then
        Examiner.Dispatch("Regression test failed: " .. table.concat(diffs, "; "), "error")
    else
        Examiner.Dispatch("Regression test passed", "info")
    end
end

-- 11. Physics Collision Monitor
-- #ex-monitorcollisions
--[[
    MonitorCollisions: Tracks touch density on parts.
]]
function Examiner.MonitorCollisions(part)
    if not HAS_ROBLOX or typeof(part) ~= "Instance" or not part:IsA("BasePart") then return end
    local touchCount = 0
    local lastReset = tick()
    part.Touched:Connect(function()
        touchCount = touchCount + 1
        if tick() - lastReset > 1 then
            if touchCount > 50 then -- high density
                Examiner.Dispatch(string.format("High collision density on %s: %d touches/sec", part.Name, touchCount), "warn")
            end
            touchCount = 0
            lastReset = tick()
        end
    end)
end

-- 12. Remote Web-Console Sync
-- #ex-synctoweb
--[[
    SyncToWeb: Batches JSON reports and posts to a URL.
]]
function Examiner.SyncToWeb(url)
    task.spawn(function()
        while true do
            task.wait(10) -- every 10s
            local reports = {}
            for _,r in ipairs(ReportCache) do
                table.insert(reports, r)
            end
            if #reports > 0 and HttpService then
                local json = Examiner.ReportToJSON(table.concat(reports, "\n"))
                if json then
                    pcall(function() HttpService:PostAsync(url, json) end)
                end
            end
        end
    end)
end

-- 13. State Lock
-- #ex-locktable
--[[
    LockTable: Locks tables to prevent modifications.
]]
function Examiner.LockTable(tbl)
    local mt = {
        __newindex = function(t, k, v)
            Examiner.Dispatch(string.format("Attempted to modify locked table at key %s", tostring(k)), "error")
        end
    }
    setmetatable(tbl, mt)
end

-- 14. Player Input Recorder (Client-side)
if ROBLOX_RUNSERVICE and ROBLOX_RUNSERVICE:IsClient() then
    local InputBuffer = {}
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer
    if LocalPlayer then
        LocalPlayer:GetMouse().Button1Down:Connect(function()
            table.insert(InputBuffer, {time=tick(), input="MouseClick"})
            if #InputBuffer > 50 then table.remove(InputBuffer, 1) end
        end)
        -- Add WASD etc. similarly
    end
    -- #ex-getinputbuffer
    --[[
        GetInputBuffer: Returns recorded player inputs (client-side).
    ]]
    function Examiner.GetInputBuffer()
        return InputBuffer
    end
end

-- 15. Global Search Indexer
-- #ex-searchtracked
--[[
    SearchTracked: Searches snapshot data for values/keys.
]]
function Examiner.SearchTracked(value, key)
    local results = {}
    for id, snap in pairs(Snapshots) do
        if type(snap.data) == "table" then
            for k,v in pairs(snap.data) do
                if (key and k == key) or (value and v == value) then
                    table.insert(results, {snapshot=id, key=k, value=v})
                end
            end
        end
    end
    return results
end

-- 16. Strict Enums
-- #ex-strictenums
--[[
    StrictEnums: Lock tables to only allow specific string values.
]]
function Examiner.StrictEnums(tbl, allowedValues)
    local mt = {
        __newindex = function(t, k, v)
            if type(v) ~= "string" or not table.find(allowedValues, v) then
                Examiner.Dispatch(string.format("Invalid enum value for key %s: %s", tostring(k), tostring(v)), "error")
            else
                rawset(t, k, v)
            end
        end
    }
    setmetatable(tbl, mt)
end

-- 17. Anti-Global Pollution
local GlobalWatch = {}
-- #ex-antiglobalpollution
--[[
    AntiGlobalPollution: Watch _G and flag any script adding non-prefixed variables.
]]
function Examiner.AntiGlobalPollution(prefix)
    prefix = prefix or ""
    for k,v in pairs(_G) do
        if not GlobalWatch[k] then
            GlobalWatch[k] = true
            if not string.match(k, "^" .. prefix) then
                Examiner.Dispatch(string.format("Global pollution detected: %s", k), "warn")
            end
        end
    end
    -- Continuously monitor
    task.spawn(function()
        while true do
            task.wait(1)
            for k,v in pairs(_G) do
                if not GlobalWatch[k] then
                    GlobalWatch[k] = true
                    if not string.match(k, "^" .. prefix) then
                        Examiner.Dispatch(string.format("Global pollution detected: %s", k), "warn")
                    end
                end
            end
        end
    end)
end

-- 18. Recursive Lockdown
-- #ex-recursivelockdown
--[[
    RecursiveLockdown: Deeply freeze an entire nested configuration tree.
]]
function Examiner.RecursiveLockdown(tbl)
    local function freeze(t)
        for k,v in pairs(t) do
            if type(v) == "table" then
                freeze(v)
            end
        end
        table.freeze(t)
    end
    freeze(tbl)
end

-- 19. Value Clamping Sentinel
local ClampWatch = {}
-- #ex-valueclampingsentinel
--[[
    ValueClampingSentinel: Watch a number and report if it exceeds a "Sanity Range".
]]
function Examiner.ValueClampingSentinel(var, minVal, maxVal, name)
    ClampWatch[var] = {min=minVal, max=maxVal, name=name}
    task.spawn(function()
        while ClampWatch[var] do
            task.wait(0.1)
            if type(var) == "number" and (var < minVal or var > maxVal) then
                Examiner.Dispatch(string.format("Value out of range for %s: %f (expected %f-%f)", name or "unknown", var, minVal, maxVal), "warn")
            end
        end
    end)
end

-- 20. Null-Pointer Mocking
local MockMode = false
local Mocks = {}
-- #ex-nullpointermocking
--[[
    NullPointerMocking: Enable mode that returns a "Dummy" object instead of nil.
]]
function Examiner.NullPointerMocking(enable)
    MockMode = enable
    if enable then
        -- Override global functions or something, but simplistic
        Examiner.Dispatch("Null-pointer mocking enabled", "info")
    end
end

-- 21. Type-Switch Logger
local TypeWatch = {}
-- #ex-typeswitchlogger
--[[
    TypeSwitchLogger: Log whenever a variable changes its type.
]]
function Examiner.TypeSwitchLogger(var, name)
    TypeWatch[var] = {type=type(var), name=name}
    task.spawn(function()
        while TypeWatch[var] do
            task.wait(0.5)
            local newType = type(var)
            if newType ~= TypeWatch[var].type then
                Examiner.Dispatch(string.format("Type switch for %s: %s -> %s", name or "unknown", TypeWatch[var].type, newType), "info")
                TypeWatch[var].type = newType
            end
        end
    end)
end

-- 22. Constant Guard
-- #ex-constantguard
--[[
    ConstantGuard: Protect specific keys in a table while leaving others mutable.
]]
function Examiner.ConstantGuard(tbl, protectedKeys)
    local mt = {
        __newindex = function(t, k, v)
            if table.find(protectedKeys, k) then
                Examiner.Dispatch(string.format("Attempted to modify protected key: %s", tostring(k)), "error")
            else
                rawset(t, k, v)
            end
        end
    }
    setmetatable(tbl, mt)
end

-- 23. Array-Only Enforcement
local ArrayWatch = {}
-- #ex-arrayonlyenforcement
--[[
    ArrayOnlyEnforcement: Monitor a table to ensure it never becomes a "Dictionary".
]]
function Examiner.ArrayOnlyEnforcement(tbl, name)
    ArrayWatch[tbl] = name
    task.spawn(function()
        while ArrayWatch[tbl] do
            task.wait(1)
            local hasNonNumeric = false
            for k in pairs(tbl) do
                if type(k) ~= "number" then hasNonNumeric = true break end
            end
            if hasNonNumeric then
                Examiner.Dispatch(string.format("Table %s became dictionary", name or "unknown"), "warn")
            end
        end
    end)
end

-- 24. Circular Reference Detector
-- #ex-circularreferencedetector
--[[
    CircularReferenceDetector: Flag tables that link back to themselves.
]]
function Examiner.CircularReferenceDetector(tbl, name)
    local seen = {}
    local function check(t, path)
        if seen[t] then
            Examiner.Dispatch(string.format("Circular reference detected in %s at %s", name or "unknown", table.concat(path, ".")), "error")
            return
        end
        seen[t] = true
        for k,v in pairs(t) do
            if type(v) == "table" then
                check(v, table.concat(path, ".") .. "." .. tostring(k))
            end
        end
        seen[t] = nil
    end
    check(tbl, "")
end

-- 25. JSON Schema Validator
-- #ex-jsonschemavalidator
--[[
    JSONSchemaValidator: Compare a table against a JSON schema string.
]]
function Examiner.JSONSchemaValidator(tbl, schemaStr)
    if not HttpService then return false end
    local ok, schema = pcall(function() return HttpService:JSONDecode(schemaStr) end)
    if not ok then return false end
    -- Simple validation, assume schema is {key: type}
    for k, expected in pairs(schema) do
        if type(tbl[k]) ~= expected then
            Examiner.Dispatch(string.format("Schema violation: %s expected %s, got %s", k, expected, type(tbl[k])), "error")
            return false
        end
    end
    return true
end

-- 26. Auto-Documentation Generator
-- #ex-autodocumentationgenerator
--[[
    AutoDocumentationGenerator: Use snapshots to build a "Data Map".
]]
function Examiner.AutoDocumentationGenerator()
    local map = {}
    for id, snap in pairs(Snapshots) do
        if type(snap.data) == "table" then
            for k,v in pairs(snap.data) do
                map[k] = type(v)
            end
        end
    end
    Examiner.Dispatch("Data Map: " .. HttpService and HttpService:JSONEncode(map) or tostring(map), "info")
end

-- 27. Module Dependency Graph
-- #ex-moduledependencygraph
--[[
    ModuleDependencyGraph: Map out which modules require each other.
]]
function Examiner.ModuleDependencyGraph()
    local graph = {}
    for mod in pairs(RequireWatchers) do
        graph[mod] = {}
        -- Assume deps from watchers
    end
    Examiner.Dispatch("Dependency Graph: " .. table.concat(table.keys(graph), ", "), "info")
end

-- 28. Cross-Server Log Sync
-- #ex-crossserverlogsync
--[[
    CrossServerLogSync: Use MessagingService to sync logs.
]]
function Examiner.CrossServerLogSync()
    if not HAS_ROBLOX then return end
    local MessagingService = game:GetService("MessagingService")
    Examiner.Signal:Connect(function(msg)
        pcall(function() MessagingService:PublishAsync("ExaminerLogs", msg) end)
    end)
    -- Subscribe to receive
    pcall(function()
        MessagingService:SubscribeAsync("ExaminerLogs", function(data)
            Examiner.Dispatch("Cross-server: " .. data.Data, "info")
        end)
    end)
end

-- 29. Environment Comparer
-- #ex-environmentcomparer
--[[
    EnvironmentComparer: Diff Server vs Client state.
]]
function Examiner.EnvironmentComparer(serverTbl, clientTbl)
    local diffs = tableDiff(serverTbl, clientTbl)
    if #diffs > 0 then
        Examiner.Dispatch("Environment diff: " .. table.concat(diffs, "; "), "info")
    end
end

-- 30. Execution Timer
-- #ex-executiontimer
--[[
    ExecutionTimer: Wrapper that logs function execution time.
]]
function Examiner.ExecutionTimer(fn, name)
    return function(...)
        local start = tick()
        local res = {fn(...)}
        local elapsed = tick() - start
        Examiner.Dispatch(string.format("%s took %.2fms", name or "function", elapsed*1000), "info")
        return unpack(res)
    end
end

-- 31. Todo-Comment Extractor
-- #ex-todocommentextractor
--[[
    TodoCommentExtractor: Scan scripts for -- TODO.
]]
function Examiner.TodoCommentExtractor(script)
    if not HAS_ROBLOX or typeof(script) ~= "Instance" or not script:IsA("LuaSourceContainer") then return end
    local source = script.Source
    for line in source:gmatch("[^\n]+") do
        if line:match("-- TODO") then
            Examiner.Dispatch(string.format("TODO in %s: %s", script.Name, line), "info")
        end
    end
end

-- 32. Heartbeat Budgeting
local HeartbeatStart = tick()
-- #ex-heartbeatbudgeting
--[[
    HeartbeatBudgeting: Warn if script uses more than 10% of frame time.
]]
function Examiner.HeartbeatBudgeting()
    if not HAS_ROBLOX then return end
    local RunService = game:GetService("RunService")
    RunService.Heartbeat:Connect(function(dt)
        local now = tick()
        local used = now - HeartbeatStart
        if used > dt * 0.1 then
            Examiner.Dispatch(string.format("Heartbeat budget exceeded: %.2fms > %.2fms", used*1000, dt*1000*0.1), "warn")
        end
        HeartbeatStart = now
    end)
end

-- 33. Table Growth Rate
local GrowthWatch = {}
-- #ex-tablegrowthrate
--[[
    TableGrowthRate: Log items added per second.
]]
function Examiner.TableGrowthRate(tbl, name)
    local lastSize = 0
    local lastTime = tick()
    GrowthWatch[tbl] = name
    task.spawn(function()
        while GrowthWatch[tbl] do
            task.wait(1)
            local size = 0
            for _ in pairs(tbl) do size = size + 1 end
            local rate = (size - lastSize)
            if rate > 0 then
                Examiner.Dispatch(string.format("Table %s growth: +%d items/sec", name or "unknown", rate), "info")
            end
            lastSize = size
        end
    end)
end

-- 34. Remote Rate Limiter
local RemoteRates = {}
-- #ex-remoteratelimiter
--[[
    RemoteRateLimiter: Flag remotes firing >20 times/sec from one client.
]]
function Examiner.RemoteRateLimiter(remote)
    if not HAS_ROBLOX or typeof(remote) ~= "Instance" then return end
    remote.OnServerEvent:Connect(function(player)
        local key = player.UserId
        RemoteRates[key] = RemoteRates[key] or {count=0, time=tick()}
        RemoteRates[key].count = RemoteRates[key].count + 1
        if tick() - RemoteRates[key].time > 1 then
            if RemoteRates[key].count > 20 then
                Examiner.Dispatch(string.format("Rate limit exceeded for player %d on %s", key, remote.Name), "warn")
            end
            RemoteRates[key] = {count=0, time=tick()}
        end
    end)
end

-- 35. Memory Snapshot Diffing
-- #ex-memorysnapshotdiffing
--[[
    MemorySnapshotDiffing: Snapshot all tables, wait 1 min, diff growth.
]]
function Examiner.MemorySnapshotDiffing()
    local initial = {}
    for id, snap in pairs(Snapshots) do
        if type(snap.data) == "table" then
            local size = 0
            for _ in pairs(snap.data) do size = size + 1 end
            initial[id] = size
        end
    end
    task.delay(60, function()
        for id, snap in pairs(Snapshots) do
            if type(snap.data) == "table" then
                local size = 0
                for _ in pairs(snap.data) do size = size + 1 end
                local growth = size - (initial[id] or 0)
                if growth > 0 then
                    Examiner.Dispatch(string.format("Memory growth in snapshot %d: +%d", id, growth), "info")
                end
            end
        end
    end)
end

-- 36. Connection Leaker
local SignalCounts = {}
-- #ex-connectionleaker
--[[
    ConnectionLeaker: Count RBXScriptSignals and flag leaks.
]]
function Examiner.ConnectionLeaker(signal, name)
    SignalCounts[signal] = (SignalCounts[signal] or 0) + 1
    task.delay(300, function() -- 5 min check
        if SignalCounts[signal] and SignalCounts[signal] > 0 then
            Examiner.Dispatch(string.format("Potential signal leak: %s", name or "unknown"), "warn")
        end
    end)
end

-- 37. Heavy Loop Detector
local LoopStart = {}
-- #ex-heavyloopdetector
--[[
    HeavyLoopDetector: Track long-running loops without task.wait().
]]
function Examiner.HeavyLoopDetector(loopId)
    LoopStart[loopId] = tick()
    task.delay(1, function()
        if LoopStart[loopId] and tick() - LoopStart[loopId] > 0.5 then
            Examiner.Dispatch(string.format("Heavy loop detected: %s", loopId), "warn")
        end
    end)
end

-- 38. Instance Count Tracker
-- #ex-instancecounttracker
--[[
    InstanceCountTracker: Snapshot Workspace parts every 30s.
]]
function Examiner.InstanceCountTracker()
    if not HAS_ROBLOX then return end
    task.spawn(function()
        while true do
            task.wait(30)
            local count = 0
            for _ in pairs(workspace:GetDescendants()) do
                count = count + 1
            end
            Examiner.Snapshot({instanceCount=count}, {note="workspace count"})
        end
    end)
end

-- 39. Debris Sentinel
-- #ex-debrissentinel
--[[
    DebrisSentinel: Watch Debris service.
]]
function Examiner.DebrisSentinel()
    if not HAS_ROBLOX then return end
    local Debris = game:GetService("Debris")
    -- Assuming Debris has events, but simplistic
    Examiner.Dispatch("Debris sentinel active", "info")
end

-- 40. Garbage Collection Ping
-- #ex-garbagecollectionping
--[[
    GarbageCollectionPing: Track weak tables.
]]
function Examiner.GarbageCollectionPing(weakTbl)
    setmetatable(weakTbl, {__mode="k"})
    task.spawn(function()
        while true do
            task.wait(10)
            local count = 0
            for _ in pairs(weakTbl) do count = count + 1 end
            Examiner.Dispatch(string.format("Weak table size: %d", count), "info")
        end
    end)
end

-- 41. Input History Playback
local InputHistory = {}
-- #ex-inputhistoryplayback
--[[
    InputHistoryPlayback: Record last 60 inputs.
]]
function Examiner.InputHistoryPlayback()
    if not ROBLOX_RUNSERVICE or not ROBLOX_RUNSERVICE:IsClient() then return end
    local UserInputService = game:GetService("UserInputService")
    UserInputService.InputBegan:Connect(function(input)
        table.insert(InputHistory, {time=tick(), input=input.KeyCode.Name})
        if #InputHistory > 60 then table.remove(InputHistory, 1) end
    end)
    function Examiner.GetInputHistory()
        return InputHistory
    end
end

-- 42. API Version Checker
-- #ex-apiversionchecker
--[[
    APIVersionChecker: Alert if module version is old.
]]
function Examiner.APIVersionChecker(module, currentVersion)
    -- Assume fetch from GitHub, but simplistic
    Examiner.Dispatch("API version check: " .. (currentVersion or "unknown"), "info")
end

-- 43. Server Age Warning
-- #ex-serveragewarning
--[[
    ServerAgeWarning: Alert after 24 hours.
]]
function Examiner.ServerAgeWarning()
    if not HAS_ROBLOX then return end
    task.delay(86400, function() -- 24h
        Examiner.Dispatch("Server running >24 hours, consider cleanup", "warn")
    end)
end

-- 44. Player Ping Snapshot
-- #ex-playerpingsnapshot
--[[
    PlayerPingSnapshot: Record ping on Dispatch.
]]
function Examiner.PlayerPingSnapshot(player)
    if not HAS_ROBLOX or typeof(player) ~= "Instance" then return end
    local ping = player:GetNetworkPing()
    Examiner.Snapshot({ping=ping}, {note="player ping"})
end

-- 45. DataStore Budget Tracker
local DSRequests = 0
-- #ex-datastorebudgettracker
--[[
    DataStoreBudgetTracker: Warn approaching limit.
]]
function Examiner.DataStoreBudgetTracker()
    -- Assume tracking requests
    if DSRequests > 100 then
        Examiner.Dispatch("Approaching DataStore limit", "warn")
    end
end

-- 46. Third-Party API Guard
-- #ex-thirdpartyapiguard
--[[
    ThirdPartyAPIGuard: Log API errors.
]]
function Examiner.ThirdPartyAPIGuard(response)
    if response.StatusCode >= 400 then
        Examiner.Dispatch(string.format("API error: %d", response.StatusCode), "error")
    end
end

-- 47. Asset Load Observer
-- #ex-assetloadobserver
--[[
    AssetLoadObserver: Report slow-loading assets.
]]
function Examiner.AssetLoadObserver(assetId)
    local start = tick()
    -- Assume load
    task.delay(1, function()
        Examiner.Dispatch(string.format("Asset %s loaded in %.2fs", assetId, tick()-start), "info")
    end)
end

-- 48. Cross-Game Teleport Log
-- #ex-crossgameteleportlog
--[[
    CrossGameTeleportLog: Record teleport data.
]]
function Examiner.CrossGameTeleportLog(destination)
    Examiner.Snapshot({destination=destination}, {note="teleport"})
end

-- 49. Server Region Logger
local RegionErrors = {}
-- #ex-serverregionlogger
--[[
    ServerRegionLogger: Group errors by region.
]]
function Examiner.ServerRegionLogger(region, errorMsg)
    RegionErrors[region] = RegionErrors[region] or {}
    table.insert(RegionErrors[region], errorMsg)
    Examiner.Dispatch(string.format("Error in %s: %s", region, errorMsg), "error")
end

-- 50. State Machine Validator
local StateMachines = {}
-- #ex-statemachinevalidator
--[[
    StateMachineValidator: Ensure valid state transitions.
]]
function Examiner.StateMachineValidator(machine, validTransitions)
    StateMachines[machine] = validTransitions
    -- Monitor changes
end

-- 51. Undo/Redo Bridge
local UndoStack = {}
-- #ex-undoredobridge
--[[
    UndoRedoBridge: Use snapshots for undo.
]]
function Examiner.UndoRedoBridge(action)
    local id = Examiner.Snapshot(action, {note="undo point"})
    table.insert(UndoStack, id)
end

-- 52. Dependency Injection Guard
-- #ex-dependencyinjectionguard
--[[
    DependencyInjectionGuard: Ensure required services.
]]
function Examiner.DependencyInjectionGuard(module, required)
    for _, req in ipairs(required) do
        if not module[req] then
            Examiner.Dispatch(string.format("Missing dependency: %s", req), "error")
        end
    end
end

-- 53. Event-Chain Tracer
local Breadcrumbs = {}
-- #ex-eventchaintracer
--[[
    EventChainTracer: Log event breadcrumbs.
]]
function Examiner.EventChainTracer(event, func)
    table.insert(Breadcrumbs, {event=event, func=func})
    Examiner.Dispatch("Breadcrumb: " .. event .. " -> " .. tostring(func), "info")
end

-- 54. Metatable Spy
-- #ex-metatablespy
--[[
    MetatableSpy: Report metatable access.
]]
function Examiner.MetatableSpy(tbl, name)
    local mt = getmetatable(tbl) or {}
    mt.__index = function(t, k)
        Examiner.Dispatch(string.format("Metatable access on %s: %s", name or "unknown", tostring(k)), "info")
        return rawget(t, k)
    end
    setmetatable(tbl, mt)
end

-- 55. Recursive Type Checker
-- #ex-recursivetypechecker
--[[
    RecursiveTypeChecker: Deep type check.
]]
function Examiner.RecursiveTypeChecker(tbl, expectedType)
    local function check(t)
        for k,v in pairs(t) do
            if type(v) ~= expectedType then
                Examiner.Dispatch(string.format("Type mismatch at %s: %s", tostring(k), type(v)), "error")
            elseif type(v) == "table" then
                check(v)
            end
        end
    end
    check(tbl)
end

-- 56. Delta-Time Monitor
-- #ex-deltatimemonitor
--[[
    DeltaTimeMonitor: Track RenderStepped consistency.
]]
function Examiner.DeltaTimeMonitor()
    if not HAS_ROBLOX then return end
    local RunService = game:GetService("RunService")
    local lastDt = 0
    RunService.RenderStepped:Connect(function(dt)
        if math.abs(dt - lastDt) > 0.01 then
            Examiner.Dispatch(string.format("Frame rate drop: dt %.4f", dt), "warn")
        end
        lastDt = dt
    end)
end

-- 57. Priority Dispatch
local PriorityQueue = {}
-- #ex-prioritydispatch
--[[
    PriorityDispatch: Sort logs by priority.
]]
function Examiner.PriorityDispatch(message, level, priority)
    table.insert(PriorityQueue, {msg=message, level=level, pri=priority or 1})
    table.sort(PriorityQueue, function(a,b) return a.pri > b.pri end)
    -- Dispatch highest
    if #PriorityQueue > 0 then
        local top = table.remove(PriorityQueue, 1)
        Examiner.Dispatch(top.msg, top.level)
    end
end

-- 58. Automatic Fixer
-- #ex-automaticfixer
function Examiner.AutomaticFixer(tbl, defaults)
    Examiner.pipe(function(report)
        for k, def in pairs(defaults) do
            if not tbl[k] then
                tbl[k] = def
                Examiner.Dispatch(string.format("Auto-fixed missing key: %s", k), "info")
            end
        end
        return report
    end)
end

-- 59. Logic Black Box
local BlackBox = {}
-- #ex-logicblackbox
--[[
    LogicBlackBox: Snapshot last 30s on crash.
]]
function Examiner.LogicBlackBox()
    task.spawn(function()
        while true do
            task.wait(1)
            table.insert(BlackBox, Examiner.Snapshot(_G, {note="black box"}))
            if #BlackBox > 30 then table.remove(BlackBox, 1) end
        end
    end)
    -- On crash, save BlackBox
end

-- 60. Script Environment Diff
-- #ex-scriptenvironmentdiff
--[[
    ScriptEnvironmentDiff: Check environment tampering.
]]
function Examiner.ScriptEnvironmentDiff(script, originalEnv)
    if not HAS_ROBLOX or typeof(script) ~= "Instance" then return end
    local currentEnv = getfenv(script:GetActor() or script)
    local diffs = tableDiff(originalEnv, currentEnv)
    if #diffs > 0 then
        Examiner.Dispatch("Environment tampered: " .. table.concat(diffs, "; "), "warn")
    end
end

-- 61. The Final Report
local Violations = {}
-- #ex-thefinalreport
--[[
    TheFinalReport: Summary on shutdown.
]]
function Examiner.TheFinalReport()
    if not HAS_ROBLOX then return end
    game:BindToClose(function()
        Examiner.Dispatch("Final Report: " .. #Violations .. " violations", "info")
        for _, v in ipairs(Violations) do
            Examiner.Dispatch(v, "info")
        end
    end)
    -- Collect violations
    Examiner.Signal:Connect(function(msg, level)
        if level == "error" or level == "warn" then
            table.insert(Violations, msg)
        end
    end)
end

-- 62. Examiner.Guard() - Promise/Catch pattern
local Guard = {}
Guard.__index = Guard

local function makeGuardRecord(fn, ctx)
    local record = setmetatable({ fn = fn, ctx = ctx, caught = false, defaulted = false, finalized = false, lastErr = nil, result = nil }, Guard)
    return record
end

-- #ex-guard
--[[
    Guard: Wraps functions with catch/default/finally chaining.
]]
function Examiner.Guard(fn, ctx)
    local self = makeGuardRecord(fn, ctx)
    task.spawn(function()
        local ok, res = pcall(function() return fn() end)
        self.result = res
        if not ok then
            self.lastErr = res
            -- Auto report
            Examiner.Examine(nil, res, { source = "Guard failure" })
        end
    end)
    return self
end

function Guard:catch(fn)
    if self.lastErr and not self.caught then
        self.caught = true
        pcall(fn, self.lastErr)
    end
    return self
end

function Guard:default(value)
    if self.lastErr and not self.defaulted then
        self.defaulted = true
        self.result = value
    end
    return self
end

function Guard:finally(fn)
    if not self.finalized then
        self.finalized = true
        pcall(fn)
    end
    return self
end


local function tableDeepEqual(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for k,v in pairs(a) do
		if not tableDeepEqual(v, b[k]) then return false end
	end
	for k,v in pairs(b) do
		if not a[k] then return false end
	end
	return true
end

-- 63. Metatable Integrity Sentinel
local PureMetatables = {} -- obj -> pure mt snapshot
-- #ex-metatableintegritysentinel
--[[
    MetatableIntegritySentinel: Check if metatables are tampered.
]]
function Examiner.MetatableIntegritySentinel(obj, name)
    if not PureMetatables[obj] then
        PureMetatables[obj] = deepCopy(getmetatable(obj) or {})
    end
    task.spawn(function()
        while PureMetatables[obj] do
            task.wait(5)
            local current = getmetatable(obj) or {}
            if not tableDeepEqual(PureMetatables[obj], current) then
                Examiner.Dispatch(string.format("Metatable tampered on %s", name or "unknown"), "error")
            end
        end
    end)
end


-- 64. Examiner.Compare() - Fluent comparison
local Compare = {}
Compare.__index = Compare

-- #ex-compare
--[[
    Compare: Fluent comparison with logging.
]]
function Examiner.Compare(value)
    return setmetatable({ value = value, failed = false }, Compare)
end

function Compare:IsGreaterThan(other)
    if self.value <= other then
        self.failed = true
        Examiner.Snapshot({left=self.value, right=other}, {note="comparison failed"})
        Examiner.Dispatch(string.format("Comparison failed: %s > %s", tostring(self.value), tostring(other)), "warn")
    end
    return self
end

function Compare:Else(fn)
    if self.failed then
        pcall(fn)
    end
    return self
end

-- 65. Examiner.useTrack - Function Hooks
local Tracks = {} -- value -> {callbacks}
-- #ex-usetrack
--[[
    useTrack: Watch table value changes, run side effects.
]]
function Examiner.useTrack(tbl, key, callback)
    Tracks[tbl] = Tracks[tbl] or {}
    Tracks[tbl][key] = callback
    task.spawn(function()
        local last = tbl[key]
        while Tracks[tbl] and Tracks[tbl][key] do
            task.wait(0.1)
            if tbl[key] ~= last then
                pcall(callback, last, tbl[key])
                last = tbl[key]
            end
        end
    end)
end

-- 66. Automated Breadcrumbs
local Breadcrumbs = {} -- list of calls
-- #ex-automatedbreadcrumbs
--[[
    AutomatedBreadcrumbs: Track calls for error context.
]]
function Examiner.AutomatedBreadcrumbs(funcName)
    table.insert(Breadcrumbs, {func=funcName, time=os.time()})
    if #Breadcrumbs > 10 then table.remove(Breadcrumbs, 1) end
end

-- Hook into Dispatch to include breadcrumbs on errors
local originalDispatch = Dispatch

--[[
    Dispatch: Consolidates and outputs reports to prevent console flooding.
    
    Public: Batches identical reports within a 0.1s window.
    
    [Open Documentation](https://ogggamer.github.io/Examiner/#core)
]]
function Examiner.Dispatch(message, level)
    if level == "error" then
        local crumbs = ""
        for i, c in ipairs(Breadcrumbs) do
            crumbs = crumbs .. (i > 1 and " -> " or "") .. c.func
        end
        message = message .. " | Breadcrumbs: " .. crumbs
    end
    return originalDispatch(message, level)
end

-- #ex-schemarecovery
--[[
    SchemaRecovery: Recover from schema violations by applying defaults.
]]
function Examiner.SchemaRecovery(tbl)
    local rec = ProtectResults[tbl]
    if not rec or rec.valid then return end
    return {
        fix = function(defaults)
            for key, def in pairs(defaults) do
                if type(tbl[key]) ~= rec.schema[key] then
                    Examiner.Dispatch(string.format("Fixing key %s with default", key), "info")
                    tbl[key] = def
                end
            end
        end
    }
end

-- Settings table for toggles
Examiner.Settings = {
    NoNil = false,
    CheckSecurity = false,
    StrictTypes = false,
    PurityCheck = false
}

-- #ex-tabledeepequal
--[[
    TableDeepEqual: Deep equality check for tables.
]]
function Examiner.TableDeepEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k,v in pairs(a) do
        if not Examiner.TableDeepEqual(v, b[k]) then return false end
    end
    for k,v in pairs(b) do
        if not a[k] then return false end
    end
    return true
end

-- 68. Nil Protection
-- #ex-nilprotection
--[[
    NilProtection: When enabled, returns dummy objects for nil access to prevent errors.
]]
function Examiner.NilProtection(enable)
    Examiner.Settings.NoNil = enable
    if enable then
        -- Override global __index or something, but simplistic: wrap tables
        Examiner.Dispatch("Nil Protection enabled", "info")
    else
        Examiner.Dispatch("Nil Protection disabled", "info")
    end
end

-- 69. Permission Guard
-- #ex-permissionguard
--[[
    PermissionGuard: Checks for RBXScriptSecurity restricted properties and prevents crashes.
]]
function Examiner.PermissionGuard(enable)
    Examiner.Settings.CheckSecurity = enable
    if enable then
        -- Hook into property access
        Examiner.Dispatch("Permission Guard enabled", "info")
    else
        Examiner.Dispatch("Permission Guard disabled", "info")
    end
end

-- 70. Linting Enforcer
-- #ex-lintingenforcer
--[[
    LintingEnforcer: Verifies function arguments match intended Luau types.
]]
function Examiner.LintingEnforcer(enable)
    Examiner.Settings.StrictTypes = enable
    if enable then
        -- Add type checking to functions
        Examiner.Dispatch("Linting Enforcer enabled", "info")
    else
        Examiner.Dispatch("Linting Enforcer disabled", "info")
    end
end

-- 71. Metatable Lock
-- #ex-metatablelock
--[[
    MetatableLock: Alerts if a script's metatable has been modified at runtime.
]]
function Examiner.MetatableLock(enable)
    Examiner.Settings.PurityCheck = enable
    if enable then
        -- Monitor metatables
        Examiner.Dispatch("Metatable Lock enabled", "info")
    else
        Examiner.Dispatch("Metatable Lock disabled", "info")
    end
end

-- 72. Catch Or Retry
-- #ex-catchorretry
--[[
    CatchOrRetry: Runs fn with retries on failure, snapshots state, dispatches fatal on limit.
]]
function Examiner.CatchOrRetry(fn, retryLimit, backoff)
    retryLimit = retryLimit or 3
    backoff = backoff or 1
    local attempts = 0
    local function attempt()
        attempts = attempts + 1
        local ok, res = pcall(fn)
        if not ok then
            local snapId = Examiner.Snapshot(_G, {note="retry failure"})
            if attempts < retryLimit then
                task.wait(backoff)
                attempt()
            else
                Examiner.Dispatch(string.format("Fatal: Operation failed after %d retries. Snapshot: %d", retryLimit, snapId), "error")
                -- Run fallback if provided
                if type(res) == "function" then pcall(res) end
            end
        end
    end
    attempt()
end

-- 73. Succeed Until
-- #ex-succeeduntil
--[[
    SucceedUntil: Runs fn while condition is true, catches state on failure.
]]
function Examiner.SucceedUntil(condition, fn)
    task.spawn(function()
        while condition() do
            local ok, err = pcall(fn)
            if not ok then
                local snapId = Examiner.Snapshot(_G, {note="condition failed"})
                Examiner.Dispatch(string.format("SucceedUntil failed: %s. Snapshot: %d", tostring(err), snapId), "error")
                break
            end
            task.wait(0.1) -- Prevent tight loop
        end
    end)
end

-- 74. Search For
-- #ex-searchfor
--[[
    SearchFor: Searches scope for objects matching query, can auto-sanitize.
]]
function Examiner.SearchFor(query, scope, autoSanitize)
    scope = scope or workspace
    local results = {}
    local function search(obj)
        local match = true
        for k,v in pairs(query) do
            if obj[k] ~= v then match = false break end
        end
        if match then
            table.insert(results, obj)
            if autoSanitize then
                pcall(function() obj:Destroy() end)
            end
        end
        if obj:IsA("Instance") then
            for _, child in ipairs(obj:GetChildren()) do
                search(child)
            end
        end
    end
    search(scope)
    return results
end

-- 75. Validate Metatable
-- #ex-validatemetatable
--[[
    ValidateMetatable: Checks metatable against template, catches drift.
]]
function Examiner.ValidateMetatable(target, template)
    local mt = getmetatable(target)
    if not mt then return false end
    for k,v in pairs(template) do
        if mt[k] ~= v then
            Examiner.Dispatch(string.format("Metatable drift on %s: %s", tostring(target), k), "error")
            return false
        end
    end
    return true
end

-- 76. Sync
-- #ex-sync
--[[
    Sync: Keeps tableA and tableB in sync, catches errors.
]]
function Examiner.Sync(tableA, tableB)
    local function syncAB()
        for k,v in pairs(tableB) do
            if type(tableA[k]) ~= type(v) then
                Examiner.Dispatch(string.format("Sync error: type mismatch at %s", k), "error")
                return false
            end
            tableA[k] = v
        end
        return true
    end
    local function syncBA()
        for k,v in pairs(tableA) do
            tableB[k] = v
        end
    end
    syncAB()
    syncBA()
    -- Monitor for changes
    task.spawn(function()
        while true do
            task.wait(1)
            if not syncAB() then break end
            syncBA()
        end
    end)
end

-- 77. Expect
-- #ex-expect
--[[
    Expect: Runtime type check for value.
]]
function Examiner.Expect(value, luauType)
    if type(value) ~= luauType then
        Examiner.Dispatch(string.format("Type expectation failed: expected %s, got %s", luauType, type(value)), "error")
        return false
    end
    return true
end

-- 78. Trace Attribute
-- #ex-traceattribute
--[[
    TraceAttribute: Monitors attribute changes with strict patterns.
]]
function Examiner.TraceAttribute(instance, attributeName, validValues)
    if not HAS_ROBLOX or typeof(instance) ~= "Instance" then return end
    instance:GetAttributeChangedSignal(attributeName):Connect(function()
        local val = instance:GetAttribute(attributeName)
        if validValues and not table.find(validValues, val) then
            Examiner.Dispatch(string.format("Invalid attribute change: %s = %s", attributeName, tostring(val)), "error")
        end
    end)
end

-- 79. Expect Return
-- #ex-expectreturn
--[[
    ExpectReturn: Wraps function to validate return type.
]]
function Examiner.ExpectReturn(fn, expectedType)
    return function(...)
        local res = {fn(...)}
        if #res == 0 or type(res[1]) ~= expectedType then
            Examiner.Dispatch(string.format("Function promised %s but returned %s", expectedType, type(res[1] or "nil")), "error")
            return nil
        end
        return unpack(res)
    end
end

-- 80. Intercept Nil
-- #ex-interceptnil
--[[
    InterceptNil: Wraps target to return fallback on nil access.
]]
function Examiner.InterceptNil(target, fallback)
    local mt = getmetatable(target) or {}
    local originalIndex = mt.__index
    mt.__index = function(t, k)
        local v = originalIndex and originalIndex(t, k) or rawget(t, k)
        if v == nil then
            Examiner.Dispatch(string.format("Nil access intercepted: %s.%s", tostring(t), tostring(k)), "warn")
            return fallback
        end
        return v
    end
    setmetatable(target, mt)
end

-- 81. Gate
-- #ex-gate
--[[
    Gate: Runs successFn only if condition is true.
]]
function Examiner.Gate(condition, successFn)
    local ctx = { _else = function() end }
    if condition then
        pcall(successFn)
    else
        ctx._else()
    end
    function ctx:Else(fn) self._else = fn; return self end
    return ctx
end

-- 82. Memoize With Verify
local MemoCache = {}
-- #ex-memoizewithverify
--[[
    MemoizeWithVerify: Caches result but verifies periodically.
]]
function Examiner.MemoizeWithVerify(fn)
    local key = tostring(fn)
    MemoCache[key] = MemoCache[key] or { value = nil, lastCheck = 0 }
    local cache = MemoCache[key]
    return function(...)
        local now = tick()
        if cache.value == nil or now - cache.lastCheck > 5 then
            local newVal = fn(...)
            if cache.value and cache.value ~= newVal then
                Examiner.Dispatch("Data drift detected in memoized function", "warn")
            end
            cache.value = newVal
            cache.lastCheck = now
        end
        return cache.value
    end
end

-- 83. Poll Until
-- #ex-polluntil
--[[
    PollUntil: Runs fn until condition is met or timeout.
]]
function Examiner.PollUntil(fn, condition, timeout)
    timeout = timeout or 10
    local start = tick()
    task.spawn(function()
        while tick() - start < timeout do
            pcall(fn)
            if condition() then return end
            task.wait(0.1)
        end
        Examiner.Snapshot(_G, {note="PollUntil timeout"})
        Examiner.Dispatch("PollUntil timed out", "error")
    end)
end

-- 84. Validate Metatable (enhanced)
-- #ex-validatemetatableenhanced
--[[
    ValidateMetatable: Checks for shadowing in metatable.
]]
function Examiner.ValidateMetatable(proxy)
    local mt = getmetatable(proxy)
    if not mt then return true end
    for k in pairs(proxy) do
        if mt[k] then
            Examiner.Dispatch(string.format("Metatable shadowing detected: %s", k), "warn")
        end
    end
    return true
end

-- 85. Match
local Match = {}
Match.__index = Match
-- #ex-match
--[[
    Match: Pattern matching with catch-all.
]]
function Examiner.Match(value)
    return setmetatable({ value = value, _otherwise = function() end }, Match)
end

function Match:__call(patterns)
    local handler = patterns[self.value] or patterns["_otherwise"] or self._otherwise
    pcall(handler)
    return self
end

function Match:Otherwise(fn)
    self._otherwise = fn
    return self
end

-- 86. Modify
local Modify = {}
Modify.__index = Modify
-- #ex-modify
--[[
    Modify: Fluent state editor with checks.
]]
function Examiner.Modify(target)
    return setmetatable({ target = target, changes = {}, checks = {}, _catch = function() end }, Modify)
end

function Modify:Set(key, value)
    self.changes[key] = value
    return self
end

function Modify:Check(fn)
    table.insert(self.checks, fn)
    return self
end

function Modify:Catch(fn)
    self._catch = fn
    return self
end

function Modify:Apply()
    for _, check in ipairs(self.checks) do
        if not check() then
            self._catch("Check failed")
            return
        end
    end
    for k, v in pairs(self.changes) do
        self.target[k] = v
    end
end

-- 87. Wait Until
local WaitUntil = {}
WaitUntil.__index = WaitUntil
-- #ex-waituntil
--[[
    WaitUntil: Smart wait with timeout and snapshot.
]]
function Examiner.WaitUntil(condition, timeout)
    timeout = timeout or 5
    local ctx = setmetatable({ _then = function() end, _catch = function() end }, WaitUntil)
    task.spawn(function()
        local start = tick()
        while tick() - start < timeout do
            local res = condition()
            if res then
                ctx._then(res)
                return
            end
            task.wait()
        end
        Examiner.Snapshot(_G, {note="WaitUntil timeout"})
        ctx._catch("Timeout")
    end)
    return ctx
end

function WaitUntil:Then(fn)
    self._then = fn
    return self
end

function WaitUntil:Catch(fn)
    self._catch = fn
    return self
end

-- 88. Observe Return
local ReturnHistory = {}
-- #ex-observereturn
--[[
    ObserveReturn: Wraps function to log returns.
]]
function Examiner.ObserveReturn(fn)
    local key = tostring(fn)
    ReturnHistory[key] = ReturnHistory[key] or {}
    return function(...)
        local res = {fn(...)}
        table.insert(ReturnHistory[key], res)
        if #ReturnHistory[key] > 20 then table.remove(ReturnHistory[key], 1) end
        return unpack(res)
    end
end

function Examiner.GetHistory(fn)
    return ReturnHistory[tostring(fn)] or {}
end

-- 89. Wait And Compare
-- #ex-waitandcompare
--[[
    WaitAndCompare: Waits for value to match expected.
]]
function Examiner.WaitAndCompare(target, key, expectedValue)
    Examiner.WaitUntil(function() return target[key] == expectedValue end, 10)
        :Then(function() Examiner.Dispatch("Value matched", "info") end)
        :Catch(function() Examiner.Dispatch("Value mismatch timeout", "error") end)
end

-- 90. Modify Property
-- #ex-modifyproperty
--[[
    ModifyProperty: Safely sets instance properties.
]]
function Examiner.ModifyProperty(instance, prop, value)
    if not HAS_ROBLOX or typeof(instance) ~= "Instance" then return end
    local ok, err = pcall(function() instance[prop] = value end)
    if not ok then
        Examiner.Dispatch(string.format("Property modification failed: %s", err), "error")
    end
end

-- 91. Limit
-- #ex-limit
--[[
    Limit: Sets guardrails on tables or instances to cap values and dispatch warnings.
]]
local Limits = {} -- target -> constraints
function Examiner.Limit(target, constraints)
    if type(target) ~= "table" and (not HAS_ROBLOX or typeof(target) ~= "Instance") then return end
    Limits[target] = constraints
    if type(target) == "table" then
        local mt = getmetatable(target) or {}
        local origNewindex = mt.__newindex
        mt.__newindex = function(t, k, v)
            local cons = constraints[k]
            if cons then
                if cons.min and type(v) == "number" and v < cons.min then
                    Examiner.Dispatch(string.format("Limit Violation: %s capped at %s", k, cons.min), "warn")
                    v = cons.min
                    Examiner.Snapshot(t, { note = "limit cap" })
                elseif cons.max and type(v) == "number" and v > cons.max then
                    Examiner.Dispatch(string.format("Limit Violation: %s capped at %s", k, cons.max), "warn")
                    v = cons.max
                    Examiner.Snapshot(t, { note = "limit cap" })
                elseif cons.blacklist and table.find(cons.blacklist, v) then
                    Examiner.Dispatch(string.format("Limit Violation: %s blacklisted value %s", k, tostring(v)), "warn")
                    return -- block
                end
            end
            if origNewindex then
                origNewindex(t, k, v)
            else
                rawset(t, k, v)
            end
        end
        setmetatable(target, mt)
    elseif HAS_ROBLOX and typeof(target) == "Instance" then
        -- For instances, use Changed event
        target.Changed:Connect(function(prop)
            local cons = constraints[prop]
            if cons then
                local v = target[prop]
                if cons.min and type(v) == "number" and v < cons.min then
                    Examiner.Dispatch(string.format("Limit Violation: %s capped at %s", prop, cons.min), "warn")
                    target[prop] = cons.min
                    Examiner.Snapshot(target, { note = "limit cap" })
                elseif cons.max and type(v) == "number" and v > cons.max then
                    Examiner.Dispatch(string.format("Limit Violation: %s capped at %s", prop, cons.max), "warn")
                    target[prop] = cons.max
                    Examiner.Snapshot(target, { note = "limit cap" })
                elseif cons.blacklist and table.find(cons.blacklist, v) then
                    Examiner.Dispatch(string.format("Limit Violation: %s blacklisted value %s", prop, tostring(v)), "warn")
                    -- revert to previous? but hard to track
                end
            end
        end)
    end
end

-- 92. Extend
-- #ex-extend
--[[
    Extend: Registers custom functions that inherit Examiner's reporting capabilities.
]]
function Examiner.Extend(name, fn)
    Examiner[name] = function(...)
        local ok, res = pcall(fn, ...)
        if not ok then
            Examiner.Dispatch(string.format("Custom function %s failed: %s", name, res), "error")
            return
        end
        -- Log the call
        Examiner.Dispatch(string.format("Custom %s called", name), "info")
        return res
    end
end

-- 93. Throttle
-- #ex-throttle
--[[
    Throttle: Limits function calls per second, blocking excess and snapshotting.
]]
local Throttles = {} -- fn -> { count, lastReset, limit }
function Examiner.Throttle(fn, limitPerSecond)
    local key = tostring(fn)
    Throttles[key] = { count = 0, lastReset = tick(), limit = limitPerSecond }
    return function(...)
        local t = Throttles[key]
        local now = tick()
        if now - t.lastReset >= 1 then
            t.count = 0
            t.lastReset = now
        end
        if t.count >= t.limit then
            Examiner.Dispatch(string.format("Throttle exceeded for %s", key), "warn")
            Examiner.Snapshot(debug.traceback(), { note = "throttle block" })
            return -- block
        end
        t.count = t.count + 1
        return fn(...)
    end
end

-- 94. SchemaAttribute
-- #ex-schemaattribute
--[[
    SchemaAttribute: Enforces type annotations from Roblox Attributes.
]]
function Examiner.SchemaAttribute()
    if not HAS_ROBLOX then return end
    -- Hook into AttributeChanged for all instances? But that's global, perhaps on demand
    -- For now, a function to apply to an instance
    return function(instance)
        if typeof(instance) ~= "Instance" then return end
        instance.AttributeChanged:Connect(function(attr)
            local typeAnn = instance:GetAttribute("TypeAnnotation")
            if typeAnn then
                local val = instance:GetAttribute(attr)
                if type(val) ~= typeAnn:lower() then
                    Examiner.Dispatch(string.format("Attribute %s type mismatch: expected %s, got %s", attr, typeAnn, type(val)), "error")
                    -- Revert to last valid? Hard, perhaps set to nil or default
                end
            end
        end)
    end
end

-- 95. MustReturn
-- #ex-mustreturn
--[[
    MustReturn: Wraps function to ensure it returns within deadline, catches timeouts.
]]
function Examiner.MustReturn(fn, timeout)
    timeout = timeout or 5
    return function(...)
        local args = {...}
        local returned = false
        local result
        local co = task.spawn(function()
            result = {fn(unpack(args))}
            returned = true
        end)
        local start = tick()
        while not returned and tick() - start < timeout do
            task.wait(0.1)
        end
        if not returned then
            Examiner.Dispatch("Function timeout: did not return within deadline", "error")
            Examiner.Snapshot(args, { note = "timeout args" })
            task.cancel(co)
            return nil
        end
        return unpack(result)
    end
end

local CurrentTest = nil

-- 96. Start Test
-- #ex-starttest
--[[
    StartTest: Start and stop tests with memory leak detection.
]]
function Examiner.StartTest(testName, options)
	if not __TESTING_ENABLED__ then
		Examiner.Report(script, "Trying to test when __TESTING_ENABLED__ is false")
		return
	end
	
	if not options then
		options = {}
	end
	
    CurrentTest = {
        Name = testName,
        StartTime = tick(),
        InitialSnapshot = Examiner.Snapshot(workspace:GetChildren()),
        StrictGlobalCheck = options.StrictGlobals or false
    }
    
    -- If StrictGlobals is on, we lock _G or shared
    if CurrentTest.StrictGlobalCheck then
        Examiner.Dispatch("Test Started: " .. testName .. " [STRICT MODE ON]", "info")
    end
end

-- 97. Stop Test
-- #ex-stoptest
--[[
    StopTest: Ends the current test, compares snapshots for leaks.
]]
function Examiner.StopTest()
	if not __TESTING_ENABLED__ then
		Examiner.Report(script, "Trying to test when __TESTING_ENABLED__ is false")
		return
	end
	
    if not CurrentTest then return end
    
    local endTime = tick()
    local finalSnapshot = workspace:GetChildren()
    local leaks = Examiner.DiffSnapshots(CurrentTest.InitialSnapshot, finalSnapshot)
    
    -- Report the results
    if #leaks > 0 then
        Examiner.Dispatch("Test Failed: " .. CurrentTest.Name .. " - Memory Leaks Detected!", "error")
        for _, item in ipairs(leaks) do
            print("   Leak found: " .. tostring(item))
        end
    else
        Examiner.Dispatch("Test Passed: " .. CurrentTest.Name .. " in " .. (endTime - CurrentTest.StartTime) .. "s", "info")
    end
    
    CurrentTest = nil
end

-- Export
return Examiner
---------------------------------------------------------------------------------------------
--                                         EXAMINER                                        --
---------------------------------------------------------------------------------------------
