local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Input = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Tags = game:GetService("CollectionService")
local StarterGui = game:GetService("StarterGui")
local Chat = game:GetService("TextChatService")
local player = Players.LocalPlayer

local Remotes = RS:WaitForChild("Remotes")
local Pick = Remotes:WaitForChild("PickItemRequest")
local Place = Remotes:WaitForChild("PlaceItemRequest")
local Deliver = Remotes:WaitForChild("DeliverParcelRequest")
local Drop = Remotes:WaitForChild("DropItemRequest")
local Rotate = Remotes:WaitForChild("RotateItemRequest")
local Preview = Remotes:WaitForChild("GetPlacementPreview")
local Sync = Remotes:WaitForChild("CarryStateChanged")

local PreviewModel = require(script:WaitForChild("PlacementPreview"))
local Carry = require(script:WaitForChild("CarryController"))
local Raycast = require(script:WaitForChild("RaycastUtil"))
local Math = require(RS:WaitForChild("Shared"):WaitForChild("PlacementMath"))

StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

local highlight = Instance.new("Highlight")
highlight.FillTransparency = 1
highlight.Enabled = false
highlight.Parent = workspace

local bundle, rotated, busy = nil, false, false
local token, pending, lastRequest = 0, false, -math.huge
local targetArea, targetRow, targetColumn = nil, nil, nil
local currentItem, elapsed = nil, 0

local function reset()
    token += 1
    targetArea, targetRow, targetColumn = nil, nil, nil
    lastRequest = -math.huge
    PreviewModel.Hide()
end


local function setCarry(nextBundle)
    PreviewModel.End()
    reset()

    bundle = nextBundle
    rotated = bundle and bundle.IsRotated == true or false
    currentItem = nil
    highlight.Adornee = nil
    highlight.Enabled = false

    if bundle then
        PreviewModel.Begin(bundle)
    end

    -- Show가 기존 소지 상태 초기화까지 담당한다.
    Carry.Show(bundle)
end

local function tagged(instance)
    while instance and instance ~= workspace do
        if instance:IsA("Tool") and Tags:HasTag(instance, "PlaceItem") then return instance end
        instance = instance.Parent
    end
    return nil
end

local function target(instance)
    if bundle then
        if Math.IsGridArea(instance) then return "GridArea", instance end
        local item = tagged(instance)
        local top = item and item:FindFirstChild("TopGridArea")
        if top and top:IsA("BasePart") then return "GridArea", top end
        return "None", nil
    end

    local item = tagged(instance)
    return item and "PlaceItem" or "None", item
end

local function updatePreview(area, hit)
    if area.Name == "DeliveryArea" then
        reset()
        return
    end

    local row, column = Math.GetMouseHitCell(area.CFrame:PointToObjectSpace(hit), area)
    if targetArea ~= area or targetRow ~= row or targetColumn ~= column then
        reset()
        targetArea, targetRow, targetColumn = area, row, column
    end

    if pending or busy or os.clock() - lastRequest < 0.15 then return end
    pending = true
    lastRequest = os.clock()

    local requestToken, requestBundle, requestRotation = token, bundle, rotated
    task.spawn(function()
        local ok, valid, frame = pcall(function()
            return Preview:InvokeServer(area, hit, requestRotation)
        end)
        pending = false

        if token ~= requestToken or bundle ~= requestBundle or rotated ~= requestRotation then return end
        if ok and valid and typeof(frame) == "CFrame" then
            PreviewModel.Update(frame)
        else
            PreviewModel.Hide()
        end
    end)
end

RunService.RenderStepped:Connect(function(deltaTime)
    elapsed += deltaTime
    if not bundle and elapsed < 0.1 then return end
    elapsed = 0

    local instance, hit = Raycast.DoRaycast()
    local kind, value = target(instance)
    currentItem = nil
    highlight.Enabled = false
    highlight.Adornee = nil

    if kind == "PlaceItem" then
        currentItem = value
        highlight.Adornee = value
        highlight.Enabled = true
    elseif bundle and kind == "GridArea" then
        updatePreview(value, hit)
    elseif bundle then
        reset()
    end
end)

local function invoke(remote, ...)
    local ok, success, data = pcall(remote.InvokeServer, remote, ...)
    if not ok then
        warn("[Placement] Request failed:", success)
        return false
    end
    return success == true, data
end

Input.InputBegan:Connect(function(input, processed)
    if processed or busy then return end

    local key = input.KeyCode
    local click = input.UserInputType == Enum.UserInputType.MouseButton1
    if key ~= Enum.KeyCode.Q and key ~= Enum.KeyCode.R and not click then return end
    busy = true

    if bundle and key == Enum.KeyCode.Q then
        local success = invoke(Drop, rotated)
        if success then setCarry(nil) end
    elseif bundle and key == Enum.KeyCode.R then
        local success = invoke(Rotate, not rotated)
        if success then
            rotated = not rotated
            reset()
        end
    elseif click and bundle then
        local instance, hit = Raycast.DoRaycast()
        local kind, area = target(instance)
        if kind == "GridArea" then
            local success, nextBundle
            if area.Name == "DeliveryArea" then
                success, nextBundle = invoke(Deliver, area, hit)
            else
                success = invoke(Place, area, hit, rotated)
            end
            if success then setCarry(nextBundle) end
        end
    elseif click and currentItem then
        local success, data = invoke(Pick, currentItem)
        if success then setCarry(data) end
    end

    busy = false
end)

Sync.OnClientEvent:Connect(setCarry)
player.CharacterRemoving:Connect(function()
    setCarry(nil)
end)

Remotes:WaitForChild("CustomerTalk").OnClientEvent:Connect(function(customer, message)
    local head = customer and customer:FindFirstChild("Head")
    if head then Chat:DisplayBubble(head, message) end
end)