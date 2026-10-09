-- Windows/Xeno attack compatibility test. Uses the equipped weapon's own code.
-- No hash lookup, remote replay, movement, flight, noclip, or attack hooks.
-- Stand beside a slime, equip your weapon, and press Start.

repeat task.wait() until game:IsLoaded()
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer
local running, closed = false, false
local attempts, observedDamage, lastError = 0, 0, nil
local healthSamples, log = {}, { "RoSnipe Windows Tool Activate test v2" }
local cameraSnapshot, activeTool
local INTERVAL, RANGE = 0.65, 12

local function create(class, properties, parent)
    local instance = Instance.new(class)
    for key, value in pairs(properties) do instance[key] = value end
    instance.Parent = parent
    return instance
end
local screen = create("ScreenGui", {
    Name = "RoSnipeWindowsAttackTest", ResetOnSpawn = false, DisplayOrder = 10000,
}, nil)
local parentOk = pcall(function() screen.Parent = game:GetService("CoreGui") end)
if not parentOk then screen.Parent = player:WaitForChild("PlayerGui") end
local panel = create("Frame", {
    Position = UDim2.fromOffset(16, 70), Size = UDim2.fromOffset(345, 275),
    BackgroundColor3 = Color3.fromRGB(250, 215, 228), BorderSizePixel = 0,
}, screen)
create("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
create("TextLabel", {
    Position = UDim2.fromOffset(12, 8), Size = UDim2.fromOffset(321, 28),
    Text = "RoSnipe Windows Slime Test", Font = Enum.Font.GothamBold, TextSize = 17,
    BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(50, 35, 43),
}, panel)
local status = create("TextLabel", {
    Position = UDim2.fromOffset(12, 42), Size = UDim2.fromOffset(321, 90),
    Text = "Equip a melee weapon and stand beside a slime. Tests normal attacks every 0.65s; range 12 studs.",
    Font = Enum.Font.Gotham, TextSize = 13, TextWrapped = true,
    BackgroundColor3 = Color3.new(1, 1, 1), TextColor3 = Color3.fromRGB(50, 35, 43),
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 6) }, status)
local function button(text, x, y, width, callback)
    local b = create("TextButton", {
        Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, 34),
        Text = text, Font = Enum.Font.GothamSemibold, TextSize = 12, BorderSizePixel = 0,
        BackgroundColor3 = Color3.new(1, 1, 1), TextColor3 = Color3.fromRGB(50, 35, 43),
    }, panel)
    create("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    b.Activated:Connect(callback)
    return b
end
local startButton
local function release()
    if activeTool then
        local ok, err = pcall(function() activeTool:Deactivate() end)
        if not ok then return false, tostring(err) end
        activeTool = nil
    end
    return true
end
local function restoreCamera()
    if cameraSnapshot then
        local snapshot = cameraSnapshot
        cameraSnapshot = nil
        pcall(function()
            snapshot.camera.CFrame = snapshot.cframe
            snapshot.camera.CameraSubject = snapshot.subject
            snapshot.camera.CameraType = snapshot.kind
        end)
    end
end
local function stop(reason)
    running = false
    local released, err = release()
    restoreCamera()
    if not released then lastError = "Tool deactivation failed: " .. tostring(err) end
    if startButton then startButton.Text = "Start" end
    if not closed then status.Text = not released and lastError or (reason or "Stopped.") end
end
local function getTarget()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then return nil end
    local island = workspace:FindFirstChild("WildernessIsland")
    local entities = island and island:FindFirstChild("Entities")
    local nearest, distance = nil, RANGE
    for _, mob in ipairs(entities and entities:GetChildren() or {}) do
        local mobRoot = mob:IsA("Model") and (mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart)
        local health = mob:FindFirstChildOfClass("Humanoid")
        if mob:IsA("Model") and mob.Name:lower():find("slime", 1, true) and mobRoot and health and health.Health > 0 then
            local length = (root.Position - mobRoot.Position).Magnitude
            if length <= distance then nearest, distance = mob, length end
        end
    end
    return nearest, distance
end
local function aim(mob)
    local camera = workspace.CurrentCamera
    local root = mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart
    assert(camera and root, "Camera or target missing")
    if cameraSnapshot and cameraSnapshot.camera ~= camera then restoreCamera() end
    if not cameraSnapshot then
        cameraSnapshot = { camera = camera, kind = camera.CameraType, subject = camera.CameraSubject, cframe = camera.CFrame }
    end
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = CFrame.lookAt(camera.CFrame.Position, root.Position)
end
local function attack(mob)
    local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
    assert(tool, "No equipped Tool")
    assert(tool.Enabled, "Equipped Tool is disabled")
    assert(not tool.RequiresHandle or tool:FindFirstChild("Handle"), "Tool requires a missing Handle")
    aim(mob)
    activeTool = tool
    tool:Activate()
    task.wait(0.06)
    local released, err = release()
    assert(released, err)
    attempts = attempts + 1
end
local function report()
    return table.concat(log, "\n") .. "\nMethod=Tool Activate Attempts=" .. attempts
        .. " Observed health decreases=" .. observedDamage .. " Last error=" .. tostring(lastError or "none")
end
create("TextLabel", {
    Position = UDim2.fromOffset(12, 144), Size = UDim2.fromOffset(321, 34),
    Text = "Attack method: Tool:Activate()", Font = Enum.Font.GothamSemibold, TextSize = 13,
    BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(50, 35, 43),
}, panel)
startButton = button("Start", 12, 188, 155, function()
    if running then stop(); return end
    local released, err = release()
    if not released then status.Text = "Cannot deactivate the previous tool: " .. tostring(err); return end
    running, lastError = true, nil
    startButton.Text = "Stop"
end)
button("Copy Report", 177, 188, 156, function()
    local text = report()
    local copy = setclipboard or toclipboard
    local saved = type(writefile) == "function" and pcall(writefile, "rosnipe-windows-attack-test.txt", text)
    if type(copy) == "function" then
        local ok, err = pcall(copy, text)
        status.Text = ok and "Report copied." or tostring(err)
    else status.Text = saved and "Saved rosnipe-windows-attack-test.txt" or "Clipboard and report saving unavailable."; print(text) end
end)
button("Close", 12, 232, 321, function() stop(); closed = true; screen:Destroy() end)
local inputConnection = UIS.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then panel.Visible = not panel.Visible end
end)
screen.Destroying:Connect(function() stop(); closed = true; inputConnection:Disconnect() end)
task.spawn(function()
    while not closed do
        if running then
            local mob, distance = getTarget()
            if mob then
                local humanoid = mob:FindFirstChildOfClass("Humanoid")
                local previous = healthSamples[mob]
                if previous and humanoid.Health < previous then observedDamage = observedDamage + 1 end
                healthSamples[mob] = humanoid.Health
                local ok, err = pcall(attack, mob)
                if not ok then
                    lastError = tostring(err)
                    table.insert(log, "Tool Activate: " .. lastError)
                    stop("Attack failed: " .. lastError)
                elseif running and not closed then
                    status.Text = "Tool Activate | " .. mob.Name .. " | " .. math.floor(distance) .. " studs\n"
                        .. "Attempts: " .. attempts .. " | Health decreases observed: " .. observedDamage
                        .. "\nWatch slime health to confirm damage. Right Shift hides this panel."
                end
            else
                restoreCamera()
                status.Text = "Waiting for a living slime within 12 studs. Walk beside one with your weapon equipped."
            end
        end
        task.wait(INTERVAL)
    end
end)
