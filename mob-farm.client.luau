-- Combat and Cutting hub, based on the supplied NekoHub / Islands.God V4 source.
-- Original authors: NtOpenProcess and soldo_io.
-- Requires the same executor APIs and remote GUI library as the original.
-- Combat and Cutting use remote requests with hash layouts verified from the live diagnostics.

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local LocalPlayer = Players.LocalPlayer
local pastelPink = Color3.fromRGB(255, 209, 227)

local Fluent = loadstring(game:HttpGet("https://raw.githubusercontent.com/IJHGIAJGIHJASUIJGHIUHIUHSUIAOHJAHOIBNAO/Nekohub/main/Fluent-master/main.lua"))()
local Window = Fluent:CreateWindow({
    Title = "RoSnipe",
    SubTitle = "by Bingchilling",
    TabWidth = 160,
    Size = UDim2.fromOffset(580, 460),
    Acrylic = false,
    Theme = "Light",
    MinimizeKey = Enum.KeyCode.RightShift,
})
-- Fluent repaints its registered layers whenever controls are added. Use the
-- unregistered outer frame for our color and make its decorative layers clear.
local windowPaint = Window.AcrylicPaint.Frame
windowPaint.BackgroundColor3 = pastelPink
windowPaint.BackgroundTransparency = 0.1 -- 90% opacity
for _, layer in ipairs(windowPaint:GetChildren()) do
    if layer:IsA("Frame") then layer.BackgroundTransparency = 1 end
end
for _, layer in ipairs(windowPaint:GetDescendants()) do
    if layer:IsA("ImageLabel") and layer.ScaleType == Enum.ScaleType.Tile then
        layer.Image = ""
    end
end
local Main = Window:AddTab({ Title = "Combat", Icon = "sword" })
local Cutting = Window:AddTab({ Title = "Cutting", Icon = "axe" })
local Farming = Window:AddTab({ Title = "Farming", Icon = "leaf" })
local MovementTab = Window:AddTab({ Title = "Movement", Icon = "footprints" })
local Auto = Window:AddTab({ Title = "Auto", Icon = "package" })
local AutoBuild = Window:AddTab({ Title = "Autobuild", Icon = "building-2" })
local GhostPreview = Window:AddTab({ Title = "Ghost Preview", Icon = "eye" })
local BuildFiles = Window:AddTab({ Title = "Build Files", Icon = "folder" })
local Settings = Window:AddTab({ Title = "Settings", Icon = "settings" })

local state = {
    running = true,
    autoFarm = false,
    bossFarm = false,
    killAura = false,
    rageblade = false,
    weapon = nil,
    selected = { slime = true },
    height = -10,
    speed = 25,
    movement = "Tween",
    target = nil,
    auraRange = 20,
    auraInterval = 0.4,
    tokensPerKill = 5,
    treeFarm = false,
    treeAura = false,
    treeType = "All",
    treeRange = 12,
    treeInterval = 0.5,
    treeTarget = nil,
    totemUpgrade = false,
    totemDestination = nil,
}
local connections = {}
local combatRemote, combatKey, combatHash, combatWeapon
local resolving = false
local movementRoot, floatVelocity
local collisions = {}
local rageData, rageTool, oldRageSpeed, oldLastClicked
local aux
local farmToggle, auraToggle
local treeFarmToggle, treeAuraToggle
local stopCutting
local stopAutoBuild
local stopChestPickup
local stopFarming, resolveCropPlacement
local stopBossFarm, runBossOnce, setBossStatus
local stopTotemUpgrade
local stopAirWalk
local stopCratePackerRecorder
local generation = 0
local combatRequests = 0
local activeCombatActivation
local combatInput
local windowFocused = true

local function releaseCombatActivation(expected)
    local activation = activeCombatActivation
    if not activation or (expected and activation ~= expected) then return true end
    local ok, err = pcall(function()
        activation.input:SendMouseButton(activation.point, Enum.UserInputType.MouseButton1, false, 0)
    end)
    -- Roblox also throws when the button is already up (for example after a
    -- physical release or loss of focus). That must not poison later clicks.
    local stateKnown, buttonDown = pcall(function()
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
    end)
    if ok or (stateKnown and not buttonDown) then
        activeCombatActivation = nil
        return true
    else
        warn("[RoSnipe] Could not release combat click: " .. tostring(err))
    end
    return false, tostring(err)
end

local Status = Main:AddParagraph({
    Title = "Status",
    Content = "Enable Mob Auto Farm, then hide this window with Right Shift to start automatic clicks.",
})
local AuraStatus = Main:AddParagraph({
    Title = "Slime Aura Status",
    Content = "Off",
})
local lastAuraStatus
local ClickStatus = Main:AddParagraph({ Title = "Auto Click Status", Content = "Off" })
local lastClickStatus
local function setClickStatus(message)
    if state.running and message ~= lastClickStatus then
        lastClickStatus = message
        ClickStatus:SetDesc(message)
    end
end

local function setAuraStatus(message)
    if state.running and message ~= lastAuraStatus then
        lastAuraStatus = message
        AuraStatus:SetDesc(message)
    end
end

local function setStatus(message)
    if state.running then
        Status:SetDesc(message)
    end
end

local function getCharacter()
    local character = LocalPlayer.Character
    if not character then return nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health <= 0 or not root then return nil end
    return character, humanoid, root
end

local function restoreMovement()
    if floatVelocity then
        floatVelocity:Destroy()
        floatVelocity = nil
    end
    for part, canCollide in pairs(collisions) do
        if part.Parent then part.CanCollide = canCollide end
    end
    collisions = {}
    movementRoot = nil
end

local function restoreRageblade()
    if rageData then
        rageData.speed = oldRageSpeed
        rageData.lastClicked = oldLastClicked
    end
    rageData, rageTool = nil, nil
end

local function stopCombat()
    generation = generation + 1
    releaseCombatActivation()
    state.target = nil
    state.treeTarget = nil
    state.bossDestination = nil
    restoreMovement()
    restoreRageblade()
end

local function netManaged()
    local current = ReplicatedStorage
    for _, name in ipairs({ "rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged" }) do
        current = current:FindFirstChild(name)
        assert(current, "Missing game remote folder: " .. name)
    end
    return current
end

-- Preferred melee weapons first. Keep both wooden sword IDs: swordWood was
-- verified in this inventory; woodenSword is the alternate user-provided ID.
local meleeWeaponOrder = {
    "cursedHammer", "reaperScythe", "reapersScythe", "divineDao", "captainsRapier",
    "noxiousStinger", "stoneSword", "rageblade", "swordWood", "woodenSword",
    "ironSword", "aquamarineSword", "rubySword", "frostSword", "cutlass",
    "antlerDagger", "jollyDagger", "cactusSpike", "woodenMallet", "graniteHammer",
    "gildedSteelHammer", "diamondWarHammer", "diamondGreatSword", "ironWarAxe",
    "kongsAxe", "obsidianGreatsword", "dragonslayer", "antlerHammer",
    "pumpkinHammer", "frostHammer", "infernalHammer", "serpentsBane", "troutsFury",
}
local meleeWeaponSet = {}
for _, name in ipairs(meleeWeaponOrder) do meleeWeaponSet[name] = true end

local function registerCombatWeapon(name)
    if not meleeWeaponSet[name] then
        meleeWeaponSet[name] = true
        table.insert(meleeWeaponOrder, name)
    end
end

local function scanCombatInventory()
    local found, equipped = {}, nil
    local character = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local function scan(container, worn)
        if not container then return end
        for _, item in ipairs(container:GetChildren()) do
            if item:IsA("Tool") then
                local name = item.Name:lower()
                if name:find("reaper", 1, true) and name:find("scythe", 1, true) then
                    registerCombatWeapon(item.Name)
                end
            end
            if item:IsA("Tool") and meleeWeaponSet[item.Name] then
                if not found[item.Name] then found[item.Name] = item end
                if worn and not equipped then equipped = item.Name end
            end
        end
    end
    scan(character, true)
    scan(backpack, false)
    local names = {}
    for _, name in ipairs(meleeWeaponOrder) do
        if found[name] then table.insert(names, name) end
    end
    return names, found, equipped
end

local function selectedCombatTool()
    if not state.weapon then return nil end
    local _, found = scanCombatInventory()
    return found[state.weapon]
end

local function equipCombatWeapon()
    local character, humanoid = getCharacter()
    if not character then return nil end
    local tool = selectedCombatTool()
    if not tool then
        local message = state.weapon and ("Waiting for " .. state.weapon .. " in your inventory.")
            or "No melee weapon found. Add a weapon to your Backpack."
        setStatus(message)
        setAuraStatus(message)
        return nil
    end
    if tool.Parent == character then return tool, false end
    humanoid:EquipTool(tool)
    if tool.Parent ~= character then return nil end
    return tool, true
end

-- PlaceVersion 1246: the hit sender stores its hash in constants, not attemptHit upvalues.
local function resolveCombat()
    local info = getinfo or (debug and debug.getinfo)
    local protos = getprotos or (debug and debug.getprotos)
    local constants = getconstants or (debug and debug.getconstants)
    assert(getgc and info and constants,
        "Executor is missing the introspection APIs used by mob hash discovery.")
    local net = netManaged()
    local weapon = equipCombatWeapon()
    assert(weapon, "Selected melee weapon is unavailable in your inventory.")
    task.wait(0.2)
    local function readHitSender(fn)
        local ok, values = pcall(constants, fn)
        if not ok or type(values) ~= "table" then return nil end
        -- Verified sender layout: remote suffix, Get, hitUnit, HASH_KEY, HASH_VALUE,
        -- argument table, CallServerAsync. Preserve the live hash string byte-for-byte.
        if type(values[1]) ~= "string" or values[1] == "" or values[2] ~= "Get"
            or values[3] ~= "hitUnit" or type(values[4]) ~= "string" or values[4] == ""
            or type(values[5]) ~= "string" or values[5] == "" or values[7] ~= "CallServerAsync" then
            return nil
        end
        local suffix = "/" .. values[1]
        local matched
        for _, remote in ipairs(net:GetChildren()) do
            if remote:IsA("RemoteEvent") and (remote.Name == values[1] or remote.Name:sub(-#suffix) == suffix) then
                if matched then return nil end -- Do not guess between ambiguous remote names.
                matched = remote
            end
        end
        if matched then return { remote = matched, key = values[4], hash = values[5] } end
    end
    local function inspectSender(fn, depth)
        local match = readHitSender(fn)
        if match then return match end
        if depth >= 2 or type(protos) ~= "function" then return nil end
        local ok, children = pcall(protos, fn)
        if ok and type(children) == "table" then
            for _, child in pairs(children) do
                local nested = inspectSender(child, depth + 1)
                if nested then return nested end
            end
        end
    end
    local ownedCandidates, sourceCandidates = {}, {}
    for _, closure in pairs(getgc(true)) do
        if type(closure) == "function" then
            pcall(function()
                local details = info(closure)
                if type(details) ~= "table" then return end
                local source = details.source or details.short_src
                -- Cloned weapon scripts can retain another weapon's debug source.
                -- The live script instance identifies the actual equipped weapon.
                local scriptKnown, belongsToWeapon = false, false
                if type(getfenv) == "function" then
                    pcall(function()
                        local environment = getfenv(closure)
                        local scriptObject = type(environment) == "table" and rawget(environment, "script")
                        if typeof(scriptObject) == "Instance" then
                            scriptKnown = true
                            belongsToWeapon = scriptObject:IsDescendantOf(weapon)
                        end
                    end)
                end
                local candidate = { fn = closure, depth = details.name == "attemptHit" and 0 or 2 }
                if belongsToWeapon then
                    table.insert(ownedCandidates, candidate)
                elseif not scriptKnown and type(source) == "string"
                    and string.find(source, "." .. weapon.Name .. ".", 1, true) then
                    -- Compatibility fallback only when script ownership is unavailable.
                    table.insert(sourceCandidates, candidate)
                end
            end)
        end
    end
    for _, candidates in ipairs({ ownedCandidates, sourceCandidates }) do
        for _, candidate in ipairs(candidates) do
            local inspected, match = pcall(inspectSender, candidate.fn, candidate.depth)
            if inspected and match then return match, weapon end
        end
    end
    error("No compatible melee hit sender found for " .. weapon.Name
        .. ". Equip it, hit a slime manually, then refresh combat remotes; a weapon diagnostic may be needed.")
end

local function refreshCombat()
    if resolving or not state.running then return end
    resolving = true
    stopCombat()
    local token = generation
    combatRemote, combatKey, combatHash, combatWeapon = nil, nil, nil, nil
    setStatus("Resolving combat for " .. (state.weapon or "selected weapon") .. "...")
    local ok, match, weapon = pcall(resolveCombat)
    resolving = false
    -- Selection, respawn, or disabling combat can invalidate an in-flight lookup.
    if not state.running then return end
    if token ~= generation then
        if (state.autoFarm or state.bossFarm or state.killAura) and selectedCombatTool() then task.defer(refreshCombat) end
        return
    end
    if ok and weapon == selectedCombatTool() then
        combatRemote, combatKey, combatHash, combatWeapon = match.remote, match.key, match.hash, weapon
        setStatus("Equipped " .. weapon.Name .. "; targeted hit sender resolved.")
    elseif not ok then
        setStatus(tostring(match))
        setAuraStatus(tostring(match))
        warn("[Mob Farm] " .. tostring(match))
    end
end

local function findNearestMob(selectedOnly)
    local _, _, root = getCharacter()
    local island = workspace:FindFirstChild("WildernessIsland")
    local entities = island and island:FindFirstChild("Entities")
    if not root or not entities then return nil end
    local nearest, distance = nil, math.huge
    for _, mob in ipairs(entities:GetChildren()) do
        local mobRoot = mob:FindFirstChild("HumanoidRootPart")
        local humanoid = mob:FindFirstChildOfClass("Humanoid")
        if mobRoot and humanoid and humanoid.Health > 0 and (not selectedOnly or state.selected[mob.Name]) then
            local currentDistance = (mobRoot.Position - root.Position).Magnitude
            if currentDistance < distance then
                nearest, distance = mob, currentDistance
            end
        end
    end
    return nearest
end

local function auraMobRoot(mob)
    local character, _, root = getCharacter()
    local mobRoot = mob and mob.Parent and mob:FindFirstChild("HumanoidRootPart")
    local humanoid = mob and mob:FindFirstChildOfClass("Humanoid")
    if not character then return nil, "player unavailable" end
    local name = mob and string.lower(mob.Name)
    if name ~= "slime" and name ~= "slimes" then return nil, "name does not match" end
    if not mobRoot then return nil, "missing HumanoidRootPart" end
    if not humanoid then return nil, "missing Humanoid" end
    if humanoid.Health <= 0 then return nil, "dead" end
    if (mobRoot.Position - root.Position).Magnitude > state.auraRange then
        return nil, "outside " .. state.auraRange .. " stud detection range"
    end
    return mobRoot
end

local function findAuraSlime()
    local _, _, root = getCharacter()
    local island = workspace:FindFirstChild("WildernessIsland")
    local entities = island and island:FindFirstChild("Entities")
    if not root then return nil, "Waiting for your character." end
    if not entities then return nil, "WildernessIsland.Entities is not loaded." end
    local nearest, distance = nil, math.huge
    local reasons, names = {}, {}
    for _, mob in ipairs(entities:GetChildren()) do
        local mobRoot, reason = auraMobRoot(mob)
        if mobRoot then
            local current = (mobRoot.Position - root.Position).Magnitude
            if current < distance then nearest, distance = mob, current end
        elseif reason ~= "name does not match" then
            reasons[reason] = (reasons[reason] or 0) + 1
        end
        names[mob.Name] = true
    end
    if nearest then return nearest end
    local details = {}
    for reason, count in pairs(reasons) do
        table.insert(details, tostring(count) .. " " .. reason)
    end
    table.sort(details)
    if #details > 0 then return nil, "No attackable slime: " .. table.concat(details, "; ") end
    for name in pairs(names) do table.insert(details, name) end
    table.sort(details)
    return nil, "No slime/slimes models found. Entity names: " .. table.concat(details, ", ", 1, math.min(#details, 8))
end

local function prepareRageblade(character)
    local tool = character:FindFirstChild("rageblade")
    if not state.rageblade or state.weapon ~= "rageblade" or not tool then
        restoreRageblade()
        return
    end
    if rageTool == tool and rageData then return end
    restoreRageblade()
    if not aux then
        aux = loadstring(game:HttpGetAsync("https://raw.githubusercontent.com/Upbolt/Hydroxide/revision/ohaux.lua"))()
    end
    local scriptPath = tool:FindFirstChild("rageblade")
    assert(scriptPath, "Equipped rageblade is missing its client script.")
    local closure = aux.searchClosure(scriptPath, "Unnamed function", 1, {
        "isHitting", "getLivingEntityFromChildPart", "attemptHit",
    })
    local data = debug.getupvalue(closure, 1)
    assert(type(data) == "table", "Could not locate the original rageblade state.")
    rageData, rageTool = data, tool
    oldRageSpeed, oldLastClicked = data.speed, data.lastClicked
    data.speed = 4
end

local function hash()
    return HttpService:GenerateGUID(false) .. HttpService:GenerateGUID(false) .. HttpService:GenerateGUID(false)
end

local function combatClickPause()
    if not windowFocused then return "Paused: focus the Roblox window." end
    if GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() then
        return "Paused while a menu or text box is open."
    end
    if not Window.Minimized then return "Hide RoSnipe with Right Shift to start automatic clicks." end
    if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        return "Release the left mouse button to resume automatic clicks."
    end
end

-- Clicks start normal sword swings independently of the targeted hit loop.
-- A delayed/rejected mouse-up must not suppress the known-working hit requests.
local function runCombatClick()
    local pause = combatClickPause()
    if activeCombatActivation then
        local released, releaseError = releaseCombatActivation()
        if not released then error("Mouse release blocked: " .. tostring(releaseError), 0) end
        pause = combatClickPause()
    end
    if pause then setClickStatus(pause) return end
    local character = getCharacter()
    if not character then return end
    local mob
    if state.autoFarm or state.bossFarm then mob=state.target else mob=findAuraSlime() end
    if not mob or not mob.Parent then setClickStatus("Waiting for a mob.") return end
    local health = mob:FindFirstChildOfClass("Humanoid")
    if not health or health.Health <= 0 then return end
    local tool = selectedCombatTool()
    if not tool or tool ~= combatWeapon or tool.Parent ~= character or not tool.Enabled then return end
    if not combatInput then
        local ok, result = pcall(function() return UserInputService:CreateVirtualInput() end)
        if not ok or not result then error("Combat auto-click unavailable: " .. tostring(result), 0) end
        combatInput = result
    end
    local camera = workspace.CurrentCamera
    if not camera then return end
    local activation = { input = combatInput, point = camera.ViewportSize / 2 }
    local token = generation
    local activated, activateError = pcall(function()
        combatInput:SendMouseButton(activation.point, Enum.UserInputType.MouseButton1, true, 0)
    end)
    if not activated then error("Combat click failed: " .. tostring(activateError), 0) end
    activeCombatActivation = activation
    task.wait(0.08)
    local released, releaseError = releaseCombatActivation(activation)
    if not released then error("Mouse release blocked: " .. tostring(releaseError), 0) end
    if token == generation and state.running then setClickStatus("Automatic clicks: " .. tool.Name) end
end

local function attack(mob, farm)
    local character = getCharacter()
    if not character then return end
    local token = generation
    local tool, equippedNow = equipCombatWeapon()
    if not tool or tool ~= combatWeapon then return end
    if equippedNow then task.wait(0.2) end
    if token ~= generation or not state.running or LocalPlayer.Character ~= character then return end
    prepareRageblade(character)
    if not state.running or token ~= generation then
        restoreRageblade()
        return
    end
    -- Original remote burst and payload; independent of Tool.Enabled and mouse state.
    local boosted = state.rageblade and tool.Name == "rageblade"
    local count = farm and (boosted and 50 or 5) or 1
    if farm then task.wait(0.5) end
    for _ = 1, count do
        local humanoid = mob:FindFirstChildOfClass("Humanoid")
        if not state.running or token ~= generation or resolving or not mob.Parent
            or not humanoid or humanoid.Health <= 0 or not mob:FindFirstChild("HumanoidRootPart")
            or LocalPlayer.Character ~= character or tool.Parent ~= character or tool ~= combatWeapon
            or (farm and not state.autoFarm and not state.bossFarm) or (not farm and not state.killAura) then
            break
        end
        if not windowFocused or GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() then return end
        combatRemote:FireServer(hash(), { { [combatKey] = combatHash, hitUnit = mob } })
        combatRequests = combatRequests + 1
        local root = character:FindFirstChild("HumanoidRootPart")
        local distance = root and (root.Position - mob.HumanoidRootPart.Position).Magnitude or 0
        local message = string.format("Hit request %d sent to %s | health %.1f | distance %.1f studs",
            combatRequests, mob.Name, humanoid.Health, distance)
        if farm then setStatus(message) else setAuraStatus(message) end
        task.wait(farm and (boosted and 0 or 0.3) or 0.4)
    end
end

-- Session kills inferred from positive slimeKingToken quantity changes.
-- The GUI is optional; hiding it does not stop collection tracking.
local tokenTracker = {
    gained = 0,
    previous = nil,
    source = nil,
    emptySince = nil,
    rebaseUntil = 0,
    message = "Reading token inventory...",
}
local quantityFields = { "Amount", "amount", "Quantity", "quantity", "Count", "count", "StackSize", "stackSize" }

local function readTokenStack(item)
    if item:IsA("IntValue") or item:IsA("NumberValue") then
        return tonumber(item.Value)
    end
    for _, field in ipairs(quantityFields) do
        local attribute = item:GetAttribute(field)
        if tonumber(attribute) then return tonumber(attribute) end
        local child = item:FindFirstChild(field)
        if child and (child:IsA("IntValue") or child:IsA("NumberValue") or child:IsA("StringValue")) then
            if tonumber(child.Value) then return tonumber(child.Value) end
        end
    end
    -- Do not guess one token per Tool: a Tool may represent a large stack.
    return nil
end

local function readTokenBalance()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local character = LocalPlayer.Character
    if not backpack or not character then return nil, nil, "Waiting for inventory..." end
    local total, found = 0, false
    for _, container in ipairs({ backpack, character }) do
        for _, item in ipairs(container:GetChildren()) do
            if string.lower(item.Name) == "slimekingtoken" then
                found = true
                local amount = readTokenStack(item)
                if not amount or amount < 0 or amount ~= amount or amount == math.huge then
                    return nil, nil, "Token found; quantity field unavailable."
                end
                total = total + math.floor(amount)
            end
        end
    end
    if found then return total, "tools" end
    -- Some versions expose a numeric inventory entry instead of a Backpack stack.
    for _, name in ipairs({ "Inventory", "inventory" }) do
        local inventory = LocalPlayer:FindFirstChild(name)
        local item = inventory and inventory:FindFirstChild("slimeKingToken")
        if item then
            local amount = readTokenStack(item)
            if amount and amount >= 0 and amount == amount and amount < math.huge then
                return math.floor(amount), name
            end
            return nil, nil, "Inventory token found; quantity field unavailable."
        end
    end
    return 0, tokenTracker.source or "tools"
end

local function sampleTokenBalance(amount, source, now)
    if amount == nil then return end
    -- Ignore brief removal while stacks move between Backpack and Character.
    if amount == 0 and tokenTracker.previous and tokenTracker.previous > 0 then
        tokenTracker.emptySince = tokenTracker.emptySince or now
        if now - tokenTracker.emptySince < 0.75 then return end
    else
        tokenTracker.emptySince = nil
    end
    if tokenTracker.previous ~= nil and tokenTracker.source == source
        and now >= tokenTracker.rebaseUntil then
        tokenTracker.gained = tokenTracker.gained + math.max(0, amount - tokenTracker.previous)
    end
    tokenTracker.previous = amount
    tokenTracker.source = source
end

local KillGui = Instance.new("ScreenGui")
KillGui.Name = "IslandsSlimeKillCounter"
KillGui.ResetOnSpawn = false
KillGui.Enabled = false
KillGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
local KillPanel = Instance.new("Frame")
KillPanel.AnchorPoint = Vector2.new(1, 0)
KillPanel.Position = UDim2.new(1, -20, 0, 20)
KillPanel.Size = UDim2.fromOffset(190, 88)
KillPanel.BackgroundColor3 = pastelPink
KillPanel.BackgroundTransparency = 0.1 -- 90% opacity
KillPanel.BorderSizePixel = 0
KillPanel.Active = false
KillPanel.Parent = KillGui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = KillPanel
local KillLabel = Instance.new("TextLabel")
KillLabel.BackgroundTransparency = 1
KillLabel.Position = UDim2.fromOffset(12, 8)
KillLabel.Size = UDim2.new(1, -24, 0, 42)
KillLabel.Font = Enum.Font.GothamBold
KillLabel.TextSize = 26
KillLabel.TextColor3 = Color3.fromRGB(75, 45, 62)
KillLabel.TextXAlignment = Enum.TextXAlignment.Left
KillLabel.Text = "Kills: 0"
KillLabel.Parent = KillPanel
local KillDetail = Instance.new("TextLabel")
KillDetail.BackgroundTransparency = 1
KillDetail.Position = UDim2.fromOffset(12, 50)
KillDetail.Size = UDim2.new(1, -24, 0, 30)
KillDetail.Font = Enum.Font.Gotham
KillDetail.TextSize = 11
KillDetail.TextWrapped = true
KillDetail.TextColor3 = Color3.fromRGB(113, 78, 96)
KillDetail.TextXAlignment = Enum.TextXAlignment.Left
KillDetail.Parent = KillPanel

local colorOptions = {
    Black = { color = Color3.fromRGB(20, 20, 24), theme = "Dark" },
    White = { color = Color3.fromRGB(255, 255, 255), theme = "Light" },
    Pink = { color = pastelPink, theme = "Light" },
    ["Pastel Blue"] = { color = Color3.fromRGB(190, 220, 255), theme = "Light" },
}
local selectedColor = "Pink"
local function applyUIColor(name)
    local palette = colorOptions[name]
    if not palette then return end
    selectedColor = name
    Fluent:SetTheme(palette.theme)
    windowPaint.BackgroundColor3 = palette.color
    KillPanel.BackgroundColor3 = palette.color
    local dark = palette.theme == "Dark"
    KillLabel.TextColor3 = dark and Color3.fromRGB(245, 245, 250) or Color3.fromRGB(40, 35, 45)
    KillDetail.TextColor3 = dark and Color3.fromRGB(210, 210, 220) or Color3.fromRGB(80, 70, 90)
end
local Appearance = Settings:AddSection("Appearance")
local colorDropdown = Appearance:AddDropdown("UIColor", {
    Title = "UI Color",
    Values = { "Black", "White", "Pink", "Pastel Blue" },
    Multi = false,
    Default = "Pink",
})
colorDropdown:OnChanged(applyUIColor)

local CounterSection = Settings:AddSection("Kill Counter")
local CounterStatus = CounterSection:AddParagraph({
    Title = "Token Tracking",
    Content = "5 slimeKingToken gained = 1 kill. Existing tokens are excluded.",
})
local lastCounterMessage
local function updateKillDisplay()
    KillLabel.Text = "Kills: " .. math.floor(tokenTracker.gained / state.tokensPerKill)
    KillDetail.Text = tokenTracker.message == "Tracking" and "Session kills from slime tokens" or tokenTracker.message
    local message = tokenTracker.message .. " | " .. tokenTracker.gained .. " tokens gained | "
        .. state.tokensPerKill .. " tokens per kill"
    if message ~= lastCounterMessage then
        lastCounterMessage = message
        CounterStatus:SetDesc(message)
    end
end
local showCounter = CounterSection:AddToggle("ShowKillCounter", { Title = "Show Simple Kill GUI", Default = false })
showCounter:OnChanged(function(value) KillGui.Enabled = value end)
CounterSection:AddInput("TokensPerKill", {
    Title = "Tokens per Kill", Default = "5", Numeric = true, Finished = true,
    Callback = function(value)
        local amount = tonumber(value)
        if amount and amount >= 1 and amount < math.huge and amount == math.floor(amount) then
            state.tokensPerKill = amount
            updateKillDisplay()
        end
    end,
})
CounterSection:AddButton({
    Title = "Reset Kill Counter",
    Callback = function()
        tokenTracker.gained = 0
        tokenTracker.previous, tokenTracker.source = readTokenBalance()
        tokenTracker.emptySince = nil
        updateKillDisplay()
    end,
})

local MobSection = Main:AddSection("Mob Auto Farm")
local WeaponStatus = MobSection:AddParagraph({
    Title = "Weapon Inventory",
    Content = "Detecting melee weapons in your Backpack and equipped tools...",
})
local weaponDropdown = MobSection:AddDropdown("CombatWeapon", {
    Title = "Melee Weapon",
    Description = "Detected inventory; preferred weapons first. Refreshes automatically.",
    Values = {}, Multi = false,
})
local updatingWeapons = false
local inventorySignature, lastWeaponInstance, lastWeaponMessage
local function invalidateWeapon()
    stopCombat()
    combatRemote, combatKey, combatHash, combatWeapon = nil, nil, nil, nil
    if (state.autoFarm or state.bossFarm or state.killAura) and selectedCombatTool() then task.spawn(refreshCombat) end
end
local function refreshWeaponInventory()
    local names, found, equipped = scanCombatInventory()
    if not state.weapon and #names > 0 then state.weapon = equipped or names[1] end
    local values = {}
    for _, name in ipairs(names) do table.insert(values, name) end
    -- Preserve the user's selection through respawn or temporarily missing tools.
    -- Never silently switch to another weapon after the user has chosen one.
    local chosen = state.weapon
    if chosen and not found[chosen] then
        chosen = chosen .. " (missing)"
        table.insert(values, chosen)
    end
    local signature = table.concat(values, "|") .. ":" .. (chosen or "")
    if signature ~= inventorySignature then
        inventorySignature = signature
        updatingWeapons = true
        weaponDropdown:SetValues(values)
        weaponDropdown:SetValue(chosen)
        updatingWeapons = false
    end
    local selected = state.weapon and found[state.weapon] or nil
    if selected ~= lastWeaponInstance then
        lastWeaponInstance = selected
        invalidateWeapon()
    end
    local message = selected and ("Selected: " .. selected.Name .. " | " .. #names .. " melee weapons detected.")
        or (state.weapon and ("Waiting for " .. state.weapon .. ". Choose another available weapon if needed.")
        or "No melee weapons found. Bows, spellbooks, arrows and shields are excluded from melee farming.")
    if message ~= lastWeaponMessage then
        lastWeaponMessage = message
        WeaponStatus:SetDesc(message)
    end
end
weaponDropdown:OnChanged(function(value)
    if updatingWeapons or not value or not meleeWeaponSet[value] or value == state.weapon then return end
    state.weapon = value
    lastWeaponInstance = selectedCombatTool()
    invalidateWeapon()
    refreshWeaponInventory()
end)
MobSection:AddButton({
    Title = "Use Equipped Weapon",
    Description = "Equip your melee weapon first. Uses its exact Tool name, including unlisted scythe IDs.",
    Callback = function()
        local character = LocalPlayer.Character
        local tool = character and character:FindFirstChildOfClass("Tool")
        if not tool then
            setStatus("Equip your melee weapon, then press Use Equipped Weapon.")
            return
        end
        registerCombatWeapon(tool.Name)
        state.weapon = tool.Name
        lastWeaponInstance = nil
        refreshWeaponInventory()
    end,
})
MobSection:AddButton({ Title = "Refresh Weapon Inventory", Callback = refreshWeaponInventory })
refreshWeaponInventory()
task.spawn(function()
    while state.running do
        task.wait(1)
        if state.running then refreshWeaponInventory() end
    end
end)

local selection = MobSection:AddDropdown("SelectedMobs", {
    Title = "Selected Mob",
    Description = "Mob to Farm",
    Values = { "wraithBoss", "slime", "buffalkor", "wizardLizard", "Skorpions", "magmaBlob", "magmaGolem", "skeletonPirate", "voidPup", "voidDog" },
    Multi = true,
    Default = { "slime" },
})
selection:OnChanged(function(options)
    local selected = {}
    for name, enabled in pairs(options) do
        if enabled then
            if name == "Skorpions" then
                for _, skorp in ipairs({ "skorpRuby", "skorpGold", "skorpIron", "skorpSerpent" }) do
                    selected[skorp] = true
                end
            else
                selected[name] = true
            end
        end
    end
    state.selected = selected
    stopCombat()
end)
MobSection:AddSlider("MobHeight", {
    Title = "Teleport Position (Y)", Default = -10, Min = -15, Max = 15, Rounding = 0,
    Callback = function(value) state.height = value end,
})
farmToggle = MobSection:AddToggle("MobAutoFarmToggle", { Title = "Mob Auto Farm", Default = false })
farmToggle:OnChanged(function(value)
    if value and stopAutoBuild then stopAutoBuild("Stopped: combat enabled.") end
    if value and stopAirWalk then stopAirWalk("Stopped: combat enabled.") end
    if value and stopTotemUpgrade then stopTotemUpgrade("Stopped: combat enabled.") end
    if value and stopBossFarm then stopBossFarm() end
    if value and stopCutting then stopCutting() end
    if value and stopFarming then stopFarming() end
    state.autoFarm = value
    stopCombat()
    if value and not combatRemote then task.spawn(refreshCombat) end
end)
auraToggle = MobSection:AddToggle("MobKillAuraToggle", { Title = "Slime Aura (Auto Click + Remote)", Default = false })
auraToggle:OnChanged(function(value)
    if value and stopAutoBuild then stopAutoBuild("Stopped: combat enabled.") end
    if value and stopAirWalk then stopAirWalk("Stopped: combat enabled.") end
    if value and stopTotemUpgrade then stopTotemUpgrade("Stopped: combat enabled.") end
    if value and stopBossFarm then stopBossFarm() end
    if value and stopCutting then stopCutting() end
    if value and stopFarming then stopFarming() end
    state.killAura = value
    stopCombat()
    setAuraStatus(value and ("Starting; equipping " .. (state.weapon or "selected weapon") .. "...") or "Off")
    if value and not combatRemote then task.spawn(refreshCombat) end
end)
MobSection:AddSlider("SlimeAuraRange", {
    Title = "Slime Aura Range", Default = 20, Min = 1, Max = 50, Rounding = 0,
    Callback = function(value) state.auraRange = value end,
})
MobSection:AddSlider("SlimeAuraInterval", {
    Title = "Slime Aura Hit Interval", Default = 0.4, Min = 0.1, Max = 2, Rounding = 2,
    Callback = function(value) state.auraInterval = value end,
})
local rageToggle = MobSection:AddToggle("MobUseRagebladeToggle", {
    Title = "Rageblade Speed Boost", Description = "Only applies when rageblade is selected.", Default = false,
})
rageToggle:OnChanged(function(value)
    state.rageblade = value
    stopCombat()
    combatRemote, combatKey, combatHash, combatWeapon = nil, nil, nil, nil
    if state.autoFarm or state.bossFarm or state.killAura then task.spawn(refreshCombat) end
end)

-- Cutting uses CLIENT_BLOCK_HIT_REQUEST with the current axe-tool hash layout.
-- Axe detection and cancellation are retained from the integrated controls.
local treePatterns = {
    All = "^tree", Oak = "^tree%d+$", Birch = "^treeBirch%d*$",
    Maple = "^treeMaple%d*$", Pine = "^treePine%d*$", Hickory = "^treeHickory%d*$",
    Spirit = "^treeSpirit%d*$", CherryBlossom = "^treeCherryBlossom%d*$",
    Apple = "^treeApple%d*$", Lemon = "^treeLemon%d*$",
}
local axeNames = { "diamondAxe", "gildedSteelAxe", "ironAxe", "opalAxe", "stoneAxe", "woodAxe" }
local TreeStatus = Cutting:AddParagraph({
    Title = "Cutting Status",
    Content = "Choose a tree. Auto Farm moves to trees; Tree Aura chops nearby trees without moving.",
})
local lastTreeStatus
local treeRemote, treeHashKey, treeHashValue
local pendingTreeHit
local function setTreeStatus(message)
    if state.running and message ~= lastTreeStatus then
        lastTreeStatus = message
        TreeStatus:SetDesc(message)
    end
end

local function treeMatches(tree)
    return string.match(tree.Name, treePatterns[state.treeType]) ~= nil
end

local function treeHitPart(tree)
    local trunk=tree:FindFirstChild("trunk",true)
    if trunk and trunk:IsA("BasePart") then return trunk end
    -- The original supports trees whose hit part is a mesh instead of "trunk".
    local mesh=tree:FindFirstChildWhichIsA("MeshPart",true)
    if mesh then return mesh end
    if tree:IsA("BasePart") then return tree end
end

local function validTreeTarget(target)
    return target and target.tree.Parent == target.parent and target.parent:IsDescendantOf(workspace)
        and (target.trunk==target.tree or target.trunk:IsDescendantOf(target.tree)) and treeMatches(target.tree)
end

local function detectTreeAxe(character)
    for _, item in ipairs(character:GetChildren()) do
        if item:IsA("Tool") and table.find(axeNames, item.Name) then return item end
    end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if backpack then
        for _, name in ipairs(axeNames) do
            local item = backpack:FindFirstChild(name)
            if item and item:IsA("Tool") then return item end
        end
    end
end

local function findTreeTarget(root)
    if validTreeTarget(state.treeTarget) then
        if state.treeFarm or (root.Position - state.treeTarget.trunk.Position).Magnitude <= state.treeRange then
            return state.treeTarget
        end
    end
    local islands = workspace:FindFirstChild("Islands")
    if not islands then return nil,"No island blocks are loaded yet." end
    local nearest, best = nil, state.treeFarm and math.huge or state.treeRange
    local matched,withPart=0,0
    local scope="loaded islands"
    -- Prefer your owned island; otherwise use the loaded islands, as the input script does.
    local candidates = islands:GetChildren()
    for _, island in ipairs(candidates) do
        local owners = island:FindFirstChild("Owners")
        if owners and owners:FindFirstChild(tostring(LocalPlayer.UserId)) then
            candidates = { island }
            scope="your island"
            break
        end
    end
    for _, island in ipairs(candidates) do
        local blocks = island:FindFirstChild("Blocks")
        if blocks then
            for _, tree in ipairs(blocks:GetChildren()) do
                if treeMatches(tree) then
                    matched=matched+1
                    local trunk = treeHitPart(tree)
                    if trunk then
                        withPart=withPart+1
                        local distance = (root.Position - trunk.Position).Magnitude
                        if distance <= best then
                            nearest, best = { tree = tree, trunk = trunk, parent = blocks }, distance
                        end
                    end
                end
            end
        end
    end
    if nearest then return nearest end
    if matched==0 then return nil,"No "..state.treeType.." trees loaded on "..scope.."." end
    if withPart==0 then return nil,"Found "..matched.." "..state.treeType.." trees, but no trunk or mesh hit parts." end
    return nil,"Found "..withPart.." "..state.treeType.." trees outside the "..state.treeRange.."-stud aura range. Move closer or enable Tree Auto Farm."
end

local function resolveTreeCombat()
    local info = getinfo or (debug and debug.getinfo)
    local protos = getprotos or (debug and debug.getprotos)
    local constants = getconstants or (debug and debug.getconstants)
    assert(getgc and info and constants,
        "Executor is missing the APIs used by tree hash discovery.")
    local remote = netManaged():FindFirstChild("CLIENT_BLOCK_HIT_REQUEST")
    assert(remote and remote:IsA("RemoteFunction"), "CLIENT_BLOCK_HIT_REQUEST RemoteFunction was not found.")
    setTreeStatus("Resolving the current axe-tool tree-hit hash...")
    local function readHash(fn)
        local ok, values = pcall(constants, fn)
        if not ok or type(values) ~= "table" then return end
        if not table.find(values, "CLIENT_BLOCK_HIT_REQUEST")
            or not table.find(values, "Get") or not table.find(values, "CallServer") then return end
        -- Verified from the user's PlaceVersion 1246 diagnostic:
        -- block, part, pos, norm, HASH_KEY, HASH_VALUE, <table>, CallServer.
        -- Read the live string verbatim; it includes control characters and newlines.
        for index, value in pairs(values) do
            if type(index) == "number" and value == "norm"
                and values[index - 3] == "block" and values[index - 2] == "part"
                and values[index - 1] == "pos" then
                local key, hashValue = values[index + 1], values[index + 2]
                if type(key) == "string" and key ~= "" and type(hashValue) == "string" and hashValue ~= "" then
                    return key, hashValue
                end
            end
        end
    end
    for _, closure in pairs(getgc(true)) do
        if type(closure) == "function" then
            local ok, key, hashValue = pcall(function()
                local details = info(closure)
                local source = type(details) == "table" and (details.source or details.short_src)
                if type(source) ~= "string" or not string.find(source, "TS.tool.tools.shared.axe-tool", 1, true) then
                    return
                end
                -- Either the live unnamed sender or onBlockHit's nested prototype can match.
                local directKey, directHash = readHash(closure)
                if directKey then return directKey, directHash end
                if details.name == "onBlockHit" and type(protos) == "function" then
                    local read, children = pcall(protos, closure)
                    if read and type(children) == "table" then
                        for _, proto in pairs(children) do
                            local childKey, childHash = readHash(proto)
                            if childKey then return childKey, childHash end
                        end
                    end
                end
            end)
            if ok and key and hashValue then
                treeRemote, treeHashKey, treeHashValue = remote, key, hashValue
                setTreeStatus("Tree-hit hash resolved from axe-tool.")
                return
            end
        end
    end
    error("Current axe-tool hash not found. Equip an axe, hit a tree manually, then use Refresh Tree Hash and retry.")
end

local function runTreeOnce()
    local character, humanoid, root = getCharacter()
    if not character then setTreeStatus("Waiting for your character.") return end
    local token = generation
    local function current()
        return state.running and generation == token and (state.treeFarm or state.treeAura)
            and LocalPlayer.Character == character and humanoid.Health > 0
    end
    local axe = detectTreeAxe(character)
    if not axe then
        state.treeTarget = nil
        restoreMovement()
        setTreeStatus("No axe found. Put an axe in your Backpack.")
        return
    end
    if axe.Parent ~= character then
        humanoid:EquipTool(axe)
        task.wait(0.4)
    end
    if not current() then return end
    if axe.Parent ~= character or not axe.Enabled then setTreeStatus("Waiting for the axe to be ready.") return end
    local target,reason = findTreeTarget(root)
    state.treeTarget = target
    if not target then setTreeStatus(reason) return end
    if (root.Position - target.trunk.Position).Magnitude > state.treeRange then
        setTreeStatus("Moving to " .. target.tree.Name .. " with " .. axe.Name .. ".")
        return
    end
    if not treeRemote or not treeRemote.Parent then resolveTreeCombat() end
    if not current() or not validTreeTarget(target) or axe.Parent ~= character then return end
    if pendingTreeHit and not pendingTreeHit.done then
        error("Previous tree hit is still waiting for the server. Wait before retrying.")
    end
    local payload = {
        [treeHashKey] = treeHashValue,
        part = target.trunk,
        block = target.tree,
        -- The source's Vector3.new(v.CFrame) is invalid; use a real surface normal.
        norm = target.trunk.CFrame.UpVector,
        pos = target.tree:IsA("BasePart") and target.tree.Position or target.trunk.Position,
    }
    local request = { done = false }
    local remote = treeRemote
    pendingTreeHit = request
    setTreeStatus("Sending tree hit: " .. target.tree.Name .. " with " .. axe.Name .. ".")
    task.spawn(function()
        request.ok, request.result = pcall(function()
            if not current() then return end
            return remote:InvokeServer(payload)
        end)
        request.done = true
    end)
    local deadline = os.clock() + 5
    while not request.done do
        if not current() then return end
        if os.clock() >= deadline then
            error("Tree hit response timed out; no additional hits will be queued.")
        end
        task.wait(0.05)
    end
    pendingTreeHit = nil
    if not current() then return end
    if not request.ok then error(request.result, 0) end
    if request.result == false then error("Server rejected the tree hit. Check reach and island permissions.") end

end

local TreeSection = Cutting:AddSection("Tree Farm")
local treeSelection = TreeSection:AddDropdown("TreeType", {
    Title = "Tree to Farm",
    Values = { "All", "Oak", "Birch", "Maple", "Pine", "Hickory", "Spirit", "CherryBlossom", "Apple", "Lemon" },
    Default = "All", Multi = false,
})
treeSelection:OnChanged(function(value)
    state.treeType = value
    stopCombat()
end)
TreeSection:AddSlider("TreeRange", {
    Title = "Tree Cutting Range", Default = 12, Min = 7, Max = 30, Rounding = 0,
    Callback = function(value) state.treeRange = value end,
})
TreeSection:AddSlider("TreeHitInterval", {
    Title = "Tree Hit Interval", Default = 0.5, Min = 0.1, Max = 2, Rounding = 2,
    Callback = function(value) state.treeInterval = value end,
})
treeFarmToggle = TreeSection:AddToggle("TreeAutoFarm", { Title = "Tree Auto Farm", Default = false })
treeAuraToggle = TreeSection:AddToggle("TreeAura", { Title = "Tree Aura (No Movement)", Default = false })
stopCutting = function()
    state.treeFarm, state.treeAura = false, false
    if treeFarmToggle.Value then treeFarmToggle:SetValue(false) end
    if treeAuraToggle.Value then treeAuraToggle:SetValue(false) end
    stopCombat()
    setTreeStatus("Off")
end
local function setCuttingMode(mode, value)
    if value and stopAirWalk then stopAirWalk("Stopped: cutting enabled.") end
    if value and stopTotemUpgrade then stopTotemUpgrade("Stopped: cutting enabled.") end
    if value and stopBossFarm then stopBossFarm() end
    if value and stopFarming then stopFarming() end
    if value and stopAutoBuild then stopAutoBuild("Stopped: cutting enabled.") end
    state[mode] = value
    stopCombat()
    if not value then
        if not state.treeFarm and not state.treeAura then setTreeStatus("Off") end
        return
    end
    if mode == "treeFarm" then
        treeAuraToggle:SetValue(false)
    else
        treeFarmToggle:SetValue(false)
    end
    farmToggle:SetValue(false)
    auraToggle:SetValue(false)
    setTreeStatus("Scanning for " .. state.treeType .. " trees; axe detection is automatic.")
end
treeFarmToggle:OnChanged(function(value) setCuttingMode("treeFarm", value) end)
treeAuraToggle:OnChanged(function(value) setCuttingMode("treeAura", value) end)
TreeSection:AddButton({
    Title = "Refresh Tree Hash",
    Callback = function()
        stopCutting()
        treeRemote, treeHashKey, treeHashValue = nil, nil, nil
        setTreeStatus("Tree hash cleared. Enable Tree Auto Farm or Tree Aura to resolve it again.")
    end,
})

local Movement = Settings:AddSection("Farm Movement")
local method = Movement:AddDropdown("TeleportMethod", {
    Title = "Teleport Method", Values = { "Tween", "Instant" }, Default = "Tween", Multi = false,
})
method:OnChanged(function(value)
    state.movement = value
    stopCombat()
end)
Movement:AddSlider("TweenFlySpeed", {
    Title = "Movement Speed", Default = 25, Min = 1, Max = 100, Rounding = 0,
    Callback = function(value) state.speed = value end,
})
Settings:AddButton({
    Title = "Refresh Combat Remotes",
    Callback = function() task.spawn(refreshCombat) end,
})

-- Follows the original ChestAura loop: send one ordinary withdraw request for
-- each child in Contents. It deliberately does not toggle the chest UI open.
local function installChestPickup()
    local section=Auto:AddSection("CHEST PICKUP")
    local status=Auto:AddParagraph({Title="Chest Pickup Status",Content="Off. Scans only chestLargeIndustrialIO on your own island."})
    local running,generation=false,0
    local delaySeconds=0
    local travelSpeed=35
    local nearbyOnly=true
    local nearbyRange=12
    local chestHover
    local chestCollisionState={}
    local chestNoclipConnection
    local toggle=section:AddToggle("ChestPickupEnabled",{
        Title="Auto Empty Large Industrial Chests",
        Description="Uses the original ChestAura pattern: request each stored stack in one pass.",
        Default=false,
    })
    section:AddSlider("ChestPickupDelay",{
        Title="Delay Between Requests (seconds)",Description="Optional pause between the original per-stack withdraw requests.",
        Default=0,Min=0,Max=1,Rounding=2,Callback=function(value) delaySeconds=tonumber(value) or 0 end,
    })
    section:AddSlider("ChestPickupTravelSpeed",{
        Title="Chest Flight Speed",Description="Flies above the route, then hovers beside each chest.",
        Default=35,Min=10,Max=100,Rounding=0,Callback=function(value) travelSpeed=tonumber(value) or 35 end,
    })
    section:AddToggle("ChestPickupNearbyOnly",{
        Title="Only Chests in Range",Description="Turn off to fly to farther chests while holding a hover beside each one.",
        Default=true,Callback=function(value) nearbyOnly=value end,
    })
    section:AddSlider("ChestPickupRange",{
        Title="Nearby Chest Range (studs)",Description="Maximum distance for the nearby-only sweep.",
        Default=12,Min=4,Max=14,Rounding=0,Callback=function(value) nearbyRange=tonumber(value) or 12 end,
    })
    local function chestPart(chest)
        local part=chest:IsA("BasePart") and chest or chest:FindFirstChild("Root",true)
        if not part or not part:IsA("BasePart") then part=chest:FindFirstChildWhichIsA("BasePart",true) end
        return part
    end
    local function releaseChestHover()
        if chestHover then chestHover:Destroy();chestHover=nil end
    end
    local function ensureChestHover(root)
        if chestHover and chestHover.Parent~=root then releaseChestHover() end
        if not chestHover then
            chestHover=Instance.new("BodyPosition")
            chestHover.Name="RoSnipeChestHover"
            chestHover.MaxForce=Vector3.new(1e9,1e9,1e9)
            chestHover.P,chestHover.D=10000,1000
            chestHover.Position=root.Position
            chestHover.Parent=root
        end
        return chestHover
    end
    local function setChestNoclip(enabled)
        local character=LocalPlayer.Character
        if enabled and character then
            local function disableCollisions()
                local current=LocalPlayer.Character
                if not current then return end
                for _,part in ipairs(current:GetDescendants()) do
                    if part:IsA("BasePart") then
                        if chestCollisionState[part]==nil then chestCollisionState[part]=part.CanCollide end
                        part.CanCollide=false
                    end
                end
            end
            disableCollisions()
            if not chestNoclipConnection then
                chestNoclipConnection=RunService.Heartbeat:Connect(disableCollisions)
            end
        else
            if chestNoclipConnection then chestNoclipConnection:Disconnect();chestNoclipConnection=nil end
            for part,canCollide in pairs(chestCollisionState) do
                if part.Parent then part.CanCollide=canCollide end
                chestCollisionState[part]=nil
            end
        end
    end
    local function moveToChest(chest,number,total,token)
        local character,humanoid,root=getCharacter()
        assert(character,"Wait for your character before starting chest pickup.")
        local part=chestPart(chest)
        assert(part,"Chest has no usable part: "..chest.Name)
        local horizontal=Vector3.new(root.Position.X-part.Position.X,0,root.Position.Z-part.Position.Z)
        if horizontal.Magnitude<0.1 then
            horizontal=Vector3.new(-part.CFrame.LookVector.X,0,-part.CFrame.LookVector.Z)
        end
        if horizontal.Magnitude<0.1 then horizontal=Vector3.new(0,0,1) end
        local destination=part.Position+Vector3.new(0,3,0)+horizontal.Unit*5
        local hover=ensureChestHover(root)
        setChestNoclip(true)
        local startPosition=root.Position
        local safeY=math.max(startPosition.Y,part.Position.Y+10)
        local waypoints={
            Vector3.new(startPosition.X,safeY,startPosition.Z),
            Vector3.new(destination.X,safeY,destination.Z),
            destination,
        }
        local distance=(startPosition-destination).Magnitude
        status:SetDesc("Moving to chest "..number.." / "..total.." ("..math.floor(distance).." studs)...")
        for _,point in ipairs(waypoints) do
            while running and generation==token and (root.Position-point).Magnitude>2 do
                local delta=point-root.Position
                local step=math.min(delta.Magnitude,math.clamp(tonumber(travelSpeed) or 35,5,60)*0.05)
                local nextPosition=root.Position+delta.Unit*step
                setChestNoclip(true)
                hover.Position=nextPosition
                root.AssemblyLinearVelocity=Vector3.zero
                root.AssemblyAngularVelocity=Vector3.zero
                root.CFrame=CFrame.new(nextPosition)*root.CFrame.Rotation
                task.wait(0.05)
            end
            if not running or generation~=token then
                if root.Parent then hover.Position=root.Position end
                setChestNoclip(false)
                return false
            end
            hover.Position=root.Position
        end
        for _=1,30 do
            if not running or generation~=token then
                hover.Position=root.Position
                setChestNoclip(false)
                return false
            end
            if (root.Position-part.Position).Magnitude<=14 then break end
            task.wait(0.1)
        end
        setChestNoclip(false)
        assert((root.Position-part.Position).Magnitude<=14,
            "Flight ended outside chest range ("..math.floor((root.Position-part.Position).Magnitude).." studs).")
        return true
    end
    local function ownBlockFolder()
        local islands=workspace:FindFirstChild("Islands")
        if not islands then return nil end
        for _,island in ipairs(islands:GetChildren()) do
            local owners=island:FindFirstChild("Owners")
            local blocks=island:FindFirstChild("Blocks")
            if blocks and owners and owners:FindFirstChild(tostring(LocalPlayer.UserId)) then return blocks end
        end
        return nil
    end
    local function chestRemote()
        local net=ReplicatedStorage
        for _,name in ipairs({"rbxts_include","node_modules","@rbxts","net","out","_NetManaged"}) do
            net=net and net:FindFirstChild(name)
        end
        local remote=net and net:FindFirstChild("CLIENT_CHEST_TRANSACTION")
        assert(remote and remote:IsA("RemoteFunction"),"CLIENT_CHEST_TRANSACTION was not found; save a chest interaction diagnostic.")
        return remote
    end
    local function amountOf(item)
        local amount=item:FindFirstChild("Amount")
        local value=amount and tonumber(amount.Value)
        assert(value and value>0,"Stored item has no positive Amount value: "..item.Name)
        return value
    end
    local function inventoryAmount(itemName)
        local total=0
        for _,container in ipairs({LocalPlayer:FindFirstChild("Backpack"),LocalPlayer.Character}) do
            if container then
                for _,item in ipairs(container:GetChildren()) do
                    if item.Name==itemName then
                        local amount=item:FindFirstChild("Amount")
                        total=total+(amount and tonumber(amount.Value) or 1)
                    end
                end
            end
        end
        return total
    end
    toggle:OnChanged(function(enabled)
        if enabled and stopAirWalk then stopAirWalk("Stopped: chest pickup enabled.") end
        if enabled and stopTotemUpgrade then stopTotemUpgrade("Stopped: chest pickup enabled.") end
        generation=generation+1
        local token=generation
        running=enabled
        if not enabled then
            setChestNoclip(false)
            status:SetDesc("Stopped. Any withdraw request already sent may still finish.")
            return
        end
        local startChestWorker
        startChestWorker=function()
        task.spawn(function()
            local ok,err=xpcall(function()
                local remote=chestRemote()
                local lastRequested=setmetatable({}, {__mode="k"})
                local total,rejected,chests,lastResult=0,0,0,nil
                status:SetDesc("Scanning your island for large industrial chests...")
                while running and generation==token do
                    local blocks=ownBlockFolder()
                    assert(blocks,"Your island Blocks folder was not found.")
                    local chests={}
                    local _,_,playerRoot=getCharacter()
                    assert(playerRoot,"Wait for your character before starting chest pickup.")
                    for _,block in ipairs(blocks:GetChildren()) do
                        if block.Name=="chestLargeIndustrialIO" and block:FindFirstChild("Contents") then
                            local part=chestPart(block)
                            local distance=part and (playerRoot.Position-part.Position).Magnitude or math.huge
                            if not nearbyOnly or distance<=nearbyRange then
                                table.insert(chests,{block=block,distance=distance})
                            end
                        end
                    end
                    table.sort(chests,function(a,b) return a.distance<b.distance end)
                    local found=#chests
                    for chestIndex,entry in ipairs(chests) do
                        if not running or generation~=token then break end
                        local chest=entry.block
                        if not nearbyOnly and not moveToChest(chest,chestIndex,found,token) then break end
                        local contents=chest:FindFirstChild("Contents")
                        local confirmedThisChest,rejectedThisChest=0,0
                        if contents then
                            for _,item in ipairs(contents:GetChildren()) do
                                if not running or generation~=token then break end
                                local attempt=0
                                while running and generation==token and item.Parent==contents do
                                    attempt=attempt+1
                                    local amountOk,amount=pcall(amountOf,item)
                                    if not amountOk then
                                        rejected=rejected+1
                                        rejectedThisChest=rejectedThisChest+1
                                        lastResult="Could not read "..item.Name.." stack; retrying"
                                        status:SetDesc(lastResult.." on chest "..chestIndex.." / "..found.." (attempt "..attempt..").")
                                        task.wait(0.5)
                                    elseif lastRequested[item]==amount then
                                        break
                                    else
                                        local inventoryBefore=inventoryAmount(item.Name)
                                        local invoked,response=pcall(function()
                                            return remote:InvokeServer({
                                                chest=chest,
                                                player_tracking_category="join_from_web",
                                                amount=amount,
                                                tool=item,
                                                action="withdraw",
                                            })
                                        end)
                                        local wasRejected=not invoked or response==false
                                            or (type(response)=="table" and response.success==false)
                                        if wasRejected then
                                            rejected=rejected+1
                                            rejectedThisChest=rejectedThisChest+1
                                            lastResult="Server rejected "..item.Name.." × "..amount.."; retrying same stack"
                                            status:SetDesc(lastResult.." (attempt "..attempt..").")
                                            task.wait(0.5)
                                        else
                                            status:SetDesc("Requested "..item.Name.." × "..amount.." from chest "..chestIndex.." / "..found.."; waiting for transfer...")
                                            local changed=false
                                            for _=1,10 do
                                                if not running or generation~=token then break end
                                                local amountValue=item:FindFirstChild("Amount")
                                                if item.Parent~=contents or not item.Parent
                                                    or (amountValue and (tonumber(amountValue.Value) or amount)<amount)
                                                    or inventoryAmount(item.Name)>inventoryBefore then
                                                    changed=true
                                                    break
                                                end
                                                task.wait(0.1)
                                            end
                                            if changed then
                                                total=total+1
                                                confirmedThisChest=confirmedThisChest+1
                                                lastRequested[item]=amount
                                                lastResult="Confirmed "..item.Name.." × "..amount
                                                local amountValue=item:FindFirstChild("Amount")
                                                local remaining=amountValue and tonumber(amountValue.Value)
                                                if item.Parent==contents and remaining and remaining<amount then
                                                    lastRequested[item]=nil
                                                    task.wait(0.1)
                                                else
                                                    break
                                                end
                                            else
                                                rejected=rejected+1
                                                rejectedThisChest=rejectedThisChest+1
                                                lastRequested[item]=nil
                                                lastResult="No transfer confirmed for "..item.Name.." × "..amount.."; retrying same stack"
                                                status:SetDesc(lastResult.." (attempt "..attempt..").")
                                                task.wait(0.5)
                                            end
                                            local pause=tonumber(delaySeconds) or 0
                                            if pause>0 then task.wait(pause) end
                                        end
                                    end
                                end
                            end
                        end
                        if confirmedThisChest>0 or rejectedThisChest>0 then
                            status:SetDesc("Chest "..chestIndex.." / "..found..": "..confirmedThisChest.." stack transfer(s) confirmed; "..rejectedThisChest.." retry attempt(s).")
                        end
                    end
                    if not running or generation~=token then break end
                    if found==0 then
                        status:SetDesc(nearbyOnly
                            and ("No large industrial chests within "..nearbyRange.." studs.")
                            or "No chestLargeIndustrialIO chests found on your island.")
                    else
                        status:SetDesc((nearbyOnly and ("Swept "..found.." nearby chest(es); ") or ("Watching "..found.." large industrial chest(es); "))
                            ..total.." confirmed stack(s), "..rejected.." rejected/retrying. "..tostring(lastResult or "Turn off to stop."))
                    end
                    task.wait(1)
                end
            end,debug.traceback)
            if not ok and generation==token then
                setChestNoclip(false)
                status:SetDesc("Chest scan error; keeping Auto on and retrying: "..tostring(err))
                warn("[RoSnipe Chest Pickup] Continuing after error: "..tostring(err))
                task.wait(1)
                if running and generation==token then startChestWorker() end
            end
        end)
        end
        startChestWorker()
    end)
    stopChestPickup=function(releaseHover)
        generation=generation+1
        running=false
        setChestNoclip(false)
        if releaseHover then releaseChestHover() end
        if toggle.Value then toggle:SetValue(false) end
    end
end
installChestPickup()

-- Totem upgrades combine the broad crop/rock mapping from Ashlux's module
-- with progress-confirmed requests from newer public Islands scripts.
local function installTotemUpgrade()
    local section = Auto:AddSection("TOTEM UPGRADER")
    local status = Auto:AddParagraph({
        Title = "Totem Upgrade Status",
        Content = "Off. Select a totem, stat, and target level.",
    })
    local cropTotems = {
        "totemPineapple", "totemStarfruit", "totemGrape", "totemOnion", "totemMelon",
        "totemRedBerryBush", "totemBlackberryBush", "totemBlueberryBush", "totemCarrot",
        "totemTomato", "totemWheat", "totemDragonfruit", "totemSpinach", "totemRadish",
        "totemPumpkin", "totemPotato",
    }
    local rockTotems = {
        "totemTest", "totemObsidian", "totemGranite", "totemClay", "totemStone",
        "totemSlate", "totemAquamarine", "totemMarble", "totemSandstoneRed",
        "totemIron", "totemDiorite", "totemAndesite", "totemSandstone", "totemCoal",
    }
    local totemNames = { "All Totems" }
    local cropSet = {}
    local knownTotems = {}
    for _, name in ipairs(cropTotems) do cropSet[name] = true; knownTotems[name] = true; table.insert(totemNames, name) end
    for _, name in ipairs(rockTotems) do knownTotems[name] = true; table.insert(totemNames, name) end
    table.sort(totemNames, function(a, b)
        if a == "All Totems" or b == "All Totems" then return a == "All Totems" and b ~= "All Totems" end
        return a < b
    end)

    local selectedTotem, selectedStat, targetLevel = "totemWheat", "All Stats", 25
    local running, generation = false, 0
    local changingToggle = false
    local totemDropdown = section:AddDropdown("TotemUpgradeTarget", {
        Title = "Totem", Values = totemNames, Default = selectedTotem, Multi = false,
    })
    totemDropdown:OnChanged(function(value) selectedTotem = value end)
    local statDropdown = section:AddDropdown("TotemUpgradeStat", {
        Title = "Upgrade", Values = { "All Stats", "utility", "efficiency", "quality" },
        Default = selectedStat, Multi = false,
    })
    statDropdown:OnChanged(function(value) selectedStat = value end)
    section:AddSlider("TotemUpgradeLevel", {
        Title = "Target Level", Default = targetLevel, Min = 1, Max = 53, Rounding = 0,
        Callback = function(value) targetLevel = math.floor(tonumber(value) or 25) end,
    })
    local toggle = section:AddToggle("AutoUpgradeTotems", {
        Title = "Auto Upgrade Totems", Description = "Waits for each UpgradeProgress value to change before continuing.",
        Default = false,
    })

    local function setStatus(message)
        if state.running then status:SetDesc(message) end
    end
    local function ownBlocks()
        local islands = workspace:FindFirstChild("Islands")
        for _, island in ipairs(islands and islands:GetChildren() or {}) do
            local owners = island:FindFirstChild("Owners")
            local blocks = island:FindFirstChild("Blocks")
            if owners and blocks and owners:FindFirstChild(tostring(LocalPlayer.UserId)) then
                return blocks
            end
        end
    end
    local function totemCategory(totemName)
        return cropSet[totemName] and "totem_crop" or "totem_rock"
    end
    local function progressValue(totem, stat)
        local progress = totem:FindFirstChild("UpgradeProgress")
        local value = progress and progress:FindFirstChild(stat)
        assert(value and value:IsA("ValueBase"), "Missing UpgradeProgress." .. stat .. " on " .. totem.Name)
        return value
    end
    local function getUpgradeRemote()
        local node = ReplicatedStorage
        for _, name in ipairs({ "rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged" }) do
            node = node and node:FindFirstChild(name)
        end
        local remote = node and node:FindFirstChild("UpgradeBlock")
        assert(remote and remote:IsA("RemoteFunction"), "UpgradeBlock remote not found.")
        return remote
    end
    local function findTotems(blocks)
        local found = {}
        for _, block in ipairs(blocks:GetChildren()) do
            if knownTotems[block.Name] and block:FindFirstChild("UpgradeProgress")
                and (selectedTotem == "All Totems" or block.Name == selectedTotem) then
                local part = block:IsA("BasePart") and block or block:FindFirstChildWhichIsA("BasePart", true)
                if part then table.insert(found, { block = block, part = part }) end
            end
        end
        local _, _, root = getCharacter()
        if root then
            table.sort(found, function(a, b)
                return (root.Position - a.part.Position).Magnitude < (root.Position - b.part.Position).Magnitude
            end)
        end
        return found
    end
    local function current(token)
        return state.running and running and generation == token
    end
    local function upgradeStat(remote, entry, stat, token)
        local block = entry.block
        local progress = progressValue(block, stat)
        while current(token) and block.Parent and progress.Value < targetLevel do
            local _, _, root = getCharacter()
            if not root then setStatus("Waiting for your character to spawn..."); task.wait(0.5); continue end
            if (root.Position - entry.part.Position).Magnitude > 10 then
                state.totemDestination = entry.part.Position + Vector3.new(0, 5, 0)
                setStatus("Moving beside " .. block.Name .. " to upgrade " .. stat .. "...")
                local moveDeadline = os.clock() + 20
                repeat
                    if not current(token) then return end
                    task.wait(0.1)
                    _, _, root = getCharacter()
                until root and (root.Position - entry.part.Position).Magnitude <= 10 or os.clock() >= moveDeadline
                state.totemDestination = nil
                assert(root and (root.Position - entry.part.Position).Magnitude <= 10,
                    "Could not reach " .. block.Name .. " within 10 studs.")
            end

            local confirmed = false
            for attempt = 1, 3 do
                if not current(token) or not block.Parent or progress.Value >= targetLevel then
                    confirmed = progress.Value >= targetLevel
                    break
                end
                local before = progress.Value
                local invoked, result = pcall(function()
                    return remote:InvokeServer(block, totemCategory(block.Name), stat)
                end)
                local rejected = not invoked or result == false or (type(result) == "table" and result.success == false)
                if not rejected then
                    setStatus(block.Name .. " / " .. stat .. ": request " .. attempt .. "/3 sent; waiting for progress...")
                    local deadline = os.clock() + 8
                    while current(token) and block.Parent and progress.Value == before and os.clock() < deadline do
                        task.wait(0.1)
                    end
                end
                if progress.Value > before then
                    confirmed = true
                    break
                end
                if attempt < 3 then
                    setStatus((rejected and "Request rejected" or "No progress yet") .. " for " .. block.Name
                        .. " / " .. stat .. "; retry " .. (attempt + 1) .. "/3 in 0.5s.")
                    task.wait(0.5)
                end
            end
            if not current(token) then return end
            assert(confirmed,
                "No progress for " .. block.Name .. " / " .. stat .. " after 3 attempts. Check upgrade materials, totem range, and current game version.")
            setStatus(block.Name .. " / " .. stat .. ": confirmed " .. progress.Value .. " / " .. targetLevel .. ".")
        end
    end

    local function start()
        generation = generation + 1
        local token = generation
        running = true
        state.totemUpgrade = true
        if stopAirWalk then stopAirWalk("Stopped: totem upgrade enabled.") end
        state.totemDestination = nil
        -- Keep the shared movement controller from fighting another active farm.
        if stopAutoBuild then stopAutoBuild("Stopped: totem upgrade enabled.") end
        if stopChestPickup then stopChestPickup(false) end
        if stopBossFarm then stopBossFarm() end
        if stopCutting then stopCutting() end
        if stopFarming then stopFarming() end
        stopCombat()
        task.spawn(function()
            local ok, err = xpcall(function()
                local remote = getUpgradeRemote()
                local stats = selectedStat == "All Stats" and { "utility", "efficiency", "quality" } or { selectedStat }
                while current(token) do
                    local blocks = ownBlocks()
                    assert(blocks, "Your island's Blocks folder was not found.")
                    local totems = findTotems(blocks)
                    if #totems == 0 then
                        setStatus("No matching owned totems with UpgradeProgress found. Scanning again...")
                    else
                        local changed = false
                        for _, entry in ipairs(totems) do
                            if not current(token) then break end
                            for _, stat in ipairs(stats) do
                                local progress = progressValue(entry.block, stat)
                                if progress.Value < targetLevel then
                                    changed = true
                                    upgradeStat(remote, entry, stat, token)
                                end
                            end
                        end
                        if not changed then
                            setStatus("All selected totems have reached the requested level.")
                            break
                        end
                    end
                    task.wait(0.5)
                end
            end, debug.traceback)
            local completedWhileActive = current(token)
            state.totemDestination = nil
            state.totemUpgrade = false
            running = false
            if completedWhileActive then
                changingToggle = true
                toggle:SetValue(false)
                changingToggle = false
            end
            if not ok then
                setStatus("Totem upgrade stopped: " .. tostring(err))
            elseif completedWhileActive then
                setStatus("All selected totems have reached the requested level.")
            end
        end)
    end
    stopTotemUpgrade = function(message)
        generation = generation + 1
        running = false
        state.totemUpgrade = false
        state.totemDestination = nil
        if toggle.Value and not changingToggle then
            changingToggle = true
            toggle:SetValue(false)
            changingToggle = false
        end
        if message then setStatus(message) end
    end
    toggle:OnChanged(function(enabled)
        if enabled then
            start()
        elseif not changingToggle then
            stopTotemUpgrade("Stopped.")
        end
    end)
end
installTotemUpgrade()

-- Capture the game's normal recipe selection before implementing a bulk changer.
-- No guessed recipe IDs, replay, or remote requests are made by this recorder.
local function installCratePackerRecorder()
    local section = Auto:AddSection("T2 CRATE PACKER")
    local status = Auto:AddParagraph({Title="Crate Packer Status",
        Content="Select a T2 packer on your island, record, then change its recipe normally. Bulk changing needs the captured recipe request."})
    local selected, recording, selecting, tap, handler
    local lines, requests, replies, version, started = {}, 0, 0, 0, 0
    local filename = "islands-crate-packer-diagnostic.txt"
    local env = type(getgenv)=="function" and getgenv() or _G
    local mouse = LocalPlayer:GetMouse()
    local function message(text)
        if state.running then status:SetDesc(text) end
    end
    local function ownBlocks()
        local islands=workspace:FindFirstChild("Islands")
        for _,island in ipairs(islands and islands:GetChildren() or {}) do
            local owners,blocks=island:FindFirstChild("Owners"),island:FindFirstChild("Blocks")
            if owners and blocks and owners:FindFirstChild(tostring(LocalPlayer.UserId)) then return blocks end
        end
    end
    local function ownBlockOf(target)
        local blocks=ownBlocks()
        while target and target.Parent~=blocks do target=target.Parent end
        if target and blocks and target.Parent==blocks then return target end
    end
    local function show(value,depth,seen)
        depth,seen=depth or 0,seen or {}
        local kind=typeof(value)
        if kind=="Instance" then return value.ClassName..":"..value:GetFullName() end
        if kind=="string" then return string.format("%q",value:sub(1,240)) end
        if kind~="table" then return tostring(value):sub(1,240) end
        if seen[value] then return "<cycle>" end
        if depth>=5 then return "<table>" end
        seen[value]=true
        local out={}
        for k,v in pairs(value) do
            if #out>=24 then table.insert(out,"...");break end
            table.insert(out,show(k,depth+1,seen).."="..show(v,depth+1,seen))
        end
        seen[value]=nil;table.sort(out)
        return "{"..table.concat(out,", ").."}"
    end
    local function log(text)
        if #lines<240 then table.insert(lines,string.format("%.3f | %s",os.clock()-started,text)) end
    end
    local function snapshot()
        if not selected or selected.Parent~=ownBlocks() then return "Selected packer unavailable." end
        local out={"Block="..show(selected)}
        for k,v in pairs(selected:GetAttributes()) do table.insert(out,"Attribute "..k.."="..show(v)) end
        for i,child in ipairs(selected:GetDescendants()) do
            if i>160 then table.insert(out,"[Remaining descendants omitted]");break end
            if child:IsA("ValueBase") then
                table.insert(out,child:GetFullName().."="..show(child.Value))
            end
        end
        local part=selected:IsA("BasePart") and selected or selected:FindFirstChildWhichIsA("BasePart",true)
        local _,_,root=getCharacter()
        if part and root then table.insert(out,"Distance="..string.format("%.1f",(part.Position-root.Position).Magnitude)) end
        table.sort(out);return table.concat(out,"\n")
    end
    local function report()
        return "RoSnipe T2 crate packer recipe diagnostic v1\nPlaceId="..game.PlaceId.." PlaceVersion="..game.PlaceVersion
            .."\nPassive capture only; normal requests pass through unchanged.\nSelected="..(selected and selected.Name or "none")
            .."\nOutgoing="..requests.." Replies="..replies.."\n"..table.concat(lines,"\n")
    end
    local function save()
        assert(type(writefile)=="function","writefile unavailable; use Copy Recipe Report.")
        writefile(filename,report())
    end
    local function detach()
        if tap and tap.handler==handler then tap.handler=nil;tap.after=nil end
    end
    stopCratePackerRecorder=function(reason)
        selecting=false
        if not recording then detach();return end
        recording=false;version=version+1
        local ok,snap=pcall(snapshot);log("FINAL STATE\n"..(ok and snap or tostring(snap)))
        log(reason or "Stopped.");detach()
        local saved,err=pcall(save)
        message(saved and ("Saved "..filename..". Requests="..requests.."; send the report to finish the changer.")
            or ("Captured "..requests.." requests. Use Copy Recipe Report. "..tostring(err)))
    end
    local function containsSelected(value,depth,seen)
        if typeof(value)=="Instance" then return value==selected or value:IsDescendantOf(selected) end
        if type(value)~="table" or depth>=5 or seen[value] then return false end
        seen[value]=true
        local count=0
        for _,v in pairs(value) do
            count=count+1;if count>32 then break end
            if containsSelected(v,depth+1,seen) then seen[value]=nil;return true end
        end
        seen[value]=nil;return false
    end
    local function recipeFields(value,depth,seen)
        if type(value)~="table" or depth>=4 or seen[value] then return false end
        seen[value]=true;local count=0
        for k,v in pairs(value) do
            count=count+1;if count>32 then break end
            if type(k)=="string" and k:lower():find("recipe",1,true) then seen[value]=nil;return true end
            if recipeFields(v,depth+1,seen) then seen[value]=nil;return true end
        end
        seen[value]=nil;return false
    end
    local function installTap(net)
        assert(type(hookmetamethod)=="function" and type(getnamecallmethod)=="function",
            "This executor cannot capture namecalls. No recipe request was sent.")
        local key="RoSnipeCrateRecipeTapV1"
        tap=env[key]
        if type(tap)~="table" or not tap.installed then
            local shared,original={}
            local function wrapper(remote,...)
                local method=getnamecallmethod()
                local observe=shared.handler
                local ticket
                if observe and (method=="InvokeServer" or method=="FireServer") then
                    local ok,value=pcall(observe,remote,method,table.pack(...))
                    if ok then ticket=value end
                end
                if ticket and method=="InvokeServer" then
                    local result=table.pack(original(remote,...))
                    if shared.handler==observe and shared.after then pcall(shared.after,ticket,result) end
                    return table.unpack(result,1,result.n)
                end
                return original(remote,...)
            end
            if type(newcclosure)=="function" then wrapper=newcclosure(wrapper) end
            original=hookmetamethod(game,"__namecall",wrapper)
            assert(type(original)=="function","Namecall capture could not be installed.")
            shared.installed=true;env[key]=shared;tap=shared
        end
        handler=function(remote,method,args)
            if not state.running or not recording or requests>=40 or typeof(remote)~="Instance" then return end
            if not selected or selected.Parent~=ownBlocks() or not remote:IsDescendantOf(net) then return end
            local name=remote.Name:lower()
            if not containsSelected(args,0,{}) and not recipeFields(args,0,{})
                and not name:find("recipe",1,true) and not name:find("craft",1,true)
                and not name:find("packer",1,true) then return end
            requests=requests+1
            local ticket={id=requests,path=remote:GetFullName(),time=os.clock(),version=version}
            log("OUT #"..ticket.id.." "..method.." "..ticket.path.." "..show(args))
            return ticket
        end
        tap.handler=handler
        tap.after=function(ticket,result)
            if not state.running or not recording or ticket.version~=version then return end
            replies=replies+1
            log("REPLY #"..ticket.id.." "..ticket.path.." elapsed="..string.format("%.3f",os.clock()-ticket.time).." "..show(result))
        end
    end
    local function record()
        assert(not recording,"Already recording.")
        assert(selected and selected.Parent==ownBlocks(),"Click Select T2 Packer, then click the packer on your island first.")
        local net=netManaged()
        local initial=snapshot()
        selecting=false;version=version+1;local token=version
        started=os.clock();lines={};requests,replies=0,0
        installTap(net)
        recording=true
        log("INITIAL STATE\n"..initial)
        for _,remote in ipairs(net:GetChildren()) do
            local name=remote.Name:lower()
            if name:find("recipe",1,true) or name:find("craft",1,true) or name:find("packer",1,true) then
                log("REMOTE "..remote.ClassName.." "..remote.Name)
            end
        end
        pcall(save)
        message("Recording for 20 seconds. Open the selected T2 packer and choose a DIFFERENT recipe in the normal game menu.")
        task.spawn(function()
            local previous=initial
            for i=1,80 do
                task.wait(0.25)
                if not state.running or not recording or version~=token then return end
                local ok,current=pcall(snapshot)
                if ok and current~=previous then log("STATE CHANGE\n"..current);previous=current end
                if i%16==0 then pcall(save) end
            end
            stopCratePackerRecorder("20 seconds completed.")
        end)
    end
    local function guarded(fn)
        return function()
            local ok,err=pcall(fn)
            if not ok then message(tostring(err)) end
        end
    end
    section:AddButton({Title="Select T2 Packer (Click in World)",Callback=guarded(function()
        assert(not recording,"Stop recording before selecting another packer.")
        assert(ownBlocks(),"Your island is not loaded.")
        selecting=true;message("Click your Tier 2 crate packer in the world. Right Shift can hide this window.")
    end)})
    table.insert(connections,UserInputService.InputBegan:Connect(function(input,processed)
        if not state.running or not selecting or processed or input.UserInputType~=Enum.UserInputType.MouseButton1 then return end
        local block=ownBlockOf(mouse.Target)
        if not block then message("Click a block on your own island.");return end
        local name=block.Name:lower()
        if not name:find("crate",1,true) and not name:find("pack",1,true) then
            message("That block is "..block.Name..". Click your T2 crate packer.");return
        end
        selecting=false;selected=block
        message("Selected "..block.Name..". Record, then change its recipe normally.")
    end))
    section:AddButton({Title="Record Recipe Change (20s)",Callback=guarded(record)})
    section:AddButton({Title="Stop & Save Recipe Report",Callback=guarded(function() stopCratePackerRecorder("Stopped by user.") end)})
    section:AddButton({Title="Copy Recipe Report",Callback=guarded(function()
        assert(#lines>0,"Record a recipe change first.")
        assert(type(setclipboard)=="function","Clipboard unavailable; use Save Recipe Report.")
        setclipboard(report());message("Recipe report copied.")
    end)})
    section:AddButton({Title="Save Recipe Report",Callback=guarded(function()
        assert(#lines>0,"Record a recipe change first.")
        save();message("Saved "..filename)
    end)})
end
installCratePackerRecorder()


-- Auto Build: adapted from the original Block Printer, with local preview state.
local function installAutoBuild()
    local build = { speed = 10, nearbyFirst = true, travelSpeed = 25, teleport = true, moveNear = false, autoReach = true, useRadius = false, radius = 85,
        retryPasses = 4, showHUD = true, noclip = true, paused = false, saveName = "mybuild", collision = false, records = {},
        version = 0, busy = false, mode = nil, file = "Template", folder = "RoSnipe/Schematica", loadNearPlayer = true, events = {}, actions = {} }
    local function trace(kind, message)
        table.insert(build.events, {time=os.clock(), kind=kind, message=tostring(message)})
        if #build.events > 40 then table.remove(build.events, 1) end
    end
    local function traceback(err)
        return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err)
    end
    local MAX_BLOCKS = 20000
    local buildConnections = {}
    local function connect(signal, fn)
        local connection = signal:Connect(fn)
        table.insert(buildConnections, connection)
        return connection
    end
    local Status = AutoBuild:AddParagraph({ Title = "Build Status", Content = "Choose a file in Build Files, load and position it in Ghost Preview, then BUILD HERE." })
    local Counts = GhostPreview:AddParagraph({ Title = "Selection / Preview", Content = "No corners selected." })
    local GhostStatus = GhostPreview:AddParagraph({Title="Ghost Status",Content="Load a file to show its preview."})
    local FileStatus = BuildFiles:AddParagraph({Title="File Status",Content="Select a build file or save an island selection."})
    local DestroyStatus
    local function status(message)
        build.lastStatus = tostring(message)
        trace("status", message)
        if state.running then Status:SetDesc(message); GhostStatus:SetDesc(message); FileStatus:SetDesc(message) end
        if state.running and DestroyStatus then DestroyStatus:SetDesc(message) end
    end
    local objects = Instance.new("Folder")
    objects.Name = "RoSnipeBuildPreview"
    objects.Parent = workspace
    local preview = Instance.new("Model")
    preview.Name = "Blocks"
    preview.Parent = objects
    local box = Instance.new("Part")
    box.Name = "Selection"
    box.Anchored, box.CanCollide, box.CanTouch, box.CanQuery = true, false, false, false
    box.Transparency = 1
    box.Size = Vector3.new(3, 3, 3)
    box.Parent = objects
    local outline = Instance.new("SelectionBox")
    outline.Color3 = Color3.fromRGB(255, 140, 185)
    outline.LineThickness = 0.04
    outline.Parent = objects
    local handles = Instance.new("Handles")
    handles.Color3 = outline.Color3
    handles.Visible = false
    handles.Parent = LocalPlayer:WaitForChild("PlayerGui")
    local mouse = LocalPlayer:GetMouse()
    local originalFilter = mouse.TargetFilter
    local pendingRequest
    local placeRemote, placeKey, placeHash
    -- Read-only snapshot for rosnipe-diagnostic.client.luau. Never exposes an
    -- action runner: diagnostics cannot place/destroy blocks or trigger buttons.
    local debugEnvironment = type(getgenv)=="function" and getgenv() or _G
    local debugBridge = { version = "auto-build-diagnostics-v1" }
    debugBridge.snapshot = function()
        local events, actions = {}, {}
        for i, event in ipairs(build.events) do
            events[i] = {time=event.time, kind=event.kind, message=event.message}
        end
        for i, title in ipairs(build.actions) do actions[i]=title end
        return {
            running=state.running, busy=build.busy, paused=build.paused, retryPasses=build.retryPasses, useRadius=build.useRadius, radius=build.radius,
            showHUD=build.showHUD, noclip=build.noclip, hasLastBuild=build.lastBuild~=nil, mode=build.mode or "none", generation=build.version,
            file=build.file, folder=build.folder, records=#build.records, status=build.lastStatus or "Ready",
            first=tostring(build.first), last=tostring(build.last), targetIsland=build.blocks and build.blocks.Parent and build.blocks.Parent.Name or "none",
            pendingRequest=pendingRequest and not pendingRequest.done or false,
            placeRemote=placeRemote and placeRemote:GetFullName() or "unresolved", hashResolved=placeKey~=nil and placeHash~=nil,
            handleMode=build.handleMode or "none", handlesVisible=handles.Visible, handlesAdornee=handles.Adornee and handles.Adornee:GetFullName() or "none",
            minimized=Window.Minimized, speed=build.speed, nearbyFirst=build.nearbyFirst, travelSpeed=build.travelSpeed, teleport=build.teleport, autoReach=build.autoReach, previewCollision=build.collision, loadNearPlayer=build.loadNearPlayer,
            actions=actions, events=events,
        }
    end
    debugEnvironment.RoSnipeBuildDebug = debugBridge
    local function finite(n) return type(n) == "number" and n == n and math.abs(n) < 1e8 end
    local function snap(n) return math.floor(n / 3 + 0.5) * 3 end
    local function snapVector(v) return Vector3.new(snap(v.X), snap(v.Y), snap(v.Z)) end
    local function blockPart(block)
        if block:IsA("BasePart") then return block end
        local root = block:FindFirstChild("Root")
        if root and root:IsA("BasePart") then return root end
        if block:IsA("Model") and block.PrimaryPart then return block.PrimaryPart end
        return block:FindFirstChildWhichIsA("BasePart", true)
    end
    local function ownBlocks()
        if build.blocks and build.blocks:IsDescendantOf(workspace) then return build.blocks end
        local islands = workspace:FindFirstChild("Islands")
        if islands then
            for _, island in ipairs(islands:GetChildren()) do
                local owners = island:FindFirstChild("Owners")
                local blocks = island:FindFirstChild("Blocks")
                if blocks and owners and owners:FindFirstChild(tostring(LocalPlayer.UserId)) then
                    build.blocks = blocks
                    return blocks
                end
            end
        end
        error("Select a block on the target island first.", 0)
    end
    -- A compact materials panel remains visible while the main window is hidden.
    local bomGui = Instance.new("ScreenGui")
    bomGui.Name, bomGui.ResetOnSpawn, bomGui.Enabled = "RoSnipeBuildBlocks", false, false
    bomGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    local bomPanel = Instance.new("Frame")
    bomPanel.AnchorPoint = Vector2.new(1, 0.5)
    bomPanel.Position = UDim2.new(1, -20, 0.5, 0)
    bomPanel.Size = UDim2.fromOffset(336, 390)
    bomPanel.BorderSizePixel = 0
    bomPanel.Parent = bomGui
    local round = Instance.new("UICorner")
    round.CornerRadius = UDim.new(0, 14)
    round.Parent = bomPanel
    local function bomCard(name, y, height)
        local card = Instance.new("Frame")
        card.Name = name
        card.Position = UDim2.fromOffset(12, y)
        card.Size = height
        card.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        card.BorderSizePixel = 0
        card.Parent = bomPanel
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = card
        return card
    end
    local bomSummary = bomCard("SummaryCard", 48, UDim2.new(1, -24, 0, 120))
    local bomMaterials = bomCard("MaterialsCard", 178, UDim2.new(1, -24, 1, -190))
    local function bomLabel(parent, y, height, size)
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Position = UDim2.fromOffset(14, y)
        label.Size = UDim2.new(1, -28, 0, height)
        label.Font = Enum.Font.Gotham
        label.TextSize = size
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Top
        label.TextWrapped = true
        label.TextColor3 = Color3.fromRGB(53, 42, 49)
        label.Parent = parent
        return label
    end
    local bomTitle = bomLabel(bomPanel, 13, 24, 20)
    bomTitle.Name = "Title"
    bomTitle.Text, bomTitle.Font = "Blocks", Enum.Font.GothamBold
    local bomProgress = bomLabel(bomSummary, 12, 24, 17)
    bomProgress.Name = "Progress"
    bomProgress.Font = Enum.Font.GothamBold
    local bomCurrent = bomLabel(bomSummary, 42, 34, 13)
    bomCurrent.Name = "Current"
    local bomNote = bomLabel(bomSummary, 82, 30, 11)
    bomNote.Name = "Note"
    bomNote.TextColor3 = Color3.fromRGB(119, 103, 113)
    local bomMaterialsTitle = bomLabel(bomMaterials, 12, 18, 11)
    bomMaterialsTitle.Text = "MATERIALS"
    bomMaterialsTitle.Font = Enum.Font.GothamBold
    bomMaterialsTitle.TextColor3 = Color3.fromRGB(149, 83, 112)
    local bomScroll = Instance.new("ScrollingFrame")
    bomScroll.Position = UDim2.fromOffset(14, 38)
    bomScroll.Size = UDim2.new(1, -28, 1, -50)
    bomScroll.BackgroundTransparency, bomScroll.BorderSizePixel = 1, 0
    bomScroll.ScrollBarThickness = 4
    bomScroll.Parent = bomMaterials
    local bomRows = Instance.new("TextLabel")
    bomRows.Name = "Materials"
    bomRows.BackgroundTransparency = 1
    bomRows.Font, bomRows.TextSize = Enum.Font.Gotham, 13
    bomRows.LineHeight = 1.6
    bomRows.TextColor3 = Color3.fromRGB(53, 42, 49)
    bomRows.TextXAlignment, bomRows.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
    bomRows.Parent = bomScroll
    local bomClose = Instance.new("TextButton")
    bomClose.Text, bomClose.TextSize, bomClose.BackgroundTransparency = "×", 22, 1
    bomClose.Size = UDim2.fromOffset(28, 28)
    bomClose.Position = UDim2.new(1, -34, 0, 8)
    bomClose.Parent = bomPanel
    connect(bomClose.MouseButton1Click, function() bomGui.Enabled=false end)
    local function paintBOM()
        bomPanel.BackgroundColor3 = windowPaint.BackgroundColor3
        bomPanel.BackgroundTransparency = windowPaint.BackgroundTransparency
        bomScroll.ScrollBarImageColor3 = Color3.fromRGB(214, 148, 178)
        for _, label in ipairs({bomTitle,bomClose}) do
            label.TextColor3 = KillLabel.TextColor3
        end
    end
    connect(windowPaint:GetPropertyChangedSignal("BackgroundColor3"), paintBOM)
    connect(KillLabel:GetPropertyChangedSignal("TextColor3"), paintBOM)
    paintBOM()
    local function newBOM(records)
        local report = {records=records, total=#records, placed=0, sent=0, byName={}, names={}, phase="Ready", existing=0}
        for _, record in ipairs(records) do
            local row = report.byName[record.name]
            if not row then
                row={total=0,placed=0}
                report.byName[record.name]=row
                table.insert(report.names,record.name)
            end
            row.total=row.total+1
        end
        table.sort(report.names)
        return report
    end
    local function renderBOM()
        local report=build.bom
        if not report then
            bomProgress.Text="No blocks selected"
            bomCurrent.Text="Load/clone a build, or select corners and hold a block."
            bomNote.Text=""
            bomRows.Text=""
            return
        end
        bomProgress.Text=report.started and ("Placed: "..report.placed.." / "..report.total) or ("Total: "..report.total.." blocks")
        bomCurrent.Text=report.phase..(report.currentName and (": "..report.currentName) or "")
        bomNote.Text=report.started and ("Verified in the island • "..report.sent.." requests sent"
            ..(report.existing>0 and ("\nIncludes "..report.existing.." already present") or "")) or "Materials required"
        local rows={}
        for _, name in ipairs(report.names) do
            local row=report.byName[name]
            table.insert(rows,name.."  "..(report.started and (row.placed.." / "..row.total) or ("× "..row.total)))
        end
        bomRows.Text=table.concat(rows,"\n")
        bomRows.Size=UDim2.new(1,-8,0,math.max(24,#rows*23))
        bomScroll.CanvasSize=UDim2.fromOffset(0,#rows*23)
    end
    local function refreshPreviewBOM()
        if not build.busy then build.bom=newBOM(build.records);renderBOM() end
    end
    local function placementKey(position, name)
        return string.format("%.1f,%.1f,%.1f:%s",position.X,position.Y,position.Z,name)
    end
    local function samplePlaced(report)
        local blocks=ownBlocks()
        local available={}
        for _, block in ipairs(blocks:GetChildren()) do
            local part=blockPart(block)
            if part then
                local key=placementKey(part.Position,block.Name)
                available[key]=(available[key] or 0)+1
            end
        end
        report.placed=0
        local missing={}
        for _, row in pairs(report.byName) do row.placed=0 end
        for _, record in ipairs(report.records) do
            local key=placementKey(record.cf.Position,record.name)
            if (available[key] or 0)>0 then
                available[key]=available[key]-1
                report.placed=report.placed+1
                report.byName[record.name].placed=report.byName[record.name].placed+1
            else
                table.insert(missing,record)
            end
        end
        return missing
    end
    local function bounds()
        assert(build.first and build.last, "Set both selection corners first.")
        local a, b = build.first, build.last
        return Vector3.new(math.min(a.X,b.X),math.min(a.Y,b.Y),math.min(a.Z,b.Z)),
            Vector3.new(math.max(a.X,b.X),math.max(a.Y,b.Y),math.max(a.Z,b.Z))
    end
    local function selectionCount()
        local low, high = bounds()
        local size = (high - low) / 3
        return (math.floor(size.X+0.01)+1)*(math.floor(size.Y+0.01)+1)*(math.floor(size.Z+0.01)+1)
    end
    local function redraw()
        local text = "Preview: " .. #build.records .. " blocks"
        if build.first and build.last then
            local low, high = bounds()
            box.Size = high - low + Vector3.new(3,3,3)
            box.CFrame = CFrame.new((low+high)/2)
            outline.Adornee = box
            local count = selectionCount()
            text = "Selection: " .. count .. " cells | " .. text .. " | minimum " .. math.ceil(count/build.speed) .. " seconds to print"
        else
            outline.Adornee = nil
        end
        Counts:SetDesc(text)
    end
    local function ensureIdle()
        assert(not build.busy, "Stop the current build before editing the selection or preview.")
        assert(state.running, "RoSnipe is unloaded.")
    end
    local function clearPreview()
        handles.Visible = false
        handles.Adornee = nil
        preview:ClearAllChildren()
        build.records = {}
        refreshPreviewBOM()
        redraw()
    end
    local function showPreview(records)
        assert(#records > 0 and #records <= MAX_BLOCKS, "Preview must contain 1–20000 blocks.")
        -- Construct off-workspace first; a bad template must not erase a good preview.
        local staged = Instance.new("Model")
        local ok, err = pcall(function()
            local assets = ReplicatedStorage:FindFirstChild("Blocks")
            for _, record in ipairs(records) do
                local template = assets and assets:FindFirstChild(record.name)
                local root = template and blockPart(template)
                local part = root and root:Clone() or Instance.new("Part")
                part.Parent = staged
                for _, descendant in ipairs(part:GetDescendants()) do
                    if descendant:IsA("LuaSourceContainer") then descendant:Destroy() end
                end
                if not root then part.Size = Vector3.new(3,3,3) end
                part.Name, part.CFrame = record.name, record.cf
                part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, build.collision, false, false
                part.Transparency, part.LocalTransparencyModifier = 0.45, 0
                for _, descendant in ipairs(part:GetDescendants()) do
                    if descendant:IsA("BasePart") then
                        descendant.Anchored, descendant.CanCollide, descendant.CanTouch, descendant.CanQuery = true, false, false, false
                        descendant.Transparency, descendant.LocalTransparencyModifier = 0.45, 0
                    end
                end
                record.preview = part
            end
        end)
        if not ok then staged:Destroy(); error(err, 0) end
        clearPreview()
        for _, part in ipairs(staged:GetChildren()) do part.Parent = preview end
        staged:Destroy()
        build.records = records
        refreshPreviewBOM()
        redraw()
    end
    local function previewAnchor()
        assert(#build.records > 0, "Clone blocks or load a file first.")
        return build.records[1].cf.Position
    end
    local function transformPreview(transform)
        ensureIdle()
        for _, record in ipairs(build.records) do
            record.cf = transform * record.cf
            record.preview.CFrame = record.cf
        end
        refreshPreviewBOM()
        redraw()
    end
    local function movePreview(position)
        local anchor = previewAnchor()
        transformPreview(CFrame.new(snapVector(position-anchor)))
    end
    local function selectedBlocks()
        local low, high = bounds()
        local found = {}
        for _, block in ipairs(ownBlocks():GetChildren()) do
            local part = blockPart(block)
            if part then
                local p = part.Position
                if p.X >= low.X-0.1 and p.X <= high.X+0.1 and p.Y >= low.Y-0.1 and p.Y <= high.Y+0.1
                    and p.Z >= low.Z-0.1 and p.Z <= high.Z+0.1 then
                    table.insert(found, { block = block, part = part, name = block.Name, cf = part.CFrame })
                end
            end
        end
        assert(#found <= MAX_BLOCKS, "Selection exceeds 20000 blocks; choose a smaller area.")
        table.sort(found, function(a,b)
            if a.cf.Y ~= b.cf.Y then return a.cf.Y < b.cf.Y end
            if a.cf.X ~= b.cf.X then return a.cf.X < b.cf.X end
            return a.cf.Z < b.cf.Z
        end)
        return found
    end
    local function serialize(records)
        local data = { Version = 1, Blocks = {} }
        for _, record in ipairs(records) do
            data.Blocks[record.name] = data.Blocks[record.name] or {}
            table.insert(data.Blocks[record.name], { C = {record.cf:GetComponents()}, upperBlock = record.upperBlock == true })
        end
        return data
    end
    local function deserialize(data)
        assert(type(data) == "table", "Invalid schematic file.")
        local records = {}
        local function add(name, c, upperBlock)
            assert(type(name)=="string" and name~="", "Invalid block type in schematic.")
            assert(type(c)=="table" and (#c==3 or #c==12), "Block position must have 3 or 12 numbers.")
            for _, n in ipairs(c) do assert(finite(n), "Invalid coordinate in schematic.") end
            assert(upperBlock==nil or type(upperBlock)=="boolean", "Invalid upperBlock flag.")
            table.insert(records, {name=name, cf=CFrame.new(table.unpack(c)), upperBlock=upperBlock==true})
            assert(#records<=MAX_BLOCKS, "Schematic exceeds 20000 blocks.")
        end
        if data.blocks ~= nil then
            -- Flare-style blueprints, verified against TrueHickory.json (1120 records).
            assert(type(data.blocks)=="table", "Invalid blocks field.")
            for _, entry in ipairs(data.blocks) do
                assert(type(entry)=="table", "Invalid blueprint entry.")
                add(entry.blockType, entry.cframe, entry.upperBlock)
            end
        else
            local groups = data.Blocks or data
            assert(type(groups)=="table", "Invalid Blocks field.")
            for name, entries in pairs(groups) do
                assert(type(entries)=="table", "Invalid block group.")
                for _, entry in ipairs(entries) do
                    assert(type(entry)=="table", "Invalid block entry.")
                    add(name, data.Blocks and entry.C or entry, data.Blocks and entry.upperBlock or nil)
                end
            end
        end
        table.sort(records, function(a,b)
            if a.cf.Y~=b.cf.Y then return a.cf.Y<b.cf.Y end
            if a.cf.X~=b.cf.X then return a.cf.X<b.cf.X end
            return a.cf.Z<b.cf.Z
        end)
        assert(#records>0, "Schematic is empty.")
        return records
    end
    local function positionLoadedPreview(records)
        if not build.loadNearPlayer then return end
        local _, _, root = getCharacter()
        assert(root, "Wait for your character, or disable Load Preview Near Me.")
        local look = root.CFrame.LookVector
        local forward = Vector3.new(look.X, 0, look.Z)
        forward = forward.Magnitude>0.01 and forward.Unit or Vector3.new(0,0,-1)
        local target = root.Position + forward*12
        -- Align to the target island's grid when a nearby block is available.
        local ok, blocks = pcall(ownBlocks)
        local anchor, distance = nil, 60
        if ok then
            for _, block in ipairs(blocks:GetChildren()) do
                local part = blockPart(block)
                if part and (part.Position-root.Position).Magnitude<distance then
                    anchor, distance = part.Position, (part.Position-root.Position).Magnitude
                end
            end
        end
        if anchor then
            target = anchor + snapVector(Vector3.new(target.X,anchor.Y+3,target.Z)-anchor)
        else
            target = snapVector(target)
        end
        local offset = target-records[1].cf.Position
        for _, record in ipairs(records) do record.cf=record.cf+offset end
    end
    local function safeFileName(name)
        assert(type(name) == "string" and name:match("^[%w _%.%-]+$") and not name:find("..",1,true), "Use a simple file name without folders or '..'.")
        return name
    end
    local function filePath() return build.folder .. "/" .. safeFileName(build.file) end
    local function ensureFolders()
        assert(type(isfolder)=="function" and type(makefolder)=="function", "Executor folder APIs are unavailable.")
        if build.folder == "RoSnipe/Schematica" then
            if not isfolder("RoSnipe") then makefolder("RoSnipe") end
            if not isfolder(build.folder) then makefolder(build.folder) end
        else
            assert(isfolder(build.folder), "Selected build folder is missing: " .. build.folder)
        end
    end
    -- Support the verified PlaceVersion 1246 sender (key 23, hash 24), plus the
    -- original 2024 layout. Never concatenate the current argument table at slot 25.
    local function resolvePlacement()
        local info = getinfo or (debug and debug.getinfo)
        local constants = getconstants or (debug and debug.getconstants)
        local protos = getprotos or (debug and debug.getprotos)
        assert(getgc and info and constants, "Executor is missing build hash lookup APIs.")
        local remote = netManaged():FindFirstChild("CLIENT_BLOCK_PLACE_REQUEST")
        assert(remote and remote:IsA("RemoteFunction"), "CLIENT_BLOCK_PLACE_REQUEST RemoteFunction not found.")
        local candidates = {}
        local function hasConstant(values, wanted)
            for _, value in pairs(values) do if value == wanted then return true end end
            return false
        end
        local function inspect(fn, depth)
            local ok, values = pcall(constants, fn)
            if ok and type(values)=="table" then
                local key, value
                if values[22]=="blockType" and type(values[23])=="string" and type(values[24])=="string"
                    and values[26]=="Client" and values[27]=="CLIENT_BLOCK_PLACE_REQUEST"
                    and values[28]=="Get" and values[29]=="CallServerAsync" then
                    key, value = values[23], values[24]
                elseif hasConstant(values,"CLIENT_BLOCK_PLACE_REQUEST") and type(values[23])=="string"
                    and type(values[25])=="string" and type(values[26])=="string" then
                    key, value = values[23], values[25]..values[26]
                end
                if key and key~="" and value~="" and key~="cframe" and key~="blockType" and key~="upperBlock" then
                    candidates[key .. "\0" .. value] = {key=key, value=value}
                end
            end
            if depth < 2 and type(protos)=="function" then
                local read, children = pcall(protos,fn)
                if read and type(children)=="table" then
                    for _, child in pairs(children) do inspect(child,depth+1) end
                end
            end
        end
        for _, fn in pairs(getgc(true)) do
            if type(fn)=="function" then
                local ok, details = pcall(info,fn)
                local source = ok and type(details)=="table" and (details.source or details.short_src)
                if type(source)=="string" and source:find("controllers.block.block-controller",1,true) then inspect(fn,0) end
            end
        end
        local match
        for _, candidate in pairs(candidates) do
            assert(not match, "Multiple placement hashes found. Save a Build Diagnostic.")
            match = candidate
        end
        assert(match, "Supported placement hash layout not found. Place one block manually, then Refresh Build Hash. If it still fails, Save Build Diagnostic.")
        placeRemote, placeKey, placeHash = remote, match.key, match.value
        status("Placement hash resolved from the current block controller.")
    end
    resolveCropPlacement = function()
        if not placeRemote or not placeRemote.Parent or not placeKey or not placeHash then resolvePlacement() end
        return placeRemote, placeKey, placeHash
    end
    local function saveDiagnostic()
        local info = getinfo or (debug and debug.getinfo)
        local constants = getconstants or (debug and debug.getconstants)
        local protos = getprotos or (debug and debug.getprotos)
        assert(getgc and info and constants, "Executor introspection APIs unavailable.")
        local lines = {"RoSnipe build diagnostic", "PlaceId="..game.PlaceId.." PlaceVersion="..game.PlaceVersion}
        local character=LocalPlayer.Character
        local equipped=character and character:FindFirstChildOfClass("Tool")
        table.insert(lines,"Equipped tool="..(equipped and equipped.Name or "none"))
        table.insert(lines,"Runtime="..HttpService:JSONEncode(debugBridge.snapshot()))
        local selected,records=pcall(selectedBlocks)
        table.insert(lines,selected and ("Selected real blocks="..#records) or ("Selection error="..tostring(records)))
        local visited,dumped={},0
        local function dump(fn, label, depth)
            if visited[fn] or dumped>=120 then return end
            visited[fn]=true;dumped=dumped+1
            table.insert(lines,label)
            local ok, values = pcall(constants,fn)
            if ok and type(values)=="table" then
                local keys={}
                for key in pairs(values) do if type(key)=="number" then table.insert(keys,key) end end
                table.sort(keys)
                for index, key in ipairs(keys) do
                    if index>160 then table.insert(lines,"[remaining constants omitted]");break end
                    local value=values[key]
                    table.insert(lines,"constant["..key.."]="..(type(value)=="string" and string.format("%q",value) or "<"..type(value)..">"))
                end
            end
            if depth<2 and type(protos)=="function" then
                local read, children=pcall(protos,fn)
                if read and type(children)=="table" then
                    for i, child in pairs(children) do dump(child,label..".proto["..tostring(i).."]",depth+1) end
                end
            end
        end
        for _, fn in pairs(getgc(true)) do
            if type(fn)=="function" then
                local ok, details=pcall(info,fn)
                local source=ok and type(details)=="table" and (details.source or details.short_src)
                if type(source)=="string" and (source:find("controllers.block.block-controller",1,true)
                    or source:find("pickaxe",1,true) or source:find("axe-tool",1,true) or source:find("gregsHammer",1,true)) then
                    dump(fn,(details.name or "unnamed").." | "..source,0)
                end
            end
        end
        assert(type(writefile)=="function", "writefile unavailable; cannot save diagnostic.")
        writefile("islands-build-diagnostic.txt", table.concat(lines,"\n"))
        status("Saved islands-build-diagnostic.txt in the executor workspace.")
    end
    local function stop(why, cleanup)
        build.version = build.version+1
        build.mode = nil
        build.paused = false
        if build.releaseMovement then build.releaseMovement() end
        handles.Visible = false
        if mouse.TargetFilter == objects then mouse.TargetFilter = originalFilter end
        if why then status(why) end
        if build.bom and build.busy then
            build.bom.phase, build.bom.currentName = "Stopped", nil
            renderBOM()
        end
        if cleanup then
            if debugEnvironment.RoSnipeBuildDebug == debugBridge then debugEnvironment.RoSnipeBuildDebug = nil end
            for _, c in ipairs(buildConnections) do c:Disconnect() end
            handles:Destroy()
            bomGui:Destroy()
            objects:Destroy()
        end
    end
    stopAutoBuild = stop
    local function stopFarms()
        if stopAirWalk then stopAirWalk("Stopped: auto build enabled.") end
        if stopTotemUpgrade then stopTotemUpgrade("Stopped: auto build enabled.") end
        if stopBossFarm then stopBossFarm() end
        if stopFarming then stopFarming() end
        farmToggle:SetValue(false)
        auraToggle:SetValue(false)
        stopCutting()
    end
    local LAST_BUILD_PATH = "RoSnipe/last-build.json"
    local function copyRecords(records)
        local copied={}
        for _,record in ipairs(records) do
            table.insert(copied,{name=record.name,cf=record.cf,upperBlock=record.upperBlock==true})
        end
        return copied
    end
    local function rememberBuild(records)
        local blocks=ownBlocks()
        build.lastBuild={records=copyRecords(records),island=blocks.Parent.Name,placeId=game.PlaceId}
        if type(writefile)=="function" and type(isfolder)=="function" and type(makefolder)=="function" then
            local ok,err=pcall(function()
                if not isfolder("RoSnipe") then makefolder("RoSnipe") end
                writefile(LAST_BUILD_PATH,HttpService:JSONEncode({Version=1,PlaceId=game.PlaceId,Island=blocks.Parent.Name,Build=serialize(records)}))
            end)
            if not ok then trace("Continue Last Build: memory only",err) end
        else
            trace("Continue Last Build","Saved for this session only; file APIs unavailable.")
        end
    end
    local function lastBuildRecords()
        if not build.lastBuild then
            assert(type(readfile)=="function","No last build in this session; readfile is unavailable.")
            local text=readfile(LAST_BUILD_PATH)
            assert(#text<=10*1024*1024,"Last build data exceeds 10 MB.")
            local data=HttpService:JSONDecode(text)
            assert(type(data)=="table" and not data.Cleared and data.Build,"No saved last build.")
            build.lastBuild={records=deserialize(data.Build),island=data.Island,placeId=data.PlaceId}
        end
        assert(build.lastBuild.placeId==game.PlaceId,"Last build belongs to a different game place.")
        assert(ownBlocks().Parent.Name==build.lastBuild.island,"Return to the island where the last build started.")
        return copyRecords(build.lastBuild.records)
    end
    local function clearLastBuild()
        ensureIdle()
        if type(isfile)=="function" and isfile(LAST_BUILD_PATH) then
            if type(delfile)=="function" then delfile(LAST_BUILD_PATH)
            else
                assert(type(writefile)=="function","Cannot clear the saved last-build file.")
                writefile(LAST_BUILD_PATH,HttpService:JSONEncode({Cleared=true}))
            end
        end
        build.lastBuild=nil
        status("Last build data cleared. Your files and placed blocks are unchanged.")
    end
    local function invoke(remote, payload, current, waitReady, beforeSend)
        assert(not pendingRequest or pendingRequest.done, "Previous build request is still waiting for the server.")
        if not waitReady() then return false end
        local request = {done=false}
        pendingRequest = request
        task.spawn(function()
            -- A pause/stop may happen before this scheduled call actually starts.
            if not waitReady() then request.cancelled=true;request.done=true;return end
            request.ok, request.result = pcall(function()
                -- Recheck reach after a pause, immediately before the actual call.
                if beforeSend and not beforeSend() then request.cancelled=true;return end
                if not waitReady() then request.cancelled=true;return end
                request.sentAt=os.clock()
                return remote:InvokeServer(payload)
            end)
            request.done = true
        end)
        while not request.done and current() do
            -- Travel can take longer than a remote reply. Start the network
            -- timeout only when InvokeServer actually starts.
            if request.sentAt and os.clock()-request.sentAt>=8 then break end
            task.wait(0.05)
        end
        if not current() or request.cancelled then return false end
        assert(request.done, "Build request timed out. Stop; wait for the server before retrying.")
        assert(request.ok, tostring(request.result))
        return true, request.result~=false
    end
    -- One batch owns the request guard until every dispatched call has returned,
    -- including when Stop is pressed. No travel or next job while calls linger.
    local function invokePlacementBatch(entries, current, waitReady, root, onSent)
        assert(not pendingRequest or pendingRequest.done,"Previous build request is still waiting for the server.")
        local batch={done=false,active=0,closed=false,calls={}}
        pendingRequest=batch
        local function finish()
            batch.done=batch.closed and batch.active==0
        end
        local function checkReplies()
            for _,call in ipairs(batch.calls) do
                if call.sentAt and not call.done and os.clock()-call.sentAt>=8 then
                    error("Placement request timed out. Stop; wait for the server before retrying.",0)
                end
                if call.done and call.error then error(call.error,0) end
            end
        end
        local ok,err=pcall(function()
            local nextSend=0
            for _,entry in ipairs(entries) do
                while current() and (batch.active>=3 or os.clock()<nextSend) do
                    checkReplies();task.wait(0.02)
                end
                if not waitReady() then break end
                checkReplies()
                local call={done=false}
                table.insert(batch.calls,call)
                batch.active=batch.active+1
                task.spawn(function()
                    local sentOk,sendError=pcall(function()
                        if not waitReady() then return end
                        -- Never move the character from a worker. Re-group an
                        -- unsent block if the character drifted outside reach.
                        if (root.Position-entry.record.cf.Position).Magnitude>28 then return end
                        call.sentAt=os.clock()
                        entry.sent=true
                        onSent(entry.record)
                        local reply=placeRemote:InvokeServer({[placeKey]=placeHash,cframe=entry.record.cf,
                            blockType=entry.record.name,upperBlock=entry.record.upperBlock==true})
                        if reply==false then trace("placement rejected",entry.record.name.."; will recheck next pass") end
                    end)
                    if not sentOk then call.error=tostring(sendError) end
                    call.done=true
                    batch.active=batch.active-1
                    finish()
                end)
                nextSend=os.clock()+1/math.clamp(build.speed,1,20)
            end
            batch.closed=true;finish()
            while current() and not batch.done do checkReplies();task.wait(0.02) end
            if current() then checkReplies() end
        end)
        batch.closed=true;finish()
        if not ok then error(err,0) end
        return current()
    end
    local function startJob(kind, records, instant, missingOnly)
        ensureIdle()
        assert(#records>0 and #records<=MAX_BLOCKS, kind=="place" and "Load a ghost preview or select 1–20000 blocks first."
            or "No real blocks selected. In Build Files, set both corners by clicking island blocks with the GUI hidden.")
        assert(not pendingRequest or pendingRequest.done, "Previous request is still pending.")
        local character, humanoid, root = getCharacter()
        assert(character, "Wait for your character.")
        local tool = character:FindFirstChildOfClass("Tool")
        if kind~="place" then
            local pickaxeNames={"woodPickaxe","stonePickaxe","diamondPickaxe","gildedSteelPickaxe",
                "ironPickaxe","opalPickaxe","voidMattock"}
            local function usable(item)
                return item:IsA("Tool") and (instant and item.Name=="gregsHammer"
                    or not instant and table.find(pickaxeNames,item.Name)~=nil)
            end
            if not tool or not usable(tool) then
                tool=nil
                local backpack=LocalPlayer:FindFirstChild("Backpack")
                if backpack then
                    for _,item in ipairs(backpack:GetChildren()) do
                        if usable(item) then tool=item;break end
                    end
                end
            end
            assert(tool,instant and "Greg's Hammer was not found in your inventory. Use Destroy Blocks [Beta] with a pickaxe."
                or "No pickaxe found in your character or Backpack. Put a pickaxe in your hotbar, then retry.")
        end
        if kind=="place" then rememberBuild(records) end
        stopFarms()
        if kind~="place" then
            if tool.Parent~=character then humanoid:EquipTool(tool) end
            assert(tool.Parent==character,"Could not equip "..tool.Name..". Equip it manually and retry.")
            status("Destroy starting: "..#records.." selected blocks | "..tool.Name.." | resolving block-hit hash...")
        end
        build.busy, build.paused, build.mode = true, false, nil
        handles.Visible = false
        local token = build.version
        local original = root.CFrame
        local frozen, movementConnection
        local holdPosition, moved = root.Position, false
        local function canMove()
            return build.teleport or build.moveNear or (kind=="place" and build.autoReach)
        end
        local savedCollisions={}
        local function releaseMovement()
            if movementConnection then movementConnection:Disconnect();movementConnection=nil end
            if frozen then frozen:Destroy();frozen=nil end
            for part,value in pairs(savedCollisions) do if part.Parent then part.CanCollide=value end end
            savedCollisions={}
        end
        build.releaseMovement=releaseMovement
        local report
        if kind=="place" then
            report=newBOM(records)
            report.started,report.phase=true,"Starting"
            build.bom=report
            bomGui.Enabled=build.showHUD
            renderBOM()
        end
        local function current()
            return state.running and build.version==token and LocalPlayer.Character==character and humanoid.Health>0
        end
        local function waitReady()
            while current() and build.paused do task.wait(0.1) end
            return current()
        end
        local function syncMovement()
            if not current() then releaseMovement();return end
            if build.noclip then
                for _,part in ipairs(character:GetDescendants()) do
                    if part:IsA("BasePart") then
                        if savedCollisions[part]==nil then savedCollisions[part]=part.CanCollide end
                        part.CanCollide=false
                    end
                end
            else
                for part,value in pairs(savedCollisions) do if part.Parent then part.CanCollide=value end end
                savedCollisions={}
            end
            if canMove() then
                if not frozen then
                    holdPosition=root.Position
                    frozen=Instance.new("BodyPosition")
                    frozen.Name="RoSnipeBuildHover"
                    frozen.MaxForce=Vector3.new(1e9,1e9,1e9)
                    frozen.P, frozen.D = 10000, 1000
                    frozen.Position=holdPosition
                    frozen.Parent=root
                end
                frozen.Position=holdPosition
            elseif frozen then frozen:Destroy();frozen=nil end
        end
        local function ensureReach(record)
            if not waitReady() then return false end
            local distance=(root.Position-record.cf.Position).Magnitude
            if distance<=24 or (not canMove() and distance<=30) then
                if canMove() then
                    syncMovement()
                    holdPosition=root.Position
                    if frozen then frozen.Position=holdPosition end
                end
                if not build.moveNear or (kind=="place" and build.nearbyFirst) then return true end
            end
            assert(canMove(),"Target out of reach ("..math.floor(distance).." studs). Enable Auto Reach Floating Blocks or Move To Build Position.")
            local destination=record.cf.Position+Vector3.new(0,10,0)
            local activeTime,stalledTime,lastStatus=0,0,-1
            local best=(root.Position-destination).Magnitude
            local travelLimit=math.max(30,best/math.max(build.travelSpeed,5)*3+10)
            trace("build movement","Travel to "..record.name.."; distance "..math.floor(distance))
            -- Small steps avoid a single long jump to a distant schematic cell.
            -- Progress uses observed positions after each physics step.
            while activeTime<travelLimit do
                if not waitReady() then return false end
                assert(canMove(),"Build movement disabled while travelling. Enable Auto Reach Floating Blocks or Move To Build Position.")
                syncMovement()
                local delta=destination-root.Position
                local remaining=delta.Magnitude
                if remaining<=2 then
                    holdPosition=root.Position
                    if frozen then frozen.Position=holdPosition end
                    task.wait(0.15)
                    if not waitReady() then return false end
                    if (root.Position-record.cf.Position).Magnitude<=24 then return true end
                end
                delta=destination-root.Position
                remaining=delta.Magnitude
                local step=math.min(remaining,math.clamp(build.travelSpeed,5,60)*0.05)
                holdPosition=remaining>0.001 and root.Position+delta.Unit*step or root.Position
                if frozen then frozen.Position=holdPosition end
                root.AssemblyLinearVelocity=Vector3.zero
                root.CFrame=CFrame.new(holdPosition)
                moved=true
                if activeTime-lastStatus>=1 then
                    status("Moving to "..record.name.." | "..math.floor((root.Position-record.cf.Position).Magnitude).." studs away")
                    lastStatus=activeTime
                end
                local elapsed=task.wait(0.05)
                elapsed=math.clamp(tonumber(elapsed) or 0.05,0.01,0.25)
                activeTime=activeTime+elapsed
                if not waitReady() then return false end
                local observed=(root.Position-destination).Magnitude
                if observed<best-0.25 then best=observed;stalledTime=0
                else stalledTime=stalledTime+elapsed end
                if stalledTime>=5 then
                    error("Build movement blocked or moved back for 5 seconds; "..math.floor((root.Position-record.cf.Position).Magnitude)
                        .." studs from "..record.name..". Enable Auto Noclip While Building and check for another movement script. No placement request sent for this block.",0)
                end
            end
            error("Build travel timed out before reaching "..record.name..". No placement request sent for this block.",0)
        end
        local function arrange(queue)
            local center=root.Position
            table.sort(queue,function(a,b)
                if build.useRadius then
                    local aNear=(a.cf.Position-center).Magnitude<=build.radius
                    local bNear=(b.cf.Position-center).Magnitude<=build.radius
                    if aNear~=bNear then return aNear end
                end
                if a.cf.Y~=b.cf.Y then return a.cf.Y<b.cf.Y end
                if a.cf.X~=b.cf.X then return a.cf.X<b.cf.X end
                return a.cf.Z<b.cf.Z
            end)
        end
        task.spawn(function()
            local ok,err=xpcall(function()
                if kind=="place" then
                    if not placeRemote or not placeRemote.Parent then resolvePlacement() end
                elseif not treeRemote or not treeRemote.Parent then resolveTreeCombat() end
                if not waitReady() then return end
                syncMovement()
                movementConnection=RunService.Heartbeat:Connect(syncMovement)
                local missing
                if report then
                    missing=samplePlaced(report)
                    report.existing=report.placed
                    renderBOM()
                    task.spawn(function()
                        while current() and build.busy and build.bom==report do
                            local sampled,sampleError=pcall(samplePlaced,report)
                            if not sampled then trace("BOM verification",sampleError) end
                            if state.running then renderBOM() end
                            task.wait(0.5)
                        end
                    end)
                end
                local requests,confirmed=0,0
                local function placeNearby(queue, pass)
                    local remaining={}
                    for i,record in ipairs(queue) do remaining[i]=record end
                    local emptyBatches=0
                    while waitReady() do
                        local entries,nearest,nearestDistance={},nil,math.huge
                        local center=root.Position
                        -- The pass is sorted bottom-up; keep that order inside
                        -- each local group so lower blocks are dispatched first.
                        for index,record in ipairs(remaining) do
                            if record then
                                local distance=(record.cf.Position-center).Magnitude
                                if distance<nearestDistance then nearest,nearestDistance=record,distance end
                                if distance<=28 and #entries<64 then
                                    table.insert(entries,{record=record,index=index})
                                end
                            end
                        end
                        if not nearest then return end
                        if #entries==0 then
                            if not ensureReach(nearest) then return end
                        else
                            -- Hold this spot until all calls for the group end.
                            if canMove() then
                                syncMovement();holdPosition=root.Position
                                if frozen then frozen.Position=holdPosition end
                            end
                            report.phase=pass==1 and "Placing nearby" or ("Retry "..(pass-1).." nearby")
                            if not invokePlacementBatch(entries,current,waitReady,root,function(record)
                                requests=requests+1;report.sent=requests;report.currentName=record.name
                            end) then return end
                            local sent=0
                            for _,entry in ipairs(entries) do
                                if entry.sent then remaining[entry.index]=false;sent=sent+1 end
                            end
                            emptyBatches=sent>0 and 0 or emptyBatches+1
                            assert(emptyBatches<3,"Character repeatedly moved out of range before placement. Stop other movement scripts, then retry.")
                            renderBOM()
                            status("Placed "..report.placed.." / "..report.total.." | nearby group: "..sent.." requests sent")
                        end
                    end
                end
                local passes=kind=="place" and (1+build.retryPasses) or 1
                local queue=kind=="place" and missing or records
                for pass=1,passes do
                    if not waitReady() or #queue==0 then break end
                    arrange(queue)
                    if kind=="place" and build.nearbyFirst then
                        placeNearby(queue,pass)
                    else
                        for index,record in ipairs(queue) do
                            if not waitReady() then break end
                            if kind~="place" then assert(tool.Parent==character,"Building tool changed; job stopped.") end
                            if report then
                                report.phase,report.currentName=pass==1 and "Placing" or ("Retry "..(pass-1)),record.name
                                renderBOM()
                            end
                            if kind=="place" then
                                local sent,accepted=invoke(placeRemote,{[placeKey]=placeHash,cframe=record.cf,blockType=record.name,upperBlock=record.upperBlock==true},current,waitReady,
                                    function() return ensureReach(record) end)
                                if not sent then break end
                                requests=requests+1;report.sent=requests
                                if not accepted then trace("placement rejected",record.name.."; will recheck on the next pass") end
                                renderBOM()
                            else
                                assert(tool.Parent==character,"Pickaxe unequipped. Re-equip it, then restart Destroy Blocks.")
                                status("Breaking "..index.." / "..#queue..": "..record.name.." | "..tool.Name)
                                for _=1,instant and 1 or 40 do
                                    if not waitReady() or not record.block.Parent then break end
                                    assert(tool.Parent==character,"Pickaxe unequipped. Re-equip it, then restart Destroy Blocks.")
                                    local sent,accepted=invoke(treeRemote,{[treeHashKey]=treeHashValue,part=record.part,block=record.block,
                                        norm=record.part.CFrame.UpVector,pos=record.part.Position},current,waitReady,
                                        function() return ensureReach(record) end)
                                    if not sent then break end
                                    assert(accepted,"Server rejected the block hit.")
                                    requests=requests+1
                                    task.wait(instant and 1/build.speed or 0.3)
                                end
                                if not record.block.Parent then confirmed=confirmed+1 end
                                if current() and record.block.Parent then
                                    error("Block still present after repeated hits: "..record.name..". Hit it once manually with your pickaxe, then click Save Destroy Diagnostic.",0)
                                end
                            end
                            if not build.paused then
                                status(report and ("Placed "..report.placed.." / "..report.total.." | "..report.phase.." "..record.name)
                                    or ("Destroying "..index.."/"..#queue))
                            end
                            task.wait(1/build.speed)
                        end
                    end
                    if report and waitReady() then
                        task.wait(0.5)
                        if not waitReady() then break end
                        queue=samplePlaced(report)
                        confirmed=report.placed
                        if #queue==0 then break end
                    end
                end
                if waitReady() then
                    if report then
                        report.phase=report.placed==report.total and "Finished" or "Finished — blocks still missing"
                        report.currentName=nil
                        renderBOM()
                        status("Build finished: "..report.placed.." / "..report.total.." blocks visible; "..requests.." placement requests."
                            ..(report.placed<report.total and " Use PLACE MISSING after checking materials." or ""))
                    else status("Destroy finished: "..confirmed.."/"..#records.." blocks removed.") end
                end
            end,traceback)
            releaseMovement()
            if build.releaseMovement==releaseMovement then build.releaseMovement=nil end
            if current() and moved and (not pendingRequest or pendingRequest.done) then root.CFrame=original end
            build.busy,build.paused=false,false
            if report and state.running then
                if not ok then report.phase="Error";report.currentName=nil
                elseif not current() then report.phase="Stopped";report.currentName=nil end
                renderBOM()
            end
            if not ok and state.running then
                trace("job error",err);status((kind=="place" and "Build error: " or "Destroy error: ")..tostring(err))
            end
        end)
    end
    local function action(section, title, fn)
        table.insert(build.actions, title)
        section:AddButton({Title=title, Callback=function()
            trace("button", title)
            if title=="Destroy Blocks [Beta]" or title=="Instant Destroy Blocks (Greg's Hammer)" then
                status("Checking destroy selection and pickaxe...")
            end
            local ok, err=xpcall(fn, traceback)
            if not ok then trace("button error: "..title, err); status("Build error: "..tostring(err))
            else trace("callback returned", title) end
        end})
    end
    local function arm(mode)
        ensureIdle()
        stopFarms()
        build.mode=mode
        mouse.TargetFilter=objects
        status("Hide RoSnipe with Right Shift, then click a block: "..mode..".")
    end
    connect(UserInputService.InputBegan,function(input,processed)
        if processed or input.UserInputType~=Enum.UserInputType.MouseButton1 or not build.mode
            or not Window.Minimized or UserInputService:GetFocusedTextBox() or build.busy then return end
        local ok,err=pcall(function()
            local hit=mouse.Target
            assert(hit, "Click an island block.")
            local block=hit
            while block.Parent and block.Parent.Name~="Blocks" do block=block.Parent end
            local islands = workspace:FindFirstChild("Islands")
            assert(islands and block.Parent and block.Parent.Name=="Blocks" and block:IsDescendantOf(islands), "Click an island block.")
            local part=blockPart(block)
            assert(part,"Selected block has no part.")
            if build.mode=="Move preview to mouse" then
                movePreview(part.Position+Vector3.new(0,3,0))
            else
                if build.mode=="First corner" or build.mode=="New selection" then
                    build.blocks=block.Parent; build.first=part.Position; build.last=part.Position
                else
                    assert(block.Parent==build.blocks,"Both corners must be on the same island.")
                    build.last=build.first+snapVector(part.Position-build.first)
                end
                redraw()
            end
            build.mode=nil
            if mouse.TargetFilter==objects then mouse.TargetFilter=originalFilter end
            status("Selection updated. Open RoSnipe with Right Shift.")
        end)
        if not ok then status(tostring(err)) end
    end)
    local dragStart
    connect(handles.MouseButton1Down,function()
        if build.busy then return end
        dragStart={first=build.first,last=build.last, records={}}
        for i,record in ipairs(build.records) do dragStart.records[i]=record.cf end
    end)
    connect(handles.MouseDrag,function(face,distance)
        if build.busy or not dragStart then return end
        local ok,err=pcall(function()
            local direction=Vector3.FromNormalId(face)
            local delta=direction*snap(distance)
            if build.handleMode=="Resize" then
                assert(dragStart.first and dragStart.last,"Set corners first.")
                local low=Vector3.new(math.min(dragStart.first.X,dragStart.last.X),math.min(dragStart.first.Y,dragStart.last.Y),math.min(dragStart.first.Z,dragStart.last.Z))
                local high=Vector3.new(math.max(dragStart.first.X,dragStart.last.X),math.max(dragStart.first.Y,dragStart.last.Y),math.max(dragStart.first.Z,dragStart.last.Z))
                if direction.X+direction.Y+direction.Z>0 then high=high+delta else low=low+delta end
                if high.X<low.X or high.Y<low.Y or high.Z<low.Z then return end
                build.first,build.last=low,high
            else
                if #build.records>0 then
                    for i,record in ipairs(build.records) do record.cf=dragStart.records[i]+delta; record.preview.CFrame=record.cf end
                    refreshPreviewBOM()
                elseif dragStart.first and dragStart.last then
                    build.first,build.last=dragStart.first+delta,dragStart.last+delta
                end
            end
            redraw()
        end)
        if not ok then status(tostring(err)) end
    end)
    local function editHandles(mode,enabled)
        ensureIdle()
        if not enabled then
            if build.handleMode==mode then handles.Visible=false; build.handleMode=nil end
            return
        end
        stopFarms()
        build.handleMode=mode
        handles.Style=mode=="Resize" and Enum.HandlesStyle.Resize or Enum.HandlesStyle.Movement
        if mode=="Move" and #build.records>0 then handles.Adornee=build.records[1].preview
        else assert(build.first and build.last,"Set selection corners first."); handles.Adornee=box end
        handles.Visible=true
        status(mode.." handles ready. Hide RoSnipe with Right Shift and drag a handle.")
    end
    local settings=AutoBuild:AddSection("BUILD SETTINGS")
    local function toggle(section,id,title,description,default,callback)
        local item=section:AddToggle(id,{Title=title,Description=description,Default=default})
        item:OnChanged(callback)
        return item
    end
    toggle(settings,"BuildMoveNear","Move Near Block Before Placing","Move beside each block before its placement request.",false,function(v) build.moveNear=v end)
    toggle(settings,"BuildAutoReach","Auto Reach Floating Blocks","Automatically move within reach and hover for elevated placements, even with Move To Build Position off.",true,function(v) build.autoReach=v end)
    settings:AddSlider("BuildTravelSpeed",{Title="Build Travel Speed",Description="Gradual movement in studs per second.",Default=25,Min=5,Max=60,Rounding=0,Callback=function(v) build.travelSpeed=v end})
    local controls=AutoBuild:AddSection("AUTOBUILD")
    toggle(controls,"BuildNearbyFirst","Place Nearby Blocks First","Place blocks within 28 studs before moving again; up to 3 requests in flight. Overrides Move Near Block Before Placing.",true,function(v) build.nearbyFirst=v end)
    toggle(controls,"BuildTeleport","Move To Build Position","Moves within reach as the build progresses.",true,function(v) build.teleport=v end)
    toggle(controls,"BuildUseRadius","Use Build Radius","Prioritizes blocks inside your radius first; remaining blocks follow.",false,function(v) build.useRadius=v end)
    controls:AddSlider("BuildRadius",{Title="Build Radius",Default=85,Min=10,Max=200,Rounding=0,Callback=function(v) build.radius=v end})
    controls:AddSlider("BuildRetries",{Title="Retry Passes",Description="Extra passes for blocks still missing after placement.",Default=4,Min=0,Max=10,Rounding=0,Callback=function(v) build.retryPasses=v end})
    toggle(controls,"BuildShowHUD","Show Live Build HUD","Shows total progress and block type counters.",true,function(v)
        build.showHUD=v
        if build.busy and build.bom then bomGui.Enabled=v elseif not v then bomGui.Enabled=false end
    end)
    toggle(controls,"BuildNoclip","Auto Noclip While Building","Stops your character from getting stuck while building.",true,function(v) build.noclip=v end)
    action(controls,"BUILD HERE",function() startJob("place",copyRecords(build.records),false,false) end)
    action(controls,"PLACE MISSING",function() startJob("place",copyRecords(build.records),false,true) end)
    action(controls,"Pause / Resume Build",function()
        assert(build.busy,"No build is running.")
        build.paused=not build.paused
        if build.bom then build.bom.phase=build.paused and "Paused" or "Resuming";renderBOM() end
        status(build.paused and "Build paused. An already-sent request may finish." or "Build resumed.")
    end)
    action(controls,"Continue Last Build",function() ensureIdle();startJob("place",lastBuildRecords(),false,true) end)
    action(controls,"Clear Last Build Data",clearLastBuild)
    action(controls,"Stop Build",function() stop("Stopped. Continue Last Build can place the remaining blocks.") end)
    action(controls,"Blocks",function()
        if not build.busy and (not build.bom or not build.bom.started) then refreshPreviewBOM() end
        assert(build.bom and build.bom.total>0,"Load a ghost preview or use Check Blocks in File first.")
        bomGui.Enabled=not bomGui.Enabled
        renderBOM()
    end)
    controls:AddSlider("BuildSpeed",{Title="Build Speed (requests/sec)",Description="Requested send rate; actual placement speed depends on the server.",Default=10,Min=1,Max=20,Rounding=0,Callback=function(v) build.speed=v;redraw() end})

    local movement=GhostPreview:AddSection("GHOST MOVEMENT")
    toggle(movement,"BuildMoveTool","Enable Moving Tool","Drag the ghost preview using its handles.",false,function(value)
        local ok,err=pcall(editHandles,"Move",value)
        if not ok then status(tostring(err)) end
    end)
    local rotations=GhostPreview:AddSection("ROTATE GHOST PREVIEW")
    for _,axis in ipairs({"X","Y","Z"}) do
        action(rotations,"Rotate 90° "..axis,function()
            local pivot=previewAnchor()
            local angle=math.pi/2
            local rotation=CFrame.Angles(axis=="X" and angle or 0,axis=="Y" and angle or 0,axis=="Z" and angle or 0)
            transformPreview(CFrame.new(pivot)*rotation*CFrame.new(-pivot))
        end)
    end
    local function readSelectedFile()
        assert(type(readfile)=="function","readfile unavailable.")
        local data=readfile(filePath()):gsub("^\239\187\191","")
        assert(#data<=10*1024*1024,"Schematic file exceeds 10 MB.")
        local lines={}
        for line in (data.."\n"):gmatch("(.-)\n") do if not line:match("^%s*%-%-") then table.insert(lines,line) end end
        return deserialize(HttpService:JSONDecode(table.concat(lines,"\n")))
    end
    action(rotations,"Load Ghost Preview",function()
        ensureIdle()
        local records=readSelectedFile()
        positionLoadedPreview(records)
        showPreview(records)
        status("Loaded "..#records.." ghost blocks. Move or rotate them, then choose BUILD HERE in Autobuild.")
    end)
    action(rotations,"Snap to My Position",function()
        ensureIdle()
        local _,_,root=getCharacter();assert(root,"Wait for your character.")
        local anchor=previewAnchor()
        -- Preserve rotations and spacing, moving the anchor to the player's grid cell.
        transformPreview(CFrame.new(snapVector(root.Position)-anchor))
    end)
    action(rotations,"Clear Ghost Preview",function() ensureIdle();handles.Visible=false;clearPreview();status("Ghost preview cleared.") end)
    toggle(rotations,"BuildLoadNearPlayer","Load Preview Near Me","Disable to retain the file's saved coordinates.",true,function(v) build.loadNearPlayer=v end)
    toggle(rotations,"BuildPreviewCollision","Build Collision (Preview)",nil,false,function(v)
        build.collision=v
        for _,record in ipairs(build.records) do record.preview.CanCollide=v end
    end)

    local selection=BuildFiles:AddSection("SELECTION")
    action(selection,"Set First Corner",function() arm("First corner") end)
    action(selection,"Set Second Corner",function() arm("Second corner") end)
    action(selection,"Change Position / New Selection",function() arm("New selection") end)
    toggle(selection,"BuildResizeTool","Use Resize Tool",nil,false,function(v)
        local ok,err=pcall(editHandles,"Resize",v)
        if not ok then status(tostring(err)) end
    end)
    local save=BuildFiles:AddSection("SAVE SELECTION")
    save:AddInput("BuildFileName",{Title="File Name (no extension)",Default="mybuild",Finished=true,Callback=function(v) build.saveName=v end})
    local fullIsland=BuildFiles:AddSection("COPY FULL ISLAND")
    local files=BuildFiles:AddSection("BUILD FILES")
    local fileDropdown=files:AddDropdown("BuildFiles",{Title="Build File",Values={},Multi=false})
    fileDropdown:OnChanged(function(v) if v then build.file=v end end)
    local function refreshFiles()
        assert(type(listfiles)=="function","listfiles is unavailable.")
        ensureFolders()
        local names={}
        for _,path in ipairs(listfiles(build.folder)) do
            if type(isfile)~="function" or isfile(path) then
                local name=path:match("([^/\\]+)$")
                if name then table.insert(names,name) end
            end
        end
        table.sort(names)
        fileDropdown:SetValues(names)
        if table.find(names,build.file) then fileDropdown:SetValue(build.file)
        elseif #names>0 then fileDropdown:SetValue(names[1])
        else fileDropdown:SetValue(nil);build.file="" end
        status("Found "..#names.." build files in "..build.folder)
    end
    local folder=files:AddDropdown("BuildFileFolder",{Title="Build Folder",Values={"RoSnipe/Schematica","Nekohub/Islands/Schematica","Flare Hub/Islands/blueprints"},Default="RoSnipe/Schematica",Multi=false})
    folder:OnChanged(function(v)
        build.folder=v
        local ok,err=pcall(refreshFiles)
        if not ok then status("File list: "..tostring(err)) end
    end)
    local function saveRecords(records)
        ensureIdle()
        assert(#records>0 and #records<=MAX_BLOCKS,"Choose 1–20000 blocks to save.")
        assert(type(writefile)=="function" and type(isfile)=="function","File saving APIs unavailable.")
        ensureFolders()
        local name=safeFileName(build.saveName)
        if not name:lower():match("%.json$") then name=name..".json" end
        local path=build.folder.."/"..name
        assert(not isfile(path),"File already exists. Choose a different File Name.")
        local data={blocks={}}
        for _,record in ipairs(records) do
            table.insert(data.blocks,{blockType=record.name,upperBlock=record.upperBlock==true,cframe={record.cf:GetComponents()}})
        end
        writefile(path,HttpService:JSONEncode(data))
        build.file=name
        refreshFiles()
        status("Saved "..#records.." blocks to "..path)
    end
    action(save,"Save Selection to File",function() saveRecords(selectedBlocks()) end)
    action(fullIsland,"Copy All Blocks on Island",function()
        ensureIdle()
        local records={}
        for _,block in ipairs(ownBlocks():GetChildren()) do
            local part=blockPart(block)
            if part then table.insert(records,{name=block.Name,cf=part.CFrame}) end
            assert(#records<=MAX_BLOCKS,"Island exceeds 20000 blocks; save smaller selections.")
        end
        saveRecords(records)
    end)
    action(files,"Select Build File",function() refreshFiles();fileDropdown:Open() end)
    action(files,"Check Blocks in File",function()
        ensureIdle()
        build.bom=newBOM(readSelectedFile())
        build.bom.phase="Materials in "..build.file
        bomGui.Enabled=true
        renderBOM()
        status("Materials listed for "..build.file..". The ghost preview has not changed.")
    end)

    -- Keep the original optional utilities separate from the screenshot workflow.
    local tools=AutoBuild:AddSection("Block Printer / Diagnostics")
    action(tools,"Print Blocks",function()
        ensureIdle();assert(selectionCount()<=MAX_BLOCKS,"Selection exceeds 20000 cells.")
        local character=getCharacter();local tool=character and character:FindFirstChildOfClass("Tool")
        assert(tool,"Hold the block you want to print.")
        local name=tool.Name
        if tool:FindFirstChild("seeds") then name=name:gsub("Seeds$","") end
        local assets=ReplicatedStorage:FindFirstChild("Blocks")
        assert(assets and assets:FindFirstChild(name),"Held tool is not a recognized block: "..name)
        local low,high=bounds();local records={}
        for y=low.Y,high.Y,3 do for x=low.X,high.X,3 do for z=low.Z,high.Z,3 do
            table.insert(records,{name=name,cf=CFrame.new(x,y,z)})
        end end end
        startJob("place",records,false,false)
    end)
    action(tools,"Refresh Build Hash",function() ensureIdle();placeRemote,placeKey,placeHash=nil,nil,nil;resolvePlacement() end)
    action(tools,"Save Build Diagnostic",saveDiagnostic)
    local extras=GhostPreview:AddSection("Selection Preview")
    action(extras,"Clone Blocks",function()
        ensureIdle()
        local records=selectedBlocks()
        for _,record in ipairs(records) do record.cf=record.cf+Vector3.new(0,3,0) end
        showPreview(records);status("Selection copied into the ghost preview.")
    end)
    action(extras,"Move Ghost to Mouse",function() previewAnchor();arm("Move preview to mouse") end)
    local destroy=AutoBuild:AddSection("Block Destroyer")
    destroy:AddParagraph({Title="Selected Blocks",Content="Destroy acts on real blocks between the two selection corners."})
    DestroyStatus=destroy:AddParagraph({Title="Destroy Status",Content="Set both corners in Build Files. A pickaxe in your Backpack will equip automatically."})
    action(destroy,"Destroy Blocks [Beta]",function() startJob("destroy",selectedBlocks(),false) end)
    action(destroy,"Instant Destroy Blocks (Greg's Hammer)",function() startJob("destroy",selectedBlocks(),true) end)
    action(destroy,"Save Destroy Diagnostic",saveDiagnostic)
    redraw()

end
installAutoBuild()

-- The original crop farm's sickle route; placement shares the verified build resolver.
local function installFarming()
    local farm = { mode=nil, selected={spiritCrop=true}, range=20, interval=2, batch=10,
        replant=true, version=0, queue={}, harvested=0, planted=0, plowed=0, plowRange=10, plowInterval=0.25, seedSpeed=10 }
    local sickles = {"cletusSickle", "sickleDiamond", "sickleIron", "sickleStone"}
    local crops = {"all", "spiritCrop", "wheat", "carrot", "potato", "onion", "tomato",
        "spinach", "pumpkin", "melon", "pineapple", "starfruit", "dragonfruit",
        "chiliPepper", "grapeVine", "candyCaneVine", "berryBush", "blackberryBush", "blueberryBush"}
    local cropSet = {}
    for _, name in ipairs(crops) do cropSet[name]=true end
    local status = Farming:AddParagraph({Title="Farming Status", Content="Select crops, plant held seeds, or enable Auto Plow. Use a sickle for harvesting and a plow for nearby grass."})
    local totals = Farming:AddParagraph({Title="Session Totals", Content="Harvested: 0 | Planted: 0 | Plowed: 0"})
    local toggles, pending = {}, nil
    local changingMode=false
    local lastMessage
    local function message(text)
        lastMessage=text
        if state.running then
            status:SetDesc(text)
            totals:SetDesc("Harvested: "..farm.harvested.." | Planted: "..farm.planted.." | Plowed: "..farm.plowed.." | Pending replants: "..#farm.queue)
        end
    end
    local function ownBlocks()
        local islands=workspace:FindFirstChild("Islands")
        for _, island in ipairs(islands and islands:GetChildren() or {}) do
            local owners=island:FindFirstChild("Owners")
            if owners and owners:FindFirstChild(tostring(LocalPlayer.UserId)) then return island:FindFirstChild("Blocks") end
        end
    end
    local function partOf(block)
        if block:IsA("BasePart") then return block end
        return block:FindFirstChildWhichIsA("BasePart",true)
    end
    local function ready(block)
        local flag=block:FindFirstChild("Harvestable",true)
        return flag and flag:IsA("BoolValue") and flag.Value==true
    end
    local function selected(block)
        return farm.selected[block.Name] or (farm.selected.all and cropSet[block.Name])
    end
    local function inventory()
        local found={}
        local backpack=LocalPlayer:FindFirstChild("Backpack")
        for _, container in pairs({backpack,LocalPlayer.Character}) do
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") then found[tool.Name]=tool end
            end
        end
        return found
    end
    local function seedCrop(tool)
        if not tool or not tool:FindFirstChild("seeds") then return nil end
        local name=tool.Name:gsub("Seeds$", "")
        if name=="spirit" then name="spiritCrop" end
        return cropSet[name] and name~="all" and name or nil
    end
    local function hasSeed(name)
        for _,tool in pairs(inventory()) do if seedCrop(tool)==name then return true end end
        return false
    end
    local function occupied(blocks, position)
        for _, block in ipairs(blocks:GetChildren()) do
            local part=partOf(block)
            if part and (part.Position-position).Magnitude<1 then return block end
        end
    end
    stopFarming = function(reason)
        farm.mode=nil; farm.version=farm.version+1; state.cropDestination=nil
        changingMode=true
        for _,toggle in pairs(toggles) do if toggle.Value then toggle:SetValue(false) end end
        changingMode=false
        restoreMovement()
        message(reason or "Off")
    end
    local function setMode(mode, value)
        if changingMode then return end
        if not value then if farm.mode==mode then stopFarming() end;return end
        if stopAirWalk then stopAirWalk("Stopped: crop farming enabled.") end
        if stopTotemUpgrade then stopTotemUpgrade("Stopped: crop farming enabled.") end
        stopFarming()
        if stopBossFarm then stopBossFarm() end
        farmToggle:SetValue(false); auraToggle:SetValue(false); stopCutting()
        if stopAutoBuild then stopAutoBuild("Stopped: farming enabled.") end
        farm.mode=mode; farm.version=farm.version+1
        -- Keep the active toggle on after stopFarming cleared the previous mode.
        changingMode=true
        toggles[mode]:SetValue(true)
        changingMode=false
        message(mode=="plow" and "Scanning your island for nearby grass to plow."
            or (mode=="plant" and "Planting held seeds on nearby empty soil." or "Scanning your island for ripe crops."))
    end
    -- A timed-out InvokeServer stays tracked until it finishes: never stack requests.
    local function invoke(remote, args, current)
        assert(not pending or pending.done,"Previous crop request is still waiting for the server. Retry after it finishes.")
        if not current() then return false end
        local request={done=false}; pending=request
        task.spawn(function()
            request.ok,request.result=pcall(function()
                if current() then return remote:InvokeServer(table.unpack(args)) end
            end)
            request.done=true
        end)
        local deadline=os.clock()+8
        while not request.done do
            if not current() then return false end
            assert(os.clock()<deadline,"Crop request timed out; further requests stopped. Save Crop Diagnostic.")
            task.wait(0.05)
        end
        if not current() then return false end
        assert(request.ok,tostring(request.result))
        assert(request.result~=false,"Server rejected the crop request. Save Crop Diagnostic.")
        return true
    end
    local function moveNear(position, root)
        if farm.mode=="auto" then state.cropDestination=position+Vector3.new(0,3,5) end
        return (root.Position-position).Magnitude<=farm.range
    end
    local function place(record, blocks, current)
        if occupied(blocks,record.cf.Position) then return true end
        assert(hasSeed(record.name),"No "..record.name.." seeds found in your hotbar. Replant is waiting.")
        local remote,key,hashValue=resolveCropPlacement()
        if not current() then return false end
        if not invoke(remote,{{[key]=hashValue,cframe=record.cf,blockType=record.name,upperBlock=false}},current) then return false end
        local deadline=os.clock()+2
        repeat
            local block=occupied(blocks,record.cf.Position)
            if block then
                if block.Name==record.name then farm.planted=farm.planted+1 end
                return true
            end
            if not current() then return false end
            task.wait(0.1)
        until os.clock()>=deadline
        error("Planting "..record.name.." was not confirmed. Check seeds and soil; Save Crop Diagnostic.")
    end
    local function isPlow(tool)
        return tool and (tool:FindFirstChild("hoe") ~= nil or tool.Name:lower():find("plow",1,true) ~= nil)
    end
    local function runPlow(character, humanoid, root, blocks, current)
        state.cropDestination=nil
        local target, part, nearest=nil,nil,farm.plowRange
        for _,block in ipairs(blocks:GetChildren()) do
            if block.Name=="grass" then
                local candidate=partOf(block)
                local distance=candidate and (candidate.Position-root.Position).Magnitude
                if distance and distance<=nearest then target,part,nearest=block,candidate,distance end
            end
        end
        if not target then message("No grass within "..farm.plowRange.." studs. Walk to the next patch.");return end
        local tool=character:FindFirstChildOfClass("Tool")
        if not isPlow(tool) then
            local tools=inventory()
            tool=tools.crystallinePlow or tools.plow
            if not isPlow(tool) then
                tool=nil
                for _,candidate in pairs(tools) do if isPlow(candidate) then tool=candidate;break end end
            end
        end
        assert(tool,"No plow found. Put a plow in your hotbar or Backpack.")
        if tool.Parent~=character then humanoid:EquipTool(tool);task.wait(0.2) end
        if not current() then return end
        assert(tool.Parent==character,"Could not equip "..tool.Name)
        -- Plowing changes grass to soil; re-check after equipping or waiting.
        if target.Parent~=blocks or target.Name~="grass" or not part.Parent
            or (part.Position-root.Position).Magnitude>farm.plowRange then return end
        local position=part.Position
        local remote=netManaged():FindFirstChild("CLIENT_PLOW_BLOCK_REQUEST")
        assert(remote and remote:IsA("RemoteFunction"),"CLIENT_PLOW_BLOCK_REQUEST RemoteFunction not found.")
        message("Plowing grass with "..tool.Name)
        -- Original payload. Send one request and confirm soil before counting it.
        if not invoke(remote,{{block=target}},current) then return end
        local deadline=os.clock()+2
        repeat
            if not current() then return end
            local block=occupied(blocks,position)
            if block and block.Name=="soil" then
                farm.plowed=farm.plowed+1
                message("Plowed "..farm.plowed.." grass blocks this session.")
                return
            end
            task.wait(0.1)
        until os.clock()>=deadline
        error("Plowing was not confirmed. Try the plow manually on nearby grass, then enable Auto Plow again.")
    end
    local function runOnce()
        local character,humanoid,root=getCharacter()
        if not character then message("Waiting for your character.");return end
        local blocks=ownBlocks()
        if not blocks then message("Your island's blocks are not loaded.");state.cropDestination=nil;return end
        local token=farm.version
        local function current()
            return state.running and farm.mode~=nil and farm.version==token and LocalPlayer.Character==character
                and humanoid.Health>0 and blocks.Parent~=nil
        end
        assert(not pending or pending.done,"Previous crop request is still pending. Wait, then enable farming again.")
        if farm.mode=="plow" then runPlow(character,humanoid,root,blocks,current);return end
        if farm.mode=="plant" then
            local name=seedCrop(character:FindFirstChildOfClass("Tool"))
            assert(name,"Hold a supported seed tool to use Crop Place Aura (including spirit seeds).")
            for _,soil in ipairs(blocks:GetChildren()) do
                if soil.Name=="soil" then
                    local part=partOf(soil)
                    if part then
                        local position=part.Position+Vector3.new(0,3,0)
                        if (root.Position-position).Magnitude<=farm.range and not occupied(blocks,position) then
                            message("Planting "..name)
                            place({name=name,cf=CFrame.new(position)},blocks,current)
                            return
                        end
                    end
                end
            end
            message("No empty soil within "..farm.range.." studs.");return
        end
        -- Queued records survive Stop/Resume; never replace a crop that still exists.
        while #farm.queue>0 do
            local record=farm.queue[1]
            if record.blocks~=blocks then error("Pending replants belong to another island. Clear Pending Replants before switching islands.") end
            if record.block.Parent~=blocks then
                if not record.counted then farm.harvested=farm.harvested+1;record.counted=true end
                if farm.replant then
                    if not moveNear(record.cf.Position,root) then message("Moving to replant "..record.name);return end
                    message("Replanting "..record.name)
                    if not place(record,blocks,current) then return end
                end
            elseif not ready(record.block) and not record.counted then
                farm.harvested=farm.harvested+1;record.counted=true
            end
            table.remove(farm.queue,1)
        end
        local candidates={}
        for _,block in ipairs(blocks:GetChildren()) do
            local part=partOf(block)
            if selected(block) and part and ready(block) then
                local distance=(root.Position-part.Position).Magnitude
                if farm.mode=="auto" or distance<=farm.range then
                    table.insert(candidates,{block=block,blocks=blocks,name=block.Name,cf=part.CFrame,distance=distance})
                end
            end
        end
        table.sort(candidates,function(a,b) return a.distance<b.distance end)
        if #candidates==0 then state.cropDestination=nil;message("Waiting for selected crops to ripen"..(farm.mode=="aura" and " within range." or "."));return end
        if not moveNear(candidates[1].cf.Position,root) then message("Moving to "..candidates[1].name);return end
        local tools=inventory(); local sickle
        for _,name in ipairs(sickles) do if tools[name] then sickle=tools[name];break end end
        assert(sickle,"No sickle found. Put cletusSickle, sickleStone, sickleIron, or sickleDiamond in your hotbar.")
        if sickle.Parent~=character then humanoid:EquipTool(sickle);task.wait(0.2) end
        if not current() then return end
        assert(sickle.Parent==character,"Could not equip "..sickle.Name)
        local remote=netManaged():FindFirstChild("SwingSickle")
        assert(remote and remote:IsA("RemoteFunction"),"SwingSickle RemoteFunction not found. Save Crop Diagnostic.")
        -- Resolve placement before harvesting so an unknown hash cannot strand a batch.
        if farm.replant then resolveCropPlacement() end
        if not current() then return end
        local batch={}
        for _,record in ipairs(candidates) do
            if #batch>=farm.batch then break end
            if record.distance<=farm.range and record.block.Parent==blocks and ready(record.block) then
                table.insert(batch,record.block);table.insert(farm.queue,record)
            end
        end
        message("Harvesting "..#batch.." crops with "..sickle.Name)
        if not invoke(remote,{sickle.Name,batch},current) then return end
        local deadline=os.clock()+2
        while current() and os.clock()<deadline do
            local changed=false
            for _,record in ipairs(farm.queue) do if record.block.Parent~=blocks or not ready(record.block) then changed=true;break end end
            if changed then return end
            task.wait(0.1)
        end
        if current() then error("Harvest was not confirmed. Try the sickle manually, then Save Crop Diagnostic.") end
    end
    local section=Farming:AddSection("Crop Farm")
    local selection=section:AddDropdown("CropSelection",{Title="Crop to Farm",Values=crops,Multi=true,Default={"spiritCrop"}})
    selection:OnChanged(function(value)
        farm.selected={}
        for name,enabled in pairs(value) do if enabled then farm.selected[name]=true end end
        farm.version=farm.version+1;state.cropDestination=nil
    end)
    for _,option in ipairs({{"auto","Crop Auto Farm"},{"aura","Crop Aura (No Movement)"},{"plant","Crop Place Aura (Held Seeds)"}}) do
        local mode=option[1]
        toggles[mode]=section:AddToggle("CropMode_"..mode,{Title=option[2],Default=false})
        toggles[mode]:OnChanged(function(value) setMode(mode,value) end)
    end
    section:AddSlider("SeedAuraSpeed",{Title="Seed Aura Speed (plants/sec)",Description="Target speed; planting still waits for each crop to appear.",
        Default=10,Min=1,Max=20,Rounding=0,Callback=function(value)
            farm.seedSpeed=math.clamp(tonumber(value) or farm.seedSpeed,1,20)
        end})
    local plowing=Farming:AddSection("Plowing")
    toggles.plow=plowing:AddToggle("AutoPlow",{Title="Auto Plow",Default=false,
        Description="Plows nearby grass on your island. Walk around to cover more ground."})
    toggles.plow:OnChanged(function(value) setMode("plow",value) end)
    plowing:AddSlider("AutoPlowRange",{Title="Plow Range",Default=10,Min=1,Max=30,Rounding=0,
        Callback=function(value) farm.plowRange=tonumber(value) or farm.plowRange end})
    plowing:AddSlider("AutoPlowInterval",{Title="Plow Interval (seconds)",Default=0.25,Min=0.1,Max=2,Rounding=2,
        Callback=function(value) farm.plowInterval=tonumber(value) or farm.plowInterval end})
    section:AddToggle("CropReplant",{Title="Auto Replace Crop",Default=true}):OnChanged(function(value) farm.replant=value end)
    section:AddSlider("CropRange",{Title="Crop Range",Default=20,Min=8,Max=30,Rounding=0,Callback=function(v) farm.range=v end})
    section:AddSlider("CropInterval",{Title="Harvest Interval (seconds)",Default=2,Min=0.5,Max=15,Rounding=1,Callback=function(v) farm.interval=v end})
    section:AddSlider("CropBatch",{Title="Crops per Harvest",Default=10,Min=1,Max=30,Rounding=0,Callback=function(v) farm.batch=v end})
    section:AddButton({Title="Stop Farming",Callback=function() stopFarming() end})
    section:AddButton({Title="Clear Pending Replants",Callback=function() stopFarming();farm.queue={};message("Pending replants cleared.") end})
    section:AddButton({Title="Save Crop Diagnostic",Callback=function()
        local ok,err=pcall(function()
            local lines={"RoSnipe crop diagnostic", "PlaceId="..game.PlaceId.." PlaceVersion="..game.PlaceVersion,
                "Mode="..tostring(farm.mode).." Status="..tostring(lastMessage),"Pending replants="..#farm.queue}
            local function log(v) table.insert(lines,v) end
            for name,tool in pairs(inventory()) do log("Tool="..name.." SeedCrop="..tostring(seedCrop(tool))) end
            local blocks=ownBlocks(); local counts={}
            for _,block in ipairs(blocks and blocks:GetChildren() or {}) do
                if cropSet[block.Name] then
                    counts[block.Name]=counts[block.Name] or {total=0,ripe=0}
                    local count=counts[block.Name];count.total=count.total+1;if ready(block) then count.ripe=count.ripe+1 end
                end
            end
            log("Crops="..HttpService:JSONEncode(counts))
            for _,name in ipairs({"SwingSickle","CLIENT_HARVEST_CROP_REQUEST","CLIENT_BLOCK_PLACE_REQUEST"}) do
                local remote=netManaged():FindFirstChild(name);log(name.."="..(remote and remote.ClassName or "missing"))
            end
            local info=getinfo or (debug and debug.getinfo)
            local constants=getconstants or (debug and debug.getconstants)
            local protos=getprotos or (debug and debug.getprotos)
            local visited,count={},0
            local function dump(fn,depth)
                if visited[fn] or count>=60 then return end
                visited[fn]=true;count=count+1
                local details=info(fn);log("Function="..tostring(details.name).." Source="..tostring(details.source))
                local values=constants(fn)
                for i=1,160 do
                    local v=values[i]
                    if type(v)=="string" then log(" constant["..i.."]="..string.format("%q",v))
                    elseif v~=nil then log(" constant["..i.."]="..(type(v)=="number" and tostring(v) or "<"..type(v)..">")) end
                end
                if depth<2 and type(protos)=="function" then for _,child in pairs(protos(fn)) do pcall(dump,child,depth+1) end end
            end
            if type(getgc)=="function" and type(info)=="function" and type(constants)=="function" then
                for _,fn in pairs(getgc(true)) do
                    if type(fn)=="function" then pcall(function()
                        local d=info(fn);local source=tostring(d.source or d.short_src)
                        if source:find("crop-service",1,true) or source:lower():find("sickle",1,true) then dump(fn,0) end
                    end) end
                end
            end
            assert(type(writefile)=="function","Executor writefile is unavailable.")
            writefile("islands-crop-diagnostic.txt",table.concat(lines,"\n"))
        end)
        message(ok and "Saved islands-crop-diagnostic.txt in your executor workspace." or ("Diagnostic error: "..tostring(err)))
    end})
    task.spawn(function()
        while state.running do
            if farm.mode then
                local token=farm.version
                local ok,err=pcall(runOnce)
                if not ok and token==farm.version then stopFarming("Farming error: "..tostring(err)) end
            end
            local interval=farm.mode=="plow" and farm.plowInterval
                or (farm.mode=="plant" and 1/farm.seedSpeed or farm.interval)
            task.wait(farm.mode and interval or 0.25)
        end
    end)
end
installFarming()

-- Try the original summon trigger first; no replacement summon remote is assumed.
local function installBossFarm()
    local boss = { autoSpawn=true, retry=15, nextSpawn=0, attempts=0, message="Off",
        afterKillWait=15, lastTarget=nil, returning=false, waitUntil=nil }
    local section=Main:AddSection("Slime King")
    local status=section:AddParagraph({Title="Boss Status",Content="Uses the original slime_king_spawn prompt. Select your weapon above; hide RoSnipe with Right Shift for automatic clicks."})
    local toggle
    setBossStatus=function(message)
        boss.message=message
        if state.running then status:SetDesc(message) end
    end
    local function findBoss()
        local wilderness=workspace:FindFirstChild("WildernessIsland")
        local entities=wilderness and wilderness:FindFirstChild("Entities")
        if not entities then return nil,nil end
        for _,entity in ipairs(entities:GetChildren()) do
            if entity.Name=="slimeKing" then
                local health=entity:FindFirstChildOfClass("Humanoid")
                local root=entity:FindFirstChild("HumanoidRootPart")
                if health and health.Health>0 and root then return entity,entities end
            end
        end
        return nil,entities
    end
    local function oldTrigger()
        local prefabs=workspace:FindFirstChild("spawnPrefabs")
        local triggers=prefabs and prefabs:FindFirstChild("WildEventTriggers")
        local trigger=triggers and triggers:FindFirstChild("slime_king_spawn")
        local prompt=trigger and trigger:FindFirstChild("ProximityPrompt")
        return trigger,prompt,triggers
    end
    local function updateReturnPosition()
        local trigger,prompt=oldTrigger()
        if trigger and trigger:IsA("BasePart") then
            local height=3
            if prompt and prompt:IsA("ProximityPrompt") and prompt.MaxActivationDistance>0 then
                height=math.min(height,prompt.MaxActivationDistance/2)
            end
            state.bossReturnPosition=trigger.Position+Vector3.new(0,height,0)
        end
        return trigger,prompt
    end
    stopBossFarm=function(reason)
        state.bossFarm=false;state.bossDestination=nil;state.bossReturnPosition=nil
        boss.lastTarget=nil;boss.returning=false;boss.waitUntil=nil
        if toggle and toggle.Value then toggle:SetValue(false) end
        stopCombat()
        setBossStatus(reason or "Off")
    end
    runBossOnce=function()
        if not state.bossFarm then return end
        local character,humanoid,root=getCharacter()
        if not character then setBossStatus("Waiting for your character.");return end
        local trigger,prompt=updateReturnPosition()
        local target,entities=findBoss()
        -- Keep a hover destination while the attack worker notices the death.
        state.target=nil
        state.bossDestination=state.bossReturnPosition or root.Position
        if boss.lastTarget and target~=boss.lastTarget then
            boss.lastTarget=nil;boss.returning=true;boss.waitUntil=nil
        end
        if boss.returning then
            if not state.bossReturnPosition then
                setBossStatus("Holding position: summon point unavailable. Save Boss Diagnostic.");return
            end
            if (root.Position-state.bossReturnPosition).Magnitude>2 then
                -- The full rest period begins only after arriving back at the trigger.
                boss.waitUntil=nil
                setBossStatus("Returning to the Slime King spawn after the fight.");return
            end
            if not boss.waitUntil then boss.waitUntil=os.clock()+boss.afterKillWait end
            local rest=boss.waitUntil-os.clock()
            if rest>0 then
                setBossStatus("Resting at Slime King spawn: "..math.ceil(rest).."s remaining.");return
            end
            boss.returning=false;boss.waitUntil=nil
        end
        if not entities then setBossStatus("WildernessIsland.Entities is not loaded. Travel to the Slime King island.");return end
        if not combatRemote then setBossStatus("Combat lookup is unresolved. Check Combat Status and Refresh Combat Remotes.");return end
        if target then
            boss.lastTarget=target
            state.target=target;state.bossDestination=nil
            local health=target:FindFirstChildOfClass("Humanoid")
            setBossStatus("Fighting slimeKing | health "..tostring(health.Health))
            if (target.HumanoidRootPart.Position-root.Position).Magnitude<=math.max(20,math.abs(state.height)+5) then attack(target,true) end
            return
        end
        if not boss.autoSpawn then setBossStatus("Waiting for Slime King. Enable Boss Auto Spawn to summon it.");return end
        assert(trigger and trigger:IsA("BasePart"),"Original slime_king_spawn part not found. Save Boss Diagnostic.")
        assert(prompt and prompt:IsA("ProximityPrompt"),"Original Slime King ProximityPrompt not found. Save Boss Diagnostic.")
        assert(type(fireproximityprompt)=="function","Executor has no fireproximityprompt. Save Boss Diagnostic.")
        if not prompt.Enabled then setBossStatus("Summon prompt is disabled; waiting for the game to enable it.");return end
        local activationRange=math.max(0,prompt.MaxActivationDistance)
        if activationRange<=0 then setBossStatus("Summon prompt has no activation range. Save Boss Diagnostic.");return end
        -- Use the hub's existing movement mode to reach the original trigger.
        state.bossDestination=state.bossReturnPosition
        if (root.Position-trigger.Position).Magnitude>activationRange then
            setBossStatus("Moving to the original Slime King summon trigger.");return
        end
        local remaining=boss.nextSpawn-os.clock()
        if remaining>0 then
            setBossStatus("Waiting for spawn / game cooldown (retry in "..math.ceil(remaining).."s). Attempts: "..boss.attempts)
            return
        end
        local token=generation
        if not state.running or not state.bossFarm or LocalPlayer.Character~=character or humanoid.Health<=0 then return end
        -- Reserve the interval before calling, even if the executor yields or throws.
        boss.nextSpawn=os.clock()+boss.retry;boss.attempts=boss.attempts+1
        fireproximityprompt(prompt)
        if state.running and state.bossFarm and generation==token then
            setBossStatus("Original summon prompt triggered (attempt "..boss.attempts.."). Waiting for Slime King; game requirements still apply.")
        end
    end
    toggle=section:AddToggle("BossAutoFarm",{Title="Boss Auto Farm (Slime King)",Default=false})
    toggle:OnChanged(function(value)
        if not value then if state.bossFarm then stopBossFarm() end;return end
        if stopAirWalk then stopAirWalk("Stopped: boss farming enabled.") end
        if stopTotemUpgrade then stopTotemUpgrade("Stopped: boss farming enabled.") end
        farmToggle:SetValue(false);auraToggle:SetValue(false)
        if stopCutting then stopCutting() end
        if stopFarming then stopFarming() end
        if stopAutoBuild then stopAutoBuild("Stopped: boss farming enabled.") end
        state.bossFarm=true;boss.nextSpawn=0;boss.attempts=0
        boss.lastTarget=nil;boss.returning=false;boss.waitUntil=nil
        updateReturnPosition()
        stopCombat();setBossStatus("Starting Slime King farm with the original summon trigger.")
        if not combatRemote or combatWeapon~=selectedCombatTool() then task.spawn(refreshCombat) end
    end)
    section:AddToggle("BossAutoSpawn",{Title="Boss Auto Spawn",Default=true}):OnChanged(function(value)
        boss.autoSpawn=value
    end)
    section:AddSlider("BossAfterKillWait",{Title="Wait at Spawn After Kill (seconds)",Default=15,Min=0,Max=300,Rounding=0,Callback=function(value)
        boss.afterKillWait=value
        if boss.waitUntil then boss.waitUntil=os.clock()+value end
    end})
    section:AddSlider("BossSpawnRetry",{Title="Summon Retry Interval (seconds)",Default=15,Min=5,Max=120,Rounding=0,Callback=function(value) boss.retry=value end})
    section:AddButton({Title="Stop Boss Farm",Callback=function() stopBossFarm() end})
    section:AddButton({Title="Save Boss Diagnostic",Callback=function()
        local ok,err=pcall(function()
            local character,_,root=getCharacter()
            local target,entities=findBoss()
            local trigger,prompt,triggers=oldTrigger()
            local lines={"RoSnipe boss diagnostic (original trigger)","PlaceId="..game.PlaceId.." PlaceVersion="..game.PlaceVersion,
                "Status="..boss.message,"BossAutoFarm="..tostring(state.bossFarm).." AutoSpawn="..tostring(boss.autoSpawn),
                "Summon attempts="..boss.attempts.." fireproximityprompt="..type(fireproximityprompt),
                "After-kill wait="..boss.afterKillWait.." Returning="..tostring(boss.returning).." WaitUntil="..tostring(boss.waitUntil),
                "Return position="..tostring(state.bossReturnPosition),
                "Selected weapon="..tostring(state.weapon).." Combat resolved="..tostring(combatRemote~=nil),
                "Player position="..tostring(root and root.Position),"Living slimeKing="..tostring(target~=nil),
                "Entities loaded="..tostring(entities~=nil),"Trigger="..(trigger and trigger:GetFullName() or "missing")}
            local function log(message) table.insert(lines,message) end
            local equipped=character and character:FindFirstChildOfClass("Tool")
            log("Equipped="..(equipped and equipped.Name or "none"))
            if trigger then
                log("Trigger class="..trigger.ClassName)
                if trigger:IsA("BasePart") and root then log("Trigger distance="..tostring((trigger.Position-root.Position).Magnitude)) end
                for i,child in ipairs(trigger:GetDescendants()) do
                    if i>100 then break end
                    log("Trigger child="..child:GetFullName().." ["..child.ClassName.."]")
                    if child:IsA("ProximityPrompt") then
                        log("Prompt Enabled="..tostring(child.Enabled).." Range="..child.MaxActivationDistance.." Hold="..child.HoldDuration
                            .." RequiresLineOfSight="..tostring(child.RequiresLineOfSight).." Action="..child.ActionText.." Object="..child.ObjectText)
                    end
                end
            end
            for i,child in ipairs(triggers and triggers:GetChildren() or {}) do
                if i>100 then break end
                log("WildEventTrigger="..child.Name.." ["..child.ClassName.."]")
            end
            for _,entity in ipairs(entities and entities:GetChildren() or {}) do
                if entity.Name:lower():find("slime",1,true) then
                    local health=entity:FindFirstChildOfClass("Humanoid")
                    log("Entity="..entity.Name.." Health="..tostring(health and health.Health))
                end
            end
            local tokens,source=readTokenBalance()
            log("slimeKingToken balance="..tostring(tokens).." Source="..tostring(source))
            assert(type(writefile)=="function","Executor writefile is unavailable.")
            writefile("islands-boss-diagnostic.txt",table.concat(lines,"\n"))
        end)
        setBossStatus(ok and "Saved islands-boss-diagnostic.txt in your executor workspace." or ("Diagnostic error: "..tostring(err)))
    end})
end
installBossFarm()

-- A local floor follows horizontal movement. Normal jumps raise its height.
local function installAirWalk()
    local section=MovementTab:AddSection("Air Walk")
    local status=MovementTab:AddParagraph({Title="Movement Status",Content="Off. Air Walk holds your height; walk normally and jump to climb."})
    local toggle=section:AddToggle("AirWalk",{Title="Air Walk",Default=false,
        Description="Walk on air with normal movement keys. Each jump raises your floating height."})
    local enabled,changing=false,false
    local platform,activeRoot,top,peak,jumping
    local function message(text)
        if state.running then status:SetDesc(text) end
    end
    local function clearFloor()
        if platform then platform:Destroy() end
        platform,activeRoot,top,peak,jumping=nil,nil,nil,nil,false
    end
    local function feetHeight(character,humanoid,root)
        local offset=humanoid.HipHeight+root.Size.Y/2
        if humanoid.RigType==Enum.HumanoidRigType.R6 then
            local leg=character:FindFirstChild("Left Leg") or character:FindFirstChild("Right Leg")
            offset=offset+(leg and leg.Size.Y or 2)
        end
        return root.Position.Y-offset
    end
    local function placeFloor(root)
        platform.CFrame=CFrame.new(root.Position.X,top-platform.Size.Y/2,root.Position.Z)
    end
    local function createFloor(character,humanoid,root)
        clearFloor()
        activeRoot=root
        top=feetHeight(character,humanoid,root)-0.05
        peak=top
        platform=Instance.new("Part")
        platform.Name="RoSnipeAirWalkFloor"
        platform.Size=Vector3.new(10,0.5,10)
        platform.Anchored=true
        platform.Transparency=1
        platform.CanCollide=true
        platform.CanTouch=false
        platform.CanQuery=false
        placeFloor(root)
        platform.Parent=workspace
        message("Air Walk on. Walk normally; jump to climb. Lower Height moves down 3 studs.")
    end
    stopAirWalk=function(reason)
        enabled=false;clearFloor()
        if toggle.Value then
            changing=true;toggle:SetValue(false);changing=false
        end
        message(reason or "Air Walk off.")
    end
    toggle:OnChanged(function(value)
        if changing then return end
        if not value then stopAirWalk();return end
        -- Let manual movement have the character while Air Walk is enabled.
        if stopAutoBuild then stopAutoBuild("Stopped: Air Walk enabled.") end
        if stopChestPickup then stopChestPickup(false) end
        if stopTotemUpgrade then stopTotemUpgrade("Stopped: Air Walk enabled.") end
        if stopBossFarm then stopBossFarm("Stopped: Air Walk enabled.") end
        if stopFarming then stopFarming("Stopped: Air Walk enabled.") end
        if stopCutting then stopCutting() end
        farmToggle:SetValue(false);auraToggle:SetValue(false)
        stopCombat()
        enabled=true
        local character,humanoid,root=getCharacter()
        if root then createFloor(character,humanoid,root)
        else message("Air Walk waiting for your character.") end
    end)
    section:AddButton({Title="Lower Height (3 Studs)",Callback=function()
        if not enabled or not platform then message("Enable Air Walk first.");return end
        top=top-3;peak=top;jumping=false
        -- Clear the ascent left over from a jump before lowering the floor.
        local velocity=activeRoot.AssemblyLinearVelocity
        activeRoot.AssemblyLinearVelocity=Vector3.new(velocity.X,math.min(velocity.Y,0),velocity.Z)
        placeFloor(activeRoot)
    end})
    table.insert(connections,RunService.Heartbeat:Connect(function()
        if not state.running or not enabled then return end
        local character,humanoid,root=getCharacter()
        if not root then clearFloor();return end
        if root~=activeRoot or not platform or not platform.Parent then
            createFloor(character,humanoid,root)
        end
        local feet=feetHeight(character,humanoid,root)
        local rising=root.AssemblyLinearVelocity.Y
        -- Leave the floor behind during ascent so jumping behaves normally.
        if not jumping and feet>top+0.5 and rising>1 then
            jumping=true;peak=feet
        end
        if jumping then
            peak=math.max(peak,feet)
            if rising<=0 then
                top=math.max(top,peak);jumping=false
            end
        end
        placeFloor(root)
    end))
end
installAirWalk()


local function shutdown()
    if not state.running then return end
    if stopAirWalk then stopAirWalk("Hub unloaded.") end
    if stopCratePackerRecorder then stopCratePackerRecorder("Hub unloaded.") end
    if stopChestPickup then stopChestPickup(true) end
    if stopTotemUpgrade then stopTotemUpgrade() end
    if stopBossFarm then stopBossFarm() end
    if stopFarming then stopFarming() end
    state.running = false
    if stopAutoBuild then stopAutoBuild(nil, true) end
    state.autoFarm, state.killAura = false, false
    state.treeFarm, state.treeAura = false, false
    stopCombat()
    KillGui:Destroy()
    for _, connection in ipairs(connections) do connection:Disconnect() end
end
Settings:AddButton({
    Title = "Unload",
    Callback = function()
        shutdown()
        Fluent:Destroy()
    end,
})

table.insert(connections, UserInputService.WindowFocusReleased:Connect(function()
    windowFocused = false
    stopCombat()
end))
table.insert(connections, UserInputService.WindowFocused:Connect(function()
    windowFocused = true
end))
table.insert(connections, LocalPlayer.CharacterRemoving:Connect(function()
    if stopAirWalk then stopAirWalk("Stopped: character respawning.") end
    if stopCratePackerRecorder then stopCratePackerRecorder("Character respawning.") end
    if stopBossFarm then stopBossFarm("Stopped: character respawning.") end
    if stopFarming then stopFarming("Stopped: character respawning.") end
    if stopAutoBuild then stopAutoBuild("Stopped: character respawning.") end
    stopCombat()
    tokenTracker.previous = nil
    tokenTracker.rebaseUntil = math.huge
end))
table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
    stopCombat()
    tokenTracker.previous = nil
    tokenTracker.emptySince = nil
    tokenTracker.rebaseUntil = os.clock() + 2
    combatRemote, combatKey, combatHash, combatWeapon = nil, nil, nil, nil
    treeRemote, treeHashKey, treeHashValue = nil, nil, nil
    if state.autoFarm or state.bossFarm or state.killAura then
        task.delay(1, refreshCombat)
    end
end))

-- Constant-speed movement and hover are local to this farm; no player/fly tab required.
table.insert(connections, RunService.Heartbeat:Connect(function(dt)
    if Fluent.Unloaded then shutdown() return end
    local character, humanoid, root = getCharacter()
    if rageData and state.rageblade and state.weapon == "rageblade" and (state.autoFarm or state.bossFarm)
        and character and rageTool and rageTool.Parent == character then
        rageData.lastClicked = 0
    elseif rageData then
        restoreRageblade()
    end
    local destination
    if state.totemUpgrade and state.totemDestination then
        destination = state.totemDestination
    elseif state.cropDestination then
        destination = state.cropDestination
    elseif state.treeFarm and validTreeTarget(state.treeTarget) then
        -- Cutting stands beside the trunk; the -10 offset belongs to Combat only.
        destination = state.treeTarget.trunk.Position + Vector3.new(0, 0, 6)
    elseif state.bossFarm and state.bossDestination then
        destination = state.bossDestination
    elseif state.autoFarm or state.bossFarm then
        local target = state.target
        local targetRoot = target and target.Parent and target:FindFirstChild("HumanoidRootPart")
        local targetHumanoid = target and target:FindFirstChildOfClass("Humanoid")
        if targetRoot and targetHumanoid and targetHumanoid.Health > 0 then
            destination = targetRoot.Position + Vector3.new(0, state.height, 0)
        end
    end
    -- A boss can die during attack()'s wait. Keep hovering and return immediately,
    -- rather than dropping the player until the next combat-worker iteration.
    if state.bossFarm and root and not destination then
        destination=state.bossReturnPosition or root.Position
    end
    if (resolving and not state.bossFarm) or not root or not destination then
        restoreMovement()
        return
    end
    if movementRoot ~= root then
        restoreMovement()
        movementRoot = root
        floatVelocity = Instance.new("BodyVelocity")
        floatVelocity.Name = "MobFarmHover"
        floatVelocity.MaxForce = Vector3.new(1e9, 1e9, 1e9)
        floatVelocity.Velocity = Vector3.zero
        floatVelocity.Parent = root
    end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            if collisions[part] == nil then collisions[part] = part.CanCollide end
            part.CanCollide = false
        end
    end
    local delta = destination - root.Position
    if state.movement == "Instant" or delta.Magnitude <= state.speed * dt then
        root.CFrame = CFrame.new(destination)
    elseif delta.Magnitude > 0 then
        root.CFrame = CFrame.new(root.Position + delta.Unit * state.speed * dt)
    end
end))

task.spawn(function()
    while state.running do
        if not resolving and (state.bossFarm or (combatRemote and state.autoFarm)) then
            local ok, err = pcall(function()
                if state.bossFarm then
                    runBossOnce()
                elseif state.autoFarm then
                    state.target = findNearestMob(true)
                    if state.target then attack(state.target, true) end
                else
                    state.target = nil
                end
            end)
            if not ok then
                if state.bossFarm then stopBossFarm("Boss error: "..tostring(err)) end
                state.autoFarm = false
                stopCombat()
                farmToggle:SetValue(false)
                setStatus(tostring(err))
                warn("[Mob Farm] " .. tostring(err))
            end
        end
        task.wait(0.1)
    end
end)

task.spawn(function()
    while state.running do
        if (state.treeFarm or state.treeAura) and not resolving then
            local ok, err = pcall(runTreeOnce)
            if not ok then
                stopCutting()
                setTreeStatus("Cutting error: " .. tostring(err))
            end
        end
        task.wait(state.treeInterval)
    end
end)

-- One click worker serves both combat modes; remote attacks never wait on it.
task.spawn(function()
    while state.running do
        if (state.autoFarm or state.bossFarm or state.killAura) and combatRemote and not resolving then
            local ok, err = pcall(runCombatClick)
            if not ok then
                releaseCombatActivation()
                setClickStatus(tostring(err) .. " | Close overlays and release left-click. Targeted hits remain enabled.")
            end
        else
            releaseCombatActivation()
            setClickStatus("Off")
        end
        task.wait(0.35)
    end
end)

-- The stationary aura uses the same remote path as Mob Auto Farm.
-- Auto Farm takes precedence if both toggles are enabled, avoiding duplicate bursts.
task.spawn(function()
    while state.running do
        if state.killAura and not state.autoFarm and not state.bossFarm and combatRemote and not resolving then
            local ok, err = pcall(function()
                local mob, reason = findAuraSlime()
                if mob then attack(mob, false) else setAuraStatus(reason) end
            end)
            if not ok then
                auraToggle:SetValue(false)
                setAuraStatus("Slime Aura error: " .. tostring(err))
            end
        end
        task.wait(state.auraInterval)
    end
end)

-- Capture the baseline before starting the polling loop; owned tokens are not kills.
tokenTracker.previous, tokenTracker.source = readTokenBalance()
task.spawn(function()
    while state.running do
        local ok, err = pcall(function()
            local amount, source, reason = readTokenBalance()
            sampleTokenBalance(amount, source, os.clock())
            tokenTracker.message = reason or "Tracking"
            updateKillDisplay()
        end)
        if not ok then
            tokenTracker.message = "Token tracking unavailable"
            warn("[Kill Counter] " .. tostring(err))
        end
        task.wait(0.2)
    end
end)

applyUIColor(selectedColor)
Window:SelectTab(1)
