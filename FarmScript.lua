-- ╔══════════════════════════════════════════════════════════════════╗
-- ║   UNIVERSAL SCRIPT  v3.0                                        ║
-- ║   Farm · Stats · Tools · Remote Browser · Executor · Spy        ║
-- ╠══════════════════════════════════════════════════════════════════╣
-- ║  DROP IN ANY OF:                                                 ║
-- ║   StarterPlayerScripts · StarterCharacterScripts                 ║
-- ║   StarterGui · Executor / loadstring paste                       ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- ── Services ──────────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Player helpers ────────────────────────────────────────────────
local LP = Players.LocalPlayer or (function()
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    return Players.LocalPlayer
end)()

local PGui = LP:WaitForChild("PlayerGui")

local function Char()   return LP.Character end
local function HRP()    local c=Char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function Hum()    local c=Char(); return c and c:FindFirstChildOfClass("Humanoid") end

local _char, _hrp, _hum
LP.CharacterAdded:Connect(function(c)
    _char = c
    _hrp  = c:WaitForChild("HumanoidRootPart")
    _hum  = c:WaitForChild("Humanoid")
end)
_char = Char(); _hrp = HRP(); _hum = Hum()

-- ── CONFIG ────────────────────────────────────────────────────────
local CFG = {
    FarmRange      = 60,
    FarmInterval   = 0.1,
    Notifications  = true,
    UIWidth        = 360,
    UIHeight       = 520,
    MaxSpyLog      = 200,
    MaxFireLog     = 100,
}

-- ── STATE ─────────────────────────────────────────────────────────
local S = {
    AutoFarm     = false, farmConn   = nil,
    AutoCollect  = false,
    FarmTarget   = "Mob",
    InfiniteJump = false,
    SpeedHack    = false,
    NoClip       = false, noclipConn = nil,
    Fly          = false, flyConn    = nil, flyBV = nil,
    AntiAFK      = false, afkConn    = nil,
    GodMode      = false,
    LoopRunning  = false,
    SpyActive    = false,
    SpyBlacklist = {},
}

-- ── Shared data stores ────────────────────────────────────────────
local ScannedRemotes  = {}   -- { path, fullPath, obj, type, hitCount, lastArgs }
local LoopEntries     = {}   -- { name, callExpr, argsTable, vars, delay, interval, active, loopConn, fireCount, lastStatus }
local FireLog         = {}   -- { time, name, status, args }  newest-first
local SpyLog          = {}   -- { time, path, method, args, argStr }  newest-first
local SpyUpdateSig    = Instance.new("BindableEvent")
local FireUpdateSig   = Instance.new("BindableEvent")
local ScanUpdateSig   = Instance.new("BindableEvent")

-- ═══════════════════════════════════════════════════════════════════
--  REMOTE SCANNER
--  Crawls every accessible service for RemoteEvent / RemoteFunction
--  Runs async so it never stalls the script.
--  Results land in ScannedRemotes, then ScanUpdateSig fires.
-- ═══════════════════════════════════════════════════════════════════
local SCAN_ROOTS = {
    "ReplicatedStorage", "ReplicatedFirst", "Workspace",
    "ServerScriptService", "ServerStorage", "StarterGui",
    "StarterPack", "StarterPlayer", "Lighting", "Teams",
    "SoundService", "Chat", "LocalizationService",
}

local function ServicePath(svcName)
    local ok, svc = pcall(function() return game:GetService(svcName) end)
    return ok and svc or nil
end

-- Serialize a game-object path to a full Lua call string
local function MakeFullPath(obj)
    local parts = {}
    local cur = obj
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    -- First segment is a service name → use GetService
    local result = "game"
    for i, seg in ipairs(parts) do
        if i == 1 then
            result = 'game:GetService("' .. seg .. '")'
        else
            result = result .. '["' .. seg .. '"]'
        end
    end
    return result
end

-- Recursively walk an object and collect remotes
local function WalkForRemotes(obj, pathStr, depth)
    depth = depth or 0
    if depth > 12 then return end
    local ok, children = pcall(function() return obj:GetChildren() end)
    if not ok then return end
    for _, child in ipairs(children) do
        local childPath = pathStr .. '["' .. child.Name .. '"]'
        if child:IsA("RemoteEvent") or child:IsA("RemoteFunction")
            or child:IsA("BindableEvent") or child:IsA("BindableFunction") then
            -- deduplicate by full path
            local fp = MakeFullPath(child)
            local exists = false
            for _, r in ipairs(ScannedRemotes) do
                if r.fullPath == fp then exists = true; break end
            end
            if not exists then
                table.insert(ScannedRemotes, {
                    name      = child.Name,
                    path      = childPath,
                    fullPath  = fp,
                    obj       = child,
                    rtype     = child.ClassName,
                    hitCount  = 0,
                    lastArgs  = "—",
                    -- vars harvested from nearby LocalScripts (filled by VarHarvester)
                    knownVars = {},
                    -- set true once spy or manual fire has recorded real args
                    observed  = false,
                })
            end
        end
        WalkForRemotes(child, childPath, depth + 1)
    end
end

-- Attempt to harvest variable hints from accessible LocalScript Sources
-- Only works in executor context where script.Source is readable.
local function HarvestVarsFromScripts(obj, depth)
    depth = depth or 0
    if depth > 8 then return end
    local ok, children = pcall(function() return obj:GetChildren() end)
    if not ok then return end
    for _, child in ipairs(children) do
        if child:IsA("LocalScript") or child:IsA("ModuleScript") then
            local src = ""
            pcall(function() src = child.Source end)
            if src ~= "" then
                -- Match patterns like: [1] = "value" / [2] = 42 / [3] = true
                for _, remote in ipairs(ScannedRemotes) do
                    if src:find(remote.name, 1, true) then
                        -- pull out args table blocks near the remote name
                        local block = src:match(remote.name .. '[^{]*({[^}]+})')
                        if block then
                            remote.knownVars["_hint"] = block:sub(1, 120)
                        end
                    end
                end
            end
        end
        HarvestVarsFromScripts(child, depth + 1)
    end
end

-- ═══════════════════════════════════════════════════════════════════
--  REMOTE SPY ENGINE
--  Hooks RemoteEvent:FireServer and RemoteFunction:InvokeServer via
--  __namecall metatable replacement (executor-style hook).
--  Falls back to per-object :Connect wrapping when __namecall is
--  unavailable (non-executor LocalScript context).
-- ═══════════════════════════════════════════════════════════════════
local SpyHooked = false
local _origNamecall = nil

local function SerializeArg(v)
    local t = type(v)
    if t == "string"  then return '"' .. v:sub(1, 40) .. '"' end
    if t == "number"  then return tostring(v) end
    if t == "boolean" then return tostring(v) end
    if t == "table"   then
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts+1] = "[" .. tostring(k) .. "]=" .. SerializeArg(val)
        end
        return "{" .. table.concat(parts, ","):sub(1, 80) .. "}"
    end
    if typeof then
        local ty = typeof(v)
        if ty == "Instance" then return v.ClassName .. '("' .. v.Name .. '")' end
        if ty == "Vector3"  then return string.format("V3(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z) end
        if ty == "CFrame"   then return "CFrame" end
    end
    return tostring(v):sub(1, 30)
end

local function ArgsToStr(args)
    local parts = {}
    for i = 1, #args do parts[#parts+1] = SerializeArg(args[i]) end
    return table.concat(parts, ", ")
end

local function PushSpyLog(path, method, args)
    if S.SpyBlacklist[path] then return end
    local argStr = ArgsToStr(args)
    local t = os.clock()
    local timeStr = string.format("%02d:%02d:%02d",
        math.floor(t/3600)%24, math.floor(t/60)%60, math.floor(t)%60)
    table.insert(SpyLog, 1, { time=timeStr, path=path, method=method, args=argStr, rawArgs=args })
    if #SpyLog > CFG.MaxSpyLog then table.remove(SpyLog) end
    -- update hitCount on matching scanned remote
    for _, r in ipairs(ScannedRemotes) do
        if r.fullPath == path then
            r.hitCount = r.hitCount + 1
            r.lastArgs  = argStr
            r.observed  = true
            -- learn vars: store raw args as argsTable hint
            if #args > 0 and not r.observedArgs then
                r.observedArgs = args
            end
            break
        end
    end
    SpyUpdateSig:Fire()
end

local function InstallSpyHook()
    if SpyHooked then return end
    SpyHooked = true
    -- Try __namecall hook (executor only)
    local mt = getrawmetatable and getrawmetatable(game)
    if mt then
        _origNamecall = rawget(mt, "__namecall")
        local ok = pcall(function() setreadonly(mt, false) end)
        if not ok then pcall(function() make_writeable(mt) end) end
        rawset(mt, "__namecall", function(self, ...)
            local method = getnamecallmethod and getnamecallmethod() or ""
            local args   = {...}
            if S.SpyActive then
                local cls = typeof(self) == "Instance" and self.ClassName or ""
                if (method == "FireServer"   and cls == "RemoteEvent") or
                   (method == "InvokeServer" and cls == "RemoteFunction") or
                   (method == "Fire"         and cls == "BindableEvent") or
                   (method == "Invoke"       and cls == "BindableFunction") then
                    local fp = MakeFullPath(self)
                    PushSpyLog(fp, method, args)
                end
            end
            return _origNamecall(self, ...)
        end)
        return
    end
    -- Fallback: hook every scanned remote individually
    task.spawn(function()
        task.wait(0.5)  -- wait for scan to populate
        for _, r in ipairs(ScannedRemotes) do
            local obj = r.obj
            if obj and obj:IsA("RemoteEvent") then
                -- can't hook outbound FireServer without __namecall,
                -- but we can watch OnClientEvent to infer the remote exists
                pcall(function()
                    obj.OnClientEvent:Connect(function(...)
                        if S.SpyActive then
                            PushSpyLog(r.fullPath, "OnClientEvent", {...})
                        end
                    end)
                end)
            end
        end
    end)
end

local function UninstallSpyHook()
    local mt = getrawmetatable and getrawmetatable(game)
    if mt and _origNamecall then
        pcall(function() setreadonly(mt, false) end)
        rawset(mt, "__namecall", _origNamecall)
        _origNamecall = nil
    end
    SpyHooked = false
end

-- ═══════════════════════════════════════════════════════════════════
--  LOOPER ENGINE  v3
-- ═══════════════════════════════════════════════════════════════════
local function PushFireLog(name, status, argStr)
    local t = os.clock()
    local ts = string.format("%02d:%02d:%02d",
        math.floor(t/3600)%24, math.floor(t/60)%60, math.floor(t)%60)
    table.insert(FireLog, 1, {time=ts, name=name, status=status, args=argStr or ""})
    if #FireLog > CFG.MaxFireLog then table.remove(FireLog) end
    FireUpdateSig:Fire()
end

local function ResolveVars(val, vars)
    if type(val) ~= "string" then return val end
    return (val:gsub("{(%w+)}", function(k)
        local v = vars and vars[k]
        return v ~= nil and tostring(v) or ("{" .. k .. "}")
    end))
end

local function BuildArgs(entry)
    local out = {}
    if not entry.argsTable then return out end
    local maxIdx = 0
    for k in pairs(entry.argsTable) do
        if type(k)=="number" and k>maxIdx then maxIdx=k end
    end
    for i=1,maxIdx do
        out[i] = ResolveVars(entry.argsTable[i], entry.vars)
    end
    return out
end

local function ExecEntry(entry)
    local resolvedArgs = BuildArgs(entry)
    local argStr = ""
    for i,v in ipairs(resolvedArgs) do
        argStr = argStr .. (i>1 and ", " or "") .. tostring(v)
    end
    local callExpr = entry.callExpr or ""
    if callExpr == "" then
        entry.lastStatus = "⚠ No expression"
        PushFireLog(entry.name, entry.lastStatus, argStr)
        return
    end
    local env = setmetatable({
        game      = game,
        workspace = workspace,
        args      = resolvedArgs,
        vars      = entry.vars or {},
        unpack    = table.unpack,
        wait      = task.wait,
        task      = task,
        print     = print,
        math      = math,
        string    = string,
        table     = table,
        tostring  = tostring,
        tonumber  = tonumber,
        pairs     = pairs,
        ipairs    = ipairs,
        type      = type,
        pcall     = pcall,
        error     = error,
    }, {__index = _G})
    local fn, compErr = loadstring(callExpr)
    if not fn then
        entry.lastStatus = "❌ " .. tostring(compErr):sub(1,50)
        PushFireLog(entry.name, entry.lastStatus, argStr)
        return
    end
    setfenv(fn, env)
    local ok, runErr = pcall(fn)
    if ok then
        entry.fireCount  = (entry.fireCount or 0) + 1
        entry.lastStatus = "✅ fired #" .. entry.fireCount
    else
        entry.lastStatus = "⚠ " .. tostring(runErr):sub(1,50)
    end
    PushFireLog(entry.name, entry.lastStatus, argStr)
end

local function StartEntryLoop(entry)
    if entry.loopConn then entry.loopConn:Disconnect(); entry.loopConn=nil end
    if not entry.active then return end
    task.spawn(function()
        if (entry.delay or 0) > 0 then task.wait(entry.delay) end
        if entry.active then ExecEntry(entry) end
        local iv = math.max(0.05, entry.interval or 1)
        local ticker = 0
        entry.loopConn = RunService.Heartbeat:Connect(function(dt)
            if not entry.active then
                entry.loopConn:Disconnect(); entry.loopConn=nil; return
            end
            ticker = ticker + dt
            if ticker >= iv then ticker=0; task.spawn(ExecEntry, entry) end
        end)
    end)
end

local function StopEntryLoop(entry)
    if entry.loopConn then entry.loopConn:Disconnect(); entry.loopConn=nil end
    entry.active = false
end

local function StopAllLoops()
    S.LoopRunning = false
    for _,e in ipairs(LoopEntries) do StopEntryLoop(e) end
end

-- ── Utility ──────────────────────────────────────────────────────
local function Notify(title, text)
    if not CFG.Notifications then return end
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification",
            {Title=title, Text=text, Duration=3})
    end)
end

local function TpTo(part)
    local h = HRP()
    if h and part then h.CFrame = CFrame.new(part.Position + Vector3.new(0,3,0)) end
end

local ScanDone = false

local function RunScan()
    ScannedRemotes = {}
    ScanDone = false
    task.spawn(function()
        for _, svcName in ipairs(SCAN_ROOTS) do
            local svc = ServicePath(svcName)
            if svc then
                local basePath = 'game:GetService("' .. svcName .. '")'
                WalkForRemotes(svc, basePath, 0)
            end
            task.wait()   -- yield between services to stay smooth
        end
        -- also scan workspace models
        pcall(function() WalkForRemotes(workspace, "workspace", 0) end)
        -- attempt script source harvest (executor only)
        for _, svcName in ipairs({"StarterGui","StarterPlayer","ReplicatedFirst"}) do
            local svc = ServicePath(svcName)
            if svc then pcall(HarvestVarsFromScripts, svc, 0) end
        end
        ScanDone = true
        ScanUpdateSig:Fire()
    end)
end

-- ═══════════════════════════════════════════════════════════════════
--  FARMING ENGINE
-- ═══════════════════════════════════════════════════════════════════
local function FindNearestMob()
    local h = HRP(); if not h then return end
    local best, bd = nil, CFG.FarmRange
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj~=Char() and obj:FindFirstChildOfClass("Humanoid") then
            local r = obj:FindFirstChild("HumanoidRootPart") or obj:FindFirstChild("Root")
            if r then
                local d = (r.Position - h.Position).Magnitude
                if d < bd then best,bd = r,d end
            end
        end
    end
    return best
end

local function FindNearestItem()
    local h = HRP(); if not h then return end
    local KEYWORDS = {"coin","gem","drop","orb","crystal","shard","token","reward","loot"}
    local best, bd = nil, CFG.FarmRange
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            local n = obj.Name:lower()
            for _, kw in ipairs(KEYWORDS) do
                if n:find(kw) then
                    local d = (obj.Position - h.Position).Magnitude
                    if d < bd then best,bd = obj,d end
                    break
                end
            end
        end
    end
    return best
end

local function StartFarm()
    if S.farmConn then S.farmConn:Disconnect() end
    S.farmConn = RunService.Heartbeat:Connect(function()
        if not S.AutoFarm then return end
        local tgt = S.FarmTarget=="Item" and FindNearestItem() or FindNearestMob()
        if tgt then TpTo(tgt) end
    end)
end

local function StopFarm()
    if S.farmConn then S.farmConn:Disconnect(); S.farmConn=nil end
end

-- ═══════════════════════════════════════════════════════════════════
--  TOOLS ENGINE
-- ═══════════════════════════════════════════════════════════════════

-- No-clip
local function UpdateNoClip()
    if S.noclipConn then S.noclipConn:Disconnect(); S.noclipConn=nil end
    if not S.NoClip then return end
    S.noclipConn = RunService.Stepped:Connect(function()
        local c = Char()
        if not c then return end
        for _, v in ipairs(c:GetDescendants()) do
            if v:IsA("BasePart") then v.CanCollide = false end
        end
    end)
end

-- Fly
local function UpdateFly()
    if S.flyConn then S.flyConn:Disconnect(); S.flyConn=nil end
    if S.flyBV then S.flyBV:Destroy(); S.flyBV=nil end
    if not S.Fly then
        local hum = Hum()
        if hum then hum.PlatformStand = false end
        return
    end
    local hrp = HRP()
    if not hrp then return end
    local bv = Instance.new("BodyVelocity")
    bv.Velocity        = Vector3.new(0,0,0)
    bv.MaxForce        = Vector3.new(1e5,1e5,1e5)
    bv.Parent          = hrp
    S.flyBV            = bv
    local hum          = Hum()
    if hum then hum.PlatformStand = true end
    local CAM = workspace.CurrentCamera
    S.flyConn = RunService.RenderStepped:Connect(function()
        if not S.Fly then return end
        local fwd = UserInputService:IsKeyDown(Enum.KeyCode.W) and 1
                 or UserInputService:IsKeyDown(Enum.KeyCode.S) and -1 or 0
        local rt  = UserInputService:IsKeyDown(Enum.KeyCode.D) and 1
                 or UserInputService:IsKeyDown(Enum.KeyCode.A) and -1 or 0
        local up  = UserInputService:IsKeyDown(Enum.KeyCode.Space) and 1
                 or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) and -1 or 0
        local spd = 40
        local cf  = CAM.CFrame
        bv.Velocity = (cf.LookVector*fwd + cf.RightVector*rt + Vector3.new(0,up,0)) * spd
    end)
end

-- Anti-AFK
local VJoy = Instance.new("VirtualUser")
VJoy.Parent = game
local function UpdateAntiAFK()
    if S.afkConn then S.afkConn:Disconnect(); S.afkConn=nil end
    if not S.AntiAFK then return end
    S.afkConn = RunService.Heartbeat:Connect(function()
        VJoy:CaptureController()
        VJoy:ClickButton2(Vector2.new())
    end)
end

-- Infinite Jump
UserInputService.JumpRequest:Connect(function()
    if S.InfiniteJump then
        local hum = Hum()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

-- ═══════════════════════════════════════════════════════════════════
--  THEME ENGINE
-- ═══════════════════════════════════════════════════════════════════

-- Every colour key used throughout the UI
local C = {}   -- live palette — overwritten by ApplyTheme

-- ── Built-in themes ──────────────────────────────────────────────
local THEMES = {
    -- Default purple/dark sci-fi (original)
    Default = {
        bg      = Color3.fromRGB(12,  10,  18),
        panel   = Color3.fromRGB(20,  14,  32),
        card    = Color3.fromRGB(26,  18,  42),
        accent  = Color3.fromRGB(110, 50, 230),
        accent2 = Color3.fromRGB(60, 180, 255),
        dimText = Color3.fromRGB(140, 115, 185),
        text    = Color3.fromRGB(230, 220, 255),
        ok      = Color3.fromRGB(80,  220, 120),
        warn    = Color3.fromRGB(255, 180,  60),
        err     = Color3.fromRGB(255,  80,  80),
        border  = Color3.fromRGB(70,  45,  120),
    },
    -- Assassin — blood red + charcoal
    Assassin = {
        bg      = Color3.fromRGB(14,  10,  10),
        panel   = Color3.fromRGB(28,  16,  16),
        card    = Color3.fromRGB(38,  20,  20),
        accent  = Color3.fromRGB(200,  30,  30),
        accent2 = Color3.fromRGB(230,  80,  80),
        dimText = Color3.fromRGB(160,  90,  90),
        text    = Color3.fromRGB(235, 180, 180),
        ok      = Color3.fromRGB(200,  30,  30),
        warn    = Color3.fromRGB(220, 140,  40),
        err     = Color3.fromRGB(255,  50,  50),
        border  = Color3.fromRGB(100,  30,  30),
    },
    -- Casual — clean black + white
    Casual = {
        bg      = Color3.fromRGB(10,  10,  10),
        panel   = Color3.fromRGB(22,  22,  22),
        card    = Color3.fromRGB(34,  34,  34),
        accent  = Color3.fromRGB(230, 230, 230),
        accent2 = Color3.fromRGB(200, 200, 200),
        dimText = Color3.fromRGB(140, 140, 140),
        text    = Color3.fromRGB(255, 255, 255),
        ok      = Color3.fromRGB(140, 200, 140),
        warn    = Color3.fromRGB(220, 190,  80),
        err     = Color3.fromRGB(220,  80,  80),
        border  = Color3.fromRGB(70,  70,  70),
    },
    -- Steampunk — dark slate + amber/brass + ice blue
    Steampunk = {
        bg      = Color3.fromRGB(18,  20,  28),
        panel   = Color3.fromRGB(28,  32,  42),
        card    = Color3.fromRGB(36,  40,  54),
        accent  = Color3.fromRGB(190, 145,  40),   -- brass/amber
        accent2 = Color3.fromRGB(100, 190, 210),   -- ice blue
        dimText = Color3.fromRGB(130, 120,  80),
        text    = Color3.fromRGB(210, 185, 110),   -- warm parchment
        ok      = Color3.fromRGB(100, 190, 210),
        warn    = Color3.fromRGB(200, 155,  40),
        err     = Color3.fromRGB(210,  70,  50),
        border  = Color3.fromRGB(80,  75,  40),
    },
}

-- Registry of themed elements: list of { obj, prop, role }
-- role is a key in C (e.g. "bg", "accent", "text", …)
local ThemeRegistry = {}

-- Register one property of one Instance for live recolouring
local function TR(obj, prop, role)
    table.insert(ThemeRegistry, {obj=obj, prop=prop, role=role})
    if C[role] then obj[prop] = C[role] end
    return obj
end

-- Apply a theme palette and repaint all registered elements
local function ApplyTheme(name)
    local t = THEMES[name] or THEMES.Default
    for k, v in pairs(t) do C[k] = v end
    for _, e in ipairs(ThemeRegistry) do
        pcall(function() e.obj[e.prop] = C[e.role] end)
    end
end

-- Start with Default
ApplyTheme("Default")

-- ── GUI SCAFFOLD ──────────────────────────────────────────────────

local SGui = Instance.new("ScreenGui")
SGui.Name           = "UniversalScript_v3"
SGui.ResetOnSpawn   = false
SGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SGui.IgnoreGuiInset = true
SGui.Parent         = PGui

local Main = Instance.new("Frame", SGui)
Main.Size            = UDim2.new(0, CFG.UIWidth, 0, CFG.UIHeight)
Main.Position        = UDim2.new(0, 16, 0, 60)
Main.BackgroundColor3 = C.bg
Main.BorderSizePixel = 0
Main.ClipsDescendants = true
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 14)
local _ms = Instance.new("UIStroke", Main)
_ms.Color = C.border; _ms.Thickness = 1.5
TR(Main, "BackgroundColor3", "bg")
TR(_ms,  "Color",            "border")

-- Title bar
local TBar = Instance.new("Frame", Main)
TBar.Size = UDim2.new(1,0,0,46)
TBar.BackgroundColor3 = C.panel
TBar.BorderSizePixel  = 0
Instance.new("UICorner", TBar).CornerRadius = UDim.new(0,14)
TR(TBar, "BackgroundColor3", "panel")

local TLabel = Instance.new("TextLabel", TBar)
TLabel.Text = "⚡ UNIVERSAL v3"
TLabel.Font = Enum.Font.GothamBold; TLabel.TextSize = 14
TLabel.TextColor3 = C.text
TLabel.BackgroundTransparency = 1
TLabel.Size = UDim2.new(1,-50,1,0); TLabel.Position = UDim2.new(0,14,0,0)
TLabel.TextXAlignment = Enum.TextXAlignment.Left
TR(TLabel, "TextColor3", "text")

local MinBtn = Instance.new("TextButton", TBar)
MinBtn.Text = "—"; MinBtn.Font = Enum.Font.GothamBold; MinBtn.TextSize = 16
MinBtn.TextColor3 = C.dimText; MinBtn.BackgroundColor3 = C.card
MinBtn.Size = UDim2.new(0,28,0,24); MinBtn.Position = UDim2.new(1,-34,0.5,-12)
MinBtn.BorderSizePixel = 0
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0,6)
TR(MinBtn, "TextColor3",       "dimText")
TR(MinBtn, "BackgroundColor3", "card")

-- Tab bar
local TabBar = Instance.new("Frame", Main)
TabBar.Size = UDim2.new(1,0,0,34); TabBar.Position = UDim2.new(0,0,0,46)
TabBar.BackgroundColor3 = C.panel; TabBar.BorderSizePixel = 0
TR(TabBar, "BackgroundColor3", "panel")
local TBL = Instance.new("UIListLayout", TabBar)
TBL.FillDirection = Enum.FillDirection.Horizontal
TBL.HorizontalAlignment = Enum.HorizontalAlignment.Left
TBL.Padding = UDim.new(0,0)

-- Content host
local ContentHost = Instance.new("Frame", Main)
ContentHost.Size = UDim2.new(1,0,1,-80); ContentHost.Position = UDim2.new(0,0,0,80)
ContentHost.BackgroundTransparency = 1; ContentHost.BorderSizePixel = 0
ContentHost.ClipsDescendants = true

-- Pages table
local Pages = {}
local function MakePage(id)
    local sf = Instance.new("ScrollingFrame", ContentHost)
    sf.Name = id; sf.Size = UDim2.new(1,0,1,0)
    sf.BackgroundTransparency = 1; sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 4; sf.ScrollBarImageColor3 = C.border
    TR(sf, "ScrollBarImageColor3", "border")
    sf.CanvasSize = UDim2.new(0,0,0,0)
    sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sf.Visible = false
    local pad = Instance.new("UIPadding", sf)
    pad.PaddingTop = UDim.new(0,8); pad.PaddingBottom = UDim.new(0,10)
    pad.PaddingLeft = UDim.new(0,10); pad.PaddingRight = UDim.new(0,10)
    local ll = Instance.new("UIListLayout", sf)
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding = UDim.new(0,6)
    Pages[id] = sf; return sf
end

local PgFarm    = MakePage("Farm")
local PgStats   = MakePage("Stats")
local PgTools   = MakePage("Tools")
local PgBrowser = MakePage("Browser")
local PgExec    = MakePage("Exec")
local PgSpy     = MakePage("Spy")

-- Tab buttons
local TABS = {
    {"Farm","🌾"},{"Stats","📊"},{"Tools","🔧"},
    {"Browser","📂"},{"Exec","⚡"},{"Spy","🔍"},{"Theme","🎨"},
}
local TabBtns = {}
local tabW = math.floor(CFG.UIWidth / #TABS)
for _, td in ipairs(TABS) do
    local id, icon = td[1], td[2]
    local btn = Instance.new("TextButton", TabBar)
    btn.Name = id; btn.Text = icon.."\n"..id
    btn.Font = Enum.Font.GothamSemibold; btn.TextSize = 10
    btn.TextColor3 = C.dimText; btn.BackgroundColor3 = C.panel
    btn.Size = UDim2.new(0,tabW,1,0); btn.BorderSizePixel = 0
    btn.LineHeight = 1.1
    TR(btn, "TextColor3",       "dimText")
    TR(btn, "BackgroundColor3", "panel")
    TabBtns[id] = btn
end

-- forward-declare SwitchTab so pages can call it
local SwitchTab
local ActiveTab = ""
SwitchTab = function(id)
    ActiveTab = id
    for _, p in pairs(Pages) do p.Visible = false end
    if Pages[id] then Pages[id].Visible = true end
    for tid, btn in pairs(TabBtns) do
        -- use live C values so themes are respected
        btn.BackgroundColor3 = tid==id and C.card    or C.panel
        btn.TextColor3       = tid==id and C.text    or C.dimText
    end
end  -- end SwitchTab

for _, td in ipairs(TABS) do
    local id = td[1]
    TabBtns[id].MouseButton1Click:Connect(function() SwitchTab(id) end)
end

-- ── Shared UI builders ────────────────────────────────────────────
local function Card(parent, h, lo)
    local f = Instance.new("Frame", parent)
    f.Size = UDim2.new(1,0,0,h or 40)
    f.BackgroundColor3 = C.card; f.BorderSizePixel = 0
    f.LayoutOrder = lo or 0
    Instance.new("UICorner", f).CornerRadius = UDim.new(0,8)
    TR(f, "BackgroundColor3", "card")
    return f
end

local function SecLabel(parent, txt, lo)
    local l = Instance.new("TextLabel", parent)
    l.Text = "── "..txt.." ──"
    l.Font = Enum.Font.GothamBold; l.TextSize = 10
    l.TextColor3 = C.accent; l.BackgroundTransparency = 1
    l.Size = UDim2.new(1,0,0,18); l.LayoutOrder = lo or 0
    l.TextXAlignment = Enum.TextXAlignment.Left
    TR(l, "TextColor3", "accent")
    return l
end

-- col can be a Color3 literal OR a theme role string like "dimText"/"accent"
local function Label(parent, txt, sz, col)
    local l = Instance.new("TextLabel", parent)
    l.Text = txt; l.Font = Enum.Font.Gotham; l.TextSize = sz or 12
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1,0,1,0); l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextWrapped = true
    if type(col) == "string" then
        -- role string: register + apply
        l.TextColor3 = C[col] or C.text
        TR(l, "TextColor3", col)
    elseif col then
        -- raw Color3: apply but do not register (won't re-theme)
        l.TextColor3 = col
    else
        -- nil → default text colour, register it
        l.TextColor3 = C.text
        TR(l, "TextColor3", "text")
    end
    return l
end

local function TextBox(parent, placeholder, sz)
    local b = Instance.new("TextBox", parent)
    b.PlaceholderText = placeholder or ""; b.Text = ""
    b.Font = Enum.Font.Gotham; b.TextSize = sz or 11
    b.TextColor3 = C.text; b.PlaceholderColor3 = C.dimText
    b.BackgroundColor3 = C.panel; b.BorderSizePixel = 0
    b.ClearTextOnFocus = false; b.TextXAlignment = Enum.TextXAlignment.Left
    b.TextWrapped = true
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
    local p = Instance.new("UIPadding", b)
    p.PaddingLeft = UDim.new(0,6); p.PaddingRight = UDim.new(0,4)
    TR(b, "TextColor3",       "text")
    TR(b, "PlaceholderColor3","dimText")
    TR(b, "BackgroundColor3", "panel")
    return b
end

local function Btn(parent, txt, col)
    local b = Instance.new("TextButton", parent)
    b.Text = txt; b.Font = Enum.Font.GothamBold; b.TextSize = 11
    b.TextColor3 = C.text; b.BackgroundColor3 = col or C.accent
    b.BorderSizePixel = 0
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,7)
    TR(b, "TextColor3", "text")
    -- only register bg if using a named role
    if not col or col == C.accent  then TR(b,"BackgroundColor3","accent")
    elseif col == C.card           then TR(b,"BackgroundColor3","card")
    elseif col == C.border         then TR(b,"BackgroundColor3","border")
    elseif col == C.panel          then TR(b,"BackgroundColor3","panel") end
    return b
end

-- ── Slider helper ─────────────────────────────────────────────────
local function Slider(parent, lbl, minV, maxV, cur, lo, cb)
    local row = Card(parent, 52, lo)
    local ll = Instance.new("TextLabel", row)
    ll.Text = lbl; ll.Font = Enum.Font.GothamSemibold; ll.TextSize = 11
    ll.TextColor3 = C.dimText; ll.BackgroundTransparency = 1
    ll.Size = UDim2.new(0.6,0,0,18); ll.Position = UDim2.new(0,8,0,4)
    ll.TextXAlignment = Enum.TextXAlignment.Left
    TR(ll, "TextColor3", "dimText")

    local vl = Instance.new("TextLabel", row)
    vl.Text = tostring(cur); vl.Font = Enum.Font.GothamBold; vl.TextSize = 11
    vl.TextColor3 = C.accent2; vl.BackgroundTransparency = 1
    vl.Size = UDim2.new(0.4,-8,0,18); vl.Position = UDim2.new(0.6,0,0,4)
    vl.TextXAlignment = Enum.TextXAlignment.Right
    TR(vl, "TextColor3", "accent2")

    local track = Instance.new("Frame", row)
    track.Size = UDim2.new(1,-16,0,6); track.Position = UDim2.new(0,8,0,32)
    track.BackgroundColor3 = C.border; track.BorderSizePixel = 0
    Instance.new("UICorner", track).CornerRadius = UDim.new(1,0)
    TR(track, "BackgroundColor3", "border")

    local pct = math.clamp((cur-minV)/(maxV-minV),0,1)
    local fill = Instance.new("Frame", track)
    fill.Size = UDim2.new(pct,0,1,0); fill.BackgroundColor3 = C.accent
    fill.BorderSizePixel = 0; Instance.new("UICorner", fill).CornerRadius = UDim.new(1,0)
    TR(fill, "BackgroundColor3", "accent")

    local dragging = false
    track.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then dragging=true end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then dragging=false end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType~=Enum.UserInputType.MouseMovement
        and i.UserInputType~=Enum.UserInputType.Touch then return end
        local ap = track.AbsolutePosition; local as = track.AbsoluteSize
        local p  = math.clamp((i.Position.X - ap.X)/as.X, 0, 1)
        local v  = math.floor(minV + p*(maxV-minV))
        fill.Size = UDim2.new(p,0,1,0); vl.Text = tostring(v)
        if cb then cb(v) end
    end)
end

-- Toggle helper (returns frame + setState fn)
local function Toggle(parent, labelTxt, lo, default, cb)
    local row = Card(parent, 38, lo)
    local lbl = Instance.new("TextLabel", row)
    lbl.Text = labelTxt; lbl.Font = Enum.Font.Gotham; lbl.TextSize = 12
    lbl.TextColor3 = C.text; lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1,-56,1,0); lbl.Position = UDim2.new(0,10,0,0)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    TR(lbl, "TextColor3", "text")

    local track = Instance.new("Frame", row)
    track.Size = UDim2.new(0,40,0,20); track.Position = UDim2.new(1,-48,0.5,-10)
    track.BackgroundColor3 = default and C.accent or C.border; track.BorderSizePixel = 0
    Instance.new("UICorner", track).CornerRadius = UDim.new(1,0)
    -- track bg is dynamic (on/off) so we register the off-state role only for off repaints
    TR(track, "BackgroundColor3", default and "accent" or "border")

    local knob = Instance.new("Frame", track)
    knob.Size = UDim2.new(0,14,0,14)
    knob.Position = default and UDim2.new(1,-17,0.5,-7) or UDim2.new(0,3,0.5,-7)
    knob.BackgroundColor3 = C.text; knob.BorderSizePixel = 0
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1,0)
    TR(knob, "BackgroundColor3", "text")

    local state = default or false
    local ti = TweenInfo.new(0.18, Enum.EasingStyle.Quad)
    local function setState(v)
        state = v
        -- use live C values so switching theme while toggle is on/off stays correct
        TweenService:Create(track, ti, {BackgroundColor3 = v and C.accent or C.border}):Play()
        TweenService:Create(knob,  ti, {Position = v and UDim2.new(1,-17,0.5,-7) or UDim2.new(0,3,0.5,-7)}):Play()
        if cb then cb(v) end
    end
    row.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then
            setState(not state)
        end
    end)
    return row, setState
end

-- ═══════════════════════════════════════════════════════════════════
--  FARM PAGE
-- ═══════════════════════════════════════════════════════════════════
do
    local lo = 0
    local function lo_() lo=lo+1; return lo end

    SecLabel(PgFarm, "AUTO FARMING", lo_())

    Toggle(PgFarm, "Auto Farm (teleport to targets)", lo_(), false, function(v)
        S.AutoFarm = v
        if v then StartFarm() else StopFarm() end
        Notify("Auto Farm", v and "ON" or "OFF")
    end)

    Toggle(PgFarm, "Auto Collect Items (coins/gems/drops)", lo_(), false, function(v)
        S.AutoCollect = v; S.FarmTarget = v and "Item" or "Mob"
    end)

    Toggle(PgFarm, "Auto Respawn after death", lo_(), false, function(v)
        S.AutoRespawn = v
    end)

    -- Farm target selector
    local tCard = Card(PgFarm, 44, lo_())
    local tLbl = Label(tCard, "Target Type", 11, "dimText")
    tLbl.Size = UDim2.new(0,90,1,0); tLbl.Position = UDim2.new(0,8,0,0)
    local TARGETS = {"Mob","Item","NPC","Boss"}
    for i, t in ipairs(TARGETS) do
        local b = Btn(tCard, t, S.FarmTarget==t and C.accent or C.border)
        b.Size = UDim2.new(0,62,0,26); b.Position = UDim2.new(0,96+(i-1)*66,0.5,-13)
        b.MouseButton1Click:Connect(function()
            S.FarmTarget = t
            for j, tt in ipairs(TARGETS) do
                local ob = tCard:FindFirstChild("tb_"..j)
                if ob then ob.BackgroundColor3 = C.border end
            end
            b.BackgroundColor3 = C.accent
        end)
        b.Name = "tb_"..i
    end

    SecLabel(PgFarm, "FARM SPEED", lo_())

    Slider(PgFarm, "Range (studs)", 10, 300, 60, lo_(), function(v) CFG.FarmRange = v end)
    Slider(PgFarm, "Tick interval (× 0.01s)", 1, 50, 10, lo_(), function(v)
        CFG.FarmInterval = v * 0.01
    end)

    SecLabel(PgFarm, "QUICK ACTIONS", lo_())

    local qRow = Card(PgFarm, 44, lo_())
    local qBtns = {
        {"Farm ON",  function() S.AutoFarm=true;  StartFarm() end},
        {"Farm OFF", function() S.AutoFarm=false; StopFarm()  end},
        {"Collect",  function() S.FarmTarget="Item" end},
        {"Mobs",     function() S.FarmTarget="Mob"  end},
    }
    for i, qb in ipairs(qBtns) do
        local b = Btn(qRow, qb[1], i<=2 and C.accent or C.border)
        b.Size = UDim2.new(0,78,0,28); b.Position = UDim2.new(0,4+(i-1)*83,0.5,-14)
        b.MouseButton1Click:Connect(qb[2])
    end
end

-- ═══════════════════════════════════════════════════════════════════
--  STATS PAGE
-- ═══════════════════════════════════════════════════════════════════
do
    local lo = 0
    local function lo_() lo=lo+1; return lo end

    SecLabel(PgStats, "MOVEMENT", lo_())

    Slider(PgStats, "Walk Speed (0–300)", 0, 300, 16, lo_(), function(v)
        local h = Hum(); if h then h.WalkSpeed = v end
    end)
    Slider(PgStats, "Jump Power (0–400)", 0, 400, 50, lo_(), function(v)
        local h = Hum(); if h then h.JumpPower = v end
    end)
    Slider(PgStats, "Max Health (1–10000)", 1, 10000, 100, lo_(), function(v)
        local h = Hum(); if h then h.MaxHealth=v; h.Health=v end
    end)

    SecLabel(PgStats, "LEADERSTATS EDITOR", lo_())

    local lsStatus = Card(PgStats, 30, lo_())
    local lsLbl = Label(lsStatus, "Click Refresh to load leaderstats", 11, "dimText")
    lsLbl.Position = UDim2.new(0,8,0,0)

    local lsContainer = Instance.new("Frame", PgStats)
    lsContainer.Name = "LSContainer"
    lsContainer.Size = UDim2.new(1,0,0,0)
    lsContainer.BackgroundTransparency = 1; lsContainer.BorderSizePixel = 0
    lsContainer.AutomaticSize = Enum.AutomaticSize.Y
    lsContainer.LayoutOrder = lo_()
    local lsLL = Instance.new("UIListLayout", lsContainer)
    lsLL.Padding = UDim.new(0,5); lsLL.SortOrder = Enum.SortOrder.LayoutOrder

    local function RefreshLS()
        for _, c in ipairs(lsContainer:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local ls = LP:FindFirstChild("leaderstats")
        if not ls then
            lsLbl.Text = "No leaderstats found on your character."
            return
        end
        lsLbl.Text = "Leaderstats loaded ✅"
        for _, stat in ipairs(ls:GetChildren()) do
            if stat:IsA("IntValue") or stat:IsA("NumberValue") or stat:IsA("StringValue") then
                local row = Card(lsContainer, 40, 0)
                local nl = Label(row, stat.Name, 11, "dimText")
                nl.Size = UDim2.new(0.38,0,1,0); nl.Position = UDim2.new(0,8,0,0)
                local box = TextBox(row, tostring(stat.Value), 11)
                box.Text = tostring(stat.Value)
                box.Size = UDim2.new(0.35,0,0,26); box.Position = UDim2.new(0.38,4,0.5,-13)
                local setBtn = Btn(row, "SET", "accent")
                setBtn.Size = UDim2.new(0,44,0,26); setBtn.Position = UDim2.new(1,-52,0.5,-13)
                setBtn.MouseButton1Click:Connect(function()
                    local n = tonumber(box.Text)
                    if n then stat.Value = n
                        Notify("Stat", stat.Name.." → "..tostring(n))
                    elseif stat:IsA("StringValue") then
                        stat.Value = box.Text
                    end
                end)
            end
        end
    end

    local rfBtn = Btn(PgStats, "↺  Refresh Leaderstats", C.card)
    rfBtn.Size = UDim2.new(1,0,0,34); rfBtn.LayoutOrder = lo_()
    rfBtn.MouseButton1Click:Connect(RefreshLS)
end

-- ═══════════════════════════════════════════════════════════════════
--  TOOLS PAGE
-- ═══════════════════════════════════════════════════════════════════
do
    local lo = 0
    local function lo_() lo=lo+1; return lo end

    SecLabel(PgTools, "MOVEMENT CHEATS", lo_())
    Toggle(PgTools,"Speed Hack  (× 3 walk speed)",lo_(),false,function(v)
        S.SpeedHack=v; local h=Hum(); if h then h.WalkSpeed = v and 48 or 16 end
    end)
    Toggle(PgTools,"Infinite Jump",lo_(),false,function(v) S.InfiniteJump=v end)
    Toggle(PgTools,"Fly Mode  (WASD + Space/Ctrl)",lo_(),false,function(v)
        S.Fly=v; UpdateFly()
    end)
    Toggle(PgTools,"No-Clip",lo_(),false,function(v) S.NoClip=v; UpdateNoClip() end)

    SecLabel(PgTools, "SURVIVAL", lo_())
    Toggle(PgTools,"God Mode (∞ health)",lo_(),false,function(v)
        S.GodMode=v; local h=Hum()
        if h then h.MaxHealth=v and math.huge or 100; h.Health=v and math.huge or 100 end
    end)
    Toggle(PgTools,"Anti-AFK",lo_(),false,function(v)
        S.AntiAFK=v; UpdateAntiAFK()
    end)

    SecLabel(PgTools, "TELEPORT", lo_())

    local function TpBtn(lbl, lo, fn)
        local b = Btn(PgTools, lbl, C.card); b.LayoutOrder = lo
        b.Size = UDim2.new(1,0,0,34)
        Instance.new("UIStroke",b).Color = C.border
        b.MouseButton1Click:Connect(fn); return b
    end

    TpBtn("📍 Teleport to Spawn", lo_(), function()
        local sp = workspace:FindFirstChild("SpawnLocation")
        local h  = HRP()
        if h and sp then h.CFrame = sp.CFrame + Vector3.new(0,5,0); Notify("TP","→ Spawn")
        else Notify("TP","No SpawnLocation found") end
    end)

    TpBtn("🎯 Teleport to Nearest Player", lo_(), function()
        local h = HRP(); if not h then return end
        local best, bd = nil, math.huge
        for _, p in ipairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local r = p.Character:FindFirstChild("HumanoidRootPart")
                if r then
                    local d = (r.Position-h.Position).Magnitude
                    if d<bd then best,bd=r,d end
                end
            end
        end
        if best then h.CFrame = best.CFrame + Vector3.new(0,3,4); Notify("TP","→ Player")
        else Notify("TP","No players nearby") end
    end)

    TpBtn("🌐 Teleport to Map Center (0,100,0)", lo_(), function()
        local h = HRP(); if h then h.CFrame = CFrame.new(0,100,0) end
    end)

    TpBtn("📌 Teleport to Camera Look Target", lo_(), function()
        local h   = HRP(); if not h then return end
        local cam = workspace.CurrentCamera
        local ray = workspace:Raycast(
            cam.CFrame.Position, cam.CFrame.LookVector * 500)
        if ray then
            h.CFrame = CFrame.new(ray.Position + Vector3.new(0,4,0))
            Notify("TP","→ Camera target")
        end
    end)

    SecLabel(PgTools, "VISUAL / ESP", lo_())

    local EspConns = {}
    local function ClearEsp()
        for _, c in ipairs(EspConns) do pcall(function() c:Destroy() end) end
        EspConns = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                for _, v in ipairs(p.Character:GetDescendants()) do
                    if v:IsA("BoxHandleAdornment") and v.Name=="ESP_Box" then v:Destroy() end
                end
            end
        end
    end

    Toggle(PgTools,"Player ESP (box highlight)",lo_(),false,function(v)
        ClearEsp()
        if not v then return end
        local function AddEsp(char)
            local root = char:WaitForChild("HumanoidRootPart", 5)
            if not root then return end
            local box = Instance.new("BoxHandleAdornment")
            box.Name = "ESP_Box"; box.Adornee = root
            box.Size = Vector3.new(3,5,3); box.AlwaysOnTop = true
            box.ZIndex = 5; box.Transparency = 0.5
            box.Color3 = Color3.fromRGB(255,80,80)
            box.Parent = root; table.insert(EspConns, box)
        end
        for _, p in ipairs(Players:GetPlayers()) do
            if p~=LP and p.Character then AddEsp(p.Character) end
            p.CharacterAdded:Connect(AddEsp)
        end
        Players.PlayerAdded:Connect(function(p)
            p.CharacterAdded:Connect(AddEsp)
        end)
    end)
end

-- ═══════════════════════════════════════════════════════════════════
--  REMOTE BROWSER PAGE
-- ═══════════════════════════════════════════════════════════════════
do
    local lo = 0
    local function lo_() lo=lo+1; return lo end

    -- Status bar
    local statusCard = Card(PgBrowser, 34, lo_())
    local statusLbl = Label(statusCard, "⏳ Not scanned yet. Press Scan.", 11, "dimText")
    statusLbl.Position = UDim2.new(0,8,0,0)

    -- Controls row
    local ctrlRow = Card(PgBrowser, 40, lo_())
    local scanBtn  = Btn(ctrlRow, "🔍 Scan All Services", "accent")
    local rescanBtn = Btn(ctrlRow, "↺ Re-scan", "border")
    scanBtn.Size  = UDim2.new(0,170,0,28); scanBtn.Position = UDim2.new(0,6,0.5,-14)
    rescanBtn.Size = UDim2.new(0,90,0,28); rescanBtn.Position = UDim2.new(0,180,0.5,-14)

    -- Filter box
    local filterCard = Card(PgBrowser, 36, lo_())
    local filterBox = TextBox(filterCard, "Filter by name...", 11)
    filterBox.Size = UDim2.new(1,-16,0,26); filterBox.Position = UDim2.new(0,8,0.5,-13)

    -- List container
    local listFrame = Instance.new("Frame", PgBrowser)
    listFrame.Size = UDim2.new(1,0,0,0)
    listFrame.BackgroundTransparency = 1; listFrame.BorderSizePixel = 0
    listFrame.AutomaticSize = Enum.AutomaticSize.Y
    listFrame.LayoutOrder = lo_()
    local listLL = Instance.new("UIListLayout", listFrame)
    listLL.Padding = UDim.new(0,4); listLL.SortOrder = Enum.SortOrder.LayoutOrder

    local function RebuildBrowserList(filter)
        for _, c in ipairs(listFrame:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local count = 0
        for i, r in ipairs(ScannedRemotes) do
            local show = not filter or filter=="" or r.name:lower():find(filter:lower(), 1, true)
                      or r.fullPath:lower():find(filter:lower(), 1, true)
            if show then
                count = count + 1
                local row = Card(listFrame, 62, i)
                -- type badge color
                local tcol = r.rtype:find("Remote") and C.accent or C.accent2
                local badge = Instance.new("TextLabel", row)
                badge.Text = r.rtype:gsub("Remote","R"):gsub("Bindable","B"):gsub("Function","Fn"):gsub("Event","Ev")
                badge.Font = Enum.Font.GothamBold; badge.TextSize = 9
                badge.TextColor3 = tcol; badge.BackgroundColor3 = C.panel
                badge.Size = UDim2.new(0,46,0,18); badge.Position = UDim2.new(0,6,0,6)
                badge.TextXAlignment = Enum.TextXAlignment.Center; badge.BorderSizePixel=0
                Instance.new("UICorner",badge).CornerRadius=UDim.new(0,4)

                local nameL = Label(row, r.name, 11, "text")
                nameL.Size = UDim2.new(1,-120,0,18); nameL.Position = UDim2.new(0,58,0,4)
                nameL.TextTruncate = Enum.TextTruncate.AtEnd; nameL.TextWrapped=false

                local hitL = Label(row, "hits: "..r.hitCount.." · "..(r.observed and "📡 observed" or "⌛ unobserved"), 9, "dimText")
                hitL.Size = UDim2.new(1,-120,0,14); hitL.Position = UDim2.new(0,58,0,22)

                local pathL = Label(row, r.fullPath, 9, "border")
                pathL.Size = UDim2.new(1,-8,0,13); pathL.Position = UDim2.new(0,6,0,44)
                pathL.TextTruncate = Enum.TextTruncate.AtEnd; pathL.TextWrapped=false

                -- Add to Executor button
                local addBtn = Btn(row, "+ Exec", "accent")
                addBtn.Size = UDim2.new(0,52,0,22); addBtn.Position = UDim2.new(1,-58,0,4)
                addBtn.TextSize = 10
                addBtn.MouseButton1Click:Connect(function()
                    -- build a default call expression from observed args or empty
                    local argsTable = {}
                    if r.observedArgs then
                        for idx, av in ipairs(r.observedArgs) do
                            argsTable[idx] = av
                        end
                    end
                    local method = (r.rtype=="RemoteFunction" or r.rtype=="BindableFunction")
                        and ":InvokeServer(unpack(args))"
                        or  ":FireServer(unpack(args))"
                    if r.rtype=="BindableEvent" then method = ":Fire(unpack(args))" end
                    if r.rtype=="BindableFunction" then method = ":Invoke(unpack(args))" end
                    table.insert(LoopEntries, {
                        name       = r.name,
                        callExpr   = r.fullPath .. method,
                        argsTable  = argsTable,
                        vars       = {},
                        delay      = 0,
                        interval   = 1,
                        active     = false,
                        loopConn   = nil,
                        fireCount  = 0,
                        lastStatus = "—",
                        observed   = r.observed,
                    })
                    Notify("Executor", "Added: "..r.name)
                    SwitchTab("Exec")
                end)

                -- Spy-blacklist toggle
                local blBtn = Btn(row, S.SpyBlacklist[r.fullPath] and "👁 off" or "👁 on", "border")
                blBtn.Size = UDim2.new(0,46,0,22); blBtn.Position = UDim2.new(1,-58,0,28)
                blBtn.TextSize = 10
                blBtn.MouseButton1Click:Connect(function()
                    S.SpyBlacklist[r.fullPath] = not S.SpyBlacklist[r.fullPath]
                    blBtn.Text = S.SpyBlacklist[r.fullPath] and "👁 off" or "👁 on"
                end)
            end
        end
        statusLbl.Text = ScanDone
            and ("✅ "..#ScannedRemotes.." remotes found · showing "..count)
            or  "⏳ Scanning…"
    end

    local function DoScan()
        statusLbl.Text = "⏳ Scanning all services…"
        RunScan()
        -- poll until done
        task.spawn(function()
            repeat task.wait(0.3) until ScanDone
            RebuildBrowserList(filterBox.Text)
        end)
    end

    scanBtn.MouseButton1Click:Connect(DoScan)
    rescanBtn.MouseButton1Click:Connect(DoScan)
    filterBox:GetPropertyChangedSignal("Text"):Connect(function()
        RebuildBrowserList(filterBox.Text)
    end)
    ScanUpdateSig.Event:Connect(function() RebuildBrowserList(filterBox.Text) end)
end

-- ═══════════════════════════════════════════════════════════════════
--  EXECUTOR / LOOPER PAGE
--  Add entries manually or from Browser.
--  Each entry has: name, callExpr, argsTable [{1]=…}, vars {k=v},
--  delay (s before first fire), interval (s between fires).
--  Variables in argsTable values use {varName} substitution.
-- ═══════════════════════════════════════════════════════════════════
do
    local lo = 0
    local function lo_() lo=lo+1; return lo end

    SecLabel(PgExec, "ADD / EDIT ENTRY", lo_())

    -- Form card
    local fCard = Card(PgExec, 260, lo_())
    local fLL   = Instance.new("UIListLayout", fCard)
    fLL.Padding = UDim.new(0,4); fLL.SortOrder = Enum.SortOrder.LayoutOrder
    local fp = Instance.new("UIPadding", fCard)
    fp.PaddingTop=UDim.new(0,6);fp.PaddingBottom=UDim.new(0,6)
    fp.PaddingLeft=UDim.new(0,6);fp.PaddingRight=UDim.new(0,6)

    local function FRow(h, lo2)
        local r = Instance.new("Frame", fCard)
        r.Size = UDim2.new(1,0,0,h); r.BackgroundTransparency=1
        r.BorderSizePixel=0; r.LayoutOrder=lo2; return r
    end

    -- Name
    local nameRow = FRow(26, 1)
    local nameLbl = Label(nameRow, "Label", 10, "dimText")
    nameLbl.Size = UDim2.new(0,50,1,0)
    local nameBox = TextBox(nameRow, "e.g. Attack", 11)
    nameBox.Size = UDim2.new(1,-54,1,0); nameBox.Position = UDim2.new(0,54,0,0)

    -- Call expression
    local exprRow = FRow(48, 2)
    local exprLbl = Label(exprRow, "Call\nexpr", 10, "dimText")
    exprLbl.Size = UDim2.new(0,50,1,0); exprLbl.TextWrapped=true
    local exprBox = TextBox(exprRow,
        'game:GetService("RS").X:FireServer(unpack(args))', 10)
    exprBox.Size = UDim2.new(1,-54,1,0); exprBox.Position = UDim2.new(0,54,0,0)
    exprBox.MultiLine = true; exprBox.TextYAlignment = Enum.TextYAlignment.Top

    -- Args table hint
    local argsRow = FRow(26, 3)
    local argsLbl = Label(argsRow, "Args\n[1],[2]…", 10, "dimText")
    argsLbl.Size = UDim2.new(0,50,1,0); argsLbl.TextWrapped=true
    local argsBox = TextBox(argsRow, '"SoccerEvent","GZ_Step",1', 10)
    argsBox.Size = UDim2.new(1,-54,1,0); argsBox.Position = UDim2.new(0,54,0,0)
    Instance.new("UITextSizeConstraint",argsBox).MaxTextSize = 11

    -- Vars
    local varsRow = FRow(26, 4)
    local varsLbl = Label(varsRow, "Vars\nk=v,…", 10, "dimText")
    varsLbl.Size = UDim2.new(0,50,1,0); varsLbl.TextWrapped=true
    local varsBox = TextBox(varsRow, 'speed=100,mode="run"', 10)
    varsBox.Size = UDim2.new(1,-54,1,0); varsBox.Position = UDim2.new(0,54,0,0)

    -- Delay + Interval
    local diRow = FRow(26, 5)
    local dLbl = Label(diRow, "Delay(s)", 10, "dimText")
    dLbl.Size = UDim2.new(0,56,1,0)
    local dBox = TextBox(diRow, "0", 11)
    dBox.Size = UDim2.new(0,50,1,0); dBox.Position = UDim2.new(0,58,0,0)
    local iLbl = Label(diRow, "Interval(s)", 10, "dimText")
    iLbl.Size = UDim2.new(0,66,1,0); iLbl.Position = UDim2.new(0,112,0,0)
    local iBox = TextBox(diRow, "1", 11)
    iBox.Size = UDim2.new(0,50,1,0); iBox.Position = UDim2.new(0,180,0,0)

    -- Observed-args hint strip
    local hintRow = FRow(20, 6)
    local hintLbl = Label(hintRow, "💡 Select a remote from Browser to pre-fill args", 9, "dimText")

    -- Add / Fire Once buttons
    local btnRow = FRow(30, 7)
    local addBtn  = Btn(btnRow, "+ Add to Queue", "accent")
    addBtn.Size = UDim2.new(0,140,1,-2); addBtn.Position = UDim2.new(0,0,0,1)
    local fireOnceBtn = Btn(btnRow, "▶ Fire Once", Color3.fromRGB(30,120,70))
    fireOnceBtn.Size = UDim2.new(0,100,1,-2); fireOnceBtn.Position = UDim2.new(0,144,0,1)
    local clrBtn = Btn(btnRow, "✕ Clear", Color3.fromRGB(90,20,20))
    clrBtn.Size = UDim2.new(0,72,1,-2); clrBtn.Position = UDim2.new(0,248,0,1)

    -- Parse argsBox text → argsTable
    local function ParseArgs(txt)
        local t = {}
        if txt=="" then return t end
        local fn = loadstring("return {"..txt.."}")
        if fn then
            local ok, res = pcall(fn)
            if ok and type(res)=="table" then
                for k,v in pairs(res) do t[k]=v end
            end
        end
        return t
    end

    -- Parse varsBox text → vars dict
    local function ParseVars(txt)
        local t = {}
        if txt=="" then return t end
        local fn = loadstring("return {"..txt.."}")
        if fn then
            local ok, res = pcall(fn)
            if ok and type(res)=="table" then
                for k,v in pairs(res) do t[k]=v end
            end
        end
        return t
    end

    local function MakeEntry()
        return {
            name       = nameBox.Text ~= "" and nameBox.Text or "Remote",
            callExpr   = exprBox.Text,
            argsTable  = ParseArgs(argsBox.Text),
            vars       = ParseVars(varsBox.Text),
            delay      = tonumber(dBox.Text) or 0,
            interval   = tonumber(iBox.Text) or 1,
            active     = false,
            loopConn   = nil,
            fireCount  = 0,
            lastStatus = "—",
            observed   = false,
        }
    end

    local function ClearForm()
        nameBox.Text=""; exprBox.Text=""; argsBox.Text=""
        varsBox.Text=""; dBox.Text="0"; iBox.Text="1"
    end

    -- Entry list
    SecLabel(PgExec, "QUEUE", lo_())

    local queueFrame = Instance.new("Frame", PgExec)
    queueFrame.Size = UDim2.new(1,0,0,0)
    queueFrame.BackgroundTransparency=1; queueFrame.BorderSizePixel=0
    queueFrame.AutomaticSize = Enum.AutomaticSize.Y
    queueFrame.LayoutOrder = lo_()
    local qLL = Instance.new("UIListLayout", queueFrame)
    qLL.Padding = UDim.new(0,5); qLL.SortOrder = Enum.SortOrder.LayoutOrder

    local function RebuildQueue()
        for _, c in ipairs(queueFrame:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        if #LoopEntries == 0 then
            local empty = Card(queueFrame, 30, 0)
            Label(empty, "No entries yet. Use Add to Queue above.", 10, "dimText").Position = UDim2.new(0,8,0,0)
            return
        end
        for idx, entry in ipairs(LoopEntries) do
            local row = Card(queueFrame, 76, idx)
            -- entry header row
            local unobsWarning = not entry.observed and "⚠ unobserved · " or ""
            local topL = Label(row, "⚡ "..entry.name.."  "..unobsWarning.."["..entry.lastStatus.."]", 11, "text")
            topL.Size = UDim2.new(1,-10,0,18); topL.Position = UDim2.new(0,6,0,4)
            topL.TextTruncate = Enum.TextTruncate.AtEnd

            -- Keep status live
            FireUpdateSig.Event:Connect(function()
                if topL.Parent then
                    topL.Text = "⚡ "..entry.name.."  ["..(entry.lastStatus or "—").."]"
                end
            end)

            local infoL = Label(row,
                "delay "..tostring(entry.delay).."s · every "..tostring(entry.interval).."s · fired #"..(entry.fireCount or 0),
                9, "dimText")
            infoL.Size = UDim2.new(1,-10,0,14); infoL.Position = UDim2.new(0,6,0,22)

            -- edit var inline: show vars as editable mini-labels
            local varStr = ""
            for k, v in pairs(entry.vars or {}) do
                varStr = varStr .. k .. "=" .. tostring(v) .. "  "
            end
            local varEditBox = TextBox(row, "vars: k=v, …", 9)
            varEditBox.Text = varStr:match("^%s*(.-)%s*$") or ""
            varEditBox.Size = UDim2.new(1,-10,0,18); varEditBox.Position = UDim2.new(0,6,0,38)
            varEditBox.FocusLost:Connect(function()
                local fn = loadstring("return {"..varEditBox.Text.."}")
                if fn then
                    local ok, res = pcall(fn)
                    if ok and type(res)=="table" then entry.vars = res end
                end
            end)

            -- buttons
            local i = idx
            local onBtn  = Btn(row, entry.active and "■ Stop" or "▶ Loop",
                entry.active and Color3.fromRGB(140,40,40) or Color3.fromRGB(30,120,60))
            onBtn.Size = UDim2.new(0,62,0,22); onBtn.Position = UDim2.new(0,6,0,54)
            onBtn.MouseButton1Click:Connect(function()
                entry.active = not entry.active
                if entry.active then StartEntryLoop(entry) else StopEntryLoop(entry) end
                RebuildQueue()
            end)

            local fireBtn = Btn(row, "▶ Once", Color3.fromRGB(20,80,50))
            fireBtn.Size = UDim2.new(0,56,0,22); fireBtn.Position = UDim2.new(0,72,0,54)
            fireBtn.MouseButton1Click:Connect(function() task.spawn(ExecEntry, entry) end)

            local editBtn = Btn(row, "✏ Edit", "border")
            editBtn.Size = UDim2.new(0,52,0,22); editBtn.Position = UDim2.new(0,132,0,54)
            editBtn.MouseButton1Click:Connect(function()
                nameBox.Text = entry.name; exprBox.Text = entry.callExpr or ""
                local at = {}
                for k, v in pairs(entry.argsTable or {}) do at[k]=v end
                local atParts={}
                for k2,v2 in pairs(at) do
                    atParts[#atParts+1]="["..k2.."]="..SerializeArg(v2)
                end
                argsBox.Text = table.concat(atParts,",")
                local vParts={}
                for k3,v3 in pairs(entry.vars or {}) do
                    vParts[#vParts+1]=k3.."="..SerializeArg(v3)
                end
                varsBox.Text = table.concat(vParts,",")
                dBox.Text = tostring(entry.delay); iBox.Text = tostring(entry.interval)
            end)

            local delBtn = Btn(row, "✕", Color3.fromRGB(90,20,20))
            delBtn.Size = UDim2.new(0,28,0,22); delBtn.Position = UDim2.new(0,188,0,54)
            delBtn.MouseButton1Click:Connect(function()
                StopEntryLoop(entry); table.remove(LoopEntries, i); RebuildQueue()
            end)
        end
    end

    addBtn.MouseButton1Click:Connect(function()
        local e = MakeEntry()
        if e.callExpr == "" then Notify("Executor","Enter a call expression!"); return end
        table.insert(LoopEntries, e); RebuildQueue()
        Notify("Executor","Added: "..e.name)
    end)

    fireOnceBtn.MouseButton1Click:Connect(function()
        local e = MakeEntry()
        if e.callExpr == "" then Notify("Executor","Enter a call expression!"); return end
        task.spawn(ExecEntry, e)
    end)

    clrBtn.MouseButton1Click:Connect(ClearForm)

    -- Master loop toggle
    SecLabel(PgExec, "MASTER LOOP", lo_())

    local masterRow = Card(PgExec, 40, lo_())
    local masterLbl = Label(masterRow, "Loop All Active Entries", 12, "text")
    masterLbl.Size = UDim2.new(1,-120,1,0); masterLbl.Position = UDim2.new(0,10,0,0)
    local startAllBtn = Btn(masterRow, "▶ Start All", "accent")
    startAllBtn.Size = UDim2.new(0,90,0,28); startAllBtn.Position = UDim2.new(1,-98,0.5,-14)

    local stopAllBtn = Btn(masterRow, "■ Stop All", Color3.fromRGB(120,30,30))
    stopAllBtn.Size = UDim2.new(0,90,0,28)
    stopAllBtn.Position = UDim2.new(1,-98,0.5,-14)
    stopAllBtn.Visible = false

    startAllBtn.MouseButton1Click:Connect(function()
        for _, e in ipairs(LoopEntries) do e.active=true; StartEntryLoop(e) end
        RebuildQueue(); Notify("Looper","All loops started")
        startAllBtn.Visible=false; stopAllBtn.Visible=true
    end)
    stopAllBtn.MouseButton1Click:Connect(function()
        StopAllLoops(); RebuildQueue()
        stopAllBtn.Visible=false; startAllBtn.Visible=true
        Notify("Looper","All loops stopped")
    end)

    -- Fire Log
    SecLabel(PgExec, "FIRE LOG (last "..CFG.MaxFireLog..")", lo_())

    local logFrame = Instance.new("Frame", PgExec)
    logFrame.Size = UDim2.new(1,0,0,0)
    logFrame.BackgroundTransparency=1; logFrame.BorderSizePixel=0
    logFrame.AutomaticSize = Enum.AutomaticSize.Y
    logFrame.LayoutOrder = lo_()
    local logLL = Instance.new("UIListLayout", logFrame)
    logLL.Padding = UDim.new(0,3); logLL.SortOrder = Enum.SortOrder.LayoutOrder

    local logCount = 0
    local function RebuildLog()
        for _, c in ipairs(logFrame:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        for i, entry in ipairs(FireLog) do
            if i > 40 then break end
            local row = Card(logFrame, 38, i)
            local isOk = entry.status:find("✅")
            local col  = isOk and C.ok or (entry.status:find("❌") and C.err or C.warn)
            local tl = Label(row, entry.time.."  "..entry.name, 10, "dimText")
            tl.Size = UDim2.new(0.5,0,0,18); tl.Position = UDim2.new(0,6,0,2)
            local sl = Label(row, entry.status, 10, col)
            sl.Size = UDim2.new(0.5,0,0,18); sl.Position = UDim2.new(0.5,0,0,2)
            sl.TextXAlignment = Enum.TextXAlignment.Right
            local al = Label(row, entry.args, 9, "dimText")
            al.Size = UDim2.new(1,-8,0,14); al.Position = UDim2.new(0,6,0,20)
            al.TextTruncate = Enum.TextTruncate.AtEnd
        end
    end

    FireUpdateSig.Event:Connect(function()
        logCount = logCount + 1
        if logCount % 1 == 0 then RebuildLog() end
    end)

    local clrLogBtn = Btn(PgExec, "🗑 Clear Log", "border")
    clrLogBtn.Size = UDim2.new(1,0,0,30); clrLogBtn.LayoutOrder = lo_()
    clrLogBtn.MouseButton1Click:Connect(function() FireLog={}; RebuildLog() end)

    -- initial build
    task.delay(0.1, function() RebuildQueue(); RebuildLog() end)
end

-- ═══════════════════════════════════════════════════════════════════
--  REMOTE SPY PAGE
-- ═══════════════════════════════════════════════════════════════════
do
    local lo = 0
    local function lo_() lo=lo+1; return lo end

    -- Master spy toggle
    local spyHeader = Card(PgSpy, 40, lo_())
    local spyTitleL = Label(spyHeader, "📡 Remote Spy — captures all FireServer / InvokeServer", 11, "text")
    spyTitleL.Size = UDim2.new(1,-10,1,0); spyTitleL.Position = UDim2.new(0,8,0,0)
    spyTitleL.TextWrapped = true

    Toggle(PgSpy, "Enable Spy (hooks __namecall)", lo_(), false, function(v)
        S.SpyActive = v
        if v then InstallSpyHook(); Notify("Spy","Active — watching remotes")
        else       Notify("Spy","Paused") end
    end)

    -- Filter
    local filterCard = Card(PgSpy, 36, lo_())
    local filterBox = TextBox(filterCard, "Filter by remote name…", 11)
    filterBox.Size = UDim2.new(1,-16,0,26); filterBox.Position = UDim2.new(0,8,0.5,-13)

    -- Controls
    local ctrlCard = Card(PgSpy, 36, lo_())
    local clrSpyBtn = Btn(ctrlCard, "🗑 Clear Log", Color3.fromRGB(90,20,20))
    clrSpyBtn.Size = UDim2.new(0,110,0,26); clrSpyBtn.Position = UDim2.new(0,4,0.5,-13)
    local pauseBtn  = Btn(ctrlCard, "⏸ Pause",   C.border)
    pauseBtn.Size   = UDim2.new(0,80,0,26); pauseBtn.Position = UDim2.new(0,118,0.5,-13)
    local copyAllBtn = Btn(ctrlCard,"📋 Copy All", "border")
    copyAllBtn.Size  = UDim2.new(0,90,0,26); copyAllBtn.Position = UDim2.new(0,202,0.5,-13)

    -- Log list container
    local spyListFrame = Instance.new("Frame", PgSpy)
    spyListFrame.Size = UDim2.new(1,0,0,0)
    spyListFrame.BackgroundTransparency=1; spyListFrame.BorderSizePixel=0
    spyListFrame.AutomaticSize = Enum.AutomaticSize.Y
    spyListFrame.LayoutOrder = lo_()
    local spyLL = Instance.new("UIListLayout", spyListFrame)
    spyLL.Padding = UDim.new(0,3); spyLL.SortOrder = Enum.SortOrder.LayoutOrder

    local spyPaused = false
    pauseBtn.MouseButton1Click:Connect(function()
        spyPaused = not spyPaused
        pauseBtn.Text = spyPaused and "▶ Resume" or "⏸ Pause"
        pauseBtn.BackgroundColor3 = spyPaused and C.accent or C.border
    end)

    clrSpyBtn.MouseButton1Click:Connect(function()
        SpyLog = {}
        for _, c in ipairs(spyListFrame:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
    end)

    local function CopyAsCode(entry)
        -- Build a ready-to-paste Lua snippet
        local lines = {
            "-- " .. entry.path .. "  [" .. entry.method .. "]",
            "local args = {",
        }
        if entry.rawArgs then
            for i, v in ipairs(entry.rawArgs) do
                lines[#lines+1] = "    [" .. i .. "] = " .. SerializeArg(v) .. ","
            end
        end
        lines[#lines+1] = "}"
        local method = entry.method == "InvokeServer" and ":InvokeServer(unpack(args))"
                    or entry.method == "FireServer"   and ":FireServer(unpack(args))"
                    or entry.method == "Fire"         and ":Fire(unpack(args))"
                    or                                    ":Invoke(unpack(args))"
        lines[#lines+1] = entry.path .. method
        return table.concat(lines, "\n")
    end

    local function RebuildSpyLog(filter)
        if spyPaused then return end
        for _, c in ipairs(spyListFrame:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local shown = 0
        for i, entry in ipairs(SpyLog) do
            if i > 80 then break end
            local flt = filter or filterBox.Text
            local pass = flt=="" or entry.path:lower():find(flt:lower(),1,true)
                      or entry.method:lower():find(flt:lower(),1,true)
            if pass then
                shown = shown + 1
                local row = Card(spyListFrame, 64, i)
                -- method badge
                local methodCol = entry.method=="FireServer" and C.accent
                               or entry.method=="InvokeServer" and C.accent2
                               or C.warn
                local mbadge = Instance.new("TextLabel", row)
                mbadge.Text = entry.method:gsub("Server",""):sub(1,8)
                mbadge.Font = Enum.Font.GothamBold; mbadge.TextSize = 9
                mbadge.TextColor3 = methodCol; mbadge.BackgroundColor3 = C.panel
                mbadge.Size = UDim2.new(0,58,0,18); mbadge.Position = UDim2.new(0,4,0,4)
                mbadge.TextXAlignment = Enum.TextXAlignment.Center; mbadge.BorderSizePixel=0
                Instance.new("UICorner",mbadge).CornerRadius=UDim.new(0,4)

                local tl = Label(row, entry.time, 9, "dimText")
                tl.Size = UDim2.new(0,52,0,18); tl.Position = UDim2.new(0,66,0,4)

                -- short path (last 2 segments)
                local segs={}
                for s in entry.path:gmatch('[^"%.%[%]]+') do segs[#segs+1]=s end
                local shortPath = #segs>=2 and segs[#segs-1].."."..segs[#segs] or entry.path
                local nl = Label(row, shortPath, 11, "text")
                nl.Size = UDim2.new(1,-130,0,18); nl.Position = UDim2.new(0,120,0,4)
                nl.TextTruncate = Enum.TextTruncate.AtEnd; nl.TextWrapped=false

                local al = Label(row, "args: "..entry.args, 9, "dimText")
                al.Size = UDim2.new(1,-8,0,16); al.Position = UDim2.new(0,6,0,24)
                al.TextTruncate = Enum.TextTruncate.AtEnd

                local fullL = Label(row, entry.path, 8, "border")
                fullL.Size = UDim2.new(1,-8,0,13); fullL.Position = UDim2.new(0,6,0,40)
                fullL.TextTruncate = Enum.TextTruncate.AtEnd; fullL.TextWrapped=false

                -- Add to Executor button
                local addExBtn = Btn(row, "+ Exec", "accent")
                addExBtn.Size = UDim2.new(0,48,0,20); addExBtn.Position = UDim2.new(1,-100,0,4)
                addExBtn.TextSize = 9
                addExBtn.MouseButton1Click:Connect(function()
                    local argsTable = {}
                    if entry.rawArgs then
                        for ii, av in ipairs(entry.rawArgs) do argsTable[ii]=av end
                    end
                    local method2 = entry.method=="InvokeServer" and ":InvokeServer(unpack(args))"
                               or  entry.method=="Fire"          and ":Fire(unpack(args))"
                               or  entry.method=="Invoke"        and ":Invoke(unpack(args))"
                               or  ":FireServer(unpack(args))"
                    table.insert(LoopEntries, {
                        name       = shortPath,
                        callExpr   = entry.path .. method2,
                        argsTable  = argsTable,
                        vars       = {},
                        delay      = 0,
                        interval   = 1,
                        active     = false,
                        loopConn   = nil,
                        fireCount  = 0,
                        lastStatus = "—",
                        observed   = true,
                    })
                    Notify("Executor","Added: "..shortPath)
                    SwitchTab("Exec")
                end)

                -- Copy-as-code button
                local cpBtn = Btn(row, "📋", "border")
                cpBtn.Size = UDim2.new(0,28,0,20); cpBtn.Position = UDim2.new(1,-48,0,4)
                cpBtn.TextSize = 12
                cpBtn.MouseButton1Click:Connect(function()
                    local code = CopyAsCode(entry)
                    -- put code into a TextBox so player can Ctrl-C it
                    local overlay = Instance.new("Frame", SGui)
                    overlay.Size = UDim2.new(1,0,1,0); overlay.BackgroundColor3=Color3.fromRGB(0,0,0)
                    overlay.BackgroundTransparency = 0.4; overlay.ZIndex=10
                    local codeBox = Instance.new("TextBox", overlay)
                    codeBox.Text = code; codeBox.MultiLine=true
                    codeBox.Font = Enum.Font.RobotoMono; codeBox.TextSize=11
                    codeBox.TextColor3=C.text; codeBox.BackgroundColor3=C.bg
                    codeBox.Size = UDim2.new(0.85,0,0.5,0)
                    codeBox.Position = UDim2.new(0.075,0,0.25,0)
                    codeBox.ZIndex=11; codeBox.BorderSizePixel=0
                    codeBox.TextXAlignment=Enum.TextXAlignment.Left
                    codeBox.TextYAlignment=Enum.TextYAlignment.Top
                    Instance.new("UICorner",codeBox).CornerRadius=UDim.new(0,10)
                    local closeBt = Btn(overlay,"✕ Close",Color3.fromRGB(90,20,20))
                    closeBt.Size=UDim2.new(0,90,0,32); closeBt.Position=UDim2.new(0.5,-45,0.76,0)
                    closeBt.ZIndex=12
                    closeBt.MouseButton1Click:Connect(function() overlay:Destroy() end)
                    codeBox:CaptureFocus(); codeBox:SelectAll()
                end)

                -- Blacklist toggle
                local blBt = Btn(row, S.SpyBlacklist[entry.path] and "❌bl" or "👁", "border")
                blBt.Size = UDim2.new(0,28,0,20); blBt.Position = UDim2.new(1,-16,0,4)
                blBt.TextSize = 10
                blBt.MouseButton1Click:Connect(function()
                    S.SpyBlacklist[entry.path] = not S.SpyBlacklist[entry.path]
                    blBt.Text = S.SpyBlacklist[entry.path] and "❌bl" or "👁"
                end)
            end
        end
    end

    copyAllBtn.MouseButton1Click:Connect(function()
        local lines={}
        for _, e in ipairs(SpyLog) do
            lines[#lines+1] = CopyAsCode(e).."\n"
        end
        local overlay = Instance.new("Frame", SGui)
        overlay.Size=UDim2.new(1,0,1,0); overlay.BackgroundColor3=Color3.fromRGB(0,0,0)
        overlay.BackgroundTransparency=0.4; overlay.ZIndex=10
        local cb2 = Instance.new("TextBox", overlay)
        cb2.Text=table.concat(lines,"\n"); cb2.MultiLine=true
        cb2.Font=Enum.Font.RobotoMono; cb2.TextSize=10; cb2.TextColor3=C.text
        cb2.BackgroundColor3=C.bg; cb2.Size=UDim2.new(0.9,0,0.7,0)
        cb2.Position=UDim2.new(0.05,0,0.1,0); cb2.ZIndex=11; cb2.BorderSizePixel=0
        cb2.TextXAlignment=Enum.TextXAlignment.Left; cb2.TextYAlignment=Enum.TextYAlignment.Top
        Instance.new("UICorner",cb2).CornerRadius=UDim.new(0,10)
        local cl2=Btn(overlay,"✕ Close",Color3.fromRGB(90,20,20))
        cl2.Size=UDim2.new(0,90,0,32); cl2.Position=UDim2.new(0.5,-45,0.82,0); cl2.ZIndex=12
        cl2.MouseButton1Click:Connect(function() overlay:Destroy() end)
        cb2:CaptureFocus(); cb2:SelectAll()
    end)

    SpyUpdateSig.Event:Connect(function() RebuildSpyLog(filterBox.Text) end)
    filterBox:GetPropertyChangedSignal("Text"):Connect(function()
        RebuildSpyLog(filterBox.Text)
    end)
end

-- ═══════════════════════════════════════════════════════════════════
--  THEME PAGE
-- ═══════════════════════════════════════════════════════════════════
local PgTheme = MakePage("Theme")

do
    local lo = 0
    local function lo_() lo=lo+1; return lo end

    SecLabel(PgTheme, "BUILT-IN THEMES", lo_())

    -- Active theme indicator
    local activeLbl = Card(PgTheme, 30, lo_())
    local activeText = Label(activeLbl, "Active: Default", 11, nil)
    activeText.Position = UDim2.new(0,8,0,0)

    -- helper: build a swatch card for a preset theme
    local function PresetSwatch(name, lo2)
        local t    = THEMES[name]
        local row  = Instance.new("Frame", PgTheme)
        row.Size   = UDim2.new(1,0,0,68)
        row.BackgroundColor3 = t.panel; row.BorderSizePixel=0
        row.LayoutOrder = lo2
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,10)
        local stroke = Instance.new("UIStroke", row)
        stroke.Color = t.border; stroke.Thickness = 1.2

        -- mini colour strip (5 swatches)
        local STRIP_ROLES = {"bg","panel","card","accent","accent2"}
        for i, role in ipairs(STRIP_ROLES) do
            local sq = Instance.new("Frame", row)
            sq.Size = UDim2.new(0,28,0,14)
            sq.Position = UDim2.new(0,6+(i-1)*30,0,6)
            sq.BackgroundColor3 = t[role]; sq.BorderSizePixel=0
            Instance.new("UICorner", sq).CornerRadius = UDim.new(0,3)
        end

        -- name label
        local nl = Instance.new("TextLabel", row)
        nl.Text = name; nl.Font = Enum.Font.GothamBold; nl.TextSize=13
        nl.TextColor3 = t.text; nl.BackgroundTransparency=1
        nl.Size = UDim2.new(0.5,0,0,20); nl.Position = UDim2.new(0,8,0,24)
        nl.TextXAlignment = Enum.TextXAlignment.Left

        -- description
        local desc = {
            Default    = "Purple/dark sci-fi",
            Assassin   = "Blood red + charcoal",
            Casual     = "Clean black + white",
            Steampunk  = "Brass + dark slate + ice",
        }
        local dl = Instance.new("TextLabel", row)
        dl.Text = desc[name] or ""; dl.Font = Enum.Font.Gotham; dl.TextSize=10
        dl.TextColor3 = t.dimText; dl.BackgroundTransparency=1
        dl.Size = UDim2.new(0.5,0,0,16); dl.Position = UDim2.new(0,8,0,44)
        dl.TextXAlignment = Enum.TextXAlignment.Left

        -- Apply button
        local applyBtn = Instance.new("TextButton", row)
        applyBtn.Text = "Apply"; applyBtn.Font=Enum.Font.GothamBold; applyBtn.TextSize=12
        applyBtn.TextColor3 = t.text; applyBtn.BackgroundColor3 = t.accent
        applyBtn.Size = UDim2.new(0,72,0,28); applyBtn.Position = UDim2.new(1,-80,0.5,-14)
        applyBtn.BorderSizePixel=0
        Instance.new("UICorner", applyBtn).CornerRadius = UDim.new(0,7)
        applyBtn.MouseButton1Click:Connect(function()
            ApplyTheme(name)
            -- refresh tab strip since SwitchTab uses C values
            SwitchTab(ActiveTab)
            activeText.Text = "Active: "..name
            Notify("Theme", name.." applied!")
        end)
        return row
    end

    PresetSwatch("Default",   lo_())
    PresetSwatch("Assassin",  lo_())
    PresetSwatch("Casual",    lo_())
    PresetSwatch("Steampunk", lo_())

    -- ── Custom theme editor ──────────────────────────────────────
    SecLabel(PgTheme, "CUSTOM THEME", lo_())

    local helpCard = Card(PgTheme, 36, lo_())
    local helpL = Label(helpCard,
        "Enter R,G,B (0-255) for each slot. Press Apply Custom.", 10, nil)
    helpL.Position = UDim2.new(0,8,0,0); helpL.TextWrapped = true

    -- Colour roles the user can customise
    local CUSTOM_ROLES = {
        {"bg",      "Background"},
        {"panel",   "Panel"},
        {"card",    "Card"},
        {"accent",  "Accent (buttons/toggles)"},
        {"accent2", "Accent 2 (secondary)"},
        {"text",    "Text"},
        {"dimText", "Dim Text"},
        {"border",  "Border"},
    }

    local customInputs = {}  -- role → TextBox

    for _, rd in ipairs(CUSTOM_ROLES) do
        local role, label = rd[1], rd[2]
        local row = Card(PgTheme, 36, lo_())
        local nl = Label(row, label, 10, nil)
        nl.Size = UDim2.new(0.48,0,1,0); nl.Position = UDim2.new(0,8,0,0)

        -- colour preview swatch
        local preview = Instance.new("Frame", row)
        preview.Size = UDim2.new(0,20,0,20); preview.Position = UDim2.new(0.5,0,0.5,-10)
        preview.BackgroundColor3 = C[role] or Color3.new(0,0,0)
        preview.BorderSizePixel = 0
        Instance.new("UICorner", preview).CornerRadius = UDim.new(0,4)
        TR(preview, "BackgroundColor3", role)

        local cur = C[role] or Color3.new(0,0,0)
        local box = TextBox(row,
            string.format("%d,%d,%d", math.floor(cur.R*255), math.floor(cur.G*255), math.floor(cur.B*255)),
            10)
        box.Text = string.format("%d,%d,%d", math.floor(cur.R*255), math.floor(cur.G*255), math.floor(cur.B*255))
        box.Size = UDim2.new(0,90,0,24); box.Position = UDim2.new(1,-98,0.5,-12)
        -- update preview live as user types
        box:GetPropertyChangedSignal("Text"):Connect(function()
            local nums = {}
            for n in box.Text:gmatch("%d+") do nums[#nums+1]=tonumber(n) end
            if #nums>=3 then
                preview.BackgroundColor3 = Color3.fromRGB(
                    math.clamp(nums[1],0,255),
                    math.clamp(nums[2],0,255),
                    math.clamp(nums[3],0,255))
            end
        end)
        customInputs[role] = box
    end

    -- Apply Custom button
    local applyCustomBtn = Btn(PgTheme, "🎨  Apply Custom Theme", nil)
    applyCustomBtn.Size = UDim2.new(1,0,0,36); applyCustomBtn.LayoutOrder = lo_()
    applyCustomBtn.MouseButton1Click:Connect(function()
        local custom = {}
        -- copy current C as base so ok/warn/err stay reasonable
        for k, v in pairs(C) do custom[k] = v end
        for role, box in pairs(customInputs) do
            local nums = {}
            for n in box.Text:gmatch("%d+") do nums[#nums+1]=tonumber(n) end
            if #nums >= 3 then
                custom[role] = Color3.fromRGB(
                    math.clamp(nums[1],0,255),
                    math.clamp(nums[2],0,255),
                    math.clamp(nums[3],0,255))
            end
        end
        -- inject as a one-off theme and apply
        THEMES["Custom"] = custom
        ApplyTheme("Custom")
        SwitchTab(ActiveTab)
        activeText.Text = "Active: Custom"
        Notify("Theme","Custom theme applied!")
    end)

    -- Reset to Default button
    local resetBtn = Btn(PgTheme, "↺  Reset to Default", nil)
    resetBtn.Size = UDim2.new(1,0,0,32); resetBtn.LayoutOrder = lo_()
    TR(resetBtn, "BackgroundColor3", "border")
    resetBtn.MouseButton1Click:Connect(function()
        ApplyTheme("Default")
        SwitchTab(ActiveTab)
        activeText.Text = "Active: Default"
        -- sync input boxes back to default values
        for role, box in pairs(customInputs) do
            local cv = C[role]
            if cv then
                box.Text = string.format("%d,%d,%d",
                    math.floor(cv.R*255), math.floor(cv.G*255), math.floor(cv.B*255))
            end
        end
        Notify("Theme","Reset to Default")
    end)
end

-- ═══════════════════════════════════════════════════════════════════
--  DRAG (mouse + touch) · MINIMIZE · KEYBIND · BOOT
-- ═══════════════════════════════════════════════════════════════════
do
    local dragging, startPos, startMPos = false, nil, nil
    local DRAG_T = {[Enum.UserInputType.MouseButton1]=true,[Enum.UserInputType.Touch]=true}
    local MOVE_T = {[Enum.UserInputType.MouseMovement]=true,[Enum.UserInputType.Touch]=true}

    TBar.InputBegan:Connect(function(i)
        if DRAG_T[i.UserInputType] then
            dragging=true; startPos=Main.Position; startMPos=i.Position
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if DRAG_T[i.UserInputType] then dragging=false end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging or not MOVE_T[i.UserInputType] then return end
        local d  = i.Position - startMPos
        local vp = workspace.CurrentCamera.ViewportSize
        local nx = math.clamp(startPos.X.Offset+d.X, 0, vp.X-Main.AbsoluteSize.X)
        local ny = math.clamp(startPos.Y.Offset+d.Y, 0, vp.Y-Main.AbsoluteSize.Y)
        Main.Position = UDim2.new(0,nx,0,ny)
    end)

    local minimized = false
    MinBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        local ti = TweenInfo.new(0.2, Enum.EasingStyle.Quad)
        TweenService:Create(Main, ti, {
            Size = minimized and UDim2.new(0,CFG.UIWidth,0,46) or UDim2.new(0,CFG.UIWidth,0,CFG.UIHeight)
        }):Play()
        MinBtn.Text = minimized and "□" or "—"
    end)

    UserInputService.InputBegan:Connect(function(i, gp)
        if gp then return end
        if i.KeyCode == Enum.KeyCode.RightShift then
            Main.Visible = not Main.Visible
        end
        if i.KeyCode == Enum.KeyCode.RightControl then
            SwitchTab("Spy")
        end
    end)
end

-- ── Initial tab + startup scan ─────────────────────────────────────
SwitchTab("Farm")

task.delay(0.5, function()
    Notify("Universal v3","Loaded! RShift=toggle · RCtrl=spy")
end)

-- Auto-scan on load in background
task.delay(1, RunScan)
