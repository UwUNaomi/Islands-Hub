-- Standalone wood cutting, extracted from mob-farm.client.luau's Tree Aura.
-- Starts enabled. Cuts nearby trees and walks right (D direction), including while unfocused.
-- Requires the same executor APIs as the hub. Server reach/cooldowns still apply.
-- Stop: getgenv().IslandsWoodCutting.Stop()
local TREE_TYPE = "All" -- All, Oak, Birch, Maple, Pine, Hickory, Spirit, CherryBlossom, Apple, Lemon
local RANGE = 29 -- studs
local HIT_INTERVAL = 0.1 -- lowest supported interval; seconds after each completed request

if not game:IsLoaded() then game.Loaded:Wait() end
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "Run wood cutting on the client.")

local environment = getgenv and getgenv() or _G
local previous = environment.IslandsWoodCutting
if type(previous) == "table" and type(previous.Stop) == "function" then
    previous.Stop()
    assert(not previous.pendingTreeHit or previous.pendingTreeHit.done,
        "The previous wood-cutting hit is still pending. Wait for it to finish before executing again.")
end
local state = {
    running = true,
    treeType = TREE_TYPE,
    treeRange = RANGE,
    treeInterval = HIT_INTERVAL,
    status = "Starting wood cutting...",
}
environment.IslandsWoodCutting = state
local characterConnection, movementConnection, focusLostConnection, focusGainedConnection
local movedHumanoid
local windowFocused = true
local RIGHT_DIRECTION = Vector3.new(1, 0, 0)
local function stopMovement()
    if movedHumanoid and movedHumanoid.Parent then
        movedHumanoid:Move(Vector3.zero, false)
    end
    movedHumanoid = nil
end
function state.Stop()
    state.running = false
    state.treeTarget = nil
    state.status = "Off"
    stopMovement()
    if movementConnection then
        movementConnection:Disconnect()
        movementConnection = nil
    end
    if focusLostConnection then
        focusLostConnection:Disconnect()
        focusLostConnection = nil
    end
    if focusGainedConnection then
        focusGainedConnection:Disconnect()
        focusGainedConnection = nil
    end
    if characterConnection then
        characterConnection:Disconnect()
        characterConnection = nil
    end
end

local lastTreeStatus
local treeRemote, treeHashKey, treeHashValue
local function setTreeStatus(message)
    if state.running and message ~= lastTreeStatus then
        lastTreeStatus = message
        state.status = message
        print("[Wood Cutting] " .. message)
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

local function netManaged()
    local current = ReplicatedStorage
    for _, name in ipairs({ "rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged" }) do
        current = current:FindFirstChild(name)
        assert(current, "Missing game remote folder: " .. name)
    end
    return current
end

local treePatterns = {
    All = "^tree", Oak = "^tree%d+$", Birch = "^treeBirch%d*$",
    Maple = "^treeMaple%d*$", Pine = "^treePine%d*$", Hickory = "^treeHickory%d*$",
    Spirit = "^treeSpirit%d*$", CherryBlossom = "^treeCherryBlossom%d*$",
    Apple = "^treeApple%d*$", Lemon = "^treeLemon%d*$",
}
local axeNames = { "diamondAxe", "gildedSteelAxe", "ironAxe", "opalAxe", "stoneAxe", "woodAxe" }
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
        if (root.Position - state.treeTarget.trunk.Position).Magnitude <= state.treeRange then
            return state.treeTarget
        end
    end
    local islands = workspace:FindFirstChild("Islands")
    if not islands then return nil,"No island blocks are loaded yet." end
    local nearest, best = nil, state.treeRange
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
    return nil,"Found "..withPart.." "..state.treeType.." trees outside the "..state.treeRange.."-stud aura range. Waiting for a tree within reach."
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
    error("Current axe-tool hash not found. Equip an axe, hit a tree manually, then execute this script again.")
end

local function runTreeOnce()
    local character, humanoid, root = getCharacter()
    if not character then setTreeStatus("Waiting for your character.") return end
    local function current()
        return state.running and environment.IslandsWoodCutting == state
            and LocalPlayer.Character == character and humanoid.Health > 0
    end
    local axe = detectTreeAxe(character)
    if not axe then
        state.treeTarget = nil
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
        setTreeStatus("Waiting for a tree within reach.")
        return
    end
    if not treeRemote or not treeRemote.Parent then resolveTreeCombat() end
    if not current() or not validTreeTarget(target) or axe.Parent ~= character then return end
    if state.pendingTreeHit and not state.pendingTreeHit.done then
        error("Previous tree hit is still waiting for the server. Wait before retrying.")
    end
    if (root.Position - target.trunk.Position).Magnitude > state.treeRange then return end
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
    state.pendingTreeHit = request
    setTreeStatus("Sending tree hit: " .. target.tree.Name .. " with " .. axe.Name .. ".")
    task.spawn(function()
        request.ok, request.result = pcall(function()
            if not current() or not validTreeTarget(target) or axe.Parent ~= character
                or not axe.Enabled or (root.Position - target.trunk.Position).Magnitude > state.treeRange then return end
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
    state.pendingTreeHit = nil
    if not current() then return end
    if not request.ok then error(request.result, 0) end
    if request.result == false then error("Server rejected the tree hit. Check reach and island permissions.") end

end

assert(treePatterns[state.treeType], "Unknown TREE_TYPE: " .. tostring(state.treeType))
assert(type(RANGE) == "number" and RANGE > 0, "RANGE must be positive.")
assert(type(HIT_INTERVAL) == "number" and HIT_INTERVAL >= 0.1, "HIT_INTERVAL must be at least 0.1 seconds.")
characterConnection = LocalPlayer.CharacterAdded:Connect(function()
    stopMovement()
    state.treeTarget = nil
    treeRemote, treeHashKey, treeHashValue = nil, nil, nil
end)

local function syncRightMovement()
    if not state.running or environment.IslandsWoodCutting ~= state then
        state.Stop()
        return
    end
    local character, humanoid = getCharacter()
    -- A text box only pauses walking while Roblox itself has focus.
    if not character or (windowFocused and UserInputService:GetFocusedTextBox() ~= nil) then
        stopMovement()
        return
    end
    if movedHumanoid ~= humanoid then
        stopMovement()
        movedHumanoid = humanoid
    end
    -- Reapply camera-relative D movement after input controls, before physics.
    -- No key-down cache or render callback: focus loss cannot clear this command.
    humanoid:Move(RIGHT_DIRECTION, true)
end
focusLostConnection = UserInputService.WindowFocusReleased:Connect(function()
    windowFocused = false
    syncRightMovement()
end)
focusGainedConnection = UserInputService.WindowFocused:Connect(function()
    windowFocused = true
    syncRightMovement()
end)
movementConnection = RunService.PreSimulation:Connect(syncRightMovement)
syncRightMovement()

setTreeStatus("Enabled: scanning nearby " .. state.treeType .. " trees; axe detection is automatic.")
task.spawn(function()
    while state.running and environment.IslandsWoodCutting == state do
        -- A respawn must not queue another hit while the old request is pending.
        if not state.pendingTreeHit or state.pendingTreeHit.done then
            local ok, err = pcall(runTreeOnce)
            if not ok and state.running then
                setTreeStatus("Stopped: " .. tostring(err))
                local message = state.status
                state.Stop()
                state.status = message
                warn("[Wood Cutting] " .. message)
            end
        end
        if state.running then task.wait(state.treeInterval) end
    end
end)
return state
