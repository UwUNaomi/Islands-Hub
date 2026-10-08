-- RoSnipe chest aura test - targets only chestLargeIndustrialIO on your own island.
-- Start/Stop GUI; withdrawals are one stack at a time and the same stack is retried
-- until its transfer is visible or you press Stop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local TARGET_NAME = "chestLargeIndustrialIO"

local oldGui = LocalPlayer:WaitForChild("PlayerGui"):FindFirstChild("RoSnipeChestAuraTest")
if oldGui then oldGui:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "RoSnipeChestAuraTest"
gui.ResetOnSpawn = false
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(360, 170)
frame.Position = UDim2.new(0.5, -180, 0.35, 0)
frame.BackgroundColor3 = Color3.fromRGB(250, 220, 232)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 30)
title.Position = UDim2.fromOffset(10, 8)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 17
title.TextColor3 = Color3.fromRGB(45, 30, 38)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Chest Aura Test"
title.Parent = frame

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 54)
status.Position = UDim2.fromOffset(10, 42)
status.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
status.BackgroundTransparency = 0.12
status.BorderSizePixel = 0
status.Font = Enum.Font.Gotham
status.TextSize = 13
status.TextColor3 = Color3.fromRGB(45, 30, 38)
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Center
status.Text = "Stopped. Target: " .. TARGET_NAME
status.Parent = frame
Instance.new("UICorner", status).CornerRadius = UDim.new(0, 7)

local function makeButton(text, x, color)
    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(160, 40)
    button.Position = UDim2.fromOffset(x, 112)
    button.BackgroundColor3 = color
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.TextSize = 14
    button.TextColor3 = Color3.fromRGB(45, 30, 38)
    button.Text = text
    button.Parent = frame
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
    return button
end

local startButton = makeButton("Start", 10, Color3.fromRGB(255, 255, 255))
local stopButton = makeButton("Stop", 190, Color3.fromRGB(242, 185, 208))

local running = false
local hoverForce
local noclipConnection
local savedCollision = {}

local function getCharacter()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return character, humanoid, root
end

local function setNoclip(enabled)
    if enabled then
        local function disableCollisions()
            local character = LocalPlayer.Character
            if not character then return end
            for _, part in ipairs(character:GetDescendants()) do
                if part:IsA("BasePart") then
                    if savedCollision[part] == nil then savedCollision[part] = part.CanCollide end
                    part.CanCollide = false
                end
            end
        end
        disableCollisions()
        if not noclipConnection then
            noclipConnection = RunService.Heartbeat:Connect(disableCollisions)
        end
    else
        if noclipConnection then noclipConnection:Disconnect(); noclipConnection = nil end
        for part, wasCollidable in pairs(savedCollision) do
            if part.Parent then part.CanCollide = wasCollidable end
            savedCollision[part] = nil
        end
    end
end

local function clearMovement()
    setNoclip(false)
    if hoverForce then hoverForce:Destroy(); hoverForce = nil end
end

local function findOwnBlocks()
    local islands = workspace:FindFirstChild("Islands")
    if not islands then return nil end
    for _, island in ipairs(islands:GetChildren()) do
        local owners = island:FindFirstChild("Owners")
        local blocks = island:FindFirstChild("Blocks")
        if owners and blocks and owners:FindFirstChild(tostring(LocalPlayer.UserId)) then
            return blocks
        end
    end
end

local function getChestPart(chest)
    if chest:IsA("BasePart") then return chest end
    return chest:FindFirstChild("Root", true) or chest:FindFirstChildWhichIsA("BasePart", true)
end

local function moveBeside(chest)
    local _, _, root = getCharacter()
    local part = getChestPart(chest)
    if not root or not part then return false end
    local offset = Vector3.new(root.Position.X - part.Position.X, 0, root.Position.Z - part.Position.Z)
    if offset.Magnitude < 0.1 then offset = Vector3.new(0, 0, 1) end
    local destination = part.Position + Vector3.new(0, 3, 0) + offset.Unit * 5
    local safeY = math.max(root.Position.Y, part.Position.Y + 10)
    local waypoints = {
        Vector3.new(root.Position.X, safeY, root.Position.Z),
        Vector3.new(destination.X, safeY, destination.Z),
        destination,
    }
    if not hoverForce then
        hoverForce = Instance.new("BodyPosition")
        hoverForce.Name = "RoSnipeChestAuraHover"
        hoverForce.MaxForce = Vector3.new(1e9, 1e9, 1e9)
        hoverForce.P, hoverForce.D = 10000, 1000
        hoverForce.Position = root.Position
        hoverForce.Parent = root
    end
    setNoclip(true)
    for _, waypoint in ipairs(waypoints) do
        while running and root.Parent and (root.Position - waypoint).Magnitude > 2 do
            local delta = waypoint - root.Position
            local step = math.min(delta.Magnitude, 1.5) -- about 30 studs/second
            local nextPosition = root.Position + delta.Unit * step
            hoverForce.Position = nextPosition
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            root.CFrame = CFrame.new(nextPosition) * root.CFrame.Rotation
            task.wait(0.05)
        end
        if not running then
            clearMovement()
            return false
        end
    end
    hoverForce.Position = root.Position
    setNoclip(false)
    return (root.Position - part.Position).Magnitude <= 14
end

local function getRemote()
    local node = ReplicatedStorage
    for _, name in ipairs({"rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged"}) do
        node = node and node:FindFirstChild(name)
    end
    local remote = node and node:FindFirstChild("CLIENT_CHEST_TRANSACTION")
    assert(remote and remote:IsA("RemoteFunction"), "CLIENT_CHEST_TRANSACTION not found")
    return remote
end

local function inventoryAmount(name)
    local amount = 0
    for _, container in ipairs({LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character}) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool.Name == name then
                    local value = tool:FindFirstChild("Amount")
                    amount += value and (tonumber(value.Value) or 0) or 1
                end
            end
        end
    end
    return amount
end

local function withdrawChest(remote, chest, index, total)
    local contents = chest:FindFirstChild("Contents")
    if not contents then return 0 end
    local moved = 0
    for _, item in ipairs(contents:GetChildren()) do
        while running and item.Parent == contents do
            local amountValue = item:FindFirstChild("Amount")
            local amount = amountValue and tonumber(amountValue.Value)
            if not amount or amount <= 0 then
                status.Text = "Can't read stack amount for " .. item.Name .. "; skipping it."
                break
            end
            local before = inventoryAmount(item.Name)
            status.Text = "Chest " .. index .. " / " .. total .. ": taking " .. item.Name .. " × " .. amount
            local ok, response = pcall(function()
                return remote:InvokeServer({
                    chest = chest,
                    player_tracking_category = "join_from_web",
                    amount = amount,
                    tool = item,
                    action = "withdraw",
                })
            end)
            local rejected = not ok or response == false or (type(response) == "table" and response.success == false)
            if not rejected then
                for _ = 1, 12 do
                    if not running then return moved end
                    local currentAmount = item:FindFirstChild("Amount")
                    if item.Parent ~= contents or (currentAmount and (tonumber(currentAmount.Value) or amount) < amount)
                        or inventoryAmount(item.Name) > before then
                        moved += 1
                        break
                    end
                    task.wait(0.1)
                end
            end
            local currentAmount = item:FindFirstChild("Amount")
            local transferred = item.Parent ~= contents or (currentAmount and (tonumber(currentAmount.Value) or amount) < amount)
                or inventoryAmount(item.Name) > before
            if transferred then
                if item.Parent == contents and currentAmount and tonumber(currentAmount.Value) and tonumber(currentAmount.Value) < amount then
                    task.wait(0.1) -- retry the remaining part of this stack
                else
                    break
                end
            else
                status.Text = (rejected and "Server rejected request" or "No transfer detected") .. "; retrying " .. item.Name .. " on this chest..."
                task.wait(0.5)
            end
        end
    end
    return moved
end

local function runAura()
    local ok, err = xpcall(function()
        local remote = getRemote()
        local totalMoved = 0
        while running do
            local blocks = findOwnBlocks()
            assert(blocks, "Couldn't find your island's Blocks folder.")
            local _, _, root = getCharacter()
            assert(root, "Wait for your character to spawn.")
            local chests = {}
            for _, block in ipairs(blocks:GetChildren()) do
                if block.Name == TARGET_NAME and block:FindFirstChild("Contents") then
                    local part = getChestPart(block)
                    if part then table.insert(chests, {block = block, distance = (root.Position - part.Position).Magnitude}) end
                end
            end
            table.sort(chests, function(a, b) return a.distance < b.distance end)
            if #chests == 0 then
                status.Text = "No " .. TARGET_NAME .. " chests found on your island. Scanning again..."
            else
                for index, entry in ipairs(chests) do
                    if not running then break end
                    status.Text = "Moving to industrial chest " .. index .. " / " .. #chests
                    if moveBeside(entry.block) then
                        totalMoved += withdrawChest(remote, entry.block, index, #chests)
                        status.Text = "Chest " .. index .. " / " .. #chests .. " done. " .. totalMoved .. " stack transfer(s) confirmed."
                    else
                        status.Text = "Couldn't get beside chest " .. index .. "; will scan again."
                    end
                end
            end
            task.wait(1)
        end
    end, debug.traceback)
    clearMovement()
    if not ok then status.Text = "Stopped after error: " .. tostring(err) end
    if running then running = false end
end

startButton.MouseButton1Click:Connect(function()
    if running then return end
    running = true
    status.Text = "Starting. Scanning your island for " .. TARGET_NAME .. "..."
    task.spawn(runAura)
end)

stopButton.MouseButton1Click:Connect(function()
    running = false
    clearMovement()
    status.Text = "Stopped."
end)

gui.Destroying:Connect(function()
    running = false
    clearMovement()
end)
