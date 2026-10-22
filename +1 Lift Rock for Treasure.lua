--[[
    PuckAFK - +1 Lift Rock for Treasure
    Smart AutoFarm v1.9.1 - Individual Luck + Mutation-Safe Pickup

    Built from the supplied place dump + captured remote trace for place 102555956950143.

    Core game mechanics accounted for:
      * 30/s training tap token bucket (script defaults below the cap, with headroom for lift taps)
      * Rebirth-gated training stations and their real multipliers
      * Updated sequential rock stages (1 -> 18; 300T / 1Qa / 5Qa late-game stones)
      * Server/zone-driven lifting; no fake "Start" remote
      * Rock lift rate ~= Strength / Stone Weight
      * Stage reward retention until banking
      * SpawnZone banking resets the stage run
      * Backpack capacity
      * Always sort live treasures by the game's rarity ranks, including Ethereal / Exclusive
      * Visual-ground/live-server reconciliation, stale-UUID protection and per-pick re-ranking
      * Strict persisted rarity filtering: Divine above Celestial, verified before each pickup
      * No matching treasure: skip inferior drops and reroll cleared run (if Auto Bank enabled)
      * Tween Speed relocated to Farming, with a fresh config key that ignores obsolete saved speeds
      * Special timed stage spawns
      * Sellable/protected item rules
      * Place Best Luck plot action
      * Arms unlock/equip progression, including owned Robux arms without purchasing Robux items
      * Backpack / move-speed upgrades with budget-aware spending
      * Plot expansion gates/costs
      * Rebirth level requirements
      * Offline reward + group reward claiming
      * Tutorial steps 1-5
      * Death / reset / stalled lift recovery
      * Game-native StoneIncome ROI model blended with live-run limits
      * Snapshot progress recovery and stale special-spawn removal
      * Direct collision-checked teleport to lift zones, shops, spawn, training and plots
      * Mid-run/reload recovery without prematurely banking a partially filled backpack
      * Authoritative special-spawn snapshot rebuild with revision-safe delta handling
      * Requirement-aware progression purchases that bypass optional budgets when actually needed
      * Automatic cash/power milestone planning for backpack, arms, rebirths and training unlocks
      * Anti-fling: temporary collision isolation, one-frame anchor, velocity reset, character state restoration
      * PuckUI v3 shared interface loaded from the canonical PuckAFK/Puck-Loader source

    The server is still authoritative: remotes are called with the same argument shapes used by the game,
    lifting is started by physically entering LiftZone, and pickups are done from the real ItemSpawn slots.
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

if game.PlaceId ~= 102555956950143 then
    warn("[PuckAFK Lift Rock] Wrong place. Expected 102555956950143, got " .. tostring(game.PlaceId))
    return
end

local ENV = (getgenv and getgenv()) or _G
local previousInstance = ENV.PuckAFK_LiftRock
if previousInstance then
    -- v1.3.0 never reached its bootstrap, so its table can be left in getgenv()
    -- even though no workers/UI were started. Discard that known dormant build
    -- directly so upgrading does not print a misleading "Unloaded" warning.
    local dormantBroken130 = tostring(previousInstance.Version or "") == "1.3.0"
        and (not previousInstance.UI or previousInstance.UI.Window == nil)
        and (type(previousInstance.Connections) ~= "table" or #previousInstance.Connections == 0)
        and (type(previousInstance.Threads) ~= "table" or #previousInstance.Threads == 0)

    if dormantBroken130 then
        previousInstance.Alive = false
        if type(previousInstance.Settings) == "table" then
            previousInstance.Settings.Enabled = false
        end
        ENV.PuckAFK_LiftRock = nil
    elseif type(previousInstance.Shutdown) == "function" then
        pcall(function()
            previousInstance:Shutdown(true)
        end)
    else
        ENV.PuckAFK_LiftRock = nil
    end
end

local P = {
    Version = "1.9.1",
    Alive = true,
    Connections = {},
    Threads = {},
    Status = "Loading game data...",
    Phase = "BOOT",
    TargetStage = 1,
    TrainingTarget = nil,
    LastError = nil,
    LastEconomyAt = 0,
    LastSpecialSync = 0,
    LastFreeClaim = 0,
    UI = {},
    Debug = {Entries = {}, LastStatus = "", LastStatusTime = 0, LastRouteIssue = ""},
    ShopRetryAfter = {},
    Run = {
        Cleared = {},
        Rewards = {},
        Progress = {},
        Session = nil,
        Specials = {},
        SpecialRevisions = {},
        Synced = false,
        LastReset = 0,
        LastBank = 0,
        LastFeedback = 0,
        PickedUUIDs = {}, -- Prevent stale rendered ground models from being picked twice.
    },
    Route = {
        GameROIStage = 0,
        CashPerSecond = 0,
        ExpectedItemValue = 0,
        TripSeconds = 0,
    },
    Navigation = {
        Token = 0,
        Destination = nil,
        LastResult = "Idle",
        Repaths = 0,
        Busy = false,
        Waypoint = 0,
        LastProgressAt = 0,
        LastDistance = 0,
        AllowedShopZone = nil,
        SkyTravel = false,
        SkyAscent = false,
        LastShopClose = 0,
    },
    Requirements = {
        Kind = "Scanning",
        Name = "Scanning progression",
        Detail = "",
        Cost = 0,
        MissingCash = 0,
        TargetPower = 0,
        DesiredBackpack = 0,
    },
}
ENV.PuckAFK_LiftRock = P

P.Settings = {
    Enabled = true,
    AutoTrain = true,
    AutoLift = true,
    AutoCollect = true,
    AutoBank = true,
    AutoSell = true,
    AutoArms = true,
    AutoUpgrades = true,
    AutoPlot = true,
    AutoRebirth = true,
    AutoOfflineReward = true,
    AutoGroupReward = true,
    AutoSpecialSpawns = true,
    IndexPriority = true,
    AdaptiveROI = true,
    PushNewStages = true,
    AntiAFK = true,

    -- Instant teleport instead of tweening. No speed setting is needed.
    WalkAcceptanceRadius = 2.75,
    PathRetries = 4,
    TeleportSettleSeconds = 0.12,
    AvoidUnwantedShops = true, -- Always enabled: do not cut across tagged shop/menu zones.
    AutoDismissShopMenus = true, -- Restore controls when a shop popup blocks AFK farming.
    DebugConsole = true, -- Detailed tagged logs; toggle in the Debug tab.

    -- 'Any' keeps highest-tier-first logic; e.g. 'Divine' skips Celestial and lower.
    MinPickupRarity = "Any",

    -- Progression requirement brain. "Required" upgrades can bypass the optional spending
    -- budgets below when they are the current bottleneck.
    AutoRequirements = true,
    RequiredBackpackFloor = 5,
    ReserveCashForNearArm = true,
    NearArmReserveRatio = 1.45,
    BuyOptionalMoveSpeed = false,

    -- 30/s is the game's configured limit. While lifting, the stock client also sends ~2 taps/s.
    -- 27 keeps total lifting traffic under the intended cap while still training extremely quickly.
    TapRate = 27,

    -- A stage is considered efficient when its current estimated lift time is <= this value.
    MaxLiftSeconds = 12,

    -- Prevent a technically liftable target from turning into a bad long cumulative run.
    MaxRunSeconds = 35,

    -- Timed special treasure is worth stretching the run budget for, but still has a hard ceiling.
    SpecialRunSeconds = 55,

    -- If the next stage/rebirth is close, train first instead of doing a low-value short run.
    TrainAheadRatio = 1.30,
    -- Late-game stages have large weight jumps; v1.6.1 never trained past Stage 15.
    -- Start advancing whenever the next updated stage is within this strength multiple.
    NewStageTrainRatio = 8,
    RebirthTrainAheadRatio = 1.18,

    -- Economy spending budgets. Arms are always first priority when the next arm is affordable.
    BackpackBudgetFraction = 0.12,
    PlotBudgetFraction = 0.15,
    -- Tween travel is independent of character WalkSpeed, so this is optional.
    MoveSpeedBudgetFraction = 0.08,
}

P.S = {
    Players = game:GetService("Players"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    CollectionService = game:GetService("CollectionService"),
    VirtualUser = game:GetService("VirtualUser"),
}
P.Player = P.S.Players.LocalPlayer
P.Shared = P.S.ReplicatedStorage:WaitForChild("Shared")

local function safeRequire(object, label)
    local ok, result = pcall(require, object)
    if not ok then
        error("[PuckAFK Lift Rock] Failed to require " .. tostring(label or object) .. ": " .. tostring(result))
    end
    return result
end

P.M = {}
P.M.Config = safeRequire(P.Shared:WaitForChild("Config"), "Config")
P.M.SharedUtils = safeRequire(P.Shared:WaitForChild("SharedUtils"), "SharedUtils")
P.M.ItemUtils = safeRequire(P.Shared:WaitForChild("Modules"):WaitForChild("ItemUtils"), "ItemUtils")
P.M.PlayerDataInfo = safeRequire(P.Shared.Modules:WaitForChild("PlayerDataInfo"), "PlayerDataInfo")
P.M.UpgradeUtils = safeRequire(P.Shared.Modules:WaitForChild("UpgradeUtils"), "UpgradeUtils")
P.M.LevelUtils = safeRequire(P.Shared.Modules:WaitForChild("LevelUtils"), "LevelUtils")
P.M.ArmsUtils = safeRequire(P.Shared.Modules:WaitForChild("ArmsUtils"), "ArmsUtils")

-- Optional helpers: the game itself uses StoneIncome to choose its best offline rock,
-- and PlotController gives an exact reference to the local player's plot. Both have fallbacks.
do
    local offlineReward = P.Shared.Modules:FindFirstChild("OfflineReward")
    local stoneIncomeModule = offlineReward and offlineReward:FindFirstChild("StoneIncome")
    if stoneIncomeModule then
        local ok, value = pcall(require, stoneIncomeModule)
        if ok then
            P.M.StoneIncome = value
        end
    end

    local playerScripts = P.Player:WaitForChild("PlayerScripts")
    local controllers = playerScripts:FindFirstChild("ClientControllers")
    local plotModule = controllers and controllers:FindFirstChild("PlotController")
    if plotModule then
        local ok, value = pcall(require, plotModule)
        if ok then
            P.M.PlotController = value
        end
    end
end
P.M.DataAggregation = safeRequire(
    P.Player:WaitForChild("PlayerScripts"):WaitForChild("ClientModules"):WaitForChild("DataAggregation"),
    "DataAggregation"
)
P.Replica = P.M.DataAggregation.WaitForReplica()
P.SessionReplica = P.M.DataAggregation.WaitForSessionReplica()

P.R = {}
for _, name in ipairs({
    "TrainingTap",
    "RockLiftingInput",
    "RockLiftingFeedback",
    "PickupStageTreasure",
    "StageTreasuresBanked",
    "SpecialStageSpawnChanged",
    "GetSpecialStageSpawns",
    "SellItems",
    "ArmsAction",
    "PurchaseUpgrade",
    "UpgradePlot",
    "PlaceBestLuck",
    "PerformRebirth",
    "CollectOfflineRewards",
    "ClaimGroupReward",
}) do
    P.R[name] = P.M.SharedUtils.GetRemote(name)
end

function P:Connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(self.Connections, connection)
    return connection
end

function P:Spawn(callback)
    local thread = task.spawn(callback)
    table.insert(self.Threads, thread)
    return thread
end

function P:DebugEvent(kind, message)
    local debug = self.Debug
    if not debug then return end
    local line = string.format("[%s][%s][%s] %s",
        os.date("%H:%M:%S"), tostring(self.Phase or "BOOT"),
        tostring(kind or "INFO"), tostring(message or ""))
    table.insert(debug.Entries, line)
    while #debug.Entries > 75 do table.remove(debug.Entries, 1) end
    if self.Settings.DebugConsole then
        if kind == "ERROR" or kind == "FAIL" then
            warn("[PuckAFK Lift Rock] "..line)
        else
            print("[PuckAFK Lift Rock] "..line)
        end
    end
end

function P:DebugSnapshot()
    local character = self.Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local position = root and root.Position
    local function pos(value)
        if typeof(value) ~= "Vector3" then return "none" end
        return string.format("%.1f, %.1f, %.1f", value.X, value.Y, value.Z)
    end
    local nav = self.Navigation
    local allowed = nav.AllowedShopZone
    local lastError = tostring(self.LastError or "none")
    return string.format(
        "Version %s  |  phase %s\nStatus: %s\nPosition: %s\nDestination: %s\nNavigation: %s; busy=%s; repaths=%s; waypoint=%s\nShop permission: %s  |  Instant Safe TP\nLast navigation failure: %s\nLast error: %s",
        self.Version, tostring(self.Phase), tostring(self.Status),
        pos(position), pos(nav.Destination), tostring(nav.LastResult),
        tostring(nav.Busy), tostring(nav.Repaths), tostring(nav.Waypoint),
        allowed and allowed:GetFullName() or "none",
        tostring(self.Debug.LastRouteIssue or "none"), lastError
    )
end

function P:GetDebugReport()
    local lines = {self:DebugSnapshot(), "", "Recent events (oldest to newest):"}
    for _, line in ipairs(self.Debug.Entries) do table.insert(lines, line) end
    return table.concat(lines, "\n")
end

function P:SetStatus(text, phase)
    local newStatus = tostring(text or "")
    local newPhase = phase or self.Phase
    local debug = self.Debug
    if debug and (newPhase ~= self.Phase or newStatus ~= self.Status)
        and (newPhase ~= debug.LastStatusPhase
            or newStatus ~= debug.LastStatus
            or os.clock() - (debug.LastStatusTime or 0) > 1.6) then
        debug.LastStatus = newStatus
        debug.LastStatusPhase = newPhase
        debug.LastStatusTime = os.clock()
        self:DebugEvent("STATE", tostring(newPhase).." :: "..newStatus)
    end
    self.Status = newStatus
    if phase then self.Phase = phase end
end

function P:Data()
    return self.Replica and self.Replica.Data or {}
end

function P:SessionData()
    return self.SessionReplica and self.SessionReplica.Data or {}
end

function P:GetCharacter()
    local character = self.Player.Character
    if not character or not character.Parent then
        character = self.Player.CharacterAdded:Wait()
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not root then
        return nil, nil, nil
    end
    return character, humanoid, root
end

function P:ObjectPosition(object)
    if not object then
        return nil
    end
    if typeof(object) == "Vector3" then
        return object
    end
    if typeof(object) == "CFrame" then
        return object.Position
    end
    if typeof(object) ~= "Instance" then
        return nil
    end
    if object:IsA("BasePart") then
        return object.Position
    end
    if object:IsA("Model") then
        local ok, cf = pcall(function()
            return object:GetBoundingBox()
        end)
        if ok and cf then
            return cf.Position
        end
        local primary = object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
        return primary and primary.Position or nil
    end
    local part = object:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

function P:IsPointInsidePart(part, worldPosition, inset)
    if not part or not part:IsA("BasePart") or typeof(worldPosition) ~= "Vector3" then
        return false
    end
    local localPoint = part.CFrame:PointToObjectSpace(worldPosition)
    local half = part.Size * 0.5
    inset = math.max(0, tonumber(inset) or 0)
    local hx = math.max(0.05, half.X - math.min(inset, math.max(0, half.X - 0.05)))
    local hz = math.max(0.05, half.Z - math.min(inset, math.max(0, half.Z - 0.05)))
    return math.abs(localPoint.X) <= hx
        and math.abs(localPoint.Z) <= hz
        and math.abs(localPoint.Y) <= half.Y + 5
end

function P:ProjectToGround(worldPosition, extraExclude)
    if typeof(worldPosition) ~= "Vector3" then
        return nil
    end
    local character = self.Player.Character
    local exclude = {}
    if character then
        table.insert(exclude, character)
    end
    if typeof(extraExclude) == "Instance" then
        table.insert(exclude, extraExclude)
    elseif type(extraExclude) == "table" then
        for _, item in ipairs(extraExclude) do
            if typeof(item) == "Instance" then
                table.insert(exclude, item)
            end
        end
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = exclude
    params.IgnoreWater = false
    pcall(function()
        params.RespectCanCollide = true
    end)

    -- v1.8.0 could project a center-corridor waypoint at Y=0 while the
    -- actual plaza is around Y=120. A ray starting 35 studs above Y=0
    -- never touched the plaza, and returned a fake Y=0 path destination.
    -- Use the observed player/map height as the ray's elevation reference.
    local referenceY = worldPosition.Y
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root then referenceY = math.max(referenceY, root.Position.Y) end
    local map = workspace:FindFirstChild("Map")
    local spawn = map and map:FindFirstChild("SpawnZone")
    if spawn and spawn:IsA("BasePart") then
        referenceY = math.max(referenceY, spawn.Position.Y)
    end
    local origin = Vector3.new(worldPosition.X, referenceY + 55, worldPosition.Z)
    local rayDepth = math.max(160, origin.Y - worldPosition.Y + 80)
    local result = workspace:Raycast(origin, Vector3.new(0, -rayDepth, 0), params)
    if result then return result.Position end
    -- Never emit impossible ground destinations far below the live map.
    if worldPosition.Y < referenceY - 45 then return nil end
    return worldPosition
end

function P:GetZoneWalkPoint(zone)
    if not zone or not zone:IsA("BasePart") then
        return self:ObjectPosition(zone)
    end
    local _, _, root = self:GetCharacter()
    if not root then
        return self:ProjectToGround(zone.Position, zone)
    end

    local half = zone.Size * 0.5
    local localRoot = zone.CFrame:PointToObjectSpace(root.Position)
    local insetX = math.min(math.max(1.25, half.X * 0.18), math.max(0.1, half.X - 0.1))
    local insetZ = math.min(math.max(1.25, half.Z * 0.18), math.max(0.1, half.Z - 0.1))
    local minX, maxX = -half.X + insetX, half.X - insetX
    local minZ, maxZ = -half.Z + insetZ, half.Z - insetZ
    if minX > maxX then minX, maxX = 0, 0 end
    if minZ > maxZ then minZ, maxZ = 0, 0 end

    -- Clamp to the nearest interior point and stay near the entry side. Going too
    -- far toward the centre can put the goal inside the rock/shop model itself.
    local x = math.clamp(localRoot.X, minX, maxX) * 0.90
    local z = math.clamp(localRoot.Z, minZ, maxZ) * 0.90
    local raw = zone.CFrame:PointToWorldSpace(Vector3.new(x, 0, z))
    return self:ProjectToGround(raw, zone)
end

function P:StopWalking()
    self.Navigation.Token = (self.Navigation.Token or 0) + 1
    self.Navigation.Destination = nil
    self.Navigation.Busy = false
    self.Navigation.LastResult = "Stopped"
    self.Navigation.Waypoint = 0
    self.Navigation.AllowedShopZone = nil
    self:ReleaseTeleportBody()
    local ch = self.Player.Character
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum.Sit=false; hum.AutoRotate=true end) end
    if root then pcall(function()
        root.AssemblyLinearVelocity=Vector3.zero
        root.AssemblyAngularVelocity=Vector3.zero
    end) end
end

function P:IsWalkTokenActive(token)
    return self.Alive
        and self.Settings.Enabled
        and self.Navigation.Token == token
end

function P:WalkArrivalSatisfied(arrivalPredicate)
    if type(arrivalPredicate) ~= "function" then
        return nil
    end
    local ok, arrived = pcall(arrivalPredicate)
    if ok then
        return arrived == true
    end
    return false
end

function P:GetRootGroundOffset(humanoid, root)
    if not humanoid or not root then
        return 3
    end
    local hip = tonumber(humanoid.HipHeight) or 2
    local halfRoot = math.max(0.5, root.Size.Y * 0.5)
    return math.max(2.25, hip + halfRoot)
end

function P:GetTeleportRootTarget(surfacePosition, humanoid, root)
    if typeof(surfacePosition) ~= "Vector3" then
        return nil
    end
    local yOffset = self:GetRootGroundOffset(humanoid, root)
    return Vector3.new(surfacePosition.X, surfacePosition.Y + yOffset, surfacePosition.Z)
end

-- Anti-fling teleport transaction. All original body collision/anchor states
-- are restored even if a PivotTo fails or the script is unloaded mid-action.
function P:ReleaseTeleportBody()
    local state=self.Navigation.MotionState
    if not state then return end
    self.Navigation.MotionState=nil
    if state.Root and state.Root.Parent then
        pcall(function()
            state.Root.AssemblyLinearVelocity=Vector3.zero
            state.Root.AssemblyAngularVelocity=Vector3.zero
            state.Root.Anchored=state.Anchored
        end)
    end
    for part,old in pairs(state.Collisions) do
        if part and part.Parent then pcall(function() part.CanCollide=old end) end
    end
    if state.Humanoid and state.Humanoid.Parent then
        pcall(function()
            state.Humanoid.AutoRotate=state.AutoRotate
            state.Humanoid.Sit=false
        end)
    end
end

function P:BeginTeleportBody(root,humanoid)
    self:ReleaseTeleportBody()
    if not root or not root.Parent or root.Anchored
        or not humanoid or humanoid.Health<=0 then return false end
    local state={Root=root,Humanoid=humanoid,Anchored=root.Anchored,
        AutoRotate=humanoid.AutoRotate,Collisions={}}
    self.Navigation.MotionState=state
    for _,part in ipairs(root.Parent:GetDescendants()) do
        if part:IsA("BasePart") then
            state.Collisions[part]=part.CanCollide
            part.CanCollide=false
        end
    end
    humanoid.Sit=false
    humanoid.AutoRotate=false
    root.AssemblyLinearVelocity=Vector3.zero
    root.AssemblyAngularVelocity=Vector3.zero
    return true
end

-- Shops use the game's CollectionService ZoneOpener tag and Menu attribute.
-- These volumes are often non-collidable, so raycasts and pathfinding do NOT
-- prevent accidental entry, unlike the dedicated checks below.
function P:GetMenuTriggerZones()
    local result, seen = {}, {}
    local function register(part, fallback)
        if not part or not part:IsA("BasePart") or not part:IsDescendantOf(workspace)
            or seen[part] then
            return
        end
        local menu = part:GetAttribute("Menu")
        if type(menu) ~= "string" or menu == "" then
            menu = fallback
        end
        if type(menu) ~= "string" or menu == "" then
            return
        end
        seen[part] = true
        table.insert(result, {Part = part, Menu = menu})
    end

    for _, part in ipairs(self.S.CollectionService:GetTagged("ZoneOpener")) do
        register(part)
    end
    -- Additional safety for streaming or map versions without the tag.
    local map = self:Map()
    local shops = map and map:FindFirstChild("Shops")
    if shops then
        for _, shop in ipairs(shops:GetChildren()) do
            local zone = shop:FindFirstChild("Zone", true)
            register(zone, shop.Name)
        end
    end
    return result
end

function P:IsWithinMenuZone(position, zone, margin)
    if typeof(position) ~= "Vector3" or not zone or not zone:IsA("BasePart") then
        return false
    end
    local q = zone.CFrame:PointToObjectSpace(position)
    local half = zone.Size * 0.5
    local xz = math.max(0, tonumber(margin) or 0)
    return math.abs(q.X) <= half.X + xz
        and math.abs(q.Z) <= half.Z + xz
        and math.abs(q.Y) <= half.Y + math.min(6, xz + 3)
end

-- Continuous 3D segment vs rotated expanded box using the slab method. It
-- catches invisible/non-collidable trigger regions that physical raycasts miss.
function P:SegmentIntersectsMenuZone(fromPos, toPos, zone, padding)
    if typeof(fromPos) ~= "Vector3" or typeof(toPos) ~= "Vector3"
        or not zone or not zone:IsA("BasePart") then
        return false
    end
    local start = zone.CFrame:PointToObjectSpace(fromPos)
    local finish = zone.CFrame:PointToObjectSpace(toPos)
    local delta = finish - start
    local half = zone.Size * 0.5
    local pad = math.max(0, tonumber(padding) or 0)
    local hx, hy, hz = half.X + pad, half.Y + 4, half.Z + pad
    local tmin, tmax = 0, 1
    for _, axis in ipairs({"X", "Y", "Z"}) do
        local halfAxis = axis == "X" and hx or (axis == "Y" and hy or hz)
        local coord, d = start[axis], delta[axis]
        if math.abs(d) < 0.00001 then
            if math.abs(coord) > halfAxis then return false end
        else
            local near = (-halfAxis - coord) / d
            local far = (halfAxis - coord) / d
            if near > far then near, far = far, near end
            tmin = math.max(tmin, near)
            tmax = math.min(tmax, far)
            if tmax < tmin then return false end
        end
    end
    return true
end

function P:RouteCrossesMenuZone(startPos, endPos, allowedZone, padding)
    if not self.Settings.AvoidUnwantedShops then return false end
    local margin = math.max(0, tonumber(padding) or 6)
    for _, entry in ipairs(self:GetMenuTriggerZones()) do
        if entry.Part ~= allowedZone
            and self:SegmentIntersectsMenuZone(startPos, endPos, entry.Part, margin) then
            local zone = entry.Part
            local from = zone.CFrame:PointToObjectSpace(startPos)
            local to = zone.CFrame:PointToObjectSpace(endPos)
            local half = zone.Size * 0.5
            local hx, hz = half.X + margin, half.Z + margin
            local startX, startZ = math.abs(from.X) / math.max(0.2, hx),
                math.abs(from.Z) / math.max(0.2, hz)
            local endX, endZ = math.abs(to.X) / math.max(0.2, hx),
                math.abs(to.Z) / math.max(0.2, hz)
            local fromRadius = math.max(startX, startZ)
            local toRadius = math.max(endX, endZ)
            local movingOut = fromRadius <= 1.001 and toRadius > 1.1
                and (from.X*(to.X-from.X) / math.max(1,hx*hx)
                    + from.Z*(to.Z-from.Z) / math.max(1,hz*hz)) >= -0.01
            -- A client rubber-banded onto an Aura/Sell pad must be able to
            -- EXIT the forbidden volume. Only outward egress is exempt;
            -- crossing into or through another protected shop remains blocked.
            if not movingOut then return true, entry end
        end
    end
    return false
end

-- Intermediate trigger-volume detours are unnecessary for instant teleport.
function P:DestinationHitsMenuZone(position, allowedZone)
    for _, entry in ipairs(self:GetMenuTriggerZones()) do
        if entry.Part ~= allowedZone and self:IsWithinMenuZone(position, entry.Part, 1.5) then
            return true, entry
        end
    end
    return false
end

-- Return the shop *building* containing a menu trigger, not other tagged UI
-- zones elsewhere in the map. Only shop buildings can cause a sky-hop.
-- No airborne navigation: normal travel stays on the ground.
function P:DismissBlockingShopMenus()
    if not self.Alive or not self.Settings.Enabled or not self.Settings.AutoDismissShopMenus then
        return false
    end
    local gui = self.Player:FindFirstChildOfClass("PlayerGui")
    local main = gui and gui:FindFirstChild("MainUI")
    local menus = main and main:FindFirstChild("Menus")
    if not menus then return false end

    local interface = self.M.GameInterface
    if not interface then
        local scripts = self.Player:FindFirstChild("PlayerScripts")
        local modules = scripts and scripts:FindFirstChild("ClientModules")
        local module = modules and modules:FindFirstChild("InterfaceModule")
        if module then
            local ok, value = pcall(require, module)
            if ok and type(value) == "table" and type(value.CloseFrame) == "function" then
                interface = value
                self.M.GameInterface = value
            end
        end
    end

    local dismissed = false
    -- The updated shop models include Auras and Trading in addition to the
    -- original shop trio; menu attributes cover future map additions too.
    local names = {
        Shop = true, Sell = true, Arms = true, Upgrades = true,
        Auras = true, TradingSelectPlayer = true,
    }
    for _, entry in ipairs(self:GetMenuTriggerZones()) do
        names[entry.Menu] = true
    end
    for name in pairs(names) do
        local frame = menus:FindFirstChild(name)
        if frame and frame:IsA("GuiObject") and frame.Visible then
            -- Use the game's native close action to release camera blur/FOV and
            -- HUD state, rather than merely hiding the blocking Frame.
            local ok = false
            if interface then
                ok = pcall(function() interface.CloseFrame(name) end)
            end
            if not ok then frame.Visible = false end
            dismissed = true
        end
    end
    if dismissed then
        self.Navigation.LastShopClose = os.clock()
        self.Navigation.LastResult = "Dismissed shop UI"
    end
    return dismissed
end

function P:InstallShopPopupGuard()
    self:Spawn(function()
        while self.Alive do
            if self.Settings.Enabled then
                pcall(function() self:DismissBlockingShopMenus() end)
                task.wait(0.12)
            else
                task.wait(0.35)
            end
        end
    end)
end

-- Old sky/roof escape removed: direct teleport never crosses intermediate shops.
-- Route through the open middle of the four shop stalls, aligned to spawn
-- and toward Stage 1. No guessed world coordinates or shop-edge ascents.
function P:GetSpawnShopCorridor()
    local map = self:Map()
    local shops = map and map:FindFirstChild("Shops")
    local spawn = map and map:FindFirstChild("SpawnZone")
    local stage = self:GetStage(1)
    local lift = stage and stage:FindFirstChild("LiftZone", true)
    if not shops or not spawn or not lift then return nil end
    local names = {Sell = true, Arms = true, Aura = true, Auras = true, Upgrades = true}
    local stores, center = {}, Vector3.zero
    for _, model in ipairs(shops:GetChildren()) do
        if names[model.Name] then
            local zone = model:FindFirstChild("Zone", true)
            if zone and zone:IsA("BasePart") then
                table.insert(stores, {Model = model, Zone = zone})
                center += zone.Position
            end
        end
    end
    -- Never use an unverified corridor when shop models are still streaming.
    if #stores < 4 then return nil end
    center /= #stores
    local direction = Vector3.new(lift.Position.X - spawn.Position.X,
        0, lift.Position.Z - spawn.Position.Z)
    if direction.Magnitude < 12 then return nil end
    local forward = direction.Unit
    local right = Vector3.new(-forward.Z, 0, forward.X)
    local lateral = math.clamp((spawn.Position - center):Dot(right), -5, 5)
    local lane = Vector3.new(center.X, 0, center.Z) + right * lateral
    local minimum, maximum = math.huge, -math.huge
    local roof = -math.huge
    for _, item in ipairs(stores) do
        local model, zone = item.Model, item.Zone
        local cf, size
        if model:IsA("Model") then
            local ok, boxCF, boxSize = pcall(function()
                return model:GetBoundingBox()
            end)
            if ok then cf, size = boxCF, boxSize end
        end
        if not cf then cf, size = zone.CFrame, zone.Size end
        local half = size * 0.5
        local offset = (cf.Position - lane):Dot(forward)
        local radius = math.abs(cf.RightVector:Dot(forward)) * half.X
            + math.abs(cf.UpVector:Dot(forward)) * half.Y
            + math.abs(cf.LookVector:Dot(forward)) * half.Z
        minimum = math.min(minimum, offset - radius)
        maximum = math.max(maximum, offset + radius)
        local explicitRoof, broadTop = -math.huge, -math.huge
        for _, part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") and part ~= zone then
                local h, pcf = part.Size * 0.5, part.CFrame
                local top = part.Position.Y + math.abs(pcf.RightVector.Y)*h.X
                    + math.abs(pcf.UpVector.Y)*h.Y + math.abs(pcf.LookVector.Y)*h.Z
                local name = string.lower(part.Name)
                if name:find("roof",1,true) or name:find("awning",1,true)
                    or name:find("ceiling",1,true) then
                    -- Include the non-collidable striped tent/awning visuals.
                    explicitRoof = math.max(explicitRoof, top)
                elseif part.CanCollide and part.Size.X * part.Size.Z >= 15 then
                    broadTop = math.max(broadTop, top)
                end
            end
        end
        local zh, zcf = zone.Size * 0.5, zone.CFrame
        local zoneTop = zone.Position.Y + math.abs(zcf.RightVector.Y)*zh.X
            + math.abs(zcf.UpVector.Y)*zh.Y + math.abs(zcf.LookVector.Y)*zh.Z
        roof = math.max(roof, zoneTop,
            explicitRoof > -math.huge and explicitRoof or broadTop)
    end
    if minimum >= maximum or roof == -math.huge then return nil end
    return {Lane=lane, Forward=forward, Min=minimum, Max=maximum, Roof=roof}
end

-- Sky travel removed in v1.8.0. Ground waypoints and shop avoidance remain.
-- Zone height is resolved using the destination zone (never the player's
-- current elevated platform). This prevents high-stage travel from picking
-- an accidental rooftop instead of the spawn/shop floor.
function P:GetTeleportSurface(goal,zone)
    if not zone or not zone:IsA("BasePart") then
        return self:ProjectToGround(goal)
    end
    local ch=self.Player.Character
    local exclusions={zone}
    if ch then table.insert(exclusions,ch) end
    local rp=RaycastParams.new()
    rp.FilterType=Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances=exclusions
    pcall(function() rp.RespectCanCollide=true end)
    local top=zone.Position.Y+zone.Size.Y*0.5
    local bottom=zone.Position.Y-zone.Size.Y*0.5
    local origin=Vector3.new(goal.X,top+10,goal.Z)
    local hit=workspace:Raycast(origin,Vector3.new(0,-110,0),rp)
    local y=bottom
    if hit and hit.Position.Y<=top+0.75 and hit.Position.Y>=bottom-12 then
        y=hit.Position.Y
    end
    return Vector3.new(goal.X,y,goal.Z)
end

function P:IsSafeTPLanding(pos,options)
    if options.Zone and not self:IsPointInsidePart(options.Zone,pos,0.1) then
        return false,"outside target zone"
    end
    local bad,entry=self:DestinationHitsMenuZone(pos,options.AllowedShopZone)
    if bad then return false,"unrelated menu trigger: "..tostring(entry.Menu) end
    local ch=self.Player.Character
    if not ch then return false,"character missing" end
    local params=OverlapParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances={ch}
    params.MaxParts=80
    local ok,parts=pcall(function()
        return workspace:GetPartBoundsInBox(CFrame.new(pos+Vector3.new(0,0.35,0)),
            Vector3.new(1.9,2.5,1.9),params)
    end)
    if not ok then return false,"collision query failed" end
    for _,part in ipairs(parts) do
        if part.CanCollide and part~=options.Zone and part~=options.Exclude then
            return false,"occupied: "..part.Name
        end
    end
    return true
end

function P:WalkToPosition(goalPosition,options)
    options=options or {}
    if typeof(goalPosition)~="Vector3" then return false end
    local character,humanoid,root=self:GetCharacter()
    if not root or not humanoid or humanoid.Health<=0 then return false end
    local predicate=options.ArrivalPredicate
    if type(predicate)=="function" and self:WalkArrivalSatisfied(predicate) then
        return true
    end
    local surface=self:GetTeleportSurface(goalPosition,options.Zone)
    if not surface then return false end
    local target=self:GetTeleportRootTarget(surface,humanoid,root)
    if not target then return false end
    if type(predicate)~="function"
        and (root.Position-target).Magnitude<=(tonumber(options.AcceptanceRadius) or 2.75) then
        return true
    end
    self.Navigation.Token=(self.Navigation.Token or 0)+1
    local token=self.Navigation.Token
    self.Navigation.Busy=true
    self.Navigation.Destination=surface
    self.Navigation.Waypoint=0
    self.Navigation.AllowedShopZone=options.AllowedShopZone
    self.Navigation.LastResult="Instant TP"
    self:DebugEvent("TP","From "..tostring(root.Position).." to "..tostring(target))
    local function finish(success,reason)
        self:ReleaseTeleportBody()
        if self.Navigation.Token==token then
            self.Navigation.Busy=false
            self.Navigation.Destination=nil
            self.Navigation.AllowedShopZone=nil
            self.Navigation.LastResult=reason or (success and "TP arrived" or "TP failed")
            if not success then
                self.Debug.LastRouteIssue=self.Navigation.LastResult
                self:DebugEvent("FAIL",self.Debug.LastRouteIssue)
            else
                self:DebugEvent("TP",self.Navigation.LastResult)
            end
        end
        return success
    end
    local offsets={
        Vector3.zero,Vector3.new(1.5,0,0),Vector3.new(-1.5,0,0),
        Vector3.new(0,0,1.5),Vector3.new(0,0,-1.5),
        Vector3.new(3,0,0),Vector3.new(-3,0,0),
        Vector3.new(0,0,3),Vector3.new(0,0,-3),
        Vector3.new(0,1.3,0),Vector3.new(0,2.4,0),
    }
    local attempts=0
    local maxAttempts=math.clamp(math.floor(tonumber(options.MaxAttempts) or 4),1,8)+3
    local last="no collision-free destination"
    for _,delta in ipairs(offsets) do
        if attempts>=maxAttempts then break end
        if not self:IsWalkTokenActive(token) then return finish(false,"TP cancelled") end
        local pos=target+delta
        local safe,why=self:IsSafeTPLanding(pos,options)
        if safe then
            attempts+=1
            character,humanoid,root=self:GetCharacter()
            if not character or not root or not humanoid or humanoid.Health<=0 then
                return finish(false,"character unavailable")
            end
            if not self:BeginTeleportBody(root,humanoid) then
                return finish(false,"cannot isolate character physics")
            end
            local forward=root.CFrame.LookVector
            local flat=Vector3.new(forward.X,0,forward.Z)
            flat=flat.Magnitude>0.05 and flat.Unit or Vector3.new(0,0,-1)
            local cf=CFrame.lookAt(pos,pos+flat,Vector3.yAxis)
            -- Anchor ONLY for the atomic PivotTo; unanchor before yielding
            -- so the next frame is network-owned and can register zone entry.
            local ok,err=pcall(function()
                root.Anchored=true
                root.AssemblyLinearVelocity=Vector3.zero
                root.AssemblyAngularVelocity=Vector3.zero
                character:PivotTo(cf)
                root.Anchored=false
                root.AssemblyLinearVelocity=Vector3.zero
                root.AssemblyAngularVelocity=Vector3.zero
            end)
            if not ok then
                last="PivotTo failed: "..tostring(err)
                self:ReleaseTeleportBody()
            else
                task.wait(math.clamp(tonumber(self.Settings.TeleportSettleSeconds) or 0.12,0.06,0.3))
                pcall(function()
                    root.AssemblyLinearVelocity=Vector3.zero
                    root.AssemblyAngularVelocity=Vector3.zero
                end)
                self:ReleaseTeleportBody()
                local _,h,r=self:GetCharacter()
                if not h or not r or h.Health<=0 then return finish(false,"character changed") end
                if (r.Position-pos).Magnitude>9 then
                    last="server position correction"
                elseif type(predicate)=="function" then
                    if self:WalkArrivalSatisfied(predicate) then
                        return finish(true,"Teleport entered zone")
                    end
                    task.wait(0.10)
                    if self:WalkArrivalSatisfied(predicate) then
                        return finish(true,"Teleport entered zone")
                    end
                    last="zone entry not confirmed"
                else
                    return finish(true,"Safe TP completed")
                end
            end
        else
            last=tostring(why)
        end
    end
    return finish(false,"Safe TP failed: "..last)
end

function P:WalkToObject(object, acceptance)
    local position = self:ObjectPosition(object)
    if not position then
        return false
    end
    return self:WalkToPosition(position, {
        AcceptanceRadius = acceptance or self.Settings.WalkAcceptanceRadius,
        Exclude = typeof(object) == "Instance" and object or nil,
    })
end

function P:WalkIntoZone(zone, intentionalShop)
    if not zone then
        return false
    end
    if not zone:IsA("BasePart") then
        return self:WalkToObject(zone, self.Settings.WalkAcceptanceRadius)
    end

    local _, _, root = self:GetCharacter()
    if root and self:IsPointInsidePart(zone, root.Position, 0.15) then
        return true
    end

    local function inside()
        local _, _, currentRoot = self:GetCharacter()
        return currentRoot and self:IsPointInsidePart(zone, currentRoot.Position, 0.08)
    end

    local candidates = {}
    local primary = self:GetZoneWalkPoint(zone)
    if primary then
        table.insert(candidates, primary)
    end

    -- Build alternate near-edge entry points. Lift zones often surround a rock,
    -- so the geometric centre can be physically occupied even though the trigger
    -- itself is valid. These points stay inside the zone but route around that centre.
    local currentCharacter, currentHumanoid
    currentCharacter, currentHumanoid, root = self:GetCharacter()
    if root then
        local half = zone.Size * 0.5
        local localRoot = zone.CFrame:PointToObjectSpace(root.Position)
        local marginX = math.min(math.max(1.0, half.X * 0.16), math.max(0.15, half.X - 0.15))
        local marginZ = math.min(math.max(1.0, half.Z * 0.16), math.max(0.15, half.Z - 0.15))
        local edgeX = math.max(0, half.X - marginX)
        local edgeZ = math.max(0, half.Z - marginZ)
        local sx = localRoot.X >= 0 and 1 or -1
        local sz = localRoot.Z >= 0 and 1 or -1
        local alongX = math.clamp(localRoot.X, -edgeX, edgeX)
        local alongZ = math.clamp(localRoot.Z, -edgeZ, edgeZ)
        local spreadX = math.min(edgeX * 0.55, 4)
        local spreadZ = math.min(edgeZ * 0.55, 4)

        local localCandidates = {}
        local normalizedX = math.abs(localRoot.X) / math.max(half.X, 0.1)
        local normalizedZ = math.abs(localRoot.Z) / math.max(half.Z, 0.1)
        if normalizedX >= normalizedZ then
            local sideX = sx * edgeX * 0.90
            table.insert(localCandidates, Vector3.new(sideX, 0, math.clamp(alongZ + spreadZ, -edgeZ, edgeZ)))
            table.insert(localCandidates, Vector3.new(sideX, 0, math.clamp(alongZ - spreadZ, -edgeZ, edgeZ)))
            table.insert(localCandidates, Vector3.new(sideX * 0.78, 0, 0))
        else
            local sideZ = sz * edgeZ * 0.90
            table.insert(localCandidates, Vector3.new(math.clamp(alongX + spreadX, -edgeX, edgeX), 0, sideZ))
            table.insert(localCandidates, Vector3.new(math.clamp(alongX - spreadX, -edgeX, edgeX), 0, sideZ))
            table.insert(localCandidates, Vector3.new(0, 0, sideZ * 0.78))
        end

        for _, localPoint in ipairs(localCandidates) do
            local worldPoint = zone.CFrame:PointToWorldSpace(localPoint)
            local grounded = self:ProjectToGround(worldPoint, zone)
            if grounded then
                table.insert(candidates, grounded)
            end
        end
    end

    -- Explicitly try all four interior-facing sides of a shop trigger.
    -- An Aura pad can block the nearest side of Sell while the other side is open.
    if intentionalShop and zone:IsA("BasePart") then
        local half = zone.Size * 0.5
        for _, side in ipairs({
            Vector3.new(half.X*0.76,0,0),
            Vector3.new(-half.X*0.76,0,0),
            Vector3.new(0,0,half.Z*0.76),
            Vector3.new(0,0,-half.Z*0.76),
        }) do
            local world=zone.CFrame:PointToWorldSpace(side)
            local floor=self:ProjectToGround(world,zone)
            if floor then
                local _, h, r=self:GetCharacter()
                local dest=h and r and self:GetTeleportRootTarget(floor,h,r)
                if dest and not self:DestinationHitsMenuZone(dest,zone) then
                    table.insert(candidates,floor)
                end
            end
        end
    end

    for index, goal in ipairs(candidates) do
        if inside() then
            return true
        end
        if intentionalShop and index > 7 then break end
        self.Navigation.LastResult = index == 1 and "Entering zone" or ("Alternate zone entry " .. tostring(index - 1))
        local reached = self:WalkToPosition(goal, {
            AcceptanceRadius = 1.15,
            Exclude = zone,
            AllowedShopZone = intentionalShop and zone or nil,
            Zone = zone,
            MaxAttempts = intentionalShop and 2 or (index == 1 and 4 or 2),
            ArrivalPredicate = inside,
        })
        if reached and inside() then
            return true
        end
        if intentionalShop then
            self:DebugEvent("SHOP", "Zone entry candidate "..index..
                " failed: "..tostring(self.Debug.LastRouteIssue))
        end
    end

    return inside() == true
end

function P:WalkOutOfZone(zone, extraDistance)
    if not zone or not zone:IsA("BasePart") then
        return false
    end
    local _, _, root = self:GetCharacter()
    if not root then
        return false
    end
    if not self:IsPointInsidePart(zone, root.Position, 0) then
        return true
    end

    local center = zone.Position
    local offset = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
    if offset.Magnitude < 0.5 then
        local look = zone.CFrame.LookVector
        offset = Vector3.new(-look.X, 0, -look.Z)
    end
    if offset.Magnitude < 0.1 then
        offset = Vector3.new(0, 0, -1)
    end
    local distance = math.max(zone.Size.X, zone.Size.Z) * 0.5 + (tonumber(extraDistance) or 7)
    local raw = center + offset.Unit * distance
    local goal = self:ProjectToGround(raw, zone)
    return self:WalkToPosition(goal, {
        AcceptanceRadius = 2.0,
        Exclude = zone,
        ArrivalPredicate = function()
            local _, _, currentRoot = self:GetCharacter()
            return currentRoot and not self:IsPointInsidePart(zone, currentRoot.Position, 0)
        end,
    })
end

function P:WaitUntil(predicate, timeout, interval)
    local deadline = os.clock() + (timeout or 5)
    repeat
        local ok, result = pcall(predicate)
        if ok and result then
            return true, result
        end
        task.wait(interval or 0.05)
    until not self.Alive or os.clock() >= deadline
    return false
end

function P:Map()
    return workspace:FindFirstChild("Map")
end

function P:GetStage(stageId)
    local map = self:Map()
    local stages = map and map:FindFirstChild("Stages")
    if not stages then
        return nil
    end
    stageId = tonumber(stageId)
    if not stageId then
        return nil
    end
    -- StageId is the authoritative identifier. Name fallback is for instances arriving
    -- before their attributes in a streaming/replication update.
    local fallback = stages:FindFirstChild("Stage" .. tostring(stageId))
    if fallback and fallback:IsA("Model") then
        local attribute = tonumber(fallback:GetAttribute("StageId"))
        if not attribute or attribute == stageId then
            return fallback
        end
    end
    for _, stage in ipairs(stages:GetChildren()) do
        if stage:IsA("Model") and tonumber(stage:GetAttribute("StageId")) == stageId then
            return stage
        end
    end
    return nil
end

function P:GetStageWeight(stageId)
    local stage = self:GetStage(stageId)
    local key = stage and stage:GetAttribute("StoneKey")
    -- The game's stage models use Stone16, Stone17 and Stone18, and its live
    -- ReplicatedStorage.Shared.Data.Stones is more reliable than a stale 15-stage map snapshot.
    local stones = self.M.Config.Stones or {}
    local config = stones[key] or stones["Stone" .. tostring(tonumber(stageId) or stageId)]
    return config and tonumber(config.Weight) or math.huge
end

function P:GetMaxStage()
    local maxStage = 0
    -- Treat the live Config.Stones as the supported game stage catalog.
    -- This automatically detects future additions without shipping a new hard-coded cap.
    for key, definition in pairs(self.M.Config.Stones or {}) do
        local id = type(key) == "string" and tonumber(key:match("^Stone(%d+)$")) or nil
        if id and type(definition) == "table" and tonumber(definition.Weight) then
            maxStage = math.max(maxStage, id)
        end
    end
    local map = self:Map()
    local stages = map and map:FindFirstChild("Stages")
    if stages then
        for _, stage in ipairs(stages:GetChildren()) do
            if stage:IsA("Model") then
                local id = tonumber(stage:GetAttribute("StageId"))
                    or tonumber(stage.Name:match("^Stage(%d+)$"))
                if id then
                    maxStage = math.max(maxStage, id)
                end
            end
        end
    end
    return maxStage
end

function P:BackpackCapacity()
    return tonumber(self.M.UpgradeUtils.GetValue(self:Data(), "Backpack")) or 3
end

function P:BackpackCount()
    local temporary = self:SessionData().TemporaryBackpack
    if type(temporary) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(temporary) do
        count = count + 1
    end
    return count
end

function P:IsAtSpawn()
    local map = self:Map()
    local spawnZone = map and map:FindFirstChild("SpawnZone")
    local _, _, root = self:GetCharacter()
    if not spawnZone or not root or not spawnZone:IsA("BasePart") then
        return false
    end
    return self:IsPointInsidePart(spawnZone, root.Position, 0)
end

-- Prefer a bank point on the open center aisle instead of the nearest shop-side
-- edge of SpawnZone. The return path stays independent of the shop UI.
function P:GetSafeSpawnBankPoint(zone)
    if not zone or not zone:IsA("BasePart") then return nil end
    local corridor = self:GetSpawnShopCorridor()
    local goals = {}
    if corridor then
        local along = (zone.Position-corridor.Lane):Dot(corridor.Forward)
        local center = corridor.Lane+corridor.Forward*along
        for _, offset in ipairs({0,-4,4,-8,8,-12,12}) do
            table.insert(goals, center+corridor.Forward*offset)
        end
    end
    table.insert(goals,zone.Position)
    for _, candidate in ipairs(goals) do
        local location = Vector3.new(candidate.X,zone.Position.Y,candidate.Z)
        if self:IsPointInsidePart(zone,location,1.5) then
            local floor = self:ProjectToGround(location,zone)
            local _,h,r = self:GetCharacter()
            local goal = floor and h and r and self:GetTeleportRootTarget(floor,h,r)
            if goal and not self:DestinationHitsMenuZone(goal) then
                return floor
            end
        end
    end
    return nil
end

function P:MoveToSpawn()
    local map=self:Map()
    local zone=map and map:FindFirstChild("SpawnZone")
    if not zone or not zone:IsA("BasePart") then
        self.LastError="SpawnZone missing; cannot bank"
        return false
    end
    self:SetStatus("Returning through center aisle to bank treasure...", "MOVE")
    local function inside()
        local _,_,r=self:GetCharacter()
        return r and self:IsPointInsidePart(zone,r.Position,0.3)==true
    end
    if inside() then return true end
    -- Direct TP to the banking zone from any stage: no sky descent or path.
    local bankPoint=self:GetSafeSpawnBankPoint(zone)
    if bankPoint then
        local ok=self:WalkToPosition(bankPoint,{
            AcceptanceRadius=1.5,Exclude=zone,Zone=zone,
            ArrivalPredicate=inside,MaxAttempts=4,
        })
        if ok and inside() then
            self:SetStatus("Inside SpawnZone; confirming bank...", "BANK")
            return true
        end
    end
    -- Keep the original alternate entry points for maps streaming in.
    if self:WalkIntoZone(zone) and inside() then
        self:SetStatus("Inside SpawnZone; confirming bank...", "BANK")
        return true
    end
    self.LastError="Failed to enter banking zone after returning from stages"
    return false
end

function P:ClearRunState()
    self.Run.Cleared = {}
    self.Run.Rewards = {}
    self.Run.Progress = {}
    self.Run.Session = nil
    self.Run.PickedUUIDs = {}
    self.Run.LastReset = os.clock()
end

function P:ApplySnapshot(snapshot)
    self.Run.Cleared = {}
    self.Run.Rewards = {}
    self.Run.Progress = {}
    self.Run.Session = nil
    if type(snapshot) ~= "table" then
        return
    end
    self.Run.Synced = true

    -- Snapshot containers are intentionally handled with pairs rather than ipairs because the
    -- game's own Restore code accepts both arrays and keyed tables.
    if type(snapshot.Cleared) == "table" then
        for key, value in pairs(snapshot.Cleared) do
            local stageId
            if value == true then
                stageId = tonumber(key)
            else
                stageId = tonumber(value)
            end
            if stageId then
                self.Run.Cleared[stageId] = true
            end
        end
    end

    if type(snapshot.Progress) == "table" then
        for key, value in pairs(snapshot.Progress) do
            local stageId = tonumber(key)
            if stageId then
                if type(value) == "table" then
                    self.Run.Progress[stageId] = tonumber(value.Progress) or 0
                else
                    self.Run.Progress[stageId] = tonumber(value) or 0
                end
            end
        end
    end

    if type(snapshot.Rewards) == "table" then
        for _, reward in pairs(snapshot.Rewards) do
            if type(reward) == "table" and tonumber(reward.StageId) then
                local stageId = tonumber(reward.StageId)
                self.Run.Rewards[stageId] = {
                    StageId = stageId,
                    Items = type(reward.Items) == "table" and reward.Items or {},
                    Completed = reward.Completed == true,
                }
            end
        end
    end

    if type(snapshot.Session) == "table" then
        self.Run.Session = snapshot.Session
        local stageId = tonumber(snapshot.Session.StageId)
        if stageId and tonumber(snapshot.Session.Progress) then
            self.Run.Progress[stageId] = tonumber(snapshot.Session.Progress)
        end
        if stageId and type(snapshot.Session.Items) == "table" then
            local reward = self.Run.Rewards[stageId] or {StageId = stageId, Items = {}, Completed = false}
            reward.Items = snapshot.Session.Items
            self.Run.Rewards[stageId] = reward
        end
    end
end

function P:InstallRemoteObservers()
    self:Connect(self.R.RockLiftingFeedback.OnClientEvent, function(kind, payload)
        self.Run.LastFeedback = os.clock()
        if kind == "Snapshot" then
            self:ApplySnapshot(payload)
        elseif kind == "Reset" then
            self:ClearRunState()
            self.Run.Synced = true
        elseif kind == "Started" and type(payload) == "table" then
            self.Run.Synced = true
            self.Run.Session = payload
            local stageId = tonumber(payload.StageId)
            if stageId then
                self.Run.Progress[stageId] = tonumber(payload.Progress) or self.Run.Progress[stageId] or 0
                local reward = self.Run.Rewards[stageId] or {StageId = stageId, Items = {}, Completed = false}
                if type(payload.Items) == "table" then
                    reward.Items = payload.Items
                end
                self.Run.Rewards[stageId] = reward
            end
        elseif kind == "Progress" and type(payload) == "table" then
            self.Run.Synced = true
            local stageId = tonumber(payload.StageId)
            if stageId then
                self.Run.Progress[stageId] = tonumber(payload.Progress) or self.Run.Progress[stageId] or 0
            end
            if self.Run.Session and self.Run.Session.SessionId == payload.SessionId then
                self.Run.Session.Progress = payload.Progress
                self.Run.Session.Rate = payload.Rate
                self.Run.Session.UpdatedAt = payload.UpdatedAt
            end
        elseif kind == "Completed" and type(payload) == "table" then
            self.Run.Synced = true
            local stageId = tonumber(payload.StageId)
            if stageId then
                self.Run.Cleared[stageId] = true
                self.Run.Progress[stageId] = 1
                local reward = self.Run.Rewards[stageId] or {StageId = stageId, Items = {}, Completed = false}
                if type(payload.Items) == "table" then
                    reward.Items = payload.Items
                end
                reward.Completed = true
                self.Run.Rewards[stageId] = reward
            end
            if self.Run.Session and self.Run.Session.SessionId == payload.SessionId then
                self.Run.Session = nil
            end
        elseif kind == "Stopped" and type(payload) == "table" then
            self.Run.Synced = true
            local stageId = tonumber(payload.StageId)
            if stageId then
                self.Run.Progress[stageId] = tonumber(payload.Progress) or self.Run.Progress[stageId] or 0
            end
            if self.Run.Session and self.Run.Session.SessionId == payload.SessionId then
                self.Run.Session = nil
            end
        end
    end)

    self:Connect(self.R.StageTreasuresBanked.OnClientEvent, function()
        self.Run.LastBank = os.clock()
    end)

    self:Connect(self.R.SpecialStageSpawnChanged.OnClientEvent, function(entry)
        self:ReceiveSpecialSpawn(entry)
    end)

    self:Connect(self.Player.CharacterAdded, function()
        self:StopWalking() -- interrupt tween bound to the old character
        task.delay(1, function()
            if self.Alive then
                pcall(function()
                    self.R.RockLiftingInput:FireServer("Sync")
                end)
            end
        end)
    end)

    pcall(function()
        self.R.RockLiftingInput:FireServer("Sync")
    end)
end

function P:ReceiveSpecialSpawn(entry)
    if type(entry) ~= "table" then
        return
    end
    local stageId = tonumber(entry.StageId)
    local slot = entry.Slot
    if not stageId or type(slot) ~= "string" then
        return
    end

    self.Run.Specials[stageId] = self.Run.Specials[stageId] or {}
    self.Run.SpecialRevisions[stageId] = self.Run.SpecialRevisions[stageId] or {}
    local oldRevision = tonumber(self.Run.SpecialRevisions[stageId][slot]) or -math.huge
    local newRevision = tonumber(entry.Revision) or oldRevision + 1
    if newRevision <= oldRevision then
        return
    end
    self.Run.SpecialRevisions[stageId][slot] = newRevision

    if type(entry.Item) == "table" then
        self.Run.Specials[stageId][slot] = entry
    else
        -- SpecialStageSpawnChanged also carries removals. Keep the revision tombstone but remove
        -- the active item so an expired special can never keep attracting the route planner.
        self.Run.Specials[stageId][slot] = nil
    end
end

function P:RefreshSpecialSpawns(force)
    if not self.Settings.AutoSpecialSpawns then
        return
    end
    if not force and os.clock() - self.LastSpecialSync < 20 then
        return
    end
    self.LastSpecialSync = os.clock()
    local ok, result = pcall(function()
        return self.R.GetSpecialStageSpawns:InvokeServer()
    end)
    if ok and type(result) == "table" then
        -- This call is an authoritative snapshot, not a delta stream. Rebuild the active cache
        -- directly so an unchanged Revision is not incorrectly rejected as stale.
        local fresh = {}
        for _, entry in pairs(result) do
            if type(entry) == "table" then
                local stageId = tonumber(entry.StageId)
                local slot = entry.Slot
                if stageId and type(slot) == "string" and type(entry.Item) == "table" then
                    fresh[stageId] = fresh[stageId] or {}
                    fresh[stageId][slot] = entry
                    self.Run.SpecialRevisions[stageId] = self.Run.SpecialRevisions[stageId] or {}
                    local revision = tonumber(entry.Revision)
                    if revision then
                        self.Run.SpecialRevisions[stageId][slot] = math.max(
                            tonumber(self.Run.SpecialRevisions[stageId][slot]) or -math.huge,
                            revision
                        )
                    end
                end
            end
        end
        self.Run.Specials = fresh
    end
end

function P:EnsureRunSynced()
    if self.Run.Synced or self.Run.LastFeedback > 0 then
        return true
    end
    pcall(function()
        self.R.RockLiftingInput:FireServer("Sync")
    end)
    local ok = self:WaitUntil(function()
        return self.Run.Synced or self.Run.LastFeedback > 0
    end, 2.0, 0.05)
    return ok == true
end

function P:IsStageCleared(stageId)
    return self.Run.Cleared[tonumber(stageId)] == true
end

function P:HighestCleared()
    local highest = 0
    for stageId, cleared in pairs(self.Run.Cleared) do
        if cleared then
            highest = math.max(highest, tonumber(stageId) or 0)
        end
    end
    return highest
end

function P:CurrentPower()
    return math.max(1, tonumber(self:Data().Power) or 1)
end

function P:CurrentLevel()
    return math.max(1, tonumber(self:Data().Level) or 1)
end

function P:CurrentRebirths()
    return math.max(0, tonumber(self:Data().Rebirths) or 0)
end

function P:NextRebirthInfo()
    local entry = self.M.Config.Rebirth.Levels[self:CurrentRebirths() + 1]
    if not entry then
        return nil
    end
    return entry, tonumber(entry.LevelRequired)
end

function P:CanRebirth()
    local _, levelRequired = self:NextRebirthInfo()
    return levelRequired ~= nil and self:CurrentLevel() >= levelRequired
end

function P:NextRebirthPower()
    local _, levelRequired = self:NextRebirthInfo()
    if not levelRequired then
        return nil
    end
    local ok, power = pcall(self.M.LevelUtils.GetRequiredPower, levelRequired)
    return ok and tonumber(power) or nil
end

function P:CumulativeLiftSeconds(stageId, power)
    power = math.max(1, tonumber(power) or self:CurrentPower())
    local total = 0
    for id = 1, math.max(0, tonumber(stageId) or 0) do
        local weight = self:GetStageWeight(id)
        if weight == math.huge then
            return math.huge
        end
        total = total + weight / power
    end
    return total
end

function P:HighestEfficientStage(power)
    power = math.max(1, tonumber(power) or self:CurrentPower())
    local maxStage = self:GetMaxStage()
    local highest = 0
    for stageId = 1, maxStage do
        local weight = self:GetStageWeight(stageId)
        if weight == math.huge then
            break
        end
        local seconds = weight / power
        local runSeconds = self:CumulativeLiftSeconds(stageId, power)
        if seconds <= self.Settings.MaxLiftSeconds and runSeconds <= self.Settings.MaxRunSeconds then
            highest = stageId
        else
            break
        end
    end
    return highest
end

function P:GetGameROIStage()
    if not self.Settings.AdaptiveROI or type(self.M.StoneIncome) ~= "table" or type(self.M.StoneIncome.Estimate) ~= "function" then
        self.Route.GameROIStage = 0
        self.Route.CashPerSecond = 0
        self.Route.ExpectedItemValue = 0
        self.Route.TripSeconds = 0
        return 0
    end
    local ok, estimate = pcall(self.M.StoneIncome.Estimate, self:Data())
    if not ok or type(estimate) ~= "table" then
        return 0
    end
    self.Route.GameROIStage = tonumber(estimate.StageId) or 0
    self.Route.CashPerSecond = tonumber(estimate.CashPerSecond) or 0
    self.Route.ExpectedItemValue = tonumber(estimate.ExpectedItemValue) or 0
    self.Route.TripSeconds = tonumber(estimate.TripSeconds) or 0
    return self.Route.GameROIStage
end

function P:GetSpecialPriorityStage(power)
    if not self.Settings.AutoSpecialSpawns then
        return 0
    end
    local maxStage = self:GetMaxStage()
    local best = 0
    for stageId, slots in pairs(self.Run.Specials) do
        if stageId <= maxStage and type(slots) == "table" then
            local active = false
            for _, entry in pairs(slots) do
                if type(entry) == "table" and type(entry.Item) == "table" then
                    active = true
                    break
                end
            end
            if active then
                local individual = self:GetStageWeight(stageId) / math.max(1, power)
                local cumulative = self:CumulativeLiftSeconds(stageId, power)
                if individual <= self.Settings.MaxLiftSeconds * 1.75 and cumulative <= self.Settings.SpecialRunSeconds then
                    best = math.max(best, stageId)
                end
            end
        end
    end
    return best
end

function P:ChooseTargetStage()
    self:RefreshSpecialSpawns(false)
    local power = self:CurrentPower()
    local efficient = self:HighestEfficientStage(power)
    if efficient <= 0 then
        return 0
    end

    -- v1.6.1 applied the offline StoneIncome ROI estimator as a hard maximum.
    -- It favors shorter/older rocks and caused a late-game Stage-15 ceiling.
    -- Keep its economic forecast, but never use it to block an affordable higher stage.
    -- Sequential stage completion also gives access to rarer treasure on later ground slots.
    local roiStage = self:GetGameROIStage()
    local target = efficient
    if self.Settings.AdaptiveROI and roiStage > 0 and efficient < 15 then
        -- In earlier zones, respect economy estimates but at most give up one rock.
        -- Beyond Stage 14, never let the offline model hide the 100T+ content.
        target = math.max(1, math.min(efficient, math.max(roiStage, efficient - 1)))
    end
    target = math.max(target, self:GetSpecialPriorityStage(power))
    return math.clamp(target, 0, self:GetMaxStage())
end

function P:ChooseTrainingTarget()
    local power = self:CurrentPower()
    local target = self:ChooseTargetStage()
    local maxStage = self:GetMaxStage()

    if target <= 0 then
        local required = self:GetStageWeight(1) / math.max(0.1, self.Settings.MaxLiftSeconds)
        return math.ceil(required), "Stage 1 efficiency"
    end

    local nextStage = target + 1
    local bestTarget, reason
    if nextStage <= maxStage then
        -- Both per-rock time and cumulative run time are hard conditions in
        -- HighestEfficientStage. Train for BOTH, not solely the next stone's weight.
        local individualNeed = self:GetStageWeight(nextStage) / math.max(0.1, self.Settings.MaxLiftSeconds)
        local totalNeed = self:CumulativeLiftSeconds(nextStage, 1) / math.max(1, self.Settings.MaxRunSeconds)
        local required = math.ceil(math.max(individualNeed, totalNeed))
        local ratio = tonumber(self.Settings.TrainAheadRatio) or 1.30
        if nextStage >= 16 and self.Settings.PushNewStages then
            -- New UPD rocks rise from 100T to 300T, 1Qa and 5Qa.
            -- The old 1.3x near-goal rule never trained far enough to unlock them.
            ratio = math.max(ratio, tonumber(self.Settings.NewStageTrainRatio) or 8)
        end
        if required > power and required <= power * ratio then
            bestTarget = required
            reason = "Stage " .. tostring(nextStage) .. " (new rock progression)"
        end
    end

    local rebirthPower = self:NextRebirthPower()
    if rebirthPower and rebirthPower > power and rebirthPower <= power * self.Settings.RebirthTrainAheadRatio then
        if not bestTarget or rebirthPower < bestTarget then
            bestTarget = math.ceil(rebirthPower)
            reason = "next rebirth"
        end
    end

    if self.Settings.AutoRequirements then
        local requirement = self:RefreshRequirementPlan()
        if requirement.Kind == "Power"
            and tonumber(requirement.TargetPower)
            and requirement.TargetPower > power then
            if not bestTarget or requirement.TargetPower < bestTarget then
                bestTarget = math.ceil(requirement.TargetPower)
                reason = requirement.Name
            end
        end
    end

    return bestTarget, reason
end

function P:GetBestTrainingStationId()
    local data = self:Data()
    local rebirths = self:CurrentRebirths()
    local bestId = nil
    local bestMultiplier = 1
    for stationId, config in ipairs(self.M.Config.Training or {}) do
        local unlocked = false
        if config.Gamepass then
            local ok, has = pcall(self.M.PlayerDataInfo.HasGamepass, data, config.Gamepass)
            unlocked = ok and has == true
        else
            unlocked = rebirths >= (tonumber(config.RequiredRebirths) or 0)
        end
        local multiplier = tonumber(config.Multiplier) or 1
        if unlocked and multiplier > bestMultiplier then
            bestMultiplier = multiplier
            bestId = stationId
        elseif unlocked and not bestId then
            bestId = stationId
            bestMultiplier = multiplier
        end
    end
    return bestId, bestMultiplier
end

function P:GetTrainingModel(stationId)
    for _, model in ipairs(self.S.CollectionService:GetTagged("Training")) do
        if tonumber(model:GetAttribute("Id")) == tonumber(stationId) and model:IsDescendantOf(workspace) then
            return model
        end
    end
    return nil
end

function P:GetTrainingPartCandidates(model)
    local candidates = {}
    local seen = {}
    local preferred = {
        Zone = 100,
        TrainingZone = 95,
        Trigger = 90,
        Area = 85,
        Hitbox = 80,
        Platform = 60,
        Floor = 55,
    }
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            local score = preferred[part.Name] or 0
            if part.Transparency >= 0.95 and not part.CanCollide then
                score = score + 35
            end
            local volume = part.Size.X * part.Size.Y * part.Size.Z
            score = score + math.min(25, (math.log(math.max(1, volume)) / math.log(2)))
            table.insert(candidates, {Part = part, Score = score})
            seen[part] = true
        end
    end
    if model.PrimaryPart and not seen[model.PrimaryPart] then
        table.insert(candidates, {Part = model.PrimaryPart, Score = 50})
    end
    table.sort(candidates, function(a, b)
        return a.Score > b.Score
    end)
    return candidates
end

function P:EnterTrainingStation(stationId)
    if tonumber(self.Player:GetAttribute("TrainingStation")) == tonumber(stationId) then
        return true
    end
    local model = self:GetTrainingModel(stationId)
    if not model then
        return false
    end
    local candidates = self:GetTrainingPartCandidates(model)
    for index = 1, math.min(#candidates, 8) do
        local part = candidates[index].Part
        if part and part.Parent then
            self:SetStatus("Moving to training station " .. tostring(stationId) .. "...", "MOVE")
            local reached = self:WalkIntoZone(part)
            if reached then
                local entered = self:WaitUntil(function()
                    return tonumber(self.Player:GetAttribute("TrainingStation")) == tonumber(stationId)
                end, 1.15, 0.05)
                if entered then
                    return true
                end
            end
        end
    end
    return false
end

function P:TrainToPower(targetPower, reason)
    if not self.Settings.AutoTrain or not targetPower then
        return false
    end
    targetPower = math.max(self:CurrentPower(), tonumber(targetPower) or self:CurrentPower())
    local stationId, multiplier = self:GetBestTrainingStationId()
    if stationId then
        self:EnterTrainingStation(stationId)
    else
        self:MoveToSpawn()
    end

    self.TrainingTarget = targetPower
    local started = os.clock()
    while self.Alive and self.Settings.Enabled and self.Settings.AutoTrain do
        local power = self:CurrentPower()
        self:SetStatus(
            string.format("Training to %s Strength (%s, station x%s)", self:Compact(targetPower), tostring(reason or "progression"), tostring(multiplier or 1)),
            "TRAIN"
        )
        if power >= targetPower then
            self.TrainingTarget = nil
            return true
        end
        if self.Settings.AutoRebirth and self:CanRebirth() then
            self.TrainingTarget = nil
            return true
        end
        if stationId and tonumber(self.Player:GetAttribute("TrainingStation")) ~= tonumber(stationId) then
            self:EnterTrainingStation(stationId)
        end
        if os.clock() - started > 180 then
            self.TrainingTarget = nil
            return false
        end
        task.wait(0.12)
    end
    self.TrainingTarget = nil
    return false
end

function P:LiftStage(stageId)
    if self:IsStageCleared(stageId) then
        return true
    end
    if not self.Settings.AutoLift then
        return false
    end
    local stage = self:GetStage(stageId)
    if not stage then
        self:WaitUntil(function()
            stage = self:GetStage(stageId)
            return stage ~= nil
        end, 2.5, 0.1)
    end
    local zone = stage and stage:FindFirstChild("LiftZone")
    if not stage or not zone then
        self.LastError = "Missing stage/LiftZone for " .. tostring(stageId)
        return false
    end

    local weight = self:GetStageWeight(stageId)
    local estimated = weight / math.max(1, self:CurrentPower())
    -- Instant teleport between rock platforms; server stage entry is still verified.
    local deadline = os.clock() + math.clamp(estimated * 2.15 + 22, 30, 150)
    local retries = 0
    local failedEntries = 0

    while self.Alive and self.Settings.Enabled and self.Settings.AutoLift and os.clock() < deadline do
        if self:IsStageCleared(stageId) then
            return true
        end

        local session = self.Run.Session
        if not session or tonumber(session.StageId) ~= tonumber(stageId) then
            retries += 1
            self:SetStatus(
                string.format("Moving to Stage %d • %ss lift estimate", stageId, self:Compact(math.max(0.1, weight / math.max(1, self:CurrentPower())))),
                "MOVE"
            )

            -- If the zone did not start after a prior entry, teleport out and back in
            -- to retrigger the authoritative zone-driven lifting session.
            if retries > 1 then
                self:WalkOutOfZone(zone, 7)
                task.wait(0.08)
            end

            local reached = self:WalkIntoZone(zone)
            if not reached then
                failedEntries += 1
                self.LastError="Could not enter Stage "..tostring(stageId)
                    ..": "..tostring(self.Debug.LastRouteIssue or "route failed")
                self:DebugEvent("STAGE",self.LastError)
                -- Stop pointless repeated attempts: keep already-cleared
                -- rewards for collection/banking rather than staying stuck.
                if failedEntries>=2 then
                    self:SetStatus("Stage "..tostring(stageId)
                        .." unreachable; collecting current rewards","RECOVER")
                    break
                end
                task.wait(0.2)
            else
                failedEntries = 0
                self:SetStatus(
                    string.format("Lifting Stage %d • %ss estimated", stageId, self:Compact(math.max(0.1, weight / math.max(1, self:CurrentPower())))),
                    "LIFT"
                )
                task.wait(0.4)
            end

            if retries % 3 == 0 then
                pcall(function()
                    self.R.RockLiftingInput:FireServer("Sync")
                end)
            end
            task.wait(0.12)
        else
            self:SetStatus(
                string.format("Lifting Stage %d • %ss estimated", stageId, self:Compact(math.max(0.1, weight / math.max(1, self:CurrentPower())))),
                "LIFT"
            )
            local _, _, root = self:GetCharacter()
            if root and zone:IsA("BasePart") and not self:IsPointInsidePart(zone, root.Position, 0) then
                self:SetStatus("Moving back into Stage " .. tostring(stageId) .. " LiftZone...", "MOVE")
                self:WalkIntoZone(zone)
            end
            task.wait(0.12)
        end
    end

    if not self:IsStageCleared(stageId) then
        pcall(function()
            self.R.RockLiftingInput:FireServer("Sync")
        end)
    end
    return self:IsStageCleared(stageId)
end

function P:DiscoveryCount(variant)
    local discovered = self:Data().DiscoveredItems
    local bucket = type(discovered) == "table" and discovered[variant] or nil
    local count = 0
    if type(bucket) == "table" then
        -- Match PlayerDataInfo.GetIndexCashMultiplier exactly: every true discovery in the variant
        -- bucket counts toward its FullBoost threshold.
        for _, value in pairs(bucket) do
            if value == true then
                count = count + 1
            end
        end
    end
    return count
end

function P:VariantCountsForIndex(variant)
    local variants = self.M.Config.Variants or {}
    local info = variants[variant]
    local index = self.M.Config.Index or {}
    local fullBoost = index.FullBoost or {}
    return type(info) == "table" and info.ExcludeIndex ~= true and tonumber(fullBoost[variant]) ~= nil
end

function P:IsDiscovered(item)
    if type(item) ~= "table" then
        return false
    end
    local variant = item.Variant or "Normal"
    local discovered = self:Data().DiscoveredItems
    local bucket = type(discovered) == "table" and discovered[variant] or nil
    return type(bucket) == "table" and bucket[item.Key] == true
end

function P:RarityRank(item)
    local rarity
    local ok, result = pcall(self.M.ItemUtils.GetRarity, item)
    if ok then
        rarity = result
    end
    if type(rarity) ~= "string" then
        rarity = item and item.Rarity
    end
    -- Remote payloads may omit ItemType while retaining the treasure Key. The
    -- static treasure catalog resolves the tier (Divine beats Celestial), whereas
    -- a nil ItemType made ItemUtils.GetRarity incorrectly return nil or 0.
    if type(rarity) ~= "string" and item and item.Key then
        local config = self.M.Config.Treasures
        local info = type(config) == "table" and config.Items or nil
        local key = type(config) == "table" and type(config.KeyAliases) == "table"
            and (config.KeyAliases[item.Key] or item.Key) or item.Key
        local definition = type(info) == "table" and info[key] or nil
        if type(definition) == "table" then
            rarity = definition.Rarity
        end
    end
    -- Ground snapshots can carry ItemType=nil and a stale Rarity value.
    -- The treasure catalog keyed by item.Key is the authoritative tier for
    -- treasure rewards regardless of whether ItemType was serialized.
    if item and (item.ItemType == nil or item.ItemType == "Treasure") and item.Key then
        local treasure = self.M.Config.Treasures or {}
        local key = (treasure.KeyAliases or {})[item.Key] or item.Key
        local configured = (treasure.Items or {})[key]
        if type(configured) == "table" and type(configured.Rarity) == "string" then
            rarity = configured.Rarity
        end
    end
    -- Use the game's own Rarities[id] table. UPD added Ethereal (10),
    -- moving Exclusive to 11; the previous hard-coded list omitted Ethereal.
    local entry = type(rarity) == "string" and (self.M.Config.Rarities or {})[rarity]
    local rank = type(entry) == "table" and tonumber(entry.id)
    if not rank then
        local fallback = {
            Common = 1, Uncommon = 2, Rare = 3, Epic = 4,
            Legendary = 5, Mythic = 6, Secret = 7, Celestial = 8,
            Divine = 9, Ethereal = 10, Exclusive = 11,
        }
        rank = fallback[rarity] or 0
    end
    return rank, rarity or "Unknown"
end

function P:MinimumRarityRank()
    local selected = tostring(self.Settings.MinPickupRarity or "Any")
    if selected == "Any" then
        return 0
    end
    local definitions = self.M.Config.Rarities or {}
    local entry = definitions[selected]
    local fallback = {
        Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5,
        Mythic = 6, Secret = 7, Celestial = 8, Divine = 9, Ethereal = 10,
        Exclusive = 11,
    }
    return (type(entry) == "table" and tonumber(entry.id)) or fallback[selected] or 0
end

function P:PickupAllowed(candidate)
    if not candidate then
        return false
    end
    -- This gate is authoritative for ALL pick requests, including the tutorial.
    -- A strict Divine+ filter should never silently collect a Celestial.
    -- New players may need to switch to Any for the mandatory tutorial pickup.
    local selectedRank = self:MinimumRarityRank()
    return (tonumber(candidate.RarityRank) or 0) >= selectedRank
end

function P:CandidateData(stageId, slot, item, special)
    -- Stage snapshots can omit ItemType. Restore the known type for the
    -- game's native per-item luck and sell-value calculations.
    local actual = item
    if actual.ItemType == nil then
        actual = table.clone(item)
        actual.ItemType = "Treasure"
    end
    local rank, rarity = self:RarityRank(actual)
    local treasureConfig = self.M.Config.Treasures or {}
    local key = (treasureConfig.KeyAliases or {})[actual.Key] or actual.Key
    local definition = (treasureConfig.Items or {})[key] or {}
    local variant = actual.Variant or "Normal"
    local mutation = tonumber(((self.M.Config.Variants or {})[variant] or {}).MutationMulti) or 1
    if mutation ~= mutation or mutation <= 0 then mutation = 1 end

    local cashMultiplier = 1
    local okMulti, multiResult = pcall(self.M.PlayerDataInfo.GetCashMultiplier, self.Player)
    if okMulti then cashMultiplier = tonumber(multiResult) or 1 end
    local price = 0
    local okPrice, priceResult = pcall(self.M.ItemUtils.GetSellPrice, actual, cashMultiplier)
    if okPrice and type(priceResult) == "number" and priceResult == priceResult then
        price = math.max(0, priceResult)
    end
    if price <= 0 then
        price = math.max(0, tonumber(actual.BestValue)
            or (tonumber(definition.Price or definition.Value) or 0) * mutation) * math.max(0, cashMultiplier)
    end

    -- CollectableItem.GetAllDisplayData uses base LuckBonus * MutationMulti,
    -- with best-owned values and StarLevel included when applicable.
    local stars = math.max(0, tonumber(actual.StarLevel) or 0)
    local fuse = self.M.Config.FuseMaschine or {}
    local fusedRarity = (fuse.Rarities or {})[rarity]
    local starMulti = 1
    if stars > 0 and type(fusedRarity) == "table" then
        starMulti = 1 + ((tonumber(fusedRarity.Multiplier) or 1) - 1) * stars
    end
    local luck = (tonumber(actual.BestLuckBonus)
        or (tonumber(definition.LuckBonus) or 0) * mutation) * starMulti
    local okDisplay, display = pcall(self.M.ItemUtils.GetAllDisplayData, actual)
    if okDisplay and type(display) == "table" then
        local preciseLuck = tonumber(display.LuckBonus)
        if preciseLuck and preciseLuck == preciseLuck and preciseLuck >= 0 then
            luck = preciseLuck
        end
    end

    local threshold = tonumber(self.M.Config.Index and self.M.Config.Index.Threshold) or 60
    local indexEligible = self:VariantCountsForIndex(variant)
    local indexIncomplete = indexEligible and self:DiscoveryCount(variant) < threshold
    local newDiscovery = self.Settings.IndexPriority and indexIncomplete and not self:IsDiscovered(actual)

    return {
        StageId = stageId,
        Slot = slot,
        Item = actual,
        Special = special == true,
        Variant = variant,
        MutationMultiplier = mutation,
        Rarity = rarity,
        RarityRank = rank,
        Price = price,
        Luck = luck,
        IndexEligible = indexEligible,
        NewDiscovery = newDiscovery == true,
    }
end

function P:GetVisibleStageItems(stageId)
    local stage = self:GetStage(stageId)
    local visible = {}
    if not stage then
        return visible
    end
    -- Actual treasure models are parented directly to their stage by TreasureVisuals.Update.
    -- They carry StageId, SpawnSlot and UUID attributes applied by ItemUtils.Spawn.
    for _, model in ipairs(stage:GetChildren()) do
        if model:IsA("Model") then
            local slot = model:GetAttribute("SpawnSlot")
            local uuid = model:GetAttribute("UUID")
            if type(slot) == "string" and type(uuid) == "string"
                and tonumber(model:GetAttribute("StageId")) == tonumber(stageId) then
                local ok, item = pcall(self.M.ItemUtils.FromInstance, model)
                if ok and type(item) == "table" and item.UUID == uuid and item.Key ~= nil then
                    visible[slot] = item
                end
            end
        end
    end
    return visible
end

function P:GetRewardCandidates()
    local candidates = {}
    local staged = {}
    for stageId, reward in pairs(self.Run.Rewards) do
        if type(reward) == "table" and reward.Completed == true then
            staged[tonumber(stageId) or stageId] = true
        end
    end
    for stageId, isCleared in pairs(self.Run.Cleared) do
        if isCleared then
            staged[tonumber(stageId) or stageId] = true
        end
    end

    -- Merge client-visible, locally spawned treasure when its pickup prompt is
    -- enabled. These can be newer than a delayed RockLiftingFeedback snapshot.
    local stagesFolder = self:Map() and self:Map():FindFirstChild("Stages")
    if stagesFolder then
        for _, stage in ipairs(stagesFolder:GetChildren()) do
            local stageId = tonumber(stage:GetAttribute("StageId")) or tonumber(stage.Name:match("^Stage(%d+)$"))
            if stageId and not staged[stageId] then
                for _, model in ipairs(stage:GetChildren()) do
                    if model:IsA("Model") and type(model:GetAttribute("UUID")) == "string"
                        and type(model:GetAttribute("SpawnSlot")) == "string" then
                        local prompt = model:FindFirstChild("PickupTreasure", true)
                        if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled then
                            staged[stageId] = true
                            break
                        end
                    end
                end
            end
        end
    end

    for stageId in pairs(staged) do
        local reward = self.Run.Rewards[stageId]
        local items = reward and reward.Items or {}
        local specials = self.Run.Specials[stageId] or {}
        local visible = self:GetVisibleStageItems(stageId)
        local slots = {}
        for slot in pairs(items) do slots[slot] = true end
        for slot in pairs(visible) do slots[slot] = true end
        for slot in pairs(specials) do slots[slot] = true end

        for slot in pairs(slots) do
            local base = items[slot]
            local spawned = visible[slot]
            local event = specials[slot]
            local specialItem = type(event) == "table" and event.Item or nil
            local item = nil
            local isSpecial = false

            if type(specialItem) == "table" and type(specialItem.UUID) == "string" then
                -- Live server special spawns override the ordinary slot item.
                item = specialItem
                isSpecial = true
            elseif type(spawned) == "table" then
                -- Real ground UUID wins over a lagged ordinary snapshot.
                item = spawned
                isSpecial = spawned.SpecialSpawnId ~= nil
            elseif type(base) == "table" and base.SpecialSpawnId == nil then
                -- Client TreasureVisuals discards orphaned SpecialSpawnId slots.
                item = base
            end

            if type(item) == "table" and type(item.UUID) == "string"
                and not self.Run.PickedUUIDs[item.UUID] then
                local candidate = self:CandidateData(stageId, slot, item, isSpecial)
                if self:PickupAllowed(candidate) then
                    table.insert(candidates, candidate)
                end
            end
        end
    end

    -- Individual bonus is the top priority; rarity, mutation and price are
    -- tiebreakers only. The minimum-rarity setting remains a hard filter.
    table.sort(candidates, function(a, b)
        if a.Luck ~= b.Luck then return a.Luck > b.Luck end
        if a.RarityRank ~= b.RarityRank then return a.RarityRank > b.RarityRank end
        if a.MutationMultiplier ~= b.MutationMultiplier then
            return a.MutationMultiplier > b.MutationMultiplier
        end
        if a.Price ~= b.Price then return a.Price > b.Price end
        if a.Special ~= b.Special then return a.Special end
        if a.NewDiscovery ~= b.NewDiscovery then return a.NewDiscovery end
        if a.StageId ~= b.StageId then return a.StageId > b.StageId end
        return tostring(a.Slot) < tostring(b.Slot)
    end)
    return candidates
end

function P:CollectCandidate(candidate)
    if type(candidate) ~= "table" or type(candidate.Item) ~= "table" then
        return false
    end
    local stage = self:GetStage(candidate.StageId)
    local spawns = stage and stage:FindFirstChild("ItemSpawns")
    local spawnPart = spawns and spawns:FindFirstChild(candidate.Slot)
    if not spawnPart then
        return false
    end

    -- Abort immediately if something better appeared between selection and travel.
    local currentBest = self:GetRewardCandidates()[1]
    if currentBest and currentBest.Item.UUID ~= candidate.Item.UUID then
        return false
    end

    self:SetStatus(
        string.format("Collecting %s %s %s (+%.1f%% Luck) at Stage %d",
            candidate.Variant ~= "Normal" and tostring(candidate.Variant) or "",
            tostring(candidate.Rarity), tostring(candidate.Item.Key),
            (tonumber(candidate.Luck) or 0) * 100, candidate.StageId),
        "COLLECT"
    )
    if not self:WalkToObject(spawnPart, 4.5) then
        self.LastError = "Could not reach treasure slot " .. tostring(candidate.Slot) .. " at Stage " .. tostring(candidate.StageId)
        return false
    end

    -- Do not send a stale slot/UUID after a ground item changes during travel.
    -- World models may still be loading, so corroborate with the live candidate source.
    local refreshed = self:GetRewardCandidates()[1]
    if not refreshed or refreshed.Item.UUID ~= candidate.Item.UUID then
        return false
    end
    local visible = self:GetVisibleStageItems(candidate.StageId)[candidate.Slot]
    -- A stale special-spawn snapshot must never override a different
    -- on-ground UUID. Recheck after TreasureVisuals reconciles the slot.
    if visible and visible.UUID ~= candidate.Item.UUID then
        return false
    end

    -- HARD CHECK: even if rarity/config changed during travel or a snapshot was
    -- stale, do not send a pickup request for anything below the selected tier.
    local currentRank, currentRarity = self:RarityRank(visible or candidate.Item)
    if not self:PickupAllowed({RarityRank = currentRank}) then
        self.LastError = string.format("Skipped %s treasure (minimum %s)",
            tostring(currentRarity), tostring(self.Settings.MinPickupRarity or "Any"))
        return false
    end

    local before = self:BackpackCount()
    local ok, success = pcall(function()
        return self.R.PickupStageTreasure:InvokeServer(candidate.StageId, candidate.Slot, candidate.Item.UUID)
    end)
    if ok and success then
        self.Run.PickedUUIDs[candidate.Item.UUID] = true
        local reward = self.Run.Rewards[candidate.StageId]
        if reward and reward.Items and type(reward.Items[candidate.Slot]) == "table"
            and reward.Items[candidate.Slot].UUID == candidate.Item.UUID then
            reward.Items[candidate.Slot] = nil
        end
        self:WaitUntil(function()
            return self:BackpackCount() > before or self:BackpackCount() >= self:BackpackCapacity()
        end, 0.8, 0.03)
        return true
    end
    return false
end

function P:CollectBestRewards(limit)
    if not self.Settings.AutoCollect then
        return 0
    end
    local capacity = self:BackpackCapacity()
    local remaining = math.max(0, capacity - self:BackpackCount())
    remaining = math.min(remaining, tonumber(limit) or remaining)
    if remaining <= 0 then
        return 0
    end

    if #self:GetRewardCandidates() == 0 and self:HighestCleared() > 0 then
        pcall(function()
            self.R.RockLiftingInput:FireServer("Sync")
        end)
        task.wait(0.55)
    end

    local collected, failures = 0, 0
    while self.Alive and self.Settings.Enabled and collected < remaining
        and self:BackpackCount() < capacity do
        -- Re-query the real displayed models + current server specials after EVERY pickup.
        -- A single precomputed list becomes wrong as timed rarity spawns or items change.
        local best = self:GetRewardCandidates()[1]
        if not best then
            break
        end
        if self:CollectCandidate(best) then
            collected += 1
            failures = 0
            task.wait(0.05)
        else
            failures += 1
            if failures == 1 then
                pcall(function()
                    self.R.RockLiftingInput:FireServer("Sync")
                end)
                self:RefreshSpecialSpawns(true)
                task.wait(0.35)
            elseif failures >= 3 then
                -- Never silently collect inferior rarity while the visible/best one
                -- repeatedly fails. Leave this run intact for another synchronized pass.
                self.LastError = "Best treasure pickup needs retry: " .. tostring(best.Rarity)
                    .. " " .. tostring(best.Item.Key)
                break
            else
                task.wait(0.15)
            end
        end
    end
    return collected
end

-- For a missed bank trigger, leave SpawnZone along the middle aisle. The old
-- radial exit could run directly into a Sell/Arms shop trigger.
function P:ExitSpawnForBankRetry(zone)
    local _,h,r=self:GetCharacter()
    if not h or not r then return false end
    if not self:IsPointInsidePart(zone,r.Position,0) then return true end
    local corridor=self:GetSpawnShopCorridor()
    if corridor then
        local forward=corridor.Forward
        local half=zone.Size*0.5
        local radius=math.abs(zone.CFrame.RightVector:Dot(forward))*half.X
            +math.abs(zone.CFrame.UpVector:Dot(forward))*half.Y
            +math.abs(zone.CFrame.LookVector:Dot(forward))*half.Z
        local current=(r.Position-zone.Position):Dot(forward)
        local exits={-forward*(radius+current+11),forward*(radius-current+11)}
        for _, offset in ipairs(exits) do
            local raw=r.Position+Vector3.new(offset.X,0,offset.Z)
            local ground=self:ProjectToGround(raw,zone)
            local goal=ground and self:GetTeleportRootTarget(ground,h,r)
            if goal and not self:IsPointInsidePart(zone,goal,0)
                and not self:DestinationHitsMenuZone(goal)
                and not self:RouteCrossesMenuZone(r.Position,goal,nil,4) then
                local ok=self:WalkToPosition(ground,{
                    AcceptanceRadius=1.75,Exclude=zone,MaxAttempts=2,
                    ArrivalPredicate=function()
                        local _,_,now=self:GetCharacter()
                        return now and not self:IsPointInsidePart(zone,now.Position,0)
                    end,
                })
                if ok then return true end
            end
        end
    end
    return self:WalkOutOfZone(zone,8)
end

function P:BankRun()
    if not self.Settings.AutoBank then return false end
    local previousReset=self.Run.LastReset
    local previousBank=self.Run.LastBank
    local clearedBefore=self:HighestCleared()
    local carriedBefore=self:BackpackCount()
    local function confirmed()
        local feedback=self.Run.LastReset>previousReset
            or self.Run.LastBank>previousBank
            or (clearedBefore>0 and self:HighestCleared()==0)
        -- A StageTreasuresBanked event can arrive BEFORE RockLiftingFeedback
        -- Reset: do not begin another cycle with old cleared-stage flags.
        return feedback and self:HighestCleared()==0 and self:BackpackCount()==0
    end
    if confirmed() then return true end
    if not self:MoveToSpawn() then
        self:SetStatus("Return to spawn failed; preserving current run", "RECOVER")
        return false
    end
    if self:WaitUntil(confirmed,2.3,0.05) then return true end
    if self.Run.LastBank>previousBank and self:HighestCleared()>0 then
        pcall(function() self.R.RockLiftingInput:FireServer("Sync") end)
        if self:WaitUntil(confirmed,0.9,0.05) then return true end
    end
    local map=self:Map()
    local zone=map and map:FindFirstChild("SpawnZone")
    if not zone or not zone:IsA("BasePart") then return false end
    for attempt=1,2 do
        if not self.Alive or not self.Settings.Enabled then return false end
        if confirmed() then return true end
        self:SetStatus("Bank confirmation "..attempt.."/2: exiting and reentering spawn", "RECOVER")
        if not self:ExitSpawnForBankRetry(zone) then
            self.LastError="Cannot safely exit SpawnZone to retry banking"
            return false
        end
        task.wait(0.18)
        if not self:MoveToSpawn() then
            self.LastError="Unable to reenter SpawnZone for bank retry"
            return false
        end
        if self:WaitUntil(confirmed,1.8,0.05) then return true end
    end
    self.LastError=string.format(
        "Bank not confirmed (cleared %d, backpack %d); preserving run",
        clearedBefore,carriedBefore)
    self:SetStatus("Bank not confirmed; preserving rewards for retry", "RECOVER")
    pcall(function() self.R.RockLiftingInput:FireServer("Sync") end)
    return false
end

function P:SellableInventory()
    local result = {}
    local seen = {}
    local inventory = self:Data().Inventory
    if type(inventory) ~= "table" then
        return result
    end
    for _, item in pairs(inventory) do
        if type(item) == "table" then
            local uuid = type(item.UUID) == "string" and item.UUID or tostring(item)
            local ok, sellable = pcall(self.M.ItemUtils.IsSellable, item)
            if ok and sellable == true and not seen[uuid] then
                seen[uuid] = true
                table.insert(result, item)
            end
        end
    end
    return result
end

-- Ground-level shop approaches use the center spawn aisle, not roof ascent.
-- A failed shop visit is temporarily backed off so selling cannot freeze
-- all rebirth/stage progression in a loop.
function P:GoToShopZone(shopName)
    local now=os.clock()
    if now<(self.ShopRetryAfter[shopName] or 0) then return false end
    local map=self:Map()
    local shops=map and map:FindFirstChild("Shops")
    local shop=shops and shops:FindFirstChild(shopName)
    local zone=shop and shop:FindFirstChild("Zone",true)
    if not zone or not zone:IsA("BasePart") then
        self.LastError="Missing shop zone "..tostring(shopName)
        self.ShopRetryAfter[shopName]=now+5
        return false
    end
    self:SetStatus("Teleporting to "..shopName.." shop...","MOVE")
    local reached=self:WalkIntoZone(zone,true)
    if reached then
        self.ShopRetryAfter[shopName]=nil
        self:DebugEvent("SHOP",shopName.." trigger reached via safe TP")
        self:DismissBlockingShopMenus()
        return true
    end
    self.LastError="Cannot TP to "..shopName..": "..tostring(self.Debug.LastRouteIssue)
    self.ShopRetryAfter[shopName]=os.clock()+5
    self:DebugEvent("FAIL",self.LastError)
    return false
end

function P:PlaceBestLuck()
    if not self.Settings.AutoPlot then
        return
    end
    local plotPart = self:GetPlotUpgradeInfo()
    if plotPart then
        self:SetStatus("Moving to plot for Best Luck placement...", "MOVE")
        self:WalkToObject(plotPart, 6)
    end
    pcall(function()
        self.R.PlaceBestLuck:FireServer()
    end)
    task.wait(0.25)
end

function P:SellInventory()
    if not self.Settings.AutoSell then
        return false
    end
    local items = self:SellableInventory()
    if #items == 0 then
        return false
    end
    if not self:GoToShopZone("Sell") then
        self:DebugEvent("SELL", "Sell deferred; "..tostring(#items)..
            " banked items retained for next attempt")
        return false
    end
    self:SetStatus("Selling " .. tostring(#items) .. " banked treasures...", "SELL")
    local oldCount = 0
    local oldInventory = self:Data().Inventory
    if type(oldInventory) == "table" then
        for _ in pairs(oldInventory) do oldCount += 1 end
    end
    pcall(function()
        self.R.SellItems:FireServer(items)
    end)
    self:WaitUntil(function()
        local inventory = self:Data().Inventory
        if type(inventory) ~= "table" then return true end
        local count = 0
        for _ in pairs(inventory) do count += 1 end
        return count < oldCount
    end, 1.8, 0.05)
    return true
end

function P:BestOwnedArmId()
    local data = self:Data()
    local purchased = data.PurchasedArms
    if type(purchased) ~= "table" then
        return nil, 1
    end
    local bestId = nil
    local bestMultiplier = 1
    for idString, owned in pairs(purchased) do
        if owned == true then
            local id = tonumber(idString)
            if id then
                local ok, multiplier = pcall(self.M.ArmsUtils.GetMultiplier, data, id)
                multiplier = ok and tonumber(multiplier) or 1
                if multiplier > bestMultiplier then
                    bestMultiplier = multiplier
                    bestId = id
                end
            end
        end
    end
    return bestId, bestMultiplier
end

function P:GetNextArmInfo()
    local data = self:Data()
    local ok, nextId = pcall(self.M.ArmsUtils.GetNextUnlockId, data)
    if not ok or not nextId then
        return nil
    end
    local config = self.M.Config.Arms[nextId]
    local cost = config and tonumber(config.UnlockCost)
    return nextId, config, cost
end

function P:GetNextUpgradeInfo(name)
    local ok, nextUpgrade = pcall(self.M.UpgradeUtils.GetNext, self:Data(), name)
    if not ok or type(nextUpgrade) ~= "table" then
        return nil
    end
    return nextUpgrade, tonumber(nextUpgrade.Cost)
end

function P:GetNextLockedTrainingStation()
    local rebirths = self:CurrentRebirths()
    local best = nil
    for stationId, config in ipairs(self.M.Config.Training or {}) do
        if not config.Gamepass then
            local required = tonumber(config.RequiredRebirths) or 0
            if required > rebirths and (not best or required < best.RequiredRebirths) then
                best = {
                    StationId = stationId,
                    RequiredRebirths = required,
                    Multiplier = tonumber(config.Multiplier) or 1,
                }
            end
        end
    end
    return best
end

function P:RequiredBackpackCapacity()
    local floor = math.clamp(
        math.floor(tonumber(self.Settings.RequiredBackpackFloor) or 5),
        3,
        12
    )
    local target = math.max(
        1,
        tonumber(self.TargetStage) or 1,
        tonumber(self.Route.GameROIStage) or 0,
        self:HighestCleared() + 1
    )
    return math.max(3, math.min(floor, target))
end

function P:RefreshRequirementPlan()
    local data = self:Data()
    local cash = tonumber(data.Cash) or 0
    local power = self:CurrentPower()
    local plan = {
        Kind = "None",
        Name = "No progression blocker",
        Detail = "Farming the best available stage",
        Cost = 0,
        MissingCash = 0,
        TargetPower = 0,
        DesiredBackpack = self:RequiredBackpackCapacity(),
    }

    if data.TutorialCompleted ~= true then
        plan.Kind = "Tutorial"
        plan.Name = "Complete tutorial"
        plan.Detail = "Following tutorial progression"
        self.Requirements = plan
        return plan
    end

    local desiredBag = plan.DesiredBackpack
    local currentBag = self:BackpackCapacity()
    if self.Settings.AutoRequirements and currentBag < desiredBag then
        local nextUpgrade, cost = self:GetNextUpgradeInfo("Backpack")
        if nextUpgrade and cost then
            plan.Kind = cash >= cost and "Purchase" or "Cash"
            plan.Name = "Required Backpack"
            plan.Detail = string.format("Capacity %d -> need at least %d", currentBag, desiredBag)
            plan.Cost = cost
            plan.MissingCash = math.max(0, cost - cash)
            self.Requirements = plan
            return plan
        end
    end

    local nextArmId, armConfig, armCost = self:GetNextArmInfo()
    if nextArmId and armCost and cash >= armCost then
        plan.Kind = "Purchase"
        plan.Name = tostring(armConfig and armConfig.DisplayName or ("Arm " .. tostring(nextArmId)))
        plan.Detail = "Next arm multiplier is affordable"
        plan.Cost = armCost
        self.Requirements = plan
        return plan
    end

    if self.Settings.AutoRebirth and self:CanRebirth() then
        plan.Kind = "Rebirth"
        plan.Name = "Next Rebirth"
        plan.Detail = "Power requirement met; bank/reset first if needed"
        self.Requirements = plan
        return plan
    end

    local nextStation = self:GetNextLockedTrainingStation()
    local rebirthPower = self:NextRebirthPower()
    if self.Settings.AutoRequirements
        and self.Settings.AutoRebirth
        and nextStation
        and rebirthPower
        and nextStation.RequiredRebirths == self:CurrentRebirths() + 1
        and rebirthPower > power then

        local gapRatio = rebirthPower / math.max(1, power)
        if gapRatio <= math.max(2.5, tonumber(self.Settings.RebirthTrainAheadRatio) or 1.18) then
            plan.Kind = "Power"
            plan.Name = "Unlock Training Station " .. tostring(nextStation.StationId)
            plan.Detail = string.format(
                "Train to %s power for Rebirth %d / station x%s",
                self:Compact(rebirthPower),
                nextStation.RequiredRebirths,
                tostring(nextStation.Multiplier)
            )
            plan.TargetPower = math.ceil(rebirthPower)
            self.Requirements = plan
            return plan
        end
    end

    if nextArmId and armCost then
        plan.Kind = "Cash"
        plan.Name = tostring(armConfig and armConfig.DisplayName or ("Arm " .. tostring(nextArmId)))
        plan.Detail = "Farm cash for the next arm multiplier"
        plan.Cost = armCost
        plan.MissingCash = math.max(0, armCost - cash)
        self.Requirements = plan
        return plan
    end

    local plotObject, currentPlot, maxPlot, plotPrice, requiredRebirths = self:GetPlotUpgradeInfo()
    if self.Settings.AutoPlot and currentPlot and currentPlot < maxPlot then
        if self:CurrentRebirths() >= requiredRebirths then
            plan.Kind = cash >= plotPrice and "OptionalPurchase" or "OptionalCash"
            plan.Name = "Plot Luck Expansion"
            plan.Detail = "Arms are maxed; improve permanent luck slots"
            plan.Cost = plotPrice
            plan.MissingCash = math.max(0, plotPrice - cash)
        else
            plan.Kind = "RebirthGate"
            plan.Name = "Plot Expansion"
            plan.Detail = "Needs Rebirth " .. tostring(requiredRebirths)
        end
    end

    self.Requirements = plan
    return plan
end

function P:ShouldReserveForNearArm(spendCost)
    if not self.Settings.ReserveCashForNearArm then
        return false
    end

    local _, _, armCost = self:GetNextArmInfo()
    if not armCost then
        return false
    end

    local cash = tonumber(self:Data().Cash) or 0
    if cash <= 0 or armCost <= cash then
        return false
    end

    local ratio = armCost / math.max(1, cash)
    if ratio > (tonumber(self.Settings.NearArmReserveRatio) or 1.45) then
        return false
    end

    return (cash - math.max(0, tonumber(spendCost) or 0)) < cash * 0.70
end

function P:ManageArms(forceTutorial)
    if not self.Settings.AutoArms then
        return
    end
    local data = self:Data()
    local firstNextId = self.M.ArmsUtils.GetNextUnlockId(data)
    local firstConfig = firstNextId and self.M.Config.Arms[firstNextId]
    local firstCost = firstConfig and tonumber(firstConfig.UnlockCost)
    local canBuy = firstCost and (tonumber(data.Cash) or 0) >= firstCost
    if forceTutorial or canBuy then
        if not self:GoToShopZone("Arms") then
            return
        end
    end

    -- ArmsUtils enforces sequential F2P unlocks. Never purchases Robux products.
    for _ = 1, 13 do
        data = self:Data()
        local nextId = self.M.ArmsUtils.GetNextUnlockId(data)
        if not nextId then
            break
        end
        local config = self.M.Config.Arms[nextId]
        local cost = config and tonumber(config.UnlockCost)
        local cash = tonumber(data.Cash) or 0
        if not cost or cash < cost then
            break
        end
        self:SetStatus("Unlocking " .. tostring(config.DisplayName or ("Arm " .. nextId)) .. "...", "UPGRADE")
        pcall(function()
            self.R.ArmsAction:FireServer("Unlock", nextId)
        end)
        self:WaitUntil(function()
            local purchased = self:Data().PurchasedArms
            return type(purchased) == "table"
                and (purchased[tostring(nextId)] == true or purchased[nextId] == true)
        end, 1.25, 0.05)
        task.wait(0.08)
    end

    local bestId = self:BestOwnedArmId()
    if bestId and tonumber(self:Data().EquippedArmId) ~= tonumber(bestId) then
        pcall(function()
            self.R.ArmsAction:FireServer("Equip", bestId)
        end)
        task.wait(0.15)
    end
end

function P:TryPurchaseUpgrade(name, budgetFraction, forceRequired)
    local data = self:Data()
    local nextUpgrade = self.M.UpgradeUtils.GetNext(data, name)
    if not nextUpgrade then
        return false
    end

    local cost = tonumber(nextUpgrade.Cost)
    local cash = tonumber(data.Cash) or 0
    if not cost or cash < cost then
        return false
    end

    local required = forceRequired == true
    local fraction = math.max(0, tonumber(budgetFraction) or 0)
    if not required then
        if cost > 0 and fraction > 0 and cost > cash * fraction then
            return false
        end
        if self:ShouldReserveForNearArm(cost) then
            return false
        end
    end

    if not self:GoToShopZone("Upgrades") then
        return false
    end

    local beforeValue
    pcall(function()
        beforeValue = tonumber(self.M.UpgradeUtils.GetValue(self:Data(), name))
    end)

    self:SetStatus(
        string.format("%s %s upgrade for $%s...", required and "Buying REQUIRED" or "Buying", tostring(name), self:Compact(cost)),
        "UPGRADE"
    )

    local ok, success = pcall(function()
        return self.R.PurchaseUpgrade:InvokeServer(name)
    end)
    if not ok or success == false then
        return false
    end

    self:WaitUntil(function()
        local current
        pcall(function()
            current = tonumber(self.M.UpgradeUtils.GetValue(self:Data(), name))
        end)
        if beforeValue and current then
            return current > beforeValue
        end
        local nextAfter = self.M.UpgradeUtils.GetNext(self:Data(), name)
        return nextAfter ~= nextUpgrade
    end, 1.6, 0.05)

    task.wait(0.08)
    return true
end

function P:GetPlotUpgradeInfo()
    local userId = self.Player.UserId

    if self.M.PlotController and type(self.M.PlotController.GetMyPlotModel) == "function" then
        local ok, plot = pcall(self.M.PlotController.GetMyPlotModel)
        if ok and plot then
            local baseUpgrade = plot:FindFirstChild("BaseUpgrade")
            local object = baseUpgrade and baseUpgrade:FindFirstChild("GUIPart")
            if object and object:IsA("BasePart") then
                local current = tonumber(object:GetAttribute("CurrentLevel"))
                local maxLevel = tonumber(object:GetAttribute("MaxLevel")) or tonumber(self.M.Config.Plot.MaxLevel) or 20
                local price = tonumber(object:GetAttribute("Price"))
                local requiredRebirths = tonumber(object:GetAttribute("RequiredRebirths"))
                if current and price and requiredRebirths then
                    return object, current, maxLevel, price, requiredRebirths
                end
            end
        end
    end

    -- Fallback for executor environments where requiring a client controller is restricted.
    for _, object in ipairs(workspace:GetDescendants()) do
        if object.Name == "GUIPart" and object:IsA("BasePart") and tonumber(object:GetAttribute("OwnerId")) == userId then
            local current = tonumber(object:GetAttribute("CurrentLevel"))
            local maxLevel = tonumber(object:GetAttribute("MaxLevel")) or tonumber(self.M.Config.Plot.MaxLevel) or 20
            local price = tonumber(object:GetAttribute("Price"))
            local requiredRebirths = tonumber(object:GetAttribute("RequiredRebirths"))
            if current and price and requiredRebirths then
                return object, current, maxLevel, price, requiredRebirths
            end
        end
    end
    return nil
end

function P:TryUpgradePlot(forceRequired)
    if not self.Settings.AutoPlot then
        return false
    end
    local object, current, maxLevel, price, requiredRebirths = self:GetPlotUpgradeInfo()
    if not current or current >= maxLevel then
        return false
    end
    local cash = tonumber(self:Data().Cash) or 0
    local rebirths = self:CurrentRebirths()
    if rebirths < requiredRebirths or cash < price then
        return false
    end
    if forceRequired ~= true then
        if price > 0 and price > cash * self.Settings.PlotBudgetFraction then
            return false
        end
        if self:ShouldReserveForNearArm(price) then
            return false
        end
    end
    if object then
        self:SetStatus("Moving to plot upgrade...", "MOVE")
        if not self:WalkToObject(object, 6) then
            return false
        end
    end
    pcall(function()
        self.R.UpgradePlot:FireServer()
    end)
    task.wait(0.25)
    return true
end

function P:ManageEconomyUpgrades()
    if not self.Settings.AutoUpgrades then
        self:RefreshRequirementPlan()
        return
    end

    -- 1) Arms are the strongest cash/strength progression multiplier and are always
    --    purchased sequentially as soon as the server says they are affordable.
    self:ManageArms(false)

    -- 2) If backpack capacity itself is the current bottleneck, bypass the optional
    --    percentage budget and buy enough tiers to reach the required floor.
    local desiredBag = self:RequiredBackpackCapacity()
    if self.Settings.AutoRequirements then
        for _ = 1, 8 do
            if self:BackpackCapacity() >= desiredBag then
                break
            end
            local _, cost = self:GetNextUpgradeInfo("Backpack")
            if not cost or (tonumber(self:Data().Cash) or 0) < cost then
                break
            end
            if not self:TryPurchaseUpgrade("Backpack", self.Settings.BackpackBudgetFraction, true) then
                break
            end
        end
    end

    -- Re-check arms after any reward/upgrade state change.
    self:ManageArms(false)

    -- 3) Beyond the required backpack floor, one extra capacity tier can still be
    --    bought opportunistically when the current run target exceeds capacity.
    if self.TargetStage > self:BackpackCapacity() then
        self:TryPurchaseUpgrade("Backpack", self.Settings.BackpackBudgetFraction, false)
    end

    -- 4) Plot expansion is optional while arm progression remains, but once arms are
    --    maxed it becomes the next permanent-luck progression sink and may bypass budget.
    local nextArmId = self:GetNextArmInfo()
    self:TryUpgradePlot(nextArmId == nil)

    -- Tween travel makes MoveSpeed non-essential. It is available only when the
    -- user explicitly enables optional movement upgrades.
    if self.Settings.BuyOptionalMoveSpeed then
        self:TryPurchaseUpgrade("MoveSpeed", self.Settings.MoveSpeedBudgetFraction, false)
    end

    self:RefreshRequirementPlan()
end

function P:PerformRebirthIfReady()
    if not self.Settings.AutoRebirth or not self:CanRebirth() then
        return false
    end
    if self:BackpackCount() > 0 or self:HighestCleared() > 0 then
        return false
    end
    local before = self:CurrentRebirths()
    self:SetStatus("Rebirthing for stronger cash + strength multipliers...", "REBIRTH")
    pcall(function()
        self.R.PerformRebirth:FireServer()
    end)
    local changed = self:WaitUntil(function()
        return self:CurrentRebirths() > before
    end, 2.5, 0.05)
    return changed == true
end

function P:ClaimFreeRewards()
    if os.clock() - self.LastFreeClaim < 20 then
        return
    end
    self.LastFreeClaim = os.clock()

    if self.Settings.AutoOfflineReward then
        local cash = tonumber(self.Player:GetAttribute("OfflineRewardCash")) or 0
        local power = tonumber(self.Player:GetAttribute("OfflineRewardPower")) or 0
        local seconds = tonumber(self.Player:GetAttribute("OfflineRewardSeconds")) or 0
        if seconds > 0 and (cash > 0 or power > 0) then
            pcall(function()
                self.R.CollectOfflineRewards:FireServer()
            end)
            task.wait(0.25)
        end
    end

    if self.Settings.AutoGroupReward and self:Data().ClaimedGroupReward ~= true then
        pcall(function()
            self.R.ClaimGroupReward:FireServer()
        end)
    end
end

function P:EconomyPass()
    self:SetStatus("Optimizing required progression, inventory, arms and upgrades...", "ECONOMY")
    self:RefreshRequirementPlan()
    self:ClaimFreeRewards()

    -- Fill existing luck stands before selling anything.
    self:PlaceBestLuck()
    self:SellInventory()

    -- New cash may unlock an arm/plot/backpack tier.
    self:ManageEconomyUpgrades()

    -- A newly expanded plot can accept another best-luck placement on the next pass immediately.
    self:PlaceBestLuck()

    if self:PerformRebirthIfReady() then
        self:ManageArms(false)
    end
    self:RefreshRequirementPlan()
    self.LastEconomyAt = os.clock()
end

function P:TutorialPass()
    local data = self:Data()
    if data.TutorialCompleted == true then
        return true
    end
    local step = tonumber(data.TutorialStep) or 1
    self:SetStatus("Completing tutorial step " .. tostring(step) .. "/5...", "TUTORIAL")

    if step == 1 then
        -- The global tap loop handles the five required training taps.
        self:WaitUntil(function()
            local d = self:Data()
            return d.TutorialCompleted == true or tonumber(d.TutorialStep) ~= 1
        end, 8, 0.08)
        return false
    end

    if step == 2 then
        self:LiftStage(1)
        return false
    end

    if step == 3 then
        local stageId = tonumber(data.TutorialLiftStageId) or math.max(1, self:HighestCleared())
        if #self:GetRewardCandidates() == 0 and self:MinimumRarityRank() > 0 then
            self:SetStatus("Tutorial: set Minimum Rarity to Any to collect the required first treasure", "FILTER")
            task.wait(0.4)
            return false
        end
        self:CollectBestRewards(1)
        if self:Data().TutorialReturnPending == true or self:BackpackCount() > 0 then
            self:BankRun()
        end
        return false
    end

    if step == 4 then
        self:SellInventory()
        self:WaitUntil(function()
            local d = self:Data()
            return d.TutorialCompleted == true or tonumber(d.TutorialStep) ~= 4
        end, 3, 0.08)
        return false
    end

    if step == 5 then
        self:ManageArms(true)
        self:WaitUntil(function()
            local d = self:Data()
            return d.TutorialCompleted == true or tonumber(d.TutorialStep) ~= 5
        end, 4, 0.08)
        return false
    end

    task.wait(0.3)
    return false
end

function P:RunProgressionCycle()
    -- A fresh injection can race the server snapshot. Synchronize before deciding that a partial
    -- backpack has no live run behind it, otherwise entering SpawnZone could erase recoverable rewards.
    self:EnsureRunSynced()

    local backpackCount = self:BackpackCount()
    local capacity = self:BackpackCapacity()
    local clearedNow = self:HighestCleared()

    if backpackCount > 0 then
        if not self.Settings.AutoBank then
            self:SetStatus("Unbanked treasure is waiting because Auto Bank is disabled", "PAUSED")
            task.wait(0.4)
            return
        end

        if backpackCount >= capacity or clearedNow == 0 then
            if not self:BankRun() then
                self:SetStatus("Could not bank yet; retaining unbanked treasure and retrying...", "RECOVER")
                task.wait(0.4)
                return
            end
            backpackCount = 0
            clearedNow = self:HighestCleared()
        else
            -- Resume the existing run. The remaining capacity can be filled from uncollected rewards
            -- or higher stages instead of throwing away the cleared-state work after a reload/lag spike.
            self:SetStatus(
                string.format("Resuming live run with %d/%d treasure already collected", backpackCount, capacity),
                "RECOVER"
            )
        end
    end

    if clearedNow == 0 and self:BackpackCount() == 0 then
        self:EconomyPass()
    end

    if self.Settings.AutoRebirth and self:CanRebirth() then
        self:PerformRebirthIfReady()
        return
    end

    local trainingTarget, trainingReason = self:ChooseTrainingTarget()
    if trainingTarget and trainingTarget > self:CurrentPower() then
        self:TrainToPower(trainingTarget, trainingReason)
        if self.Settings.AutoRebirth and self:CanRebirth() then
            self:PerformRebirthIfReady()
            return
        end
    end

    local target = self:ChooseTargetStage()
    if target <= 0 then
        local needed = math.ceil(self:GetStageWeight(1) / math.max(0.1, self.Settings.MaxLiftSeconds))
        self:TrainToPower(needed, "first efficient rock")
        return
    end
    self.TargetStage = target

    local stageId = 1
    while self.Alive and self.Settings.Enabled and stageId <= self:GetMaxStage() do
        if self:IsStageCleared(stageId) then
            stageId = stageId + 1
        else
            -- Re-evaluate after every stage because constant training during lifting can make another stage efficient.
            target = math.max(target, self:ChooseTargetStage())
            self.TargetStage = target
            if stageId > target then
                break
            end
            local lifted = self:LiftStage(stageId)
            if not lifted then
                break
            end
            stageId = stageId + 1
        end
    end

    local cleared = self:HighestCleared()
    if cleared > 0 then
        self:RefreshSpecialSpawns(true)
        if not self.Settings.AutoCollect then
            self:SetStatus("Stage rewards are waiting because Auto Collect is disabled", "PAUSED")
            task.wait(0.4)
            return
        end

        self:SetStatus("Selecting the best treasure from cleared stages...", "COLLECT")
        local collected = self:CollectBestRewards(self:BackpackCapacity())

        if collected == 0 and self:BackpackCount() == 0
            and #self:GetRewardCandidates() == 0 and self:MinimumRarityRank() > 0 then
            local minimum = tostring(self.Settings.MinPickupRarity)
            if self.Settings.AutoBank then
                self:SetStatus("No " .. minimum .. "+ treasure: skipping lower tiers and rerolling", "FILTER")
            else
                self:SetStatus("No " .. minimum .. "+ treasure: waiting (enable Auto Bank to reroll)", "FILTER")
            end
        end

        if self.Settings.AutoBank then
            -- Only bank early if no better treasure remains or the backpack is full;
            -- otherwise a transient pickup failure would irreversibly discard the rarest item.
            if self:BackpackCount() < self:BackpackCapacity() and #self:GetRewardCandidates() > 0 then
                self:SetStatus("Retrying the best remaining treasure before banking...", "RECOVER")
                task.wait(0.50)
                return
            end
            if self:BackpackCount() > 0 then
                if not self:BankRun() then
                    self:SetStatus("Bank retry needed; retaining the current run", "RECOVER")
                    task.wait(0.4)
                    return
                end
            elseif #self:GetRewardCandidates() > 0 then
                -- Do not enter SpawnZone and erase a run when pickup failed transiently.
                self:SetStatus("Pickup did not confirm; retaining rewards and retrying instead of resetting", "RECOVER")
                pcall(function()
                    self.R.RockLiftingInput:FireServer("Sync")
                end)
                task.wait(0.65)
                return
            else
                -- Even filtered-out or empty rewards need an authoritative
                -- reset. Never enter the next run on stale cleared flags.
                if not self:BankRun() then
                    self:SetStatus("Waiting for spawn reset before next rock run...", "RECOVER")
                    task.wait(0.3)
                    return
                end
            end
        else
            self:SetStatus("Collected " .. tostring(collected) .. " treasure; Auto Bank is disabled", "PAUSED")
            task.wait(0.4)
            return
        end

        if self:HighestCleared() == 0 and self:BackpackCount() == 0 then
            self:EconomyPass()
        end
    else
        task.wait(0.25)
    end
end

function P:Compact(value)
    value = tonumber(value) or 0
    local abs = math.abs(value)
    local units = {
        {1e18, "Qi"},
        {1e15, "Qa"},
        {1e12, "T"},
        {1e9, "B"},
        {1e6, "M"},
        {1e3, "K"},
    }
    for _, unit in ipairs(units) do
        if abs >= unit[1] then
            local scaled = value / unit[1]
            if math.abs(scaled) >= 100 then
                return string.format("%.0f%s", scaled, unit[2])
            elseif math.abs(scaled) >= 10 then
                return string.format("%.1f%s", scaled, unit[2])
            end
            return string.format("%.2f%s", scaled, unit[2])
        end
    end
    if value == math.floor(value) then
        return tostring(math.floor(value))
    end
    return string.format("%.2f", value)
end

function P:InstallTapLoop()
    self:Spawn(function()
        while self.Alive do
            if self.Settings.Enabled and self.Settings.AutoTrain then
                local rate = math.clamp(tonumber(self.Settings.TapRate) or 27, 1, 29)
                if self.Run.Session then
                    -- Stock RockLiftingController adds about 2/s; reserve headroom under the 30/s token bucket.
                    rate = math.min(rate, 27)
                end
                pcall(function()
                    self.R.TrainingTap:FireServer(Vector2.new(0.5, 0.5))
                end)
                task.wait(1 / rate)
            else
                task.wait(0.15)
            end
        end
    end)
end

function P:InstallAntiAFK()
    self:Connect(self.Player.Idled, function()
        if not self.Alive or not self.Settings.AntiAFK then
            return
        end
        pcall(function()
            self.S.VirtualUser:CaptureController()
            self.S.VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
            task.wait(0.05)
            self.S.VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        end)
    end)
end

function P:CreateUI()
    local PuckUIUrl = "https://raw.githubusercontent.com/PuckAFK/Puck-Loader/refs/heads/main/ui/PuckUI.lua"
    local okSource, source = pcall(function()
        return game:HttpGet(PuckUIUrl)
    end)
    if not okSource or type(source) ~= "string" or source == "" then
        error("[PuckAFK Lift Rock] Could not download PuckUI: " .. tostring(source))
    end

    local loader, compileError = loadstring(source)
    if not loader then
        error("[PuckAFK Lift Rock] Could not compile PuckUI: " .. tostring(compileError))
    end
    local okUI, PuckUI = pcall(loader)
    if not okUI or type(PuckUI) ~= "table" then
        error("[PuckAFK Lift Rock] Could not initialize PuckUI: " .. tostring(PuckUI))
    end

    local window = PuckUI:CreateWindow({
        Name = "PuckAFK | Lift Rock for Treasure",
        GuiName = "PuckAFK_LiftRock",
        Width = 560,
        Height = 500,
        ConfigId = "LiftRockForTreasure",
        Configs = {
            AutoSave = true,
            AutoLoad = true,
            DefaultProfile = "default",
        },
    })
    window.CloseCallback = function()
        self:Shutdown()
    end

    self.UI.Library = PuckUI
    self.UI.Window = window

    local function bindToggle(tab, name, key, extra)
        return tab:CreateToggle({
            Name = name,
            CurrentValue = self.Settings[key] == true,
            Flag = "LiftRock." .. key,
            Callback = function(value)
                self.Settings[key] = value == true
                if key == "Enabled" and not self.Settings.Enabled then
                    self:StopWalking()
                end
                if type(extra) == "function" then
                    extra(value == true)
                end
            end,
        })
    end

    local function bindSlider(tab, name, key, range, increment, suffix)
        return tab:CreateSlider({
            Name = name,
            Range = range,
            Increment = increment,
            CurrentValue = self.Settings[key],
            Suffix = suffix or "",
            Flag = "LiftRock." .. key,
            Callback = function(value)
                self.Settings[key] = value
            end,
        })
    end

    local function stopWhenDisabled(enabled)
        if not enabled then
            self:StopWalking()
        end
    end

    local function friendlyStatus(text)
        text = tostring(text or "Ready")
        local replacements = {
            {"Synchronizing current rock run%.%.%.", "Preparing..."},
            {"Optimizing required progression, inventory, arms and upgrades%.%.%.", "Checking upgrades..."},
            {"Moving to ", "Moving to "},
            {"teleporting to ", "moving to "},
            {"Bank did not trigger; moving out and back into SpawnZone%.%.%.", "Retrying bank..."},
            {"Bank did not trigger; moving out and back into SpawnZone%.%.%.", "Retrying bank..."},
            {"Could not bank yet; retaining unbanked treasure and retrying%.%.%.", "Retrying bank..."},
            {"Pickup did not confirm; retaining rewards and retrying instead of resetting", "Retrying treasure pickup..."},
            {"Main loop crashed %- see console", "Recovering..."},
            {"Installing remote observers%.%.%.", "Starting..."},
            {"Starting training loop%.%.%.", "Starting..."},
            {"Installing anti%-AFK%.%.%.", "Starting..."},
            {"Synchronizing special spawns%.%.%.", "Starting..."},
            {"Loading PuckUI%.%.%.", "Starting..."},
            {"Starting progression brain%.%.%.", "Starting..."},
        }
        for _, pair in ipairs(replacements) do
            text = text:gsub(pair[1], pair[2])
        end
        return text
    end

    local function friendlyGoal(plan)
        plan = plan or {}
        local name = tostring(plan.Name or "Keep farming")
        local detail = tostring(plan.Detail or "")

        if name == "No progression blocker" then
            return "Keep farming", "Working on the best available treasure route."
        elseif name == "Complete tutorial" then
            return "Finish tutorial", "Completing the starter steps automatically."
        elseif name == "Required Backpack" then
            return "Upgrade backpack", "More space is needed before progressing efficiently."
        elseif name == "Next Rebirth" then
            return "Rebirth", "Ready to rebirth for stronger permanent multipliers."
        elseif name:match("^Unlock Training Station") then
            return "Unlock better training", "Building enough strength for the next rebirth and training area."
        elseif name == "Plot Luck Expansion" then
            return "Upgrade plot luck", "Improving permanent treasure luck."
        elseif name == "Plot Expansion" then
            return "Unlock plot upgrade", detail ~= "" and detail or "A higher rebirth is needed first."
        elseif plan.Kind == "Cash" or plan.Kind == "Purchase" then
            return "Next upgrade: " .. name, plan.MissingCash and plan.MissingCash > 0
                and ("Saving $" .. self:Compact(plan.MissingCash) .. " more")
                or "Buying it when ready."
        elseif plan.Kind == "Power" then
            return "Build more strength", detail ~= "" and detail or "Training for the next progression step."
        end

        return name, detail ~= "" and detail or "Continuing automatic progression."
    end

    local home = window:CreateTab("Home")
    home:CreateSection("Overview")
    local statusCard = home:CreateParagraph({
        Title = "Status",
        Content = "Starting...",
        Height = 58,
    })
    local progressCard = home:CreateParagraph({
        Title = "Progress",
        Content = "Loading your progress...",
        Height = 94,
    })
    local goalCard = home:CreateParagraph({
        Title = "Next Goal",
        Content = "Choosing the best next step...",
        Height = 62,
    })

    home:CreateSection("Main Control")
    bindToggle(home, "Smart Autofarm", "Enabled")

    local farm = window:CreateTab("Farming")
    farm:CreateSection("Automatic Farming")
    bindToggle(farm, "Auto Train", "AutoTrain", stopWhenDisabled)
    bindToggle(farm, "Auto Lift Rocks", "AutoLift", stopWhenDisabled)
    bindToggle(farm, "Auto Collect Treasure", "AutoCollect", stopWhenDisabled)
    bindToggle(farm, "Auto Bank Treasure", "AutoBank", stopWhenDisabled)
    bindToggle(farm, "Auto Special Treasure", "AutoSpecialSpawns")

    farm:CreateSection("Smart Choices")
    bindToggle(farm, "Smart Stage Selection", "AdaptiveROI")
    bindToggle(farm, "Push New Rock Stages", "PushNewStages")
    bindToggle(farm, "Prioritize New Treasures", "IndexPriority")
    farm:CreateSection("Treasure Rarity Filter")
    farm:CreateDropdown({
        Name = "Minimum Rarity to Collect",
        Options = {
            "Any", "Common", "Uncommon", "Rare", "Epic", "Legendary",
            "Mythic", "Secret", "Celestial", "Divine", "Ethereal", "Exclusive",
        },
        CurrentOption = tostring(self.Settings.MinPickupRarity or "Any"),
        Flag = "LiftRock.MinPickupRarity",
        Callback = function(value)
            -- PuckUI sends {selectedOption}, including when loading a saved profile.
            -- v1.7.1-1.7.3 ignored this table, leaving the setting stuck at Any.
            if type(value) == "table" then
                value = value[1]
            end
            local available = {
                Any = true, Common = true, Uncommon = true, Rare = true,
                Epic = true, Legendary = true, Mythic = true, Secret = true,
                Celestial = true, Divine = true, Ethereal = true, Exclusive = true,
            }
            if type(value) == "string" and available[value] then
                self.Settings.MinPickupRarity = value
                self:SetStatus("Minimum treasure rarity: " .. value, "FILTER")
            end
        end,
    })
    farm:CreateParagraph({
        Title = "Rarity Filter",
        Content = "Only collect the chosen rarity OR higher. Divine skips Celestial. "
            .. "If none appear, Auto Bank resets the run to try again. "
            .. "Set Any for the mandatory tutorial pickup.",
        Height = 68,
    })
    farm:CreateParagraph({
        Title = "Instant Safe TP",
        Content = "Direct teleports to zones and stages (no tween or speed slider). "
            .. "Collision checks, velocity resets and physics restoration prevent most flinging.",
        Height = 64,
    })

    bindSlider(farm, "Training Speed", "TapRate", {5, 29}, 1, "/s")

    local upgrades = window:CreateTab("Upgrades")
    upgrades:CreateSection("Progression")
    bindToggle(upgrades, "Auto Sell", "AutoSell", stopWhenDisabled)
    bindToggle(upgrades, "Auto Best Arms", "AutoArms", stopWhenDisabled)
    bindToggle(upgrades, "Auto Backpack & Useful Upgrades", "AutoUpgrades", stopWhenDisabled)
    bindToggle(upgrades, "Auto Buy Needed Progression", "AutoRequirements")
    bindToggle(upgrades, "Auto Rebirth", "AutoRebirth")
    bindToggle(upgrades, "Auto Plot Luck", "AutoPlot", stopWhenDisabled)

    upgrades:CreateSection("Rewards")
    bindToggle(upgrades, "Claim Offline Rewards", "AutoOfflineReward")
    bindToggle(upgrades, "Claim Group Reward", "AutoGroupReward")

    local debugTab = window:CreateTab("Debug")
    debugTab:CreateSection("Navigation Diagnostics")
    local debugLive = debugTab:CreateParagraph({
        Title = "Live Route",
        Content = "Waiting for debug updates...",
        Height = 175,
    })
    local debugEvents = debugTab:CreateParagraph({
        Title = "Recent Events",
        Content = "No events yet",
        Height = 130,
    })
    bindToggle(debugTab, "Log to Executor Console", "DebugConsole")
    debugTab:CreateButton({
        Name = "Copy Debug Log",
        Callback = function()
            local report = self:GetDebugReport()
            if type(setclipboard) == "function" then
                local ok = pcall(setclipboard, report)
                if ok then
                    PuckUI:Notify({Title = "Debug", Content = "Debug report copied", Duration = 3})
                    return
                end
            end
            print(report)
            PuckUI:Notify({Title = "Debug", Content = "Clipboard unavailable; printed to console", Duration = 4})
        end,
    })
    debugTab:CreateButton({
        Name = "Recover Stuck Movement",
        Callback = function()
            self:DebugEvent("MANUAL", "User requested movement recovery")
            self:StopWalking()
            self.ShopRetryAfter = {}
            self:SetStatus("Movement reset; retrying ground route...", "RECOVER")
        end,
    })

    local settingsTab = window:CreateTab("Settings")
    settingsTab:CreateSection("General")
    bindToggle(settingsTab, "Anti AFK", "AntiAFK")
    settingsTab:CreateButton({
        Name = "Unload Script",
        Callback = function()
            self:Shutdown()
        end,
    })

    self.UI.Status = statusCard
    self.UI.Stats = progressCard
    self.UI.Goal = goalCard

    self:Spawn(function()
        while self.Alive and self.UI.Window and self.UI.Window.ScreenGui and self.UI.Window.ScreenGui.Parent do
            local data = self:Data()
            local _, armMulti = self:BestOwnedArmId()
            local plan = self:RefreshRequirementPlan()
            local goalTitle, goalText = friendlyGoal(plan)

            statusCard:Set({
                Title = "Status",
                Content = friendlyStatus(self.Status),
            })

            progressCard:Set({
                Title = "Progress",
                Content = string.format(
                    "Strength %s   •   Cash $%s\nRebirths %s   •   Arm x%s   •   Backpack %d/%d\nRock Target %d / %d",
                    self:Compact(data.Power or 0),
                    self:Compact(data.Cash or 0),
                    self:Compact(data.Rebirths or 0),
                    self:Compact(armMulti or 1),
                    self:BackpackCount(),
                    self:BackpackCapacity(),
                    math.min(self.TargetStage or 1, self:GetMaxStage()),
                    self:GetMaxStage()
                ),
            })

            goalCard:Set({
                Title = goalTitle,
                Content = goalText,
            })

            debugLive:Set({Title = "Live Route", Content = self:DebugSnapshot()})
            local recent = self.Debug.Entries
            local from = math.max(1, #recent - 3)
            local selected = {}
            for i = from, #recent do table.insert(selected, recent[i]) end
            debugEvents:Set({Title = "Recent Events", Content = table.concat(selected, "\n")})
            task.wait(0.35)
        end
    end)

    PuckUI:Notify({
        Title = "PuckAFK",
        Content = "Lift Rock is ready",
        Duration = 2.5,
    })
end

function P:MainLoop()
    self:SetStatus("Synchronizing current rock run...", "SYNC")
    self:EnsureRunSynced()
    self:SetStatus("Ready", "IDLE")
    while self.Alive do
        if not self.Settings.Enabled then
            self:SetStatus("Paused", "PAUSED")
            task.wait(0.25)
        else
            local ok, err = pcall(function()
                if self:Data().TutorialCompleted ~= true then
                    self:TutorialPass()
                else
                    self:RunProgressionCycle()
                end
            end)
            if not ok then
                self.LastError = tostring(err)
                self:StopWalking() -- restores movement collision state after a failed tween
                warn("[PuckAFK Lift Rock] cycle error: " .. tostring(err))
                pcall(function()
                    self.R.RockLiftingInput:FireServer("Sync")
                end)
                task.wait(0.75)
            else
                -- Preserve the most recent recoverable navigation error in Debug.
                task.wait(0.05)
            end
        end
    end
end

function P:Shutdown(silent)
    if not self.Alive then
        return
    end
    self.Alive = false
    self.Settings.Enabled = false
    self:StopWalking()
    for _, connection in ipairs(self.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(self.Connections)
    if self.UI.Window then
        local window = self.UI.Window
        self.UI.Window = nil
        pcall(function()
            window:Destroy()
        end)
    end
    pcall(function()
        if self.Run.Session and self.Run.Session.SessionId then
            self.R.RockLiftingInput:FireServer("Stop", self.Run.Session.SessionId)
        end
    end)
    if ENV.PuckAFK_LiftRock == self then
        ENV.PuckAFK_LiftRock = nil
    end
    if not silent then
        warn("[PuckAFK Lift Rock] Unloaded")
    end
end

-- v1.4.0 boot fix: v1.3.0 accidentally ended after defining Shutdown(), so none of
-- the observers, tap loop, anti-AFK, PuckUI, or main progression loop ever started.
-- Keep boot in one guarded block so a future game/UI change reports the real error
-- and does not leave a half-alive instance in getgenv().
local function Bootstrap()
    P:SetStatus("Installing remote observers...", "BOOT")
    P:InstallRemoteObservers()

    P:SetStatus("Starting training loop...", "BOOT")
    P:InstallTapLoop()

    P:SetStatus("Installing anti-AFK...", "BOOT")
    P:InstallAntiAFK()

    P:SetStatus("Protecting movement from shop popups...", "BOOT")
    P:InstallShopPopupGuard()

    P:SetStatus("Synchronizing special spawns...", "BOOT")
    P:RefreshSpecialSpawns(true)

    P:SetStatus("Loading PuckUI...", "BOOT")
    P:CreateUI()

    P:SetStatus("Starting progression brain...", "BOOT")
    P:Spawn(function()
        local ok, err = pcall(function()
            P:MainLoop()
        end)
        if not ok and P.Alive then
            P.LastError = tostring(err)
            warn("[PuckAFK Lift Rock] main loop crashed: " .. tostring(err))
            P:SetStatus("Main loop crashed - see console", "ERROR")
        end
    end)

    print("[PuckAFK Lift Rock] Smart AutoFarm v" .. P.Version .. " loaded")
end

local bootOk, bootErr = pcall(Bootstrap)
if not bootOk then
    local message = tostring(bootErr)
    P.LastError = message
    warn("[PuckAFK Lift Rock] BOOT FAILED: " .. message)

    -- Clean up workers/connections created before the failure without producing
    -- a misleading extra 'Unloaded' warning.
    pcall(function()
        P:Shutdown(true)
    end)

    if ENV.PuckAFK_LiftRock == P then
        ENV.PuckAFK_LiftRock = nil
    end
end

