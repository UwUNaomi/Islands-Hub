-- Standalone, read-only Islands melee hit diagnostic.
-- Run this after equipping the weapon and manually hitting a slime once.
-- It does not send game remotes, activate tools, or automate attacks.

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local REPORT_NAME = "islands-mob-hit-diagnostic.txt"
local lines = {}
local running = false

local function append(value)
    table.insert(lines, tostring(value))
end

local function make(className, properties, parent)
    local object = Instance.new(className)
    for key, value in pairs(properties) do object[key] = value end
    object.Parent = parent
    return object
end

local screen = Instance.new("ScreenGui")
screen.Name = "SlimeHitDiagnosticGui"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 10000
pcall(function()
    if type(protect_gui) == "function" then protect_gui(screen)
    elseif syn and type(syn.protect_gui) == "function" then syn.protect_gui(screen) end
end)
local parentOk = pcall(function() screen.Parent = CoreGui end)
if not parentOk then screen.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local window = make("Frame", {
    Name = "Window", Size = UDim2.fromOffset(620, 470), Position = UDim2.new(0.5, -310, 0.5, -235),
    BackgroundColor3 = Color3.fromRGB(250, 215, 228), BackgroundTransparency = 0.08, BorderSizePixel = 0,
}, screen)
make("UICorner", { CornerRadius = UDim.new(0, 10) }, window)
make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 2, Transparency = 0.1 }, window)
local title = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 38), Position = UDim2.fromOffset(12, 8), BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold, Text = "Slime Hit Diagnostic", TextSize = 20,
    TextColor3 = Color3.fromRGB(55, 35, 45), TextXAlignment = Enum.TextXAlignment.Left,
}, window)
local status = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 32), Position = UDim2.fromOffset(12, 46), BackgroundTransparency = 1,
    Font = Enum.Font.Gotham, Text = "Equip the weapon, hit a slime manually, then run the scan.", TextSize = 13,
    TextColor3 = Color3.fromRGB(65, 48, 58), TextXAlignment = Enum.TextXAlignment.Left,
    TextWrapped = true,
}, window)
local output = make("ScrollingFrame", {
    Name = "Report", Size = UDim2.new(1, -24, 1, -142), Position = UDim2.fromOffset(12, 82),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255), BackgroundTransparency = 0.12,
    BorderSizePixel = 0, ScrollBarThickness = 8, CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, window)
make("UICorner", { CornerRadius = UDim.new(0, 7) }, output)
local reportLabel = make("TextLabel", {
    Name = "ReportText", Size = UDim2.new(1, -16, 0, 0), Position = UDim2.fromOffset(8, 8),
    BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Font = Enum.Font.Code,
    Text = "Click Run Diagnostic to scan. The report is also saved to your executor workspace.",
    TextSize = 12, TextColor3 = Color3.fromRGB(45, 40, 45), TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, output)

local function button(label, x, width, callback)
    local b = make("TextButton", {
        Size = UDim2.fromOffset(width, 38), Position = UDim2.new(0, x, 1, -48),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255), BackgroundTransparency = 0.08,
        BorderSizePixel = 0, Font = Enum.Font.GothamSemibold, Text = label,
        TextSize = 13, TextColor3 = Color3.fromRGB(45, 38, 44), AutoButtonColor = true,
    }, window)
    make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    make("UIStroke", { Color = Color3.fromRGB(218, 160, 185), Thickness = 1 }, b)
    b.Activated:Connect(callback)
    return b
end

local runButton
local function setReport(text)
    reportLabel.Text = text
    output.CanvasPosition = Vector2.new(0, 0)
end

local function runDiagnostic()
    if running then return end
    running = true
    runButton.Text = "Scanning..."
    status.Text = "Scanning functions. This may take a few seconds."
    task.spawn(function()
        local ok, err = pcall(function()
            lines = {}
            local info = getinfo or (debug and debug.getinfo)
            local constants = getconstants or (debug and debug.getconstants)
            local upvalues = getupvalues or (debug and debug.getupvalues)
            local protos = getprotos or (debug and debug.getprotos)
            append("RoSnipe standalone slime-hit diagnostic v1")
            append("PlaceId=" .. tostring(game.PlaceId) .. " PlaceVersion=" .. tostring(game.PlaceVersion))
            append("getgc=" .. type(getgc) .. " getinfo=" .. type(info) .. " getconstants=" .. type(constants)
                .. " getupvalues=" .. type(upvalues) .. " getprotos=" .. type(protos) .. " getfenv=" .. type(getfenv))
            local character = LocalPlayer.Character
            local equipped = character and character:FindFirstChildOfClass("Tool")
            append("Equipped weapon=" .. tostring(equipped and equipped.Name or "none"))
            if not equipped then append("WARNING: No tool equipped. Equip the selected weapon, manually hit a slime, and rerun.") end

            local net = game:GetService("ReplicatedStorage")
            for _, name in ipairs({ "rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged" }) do
                net = net and net:FindFirstChild(name)
            end
            local remotes = net and net:GetChildren() or {}
            append("NetManaged remotes=" .. #remotes)
            assert(type(getgc) == "function" and type(info) == "function" and type(constants) == "function",
                "Missing getgc/getinfo/getconstants support.")

            local function countFunctions(items)
                if type(items) ~= "table" then return 0, 0 end
                local total, functions = 0, 0
                for _, item in pairs(items) do
                    total = total + 1
                    if type(item) == "function" then functions = functions + 1 end
                end
                return total, functions
            end
            local gcTrueOk, gcTrueItems = pcall(getgc, true)
            local trueTotal, trueFunctions = 0, 0
            if gcTrueOk then trueTotal, trueFunctions = countFunctions(gcTrueItems) end
            local gcFalseOk, gcFalseItems = pcall(getgc, false)
            local falseTotal, falseFunctions = 0, 0
            if gcFalseOk then falseTotal, falseFunctions = countFunctions(gcFalseItems) end
            local gcDefaultOk, gcDefaultItems = pcall(getgc)
            local defaultTotal, defaultFunctions = 0, 0
            if gcDefaultOk then defaultTotal, defaultFunctions = countFunctions(gcDefaultItems) end
            append("getgc(true): ok=" .. tostring(gcTrueOk) .. " objects=" .. trueTotal .. " functions=" .. trueFunctions
                .. (gcTrueOk and "" or " error=" .. tostring(gcTrueItems)))
            append("getgc(false): ok=" .. tostring(gcFalseOk) .. " objects=" .. falseTotal .. " functions=" .. falseFunctions
                .. (gcFalseOk and "" or " error=" .. tostring(gcFalseItems)))
            append("getgc(): ok=" .. tostring(gcDefaultOk) .. " objects=" .. defaultTotal .. " functions=" .. defaultFunctions
                .. (gcDefaultOk and "" or " error=" .. tostring(gcDefaultItems)))
            -- Prefer the function-only form when available; otherwise scan the
            -- successful result with the largest function count for diagnostics.
            local gcItems, gcMode, bestFunctions = {}, "none", 0
            if gcFalseOk and falseFunctions > bestFunctions then
                gcItems, gcMode, bestFunctions = gcFalseItems, "getgc(false)", falseFunctions
            end
            if gcTrueOk and trueFunctions > bestFunctions then
                gcItems, gcMode, bestFunctions = gcTrueItems, "getgc(true)", trueFunctions
            end
            if gcDefaultOk and defaultFunctions > bestFunctions then
                gcItems, gcMode, bestFunctions = gcDefaultItems, "getgc()", defaultFunctions
            end

            local executorCheck = isexecutorclosure or checkclosure or (syn and syn.isexecutorclosure)
            local ownFunctions = { [append] = true, [make] = true, [button] = true, [setReport] = true, [runDiagnostic] = true }
            local function scalar(value)
                if type(value) == "string" then
                    if #value > 1000 then return string.format("%q [truncated]", value:sub(1, 1000)) end
                    return string.format("%q", value)
                end
                if type(value) == "number" or type(value) == "boolean" or value == nil then return tostring(value) end
                return "<" .. type(value) .. ">"
            end
            local scanned, infoErrors, constantErrors, excluded, candidateCount = 0, 0, 0, 0, 0
            local sourceCounts, firstInfoError, firstConstantError = {}, nil, nil
            for _, fn in pairs(gcItems or {}) do
                if type(fn) == "function" then
                    scanned = scanned + 1
                    local infoOk, details = pcall(info, fn)
                    local infoError = not infoOk and tostring(details) or nil
                    details = infoOk and type(details) == "table" and details or {}
                    local source = tostring(details.source or details.short_src or "unknown")
                    sourceCounts[source] = (sourceCounts[source] or 0) + 1
                    if not infoOk then infoErrors = infoErrors + 1; firstInfoError = firstInfoError or infoError end
                    local isExecutor = ownFunctions[fn] == true
                    if type(executorCheck) == "function" then
                        local checked, result = pcall(executorCheck, fn)
                        isExecutor = isExecutor or (checked and result == true)
                    end
                    if isExecutor then
                        excluded = excluded + 1
                    else
                        local constantsOk, values = pcall(constants, fn)
                        if not constantsOk or type(values) ~= "table" then
                            constantErrors = constantErrors + 1
                            firstConstantError = firstConstantError or tostring(values)
                        else
                            local hasHitUnit = table.find(values, "hitUnit") ~= nil
                            local named = string.lower(tostring(details.name or "")) == "attempthit"
                            local selectedSource = equipped and string.find(source, "." .. equipped.Name .. ".", 1, true) ~= nil
                            local activeScript = false
                            if type(getfenv) == "function" and equipped then
                                local envOk, belongs = pcall(function()
                                    local env = getfenv(fn)
                                    local scriptObject = type(env) == "table" and rawget(env, "script")
                                    return typeof(scriptObject) == "Instance" and scriptObject:IsDescendantOf(equipped)
                                end)
                                activeScript = envOk and belongs == true
                            end
                            if hasHitUnit or named or selectedSource or activeScript then
                                candidateCount = candidateCount + 1
                                if candidateCount <= 40 then
                                    append("Candidate " .. candidateCount .. ": name=" .. tostring(details.name or "unnamed")
                                        .. " source=" .. source .. " activeScript=" .. tostring(activeScript)
                                        .. " selectedSource=" .. tostring(selectedSource) .. " hitUnit=" .. tostring(hasHitUnit))
                                    local hasDiagnosticMarker = false
                                    for _, value in pairs(values) do
                                        if value == "RoSnipe standalone slime-hit diagnostic v1" then hasDiagnosticMarker = true end
                                    end
                                    if not hasDiagnosticMarker then
                                        for index, value in pairs(values) do append("  constant[" .. tostring(index) .. "]=" .. scalar(value)) end
                                    else
                                        append("  [own diagnostic closure omitted]")
                                    end
                                    if type(upvalues) == "function" and not hasDiagnosticMarker then
                                        local upsOk, ups = pcall(upvalues, fn)
                                        if upsOk and type(ups) == "table" then
                                            for index, value in pairs(ups) do append("  upvalue[" .. tostring(index) .. "]=" .. scalar(value)) end
                                        else
                                            append("  getupvalues error=" .. tostring(ups))
                                        end
                                    end
                                    if not hasDiagnosticMarker then
                                        for _, value in pairs(values) do
                                            if type(value) == "string" then
                                                for _, remote in ipairs(remotes) do
                                                    if remote:IsA("RemoteEvent") and (remote.Name == value
                                                        or remote.Name:sub(-#("/" .. value)) == "/" .. value) then
                                                        append("  matching RemoteEvent=" .. remote:GetFullName())
                                                    end
                                                end
                                            end
                                        end
                                    end
                                    if type(protos) == "function" and named then
                                        local protoOk, children = pcall(protos, fn)
                                        append("  getprotos=" .. (protoOk and type(children) == "table" and #children or tostring(children)))
                                    end
                                end
                            end
                        end
                    end
                    if scanned % 200 == 0 then task.wait() end
                end
            end
            append("GC source=" .. gcMode .. " | Functions scanned=" .. scanned .. " candidates=" .. candidateCount
                .. " executor closures excluded=" .. excluded .. " getinfo errors=" .. infoErrors
                .. " getconstants errors=" .. constantErrors)
            if firstInfoError then append("First getinfo error=" .. firstInfoError) end
            if firstConstantError then append("First getconstants error=" .. firstConstantError) end
            local sources = {}
            for source, count in pairs(sourceCounts) do table.insert(sources, { source = source, count = count }) end
            table.sort(sources, function(a, b) return a.count > b.count end)
            for index = 1, math.min(5, #sources) do
                append("Common source " .. index .. ": " .. sources[index].source .. " (" .. sources[index].count .. ")")
            end
            if candidateCount > 40 then append("[remaining candidates omitted]") end
        end)
        running = false
        runButton.Text = "Run Diagnostic"
        if not ok then
            append("Diagnostic error: " .. tostring(err))
            warn("[Slime Hit Diagnostic] " .. tostring(err))
        end
        local report = table.concat(lines, "\n")
        setReport(report)
        local saved, saveError = false, "writefile unavailable"
        if type(writefile) == "function" then saved, saveError = pcall(writefile, REPORT_NAME, report) end
        status.Text = saved and ("Saved " .. REPORT_NAME .. " to the executor workspace. Copy Report or share that file.")
            or ("Report shown here; save failed: " .. tostring(saveError))
    end)
end

runButton = button("Run Diagnostic", 12, 180, runDiagnostic)
button("Copy Report", 204, 140, function()
    local report = table.concat(lines, "\n")
    local copy = setclipboard or toclipboard
    if type(copy) == "function" then
        local ok, err = pcall(copy, report)
        status.Text = ok and "Diagnostic report copied to clipboard." or ("Copy failed: " .. tostring(err))
    else
        status.Text = "Clipboard API unavailable. Select and copy from the report box."
    end
end)
button("Close", 496, 112, function() screen:Destroy() end)

-- Drag the panel from its title area.
do
    local dragging, dragInput, dragStart, startPosition
    local inputConnection
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = window.Position
            input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then dragging = false end end)
        end
    end)
    title.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then dragInput = input end
    end)
    inputConnection = game:GetService("UserInputService").InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            window.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end)
    screen.Destroying:Connect(function()
        if inputConnection then inputConnection:Disconnect() end
    end)
end
