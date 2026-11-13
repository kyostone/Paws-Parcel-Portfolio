
-- 소포 내부 Weld는 보존하고 배치/묶음 연결만 관리한다.
local Assembly = {}
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Geometry = require(Shared:WaitForChild("ParcelGeometry"))
local Tags = game:GetService("CollectionService")
local State = require(script.Parent:WaitForChild("PlacementState"))

local function endpoints(joint)
    if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
        return joint.Part0, joint.Part1
    end
    if joint:IsA("Constraint") then
        local attachment0, attachment1 = joint.Attachment0, joint.Attachment1
        return attachment0 and attachment0.Parent, attachment1 and attachment1.Parent
    end
    return nil, nil
end

local function owned(joint)
    if joint:GetAttribute("PawsPlacementJoint") == true then return true end

    -- 이전 서버가 만든 정확한 형식의 PlacementWeld만 인정한다.
    if joint:IsA("WeldConstraint") and joint.Name == "PlacementWeld" and joint.Part0 and joint.Part1 then
        local item = joint.Part0:FindFirstAncestorOfClass("Tool")
        return item and joint.Parent == joint.Part0 and Geometry.Handle(item) == joint.Part0
            and Tags:HasTag(item, "PlaceItem") and Tags:HasTag(joint.Part1, "GridArea")
    end
    return false
end

-- 관리 대상은 배치/묶음용 동적 Joint뿐이다. Tape 등 내부 외형 Weld는 제외한다.
-- 양쪽 소포에서 같은 Joint를 찾을 수 있도록 역인덱스를 유지한다.
local managedByItem: {[Tool]: {[Instance]: boolean}} = {}
local itemsByJoint: {[Instance]: {[Tool]: boolean}} = {}
local destroyingByJoint: {[Instance]: RBXScriptConnection} = {}
local initialized = false

local function toolOf(part: Instance?): Tool?
    if not part or not part:IsA("BasePart") then return nil end
    local tool = part:FindFirstAncestorOfClass("Tool")
    if tool and Tags:HasTag(tool, "PlaceItem") then return tool end
    return nil
end

local function untrack(joint: Instance)
    local indexedItems = itemsByJoint[joint]
    if indexedItems then
        for item in indexedItems do
            local entries = managedByItem[item]
            if entries then
                entries[joint] = nil
                if not next(entries) then managedByItem[item] = nil end
            end
        end
        itemsByJoint[joint] = nil
    end

    local connection = destroyingByJoint[joint]
    if connection then
        destroyingByJoint[joint] = nil
        connection:Disconnect()
    end
end

local function track(joint: Instance): boolean
    if not owned(joint) then return false end
    if itemsByJoint[joint] then return true end

    local part0, part1 = endpoints(joint)
    local indexedItems: {[Tool]: boolean} = {}
    local item0, item1 = toolOf(part0), toolOf(part1)
    if item0 then indexedItems[item0] = true end
    if item1 then indexedItems[item1] = true end
    if not next(indexedItems) then return false end

    itemsByJoint[joint] = indexedItems
    for item in indexedItems do
        local entries = managedByItem[item]
        if not entries then
            entries = {}
            managedByItem[item] = entries
        end
        entries[joint] = true
    end

    destroyingByJoint[joint] = joint.Destroying:Connect(function()
        untrack(joint)
    end)
    return true
end

-- 최초 한 번만 기존 월드의 동적 Weld를 등록한다.
-- 이후 생성한 Weld는 weld()가, 복원된 Weld는 Restore()가 직접 등록한다.
function Assembly.Initialize()
    if initialized then return end
    initialized = true

    for _, descendant in workspace:GetDescendants() do
        if descendant:IsA("WeldConstraint") or descendant:IsA("JointInstance")
            or descendant:IsA("Constraint") then
            track(descendant)
        end
    end
end


-- 묶음의 전체 Part 집합과 소포별 Part 목록을 함께 수집
local function collectParts(bundle)
    local partSet = {}
    local partsByItem = {}

    for _, item in bundle.Items do
        local parts = Geometry.Parts(item)
        partsByItem[item] = parts

        for _, part in parts do
            partSet[part] = true
        end
    end

    return partSet, partsByItem
end

function Assembly.PartSet(bundle)
    local parts = collectParts(bundle)
    return parts
end


function Assembly.Joints(bundle)
    local result = {}
    local parts, partsByItem = collectParts(bundle)
    local seen = {}

    local function inspect(joint)
        if seen[joint] then return end
        seen[joint] = true

        if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") or joint:IsA("Constraint") then
            local part0, part1 = endpoints(joint)
            if parts[part0] or parts[part1] then
                table.insert(result, {
                    Joint = joint,
                    A = part0,
                    B = part1,
                })

                -- 이미 존재하던 관리 대상도 발견 즉시 인덱스에 편입한다.
                if owned(joint) then track(joint) end
            end
        end
    end

    -- 비활성 상태(Backpack 포함)에서도 관리 대상 Weld를 놓치지 않는다.
    for _, item in bundle.Items do
        local entries = managedByItem[item]
        if entries then
            for joint in entries do
                inspect(joint)
            end
        end
    end

    -- 파트가 물리적으로 연결된 다른 오브젝트의 Joint도 검사한다.
    -- GetJoints()는 활성화된 연결만 반환하므로 아래 로컬 탐색을 함께 유지한다.
    for part in parts do
        for _, joint in part:GetJoints() do
            inspect(joint)
        end
    end

    -- 소포 내부에 놓인 비활성 Joint(예: Tape의 Weld)도 검증한다.
    for _, item in bundle.Items do
        for _, joint in item:GetDescendants() do
            inspect(joint)
        end
    end

    return result, parts, partsByItem
end


function Assembly.Safe(bundle, character)
    local joints, parts, partsByItem = Assembly.Joints(bundle)

    for _, entry in joints do
        local crosses = entry.A and entry.B
            and (parts[entry.A] ~= parts[entry.B])

        local isGrip = character
            and entry.Joint:IsA("JointInstance")
            and entry.Joint.Name == "RightGrip"
            and entry.B == Geometry.Handle(bundle.Root)
            and entry.A
            and entry.A:IsDescendantOf(character)

        if crosses and not owned(entry.Joint) and not isGrip then
            return false
        end

        if entry.Joint:IsA("Constraint")
            and entry.Joint.Enabled
            and (not entry.A or not entry.B) then
            return false
        end
    end

    for _, item in bundle.Items do
        local handle = Geometry.Handle(item)
        local connected = { [handle] = true }

        for _, part in handle:GetConnectedParts(true) do
            connected[part] = true
        end

        -- 기존에 수집한 소포별 Part 목록 재사용
        for _, part in partsByItem[item] do
            if not connected[part] then
                return false
            end
        end
    end

    return true
end


function Assembly.Detach(bundle)
    local joints = Assembly.Joints(bundle)

    for _, entry in joints do
        if owned(entry.Joint) then
            untrack(entry.Joint)
            entry.Joint:Destroy()
        end
    end
end

function Assembly.Freeze(bundle)
    for part in Assembly.PartSet(bundle) do
        part.Anchored = true
    end
end

local function weld(part0, part1, name)
    local joint = Instance.new("WeldConstraint")
    joint.Name = name
    joint:SetAttribute("PawsPlacementJoint", true)
    joint.Part0 = part0
    joint.Part1 = part1
    joint.Parent = part0

    assert(track(joint), "Failed to register parcel Weld")
end

-- 소지 중에는 Root에 묶고, 내려놓으면 실제 받침과 연결한다.
-- 자유 배치의 독립된 받침은 각각 고정하여 한 받침을 집어도 옆 묶음이 따라오지 않는다.
function Assembly.Link(bundle, area, carried)
    local rootHandle = Geometry.Handle(bundle.Root)

    for _, item in bundle.Items do
        for _, part in Geometry.Parts(item) do
            part.Anchored = false
            part.CanCollide = false
            part.CanTouch = false
            part.Massless = carried
        end
    end

    for _, item in bundle.Items do
        local handle = Geometry.Handle(item)

        if carried then
            if item ~= bundle.Root then
                weld(handle, rootHandle, "BundleWeld")
            end
        else
            local below = State.GetBelow(item)

            if #below > 0 then
                for _, support in below do
                    weld(handle, assert(Geometry.Handle(support)), "PlacementWeld")
                end
            else
                local record = State.GetPlacement(item)
                local rootArea = record and record.RootGridArea or area
                local grid = rootArea and State.GetGridState(rootArea)

                if rootArea and grid and not grid.Owner then
                    weld(handle, rootArea, "PlacementWeld")
                else
                    handle.Anchored = true
                end
            end
        end
    end

    if not carried then
        for _, item in bundle.Items do
            local handle = Geometry.Handle(item)

            if handle:CanSetNetworkOwnership() then
                handle:SetNetworkOwner(nil)
            end
        end
    end
end

function Assembly.Snapshot(bundle)
    local snapshot = {
        Parts = {},
        Tools = {},
        Joints = {},
    }

    for _, item in bundle.Items do
        table.insert(snapshot.Tools, {
            Item = item,
            Parent = item.Parent,
            Enabled = item.Enabled,
            Grip = item.Grip,
            Rotated = item:GetAttribute("IsRotated"),
        })

        for _, part in Geometry.Parts(item) do
            table.insert(snapshot.Parts, {
                Part = part,
                Frame = part.CFrame,
                Anchored = part.Anchored,
                Collide = part.CanCollide,
                Touch = part.CanTouch,
                Massless = part.Massless,
                Linear = part.AssemblyLinearVelocity,
                Angular = part.AssemblyAngularVelocity,
            })
        end
    end

    local joints = Assembly.Joints(bundle)

    for _, entry in joints do
        if owned(entry.Joint) then
            local copy = assert(
                entry.Joint:Clone(),
                "Managed joint must be Archivable"
            )

            table.insert(snapshot.Joints, {
                Copy = copy,
                Parent = entry.Joint.Parent,
            })
        end
    end

    return snapshot
end

function Assembly.Restore(bundle, snapshot)
    Assembly.Detach(bundle)
    Assembly.Freeze(bundle)

    for _, entry in snapshot.Tools do
        entry.Item.Parent = entry.Parent
        entry.Item.Enabled = entry.Enabled
        entry.Item.Grip = entry.Grip
        entry.Item:SetAttribute("IsRotated", entry.Rotated)
    end

    for _, entry in snapshot.Parts do
        local part = entry.Part
        part.CFrame = entry.Frame
        part.CanCollide = entry.Collide
        part.CanTouch = entry.Touch
        part.Massless = entry.Massless
    end

    for _, entry in snapshot.Joints do
        entry.Copy.Parent = entry.Parent
        assert(track(entry.Copy), "Failed to restore parcel Weld index")
    end

    for _, entry in snapshot.Parts do
        entry.Part.Anchored = entry.Anchored
        entry.Part.AssemblyLinearVelocity = entry.Linear
        entry.Part.AssemblyAngularVelocity = entry.Angular
    end
end

function Assembly.Discard(snapshot)
    for _, entry in snapshot.Joints do
        if not entry.Copy.Parent then
            entry.Copy:Destroy()
        end
    end
end

return Assembly
