local ServerScriptService = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Tags = game:GetService("CollectionService")
local Remotes = RS:WaitForChild("Remotes")
local Shared = RS:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GridConfig"))
local Geometry = require(Shared:WaitForChild("ParcelGeometry"))
local State = require(script.Parent:WaitForChild("PlacementState"))
local Assembly = require(script.Parent:WaitForChild("ParcelAssembly"))
local Parcels = require(script.Parent:WaitForChild("ParcelManager"))

local function isFiniteVector3(value: any): boolean
    if typeof(value) ~= "Vector3" then return false end
    local function finite(number: number): boolean
        return number == number and math.abs(number) < math.huge
    end
    return finite(value.X) and finite(value.Y) and finite(value.Z)
end

local function remote(name)
    local value = Remotes:FindFirstChild(name)
    if not value then
        value = Instance.new("RemoteFunction")
        value.Name = name
        value.Parent = Remotes
    end
    assert(value:IsA("RemoteFunction"), name .. " must be RemoteFunction")
    return value
end

local Pick = remote("PickItemRequest")
local Place = remote("PlaceItemRequest")
local Deliver = remote("DeliverParcelRequest")
local Drop = remote("DropItemRequest")
local Preview = remote("GetPlacementPreview")
local Rotate = remote("RotateItemRequest")
local Sync = Remotes:FindFirstChild("CarryStateChanged")

if not Sync then
    Sync = Instance.new("RemoteEvent")
    Sync.Name = "CarryStateChanged"
    Sync.Parent = Remotes
end
assert(Sync:IsA("RemoteEvent"))

local carried, lastPreview, lastAction = {}, {}, {}

local READY_ATTRIBUTE = "PawsPlacementReady"
ServerScriptService:SetAttribute(READY_ATTRIBUTE, false)

State.Initialize()
Parcels.InitializeTruckParcels()
State.ImportExisting()
Assembly.Initialize()

for _, item in Tags:GetTagged("PlaceItem") do
    if item:IsA("Tool") and item:IsDescendantOf(workspace) and not State.GetPlacement(item) then
        local tracked, reason = State.TrackWorldBundle({Root = item, Items = { item }, })
        if not tracked then
            warn("[Placement] World registration failed:", reason)
        end
    end
end

Tags:GetInstanceAddedSignal("PlaceItem"):Connect(function(item)
    if item:IsA("Tool") then State.RegisterItem(item) end
end)

local function characterContext(player)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then return nil end
    return character, humanoid, root
end

local function itemSet(bundle)
    local set = {}
    for _, item in bundle.Items do set[item] = true end
    return set
end

local function validCarry(player)
    local bundle = carried[player]
    local character, humanoid, root = characterContext(player)
    if not bundle or not character or bundle.Root.Parent ~= character then return nil end

    for _, item in bundle.Items do
        if not item.Parent or not Geometry.Handle(item) or not Tags:HasTag(item, "PlaceItem") then return nil end
        if item ~= bundle.Root and not item:IsDescendantOf(bundle.Root) then return nil end
    end
    return bundle, character, humanoid, root
end

local function payload(bundle)
    if not bundle then return nil end
    return { Root = bundle.Root, Items = bundle.Items, IsRotated = bundle.Rotated }
end

local function pack(bundle)
    local folder = bundle.Root:FindFirstChild("CarriedItems")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "CarriedItems"
        folder.Parent = bundle.Root
    end
    assert(folder:IsA("Folder"), "CarriedItems reserved")

    for _, item in bundle.Items do
        item.Enabled = false
        if item ~= bundle.Root then item.Parent = folder end
    end
end

local function unpackItems(bundle)
    for _, item in bundle.Items do
        item.Parent = workspace
        item.Enabled = bundle.Enabled[item] ~= false
    end
end

local function giveOwnership(bundle, player)
    local handle = Geometry.Handle(bundle.Root)
    local allowed = handle:CanSetNetworkOwnership()
    if allowed then handle:SetNetworkOwner(player) end
end

-- action 내부는 yield 없이 처리하고 실패 시 물리·논리 상태를 복원한다.
local function transaction(player, bundle, action)
    local captured, physical = pcall(Assembly.Snapshot, bundle)
    if not captured then
        warn("[Placement] Cannot snapshot:", physical)
        return false
    end

    local logical = State.Snapshot()
    local previous = carried[player]
    local ok, message = pcall(action)
    if not ok then
        local restored, restoreError = pcall(function()
            Assembly.Restore(bundle, physical)
            State.Restore(logical)
            carried[player] = previous

            if previous and player.Character then
                local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
                if humanoid then
                    previous.Root.Parent = player.Backpack
                    humanoid:EquipTool(previous.Root)
                    giveOwnership(previous, player)
                end
            end
        end)
        warn("[Placement] Rolled back:", message)
        if not restored then warn("[Placement] ROLLBACK FAILED:", restoreError) end
    end

    Assembly.Discard(physical)
    return ok
end

local function throttle(player)
    local now = os.clock()
    if now - (lastAction[player] or -math.huge) < 0.12 then return false end
    lastAction[player] = now
    return true
end

local function placementContext(player, area, hit, rotated, reportFailure)
    local function reject(reason)
        if reportFailure then warn("[Placement] " .. reason) end
        return nil, nil, nil, nil, reason
    end

    if typeof(rotated) ~= "boolean" or not isFiniteVector3(hit) then
        return reject("InvalidRequest")
    end
    if typeof(area) ~= "Instance" or not area:IsA("BasePart") or not area:IsDescendantOf(workspace) then
        return reject("InvalidArea")
    end

    local bundle, character, humanoid, root = validCarry(player)
    if not bundle then return reject("InvalidCarryState") end
    if (root.Position - hit).Magnitude > Config.MaxDistance then return reject("TargetTooFar") end

    local plan, reason = State.Plan(bundle, area, hit, rotated)
    if not plan then return reject(reason or "NoPlacementPlan") end

    local overlap = OverlapParams.new()
    overlap.FilterType = Enum.RaycastFilterType.Exclude
    overlap.FilterDescendantsInstances = { character, plan.RootGridArea }
    overlap.RespectCanCollide = true

    local oldRoot = Geometry.Handle(bundle.Root).CFrame
    for _, record in plan.Records do
        local relative = oldRoot:ToObjectSpace(Geometry.Handle(record.Item).CFrame)
        if (relative.Position - bundle.Offsets[record.Item].Position).Magnitude > Config.Epsilon then
            return reject("BundleOffsetChanged")
        end

        local size = Geometry.Handle(record.Item).Size
        if (root.Position - record.TargetCFrame.Position).Magnitude > Config.MaxDistance + size.Magnitude then
            return reject("BundleTargetTooFar")
        end

        local blockers = workspace:GetPartBoundsInBox(
            record.TargetCFrame, size - Vector3.new(0.01, 0.01, 0.01), overlap
        )
        if #blockers > 0 then
            return reject("WorldObstacle: " .. blockers[1]:GetFullName())
        end
    end
    return bundle, character, humanoid, plan
end

Preview.OnServerInvoke = function(player, area, hit, rotated)
    local now = os.clock()
    if now - (lastPreview[player] or -math.huge) < 0.1 then
        return false, nil, "PreviewRateLimited"
    end
    lastPreview[player] = now

    local bundle, _, _, plan, reason = placementContext(player, area, hit, rotated)
    if not bundle then return false, nil, reason end
    if plan.RootGridArea.Name == "DeliveryArea" then
        return false, nil, "UseDeliveryRequest"
    end
    return true, plan.TargetCFrame
end

Pick.OnServerInvoke = function(player, item)
    if not throttle(player) or carried[player] then return false end
    if typeof(item) ~= "Instance" or not item:IsA("Tool")
        or not Tags:HasTag(item, "PlaceItem") or not item:IsDescendantOf(workspace) then
        return false
    end

    local character, humanoid, root = characterContext(player)
    local handle = Geometry.Handle(item)
    if not character or not handle or (root.Position - handle.Position).Magnitude > Config.MaxDistance then
        return false
    end

    local ancestor = item.Parent
    while ancestor and ancestor ~= workspace do
        local isCharacter = ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid")
        if ancestor:IsA("Tool") or isCharacter then return false end
        ancestor = ancestor.Parent
    end

    -- 선택한 소포와 Above로 연결된 상단 소포만 집는다.
    local items = State.GetStackItems(item)
    if #items > Config.MaxBundleItems then return false end

    local bundle = Geometry.Capture(item, items)
    if not bundle or not Assembly.Safe(bundle) then return false end

    local selected = itemSet(bundle)
    for _, member in items do
        if not Tags:HasTag(member, "PlaceItem") then return false end
    end
    for _, existing in carried do
        for _, member in existing.Items do
            if selected[member] then return false end
        end
    end

    bundle.Rotated = item:GetAttribute("IsRotated") == true
    bundle.OriginalGrip = item.Grip

    local ok = transaction(player, bundle, function()
        Assembly.Freeze(bundle)
        Assembly.Detach(bundle)
        State.RemoveItems(itemSet(bundle))
        pack(bundle)
        Assembly.Link(bundle, nil, true)

        item.Grip = bundle.OriginalGrip * CFrame.Angles(0, bundle.Rotated and math.pi / 2 or 0, 0)
        item.Parent = player.Backpack
        humanoid:EquipTool(item)
        assert(item.Parent == character, "Equip failed")

        giveOwnership(bundle, player)
        carried[player] = bundle
    end)

    if not ok then return false end
    for _, member in items do Parcels.OnParcelPickedUp(member) end
    return true, payload(bundle)
end

Rotate.OnServerInvoke = function(player, rotated)
    if not throttle(player) or typeof(rotated) ~= "boolean" then return false end
    local bundle = validCarry(player)
    if not bundle then return false end

    bundle.Root.Grip = bundle.OriginalGrip * CFrame.Angles(0, rotated and math.pi / 2 or 0, 0)
    bundle.Rotated = rotated
    return true
end

Place.OnServerInvoke = function(player, area, hit, rotated)
    if not throttle(player) then return false end

    local bundle, character, humanoid, plan, reason = placementContext(player, area, hit, rotated, true)
    if not bundle then return false, reason end
    if plan.RootGridArea.Name == "DeliveryArea" then return false, "UseDeliveryRequest" end
    if not Assembly.Safe(bundle, character) then return false, "UnsafeAssembly" end

    return transaction(player, bundle, function()
        humanoid:UnequipTools()
        Assembly.Freeze(bundle)
        Assembly.Detach(bundle)
        unpackItems(bundle)
        Geometry.Move(bundle, plan.TargetCFrame)

        assert(State.Commit(plan.Records), "Placement state changed")
        Assembly.Link(bundle, plan.RootGridArea, false)
        bundle.Root.Grip = bundle.OriginalGrip

        for _, record in plan.Records do
            local grid = State.GetGridState(plan.RootGridArea)
            local localFrame = Geometry.GridFrame(plan.RootGridArea, grid):ToObjectSpace(record.TargetCFrame)
            record.Item:SetAttribute("IsRotated", math.abs(localFrame.RightVector.Z) > 0.5)
        end
        carried[player] = nil
    end)
end

local function deliveryContext(player, area, hit)
    local bundle, character, humanoid, root = validCarry(player)
    local locations = workspace:FindFirstChild("Locations")
    if not bundle or not isFiniteVector3(hit) or typeof(area) ~= "Instance"
        or not area:IsA("BasePart") or area.Name ~= "DeliveryArea" or not locations
        or not area.Parent or area.Parent.Parent ~= locations
        or area.Parent:FindFirstChild("DeliveryArea") ~= area then
        return nil
    end

    if (root.Position - area.Position).Magnitude > Config.MaxDistance
        or (root.Position - hit).Magnitude > Config.MaxDistance then
        return nil
    end

    local position = area.CFrame:PointToObjectSpace(hit)
    if math.abs(position.X) > area.Size.X / 2 + 0.01
        or math.abs(position.Z) > area.Size.Z / 2 + 0.01
        or math.abs(position.Y - area.Size.Y / 2) > 0.3 then
        return nil
    end
    return bundle, character, humanoid, area.Parent
end

Deliver.OnServerInvoke = function(player, area, hit)
    if not throttle(player) then return false end

    local bundle, character, humanoid, seat = deliveryContext(player, area, hit)
    if not bundle or not Assembly.Safe(bundle, character) then return false end

    local selected = Parcels.GetDeliverableParcels(bundle.Items, seat)
    if #selected == 0 then return false end

    local selectedSet, remaining = {}, {}
    for _, item in selected do selectedSet[item] = true end
    for _, item in bundle.Items do
        if not selectedSet[item] then table.insert(remaining, item) end
    end

    local nextBundle
    if #remaining > 0 then
        local nextRoot = not selectedSet[bundle.Root] and bundle.Root or remaining[1]
        if selectedSet[bundle.Root] then
            local bottom = math.huge
            for _, item in remaining do
                local offset = bundle.Offsets[item]
                local itemBottom = offset.Position.Y - Geometry.Handle(item).Size.Y / 2
                if itemBottom < bottom then
                    bottom = itemBottom
                    nextRoot = item
                end
            end
        end

        nextBundle = Geometry.Capture(nextRoot, remaining)
        nextBundle.Enabled = table.clone(bundle.Enabled)
        nextBundle.OriginalGrip = nextRoot == bundle.Root and bundle.OriginalGrip or nextRoot.Grip
        nextBundle.Rotated = false
    end

    local ok = transaction(player, bundle, function()
        humanoid:UnequipTools()
        Assembly.Freeze(bundle)
        Assembly.Detach(bundle)
        unpackItems(bundle)
        bundle.Root.Grip = bundle.OriginalGrip

        if nextBundle then
            pack(nextBundle)
            Assembly.Link(nextBundle, nil, true)
            nextBundle.Root.Parent = player.Backpack
            humanoid:EquipTool(nextBundle.Root)
            assert(nextBundle.Root.Parent == character, "Re-equip failed")
            giveOwnership(nextBundle, player)
        end
        carried[player] = nextBundle
    end)

    if not ok then return false end
    Parcels.CompletePickupDelivery(selected, seat)
    return true, payload(nextBundle)
end

Drop.OnServerInvoke = function(player, rotated)
    if not throttle(player) then return false end

    local bundle, character, humanoid, root = validCarry(player)
    if not bundle or not Assembly.Safe(bundle, character) then return false end
    if rotated == nil then rotated = bundle.Rotated end
    if typeof(rotated) ~= "boolean" then return false end

    local origin = root.Position + root.CFrame.LookVector * 3 + Vector3.new(0, 3, 0)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character }
    params.RespectCanCollide = true

    local result = workspace:Raycast(origin, Vector3.new(0, -20, 0), params)
    if not result or result.Normal.Y < 0.99 then return false end

    local yaw = math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
    local target = CFrame.new(
        result.Position + Vector3.new(0, Geometry.Handle(bundle.Root).Size.Y / 2, 0)
    ) * CFrame.Angles(0, yaw + (rotated and math.pi / 2 or 0), 0)

    local overlap = OverlapParams.new()
    overlap.FilterType = Enum.RaycastFilterType.Exclude
    overlap.FilterDescendantsInstances = { character }
    overlap.RespectCanCollide = true

    for _, item in bundle.Items do
        local handle = Geometry.Handle(item)
        local frame = target * bundle.Offsets[item]
        local blockers = workspace:GetPartBoundsInBox(
            frame, handle.Size - Vector3.new(0.01, 0.01, 0.01), overlap
        )
        if #blockers > 0 then return false end
    end

    return transaction(player, bundle, function()
        humanoid:UnequipTools()
        Assembly.Freeze(bundle)
        Assembly.Detach(bundle)
        unpackItems(bundle)
        Geometry.Move(bundle, target)

        local tracked, reason = State.TrackWorldBundle(bundle, true)
        assert(tracked, reason)
        Assembly.Link(bundle, nil, false)

        bundle.Root.Grip = bundle.OriginalGrip
        carried[player] = nil
    end)
end

local function release(player)
    local bundle = carried[player]
    if not bundle then return end

    local ok = transaction(player, bundle, function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then humanoid:UnequipTools() end

        Assembly.Freeze(bundle)
        Assembly.Detach(bundle)
        unpackItems(bundle)

        local tracked, reason = State.TrackWorldBundle(bundle, true)
        assert(tracked, reason)
        Assembly.Link(bundle, nil, false)

        bundle.Root.Grip = bundle.OriginalGrip
        carried[player] = nil
    end)

    if ok and player.Parent == Players then Sync:FireClient(player) end
end

local function watch(player)
    player.CharacterRemoving:Connect(function()
        release(player)
    end)

    player.CharacterAdded:Connect(function(character)
        local humanoid = character:WaitForChild("Humanoid")
        humanoid.Died:Connect(function()
            release(player)
        end)
    end)

    if player.Character then
        local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.Died:Connect(function()
                release(player)
            end)
        end
    end
end

for _, player in Players:GetPlayers() do watch(player) end
Players.PlayerAdded:Connect(watch)

Players.PlayerRemoving:Connect(function(player)
    release(player)
    carried[player] = nil
    lastPreview[player] = nil
    lastAction[player] = nil
end)

-- 초기 등록과 모든 Remote 핸들러 구성이 끝난 뒤 알린다.
ServerScriptService:SetAttribute(READY_ATTRIBUTE, true)