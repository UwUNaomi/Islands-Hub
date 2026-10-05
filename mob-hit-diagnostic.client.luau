-- Run beside a slime with the failing melee weapon equipped, after trying a hit.
-- Read-only inspection: no remote requests, hooks, or game-state modifications.
-- Prints a report and, when writefile is supported, saves it in the executor workspace.
local lines, summary = {}, {}
local function brief(message)
    table.insert(summary, tostring(message))
    table.insert(lines, tostring(message))
end
local function log(message)
    table.insert(lines, tostring(message))
end
local info = getinfo or (debug and debug.getinfo)
local constants = getconstants or (debug and debug.getconstants)
local protos = getprotos or (debug and debug.getprotos)
local upvalues = getupvalues or (debug and debug.getupvalues)
brief("Islands mob-hit diagnostic v2")
brief("PlaceId=" .. game.PlaceId .. " PlaceVersion=" .. game.PlaceVersion)
brief("getgc=" .. type(getgc) .. " getinfo=" .. type(info)
    .. " getconstants=" .. type(constants) .. " getprotos=" .. type(protos) .. " getupvalues=" .. type(upvalues))

local remote = game:GetService("ReplicatedStorage")
for _, name in ipairs({ "rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged" }) do
    remote = remote and remote:FindFirstChild(name)
end
local remotes = remote and remote:GetChildren() or {}
brief("NetManaged remotes: " .. #remotes)
local player = game:GetService("Players").LocalPlayer
local character = player and player.Character
local equipped = character and character:FindFirstChildOfClass("Tool")
brief("Equipped weapon: " .. (equipped and equipped.Name or "none"))
if equipped then
    brief("Weapon Enabled="..tostring(equipped.Enabled).." RequiresHandle="..tostring(equipped.RequiresHandle)
        .." Handle="..tostring(equipped:FindFirstChild("Handle")~=nil))
    for _,child in ipairs(equipped:GetDescendants()) do
        if child:IsA("LuaSourceContainer") then log("Weapon script: "..child:GetFullName().." ["..child.ClassName.."]") end
    end
end
local ui=game:GetService("UserInputService")
local gui=game:GetService("GuiService")
local inputOK,inputState=pcall(function()
    return "MenuIsOpen="..tostring(gui.MenuIsOpen).." TextBoxFocused="..tostring(ui:GetFocusedTextBox()~=nil)
        .." MouseButton1Down="..tostring(ui:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))
end)
brief(inputOK and inputState or ("Input state unavailable: "..tostring(inputState)))
local root = character and character:FindFirstChild("HumanoidRootPart")
local playerHealth=character and character:FindFirstChildOfClass("Humanoid")
brief("Player health="..tostring(playerHealth and playerHealth.Health).." Root="..tostring(root and root.Position))
local wilderness = workspace:FindFirstChild("WildernessIsland")
local entities = wilderness and wilderness:FindFirstChild("Entities")
brief("Wilderness entities="..tostring(entities and #entities:GetChildren() or "not loaded"))
local nearest, distance = nil, math.huge
if root and entities then
    for _, mob in ipairs(entities:GetChildren()) do
        local mobRoot = mob:FindFirstChild("HumanoidRootPart")
        local humanoid = mob:FindFirstChildOfClass("Humanoid")
        local name=string.lower(mob.Name)
        if mobRoot and humanoid and humanoid.Health > 0 and (name=="slime" or name=="slimes") then
            local current = (root.Position - mobRoot.Position).Magnitude
            if current < distance then nearest, distance = mob, current end
        end
    end
end
brief(nearest and string.format("Nearest slime: %.1f studs | health %.1f", distance, nearest:FindFirstChildOfClass("Humanoid").Health)
    or "No loaded living slime nearby.")
if nearest then
    local p=nearest:FindFirstChild("HumanoidRootPart").Position
    brief("Slime="..nearest:GetFullName().." Position="..tostring(p).." Player Y offset="..tostring(root.Position.Y-p.Y))
end

local function scalar(value)
    if type(value) == "string" then
        if #value > 1024 then return string.format("%q", value:sub(1, 1024)) .. " [truncated]" end
        return string.format("%q", value)
    end
    if type(value) == "number" or type(value) == "boolean" or value == nil then return tostring(value) end
    return "<" .. type(value) .. ">"
end

local visited,dumped={},0
local function dump(fn, label, depth)
    if visited[fn] or dumped>=80 then return end
    visited[fn]=true;dumped=dumped+1
    log(label)
    if type(constants) == "function" then
        local ok, values = pcall(constants, fn)
        if ok and type(values) == "table" then
            if table.find(values,"hitUnit") then
                local matches=type(values[1])=="string" and values[2]=="Get" and values[3]=="hitUnit"
                    and type(values[4])=="string" and type(values[5])=="string" and values[7]=="CallServerAsync"
                log("  Matches current hub sender layout="..tostring(matches))
            end
            local indices = {}
            for key in pairs(values) do
                if type(key) == "number" then table.insert(indices, key) end
            end
            table.sort(indices)
            for n, key in ipairs(indices) do
                if n > 128 then log("  [remaining constants omitted]") break end
                log("  constant[" .. key .. "]=" .. scalar(values[key]))
                if type(values[key]) == "string" and #values[key] >= 3 then
                    for _, candidate in ipairs(remotes) do
                        if candidate.Name == values[key] or string.find(candidate.Name, "/" .. values[key], 1, true) then
                            log("    Matching remote: " .. candidate.Name .. " [" .. candidate.ClassName .. "]")
                        end
                    end
                end
            end
            if #indices == 0 then log("  No constants returned.") end
        else
            log("  getconstants failed: " .. tostring(values))
        end
    end
    if type(upvalues) == "function" then
        local read, values = pcall(upvalues, fn)
        if read and type(values) == "table" then
            local count = 0
            for index, value in pairs(values) do
                count = count + 1
                if count > 24 then log("  [remaining upvalues omitted]") break end
                log("  upvalue[" .. tostring(index) .. "]=" .. scalar(value))
            end
            if count == 0 then log("  No upvalues returned.") end
        else
            log("  getupvalues failed: " .. tostring(values))
        end
    end
    if depth < 2 and type(protos) == "function" then
        local ok, children = pcall(protos, fn)
        if ok and type(children) == "table" then
            local count = 0
            for key, child in pairs(children) do
                count = count + 1
                if count > 8 then log("  [remaining prototypes omitted]") break end
                if type(child) == "function" then
                    dump(child, label .. ".proto[" .. tostring(key) .. "]", depth + 1)
                end
            end
            if count == 0 then log("  No prototypes returned.") end
        else
            log("  getprotos failed: " .. tostring(children))
        end
    end
end

local executorCheck = isexecutorclosure or checkclosure or (syn and syn.isexecutorclosure)
brief("Executor-closure filter: " .. type(executorCheck))
local ownFunctions = { [log] = true, [brief] = true, [scalar] = true, [dump] = true }

local function scan()
    assert(type(getgc) == "function" and type(info) == "function", "Missing getgc/getinfo support.")
    local functions, skipped, infoFailures, constantFailures = 0, 0, 0, 0
    local sources, candidates = {}, {}
    local firstInfoError, firstConstantError
    for _, fn in pairs(getgc(true)) do
        if type(fn) == "function" then
            functions = functions + 1
            local inspected, details = pcall(info, fn)
            local name = inspected and type(details) == "table" and details.name or ""
            local source = inspected and type(details) == "table" and (details.source or details.short_src) or "unknown"
            source = tostring(source or "unknown")
            sources[source] = (sources[source] or 0) + 1
            if not inspected then
                infoFailures = infoFailures + 1
                firstInfoError = firstInfoError or tostring(details)
            end
            name = type(name) == "string" and name or ""
            local excluded = ownFunctions[fn] or source == "=[C]" or source == "[C]" or string.find(string.lower(source), "raptor.thread", 1, true) ~= nil
            if not excluded and type(executorCheck) == "function" then
                local checked, result = pcall(executorCheck, fn)
                excluded = checked and result == true
            end
            local values
            if not excluded and type(constants) == "function" then
                local read, result = pcall(constants, fn)
                if read and type(result) == "table" then
                    values = result
                    for _, value in pairs(values) do
                        if type(value) == "string" then
                            local lower = string.lower(value)
                            -- Also exclude stale copies of the diagnostic and our hub helpers.
                            if string.find(lower, "islands mob-hit diagnostic", 1, true)
                                or string.find(lower, "no matching mob-hit function found", 1, true)
                                or string.find(lower, "could not resolve mob combat", 1, true)
                                or string.find(lower, "islands tree-hit diagnostic", 1, true)
                                or string.find(lower, "combat & cutting", 1, true) then
                                excluded = true
                                break
                            end
                        end
                    end
                elseif not read then
                    constantFailures = constantFailures + 1
                    firstConstantError = firstConstantError or tostring(result)
                end
            end
            if excluded then
                skipped = skipped + 1
            else
                local lowerName = string.lower(name)
                local named = lowerName == "attempthit"
                local match = named
                for _, value in pairs(values or {}) do
                    if value == "hitUnit" then match = true break end
                end
                local selected=equipped and source:find("."..equipped.Name..".",1,true)~=nil
                local activeScript=false
                    if equipped and type(getfenv)=="function" then
                        local read,active=pcall(function()
                            local environment=getfenv(fn)
                            local scriptObject=type(environment)=="table" and rawget(environment,"script")
                            return typeof(scriptObject)=="Instance" and scriptObject:IsDescendantOf(equipped)
                        end)
                        activeScript=read and active==true
                    end
                -- Heavy weapons may use a different callback name or payload.
                -- Include every equipped-weapon closure, even without hitUnit.
                if match or selected or activeScript then
                    local priority=(activeScript and 0 or selected and 3 or 6)+(named and 0 or match and 1 or 2)
                    table.insert(candidates, { fn = fn, name = name, source = source, priority = priority,
                        selected=selected==true, activeScript=activeScript })
                end
            end
            if functions % 200 == 0 then task.wait() end
        end
    end
    table.sort(candidates, function(a, b) return a.priority < b.priority end)
    brief("Functions inspected: " .. functions .. "; excluded diagnostic/executor/native functions: " .. skipped)
    brief("Mob-hit candidates: " .. #candidates .. "; getinfo errors: " .. infoFailures .. "; getconstants errors: " .. constantFailures)
    local sourceList = {}
    for source, count in pairs(sources) do table.insert(sourceList, { source = source, count = count }) end
    table.sort(sourceList, function(a, b) return a.count > b.count end)
    for i = 1, math.min(5, #sourceList) do
        brief("Function source: " .. sourceList[i].source .. " (" .. sourceList[i].count .. ")")
    end
    if firstInfoError then brief("First getinfo error: " .. firstInfoError) end
    if firstConstantError then brief("First getconstants error: " .. firstConstantError) end
    for index, candidate in ipairs(candidates) do
        if index > 32 then log("[remaining candidates omitted]") break end
        local label = "Candidate " .. index .. ": " .. (candidate.name ~= "" and candidate.name or "unnamed")
        brief(label .. " | source=" .. candidate.source)
        log("  Selected weapon source="..tostring(candidate.selected).." Script belongs to equipped instance="..tostring(candidate.activeScript))
        dump(candidate.fn, label, 0)
    end
    if #candidates == 0 then
        brief("No game mob-hit candidate found. This result does not identify a replacement hash.")
    end
end
ownFunctions[scan] = true
local ok, err = pcall(scan)
if not ok then brief("Diagnostic failed: " .. tostring(err)) end
local report = table.concat(lines, "\n")
local saved = false
if type(writefile) == "function" then
    local saveError
    saved, saveError = pcall(writefile, "islands-mob-hit-diagnostic.txt", report)
    if not saved then table.insert(summary, "Could not save report: " .. tostring(saveError)) end
end
-- Print separate, short lines so the executor does not truncate one giant message.
if saved then
    for _, line in ipairs(summary) do print(line) end
    print("Full constants saved to islands-mob-hit-diagnostic.txt in the executor workspace.")
else
    for _, line in ipairs(lines) do print(line) end
end
