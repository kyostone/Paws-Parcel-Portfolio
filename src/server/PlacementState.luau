-- 점유 셀은 배치된 소포만 관리하고, Above/Below는 소지 중에도 유지한다.
local State = {}
local RS = game:GetService("ReplicatedStorage")
local Tags = game:GetService("CollectionService")
local Shared = RS:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GridConfig"))
local Geometry = require(Shared:WaitForChild("ParcelGeometry"))
local grids, placements, relations, registered = {}, {}, {}, {}

local function reference(parent, value)
    local object = parent:FindFirstChild("RootGridArea")
    assert(not object or object:IsA("ObjectValue"), "RootGridArea must be ObjectValue")
    if not object then
        object = Instance.new("ObjectValue")
        object.Name = "RootGridArea"
        object.Parent = parent
    end
    object.Value = value
end

function State.GetTopGridArea(item)
    local area = item:FindFirstChild("TopGridArea")
    return area and area:IsA("BasePart") and area or nil
end

local function node(item)
    if not relations[item] then relations[item] = { Above = {}, Below = {} } end
    return relations[item]
end

local function publish(item)
    if not item.Parent then return end
    local record = placements[item]
    local area = record and record.RootGridArea or nil
    reference(item, area)
    local top = State.GetTopGridArea(item)
    if top then
        reference(top, area)
        local grid = area and grids[area]
        local remaining = grid and grid.MaxHeight < math.huge
            and (grid.MaxHeight - record.Top) * Config.HeightUnit or nil
        top:SetAttribute("RemainingHeight", remaining)
    end
end

local function eachCell(record, callback)
    for x = record.StartX, record.EndX do
        for z = record.StartZ, record.EndZ do callback(x, z) end
    end
end

local function connect(below, above)
    node(below).Above[above] = true
    node(above).Below[below] = true
end

-- 기존 내부 관계는 유지하고 새로 접한 셀에서 경계 관계만 추가한다.
local function insertRecords(records)
    local touched = {}
    for _, source in records do
        local record = table.clone(source)
        local links = node(record.Item)
        record.Above, record.Below = links.Above, links.Below
        placements[record.Item] = record

        local grid = grids[record.RootGridArea]
        eachCell(record, function(x, z)
            local column = grid.Cells[x]
            if not column then column = {}; grid.Cells[x] = column end
            local layers = column[z]
            if not layers then layers = {}; column[z] = layers end

            for _, other in layers do
                if other.Top == record.Bottom then connect(other.Item, record.Item) end
                if record.Top == other.Bottom then connect(record.Item, other.Item) end
            end
            table.insert(layers, record)
        end)

        touched[grid] = true
        publish(record.Item)
    end
    for grid in touched do grid.Version += 1 end
end

function State.GetPlacement(item) return placements[item] end
function State.GetGridState(area) return grids[area] end

function State.ResolveRootGridArea(area)
    if grids[area] then return area end
    local item = typeof(area) == "Instance" and area:FindFirstAncestorOfClass("Tool")
    local record = item and State.GetTopGridArea(item) == area and placements[item]
    return record and record.RootGridArea or nil
end

function State.RegisterGridArea(area)
    if grids[area] then return grids[area] end
    local sizeX, sizeZ = Geometry.Units(area.Size.X), Geometry.Units(area.Size.Z)
    local maxHeight = area:GetAttribute("MaxHeight")
    local height = typeof(maxHeight) == "number" and Geometry.Units(maxHeight)
    if not sizeX or not sizeZ or sizeX < 1 or sizeZ < 1
        or sizeX * sizeZ > Config.MaxGridCells or not height or height < 1 then
        warn("[Placement] Invalid root dimensions / MaxHeight:", area:GetFullName())
        return nil
    end

    local grid = {
        GridSizeX = sizeX,
        GridSizeZ = sizeZ,
        MaxHeight = height,
        Cells = {},
        Version = 0,
    }
    grids[area] = grid
    area:SetAttribute("GridSizeX", sizeX)
    area:SetAttribute("GridSizeZ", sizeZ)
    area:SetAttribute("RemainingHeight", maxHeight)
    reference(area, area)
    Tags:AddTag(area, "GridArea")

    area.Destroying:Connect(function()
        local removed = {}
        for item, record in placements do
            if record.RootGridArea == area then removed[item] = true end
        end
        State.RemoveItems(removed)
        grids[area] = nil
    end)
    return grid
end

function State.RegisterItem(item)
    if registered[item] then return end
    registered[item] = true
    node(item)
    item.CanBeDropped = false

    local handle = Geometry.Handle(item)
    -- 기본 Tool의 접촉 집기가 서버의 집기 검증을 우회하지 않도록 한다.
    if handle then handle.CanTouch = false end

    local top = State.GetTopGridArea(item)
    if top then
        Tags:AddTag(top, "GridArea")
        top.CanCollide, top.CanTouch, top.CanQuery = false, false, true
        top:SetAttribute("GridSizeX", math.floor(top.Size.X / Config.CellSize))
        top:SetAttribute("GridSizeZ", math.floor(top.Size.Z / Config.CellSize))
    end
    publish(item)

    item.Destroying:Connect(function()
        State.RemoveItems({ [item] = true })
        local links = relations[item]
        if links then
            for above in links.Above do node(above).Below[item] = nil end
            for below in links.Below do node(below).Above[item] = nil end
        end
        relations[item], registered[item] = nil, nil
    end)
end

local function neighbors(item, direction)
    local result = {}
    local links = relations[item]
    if links then
        for other in links[direction] do table.insert(result, other) end
    end
    return result
end

function State.GetAbove(item) return neighbors(item, "Above") end
function State.GetBelow(item) return neighbors(item, "Below") end
State.GetDirectChildren = State.GetAbove

-- 선택한 소포에서 위쪽으로만 탐색한다.
-- 공통 받침이나 예전 묶음 Root는 따라가지 않는다.
function State.GetStackItems(root)
    local result, seen = { root }, { [root] = true }
    local index = 1
    while index <= #result do
        for _, above in State.GetAbove(result[index]) do
            if not seen[above] then
                seen[above] = true
                table.insert(result, above)
            end
        end
        index += 1
    end
    return result
end

-- 셀 배열은 복사하지 않는다.
-- 실패 복구 시에만 저장된 배치에서 다시 만든다.
function State.Snapshot()
    local snapshot = { Placements = {}, Grids = {}, Relations = {} }
    for item, record in placements do
        snapshot.Placements[item] = table.clone(record)
    end
    for area, grid in grids do
        local copy = table.clone(grid)
        copy.Cells = {}
        snapshot.Grids[area] = copy
    end
    for item, links in relations do
        snapshot.Relations[item] = {
            Above = table.clone(links.Above),
            Below = table.clone(links.Below),
        }
    end
    return snapshot
end

function State.Restore(snapshot)
    placements, grids, relations = {}, {}, {}
    for area, grid in snapshot.Grids do
        grids[area] = table.clone(grid)
        grids[area].Cells = {}
    end
    for item, links in snapshot.Relations do
        relations[item] = {
            Above = table.clone(links.Above),
            Below = table.clone(links.Below),
        }
    end

    local records = {}
    for _, record in snapshot.Placements do table.insert(records, record) end
    insertRecords(records)
    for area, grid in snapshot.Grids do grids[area].Version = grid.Version end
    for item in registered do publish(item) end
end

-- 집는 집합 내부의 Above/Below는 유지하고,
-- 남겨진 소포와의 경계만 끊는다.
function State.RemoveItems(items)
    local touched = {}
    for item in items do
        local record = placements[item]
        if record then
            local grid = grids[record.RootGridArea]
            eachCell(record, function(x, z)
                local column = grid.Cells[x]
                local layers = column and column[z]
                if not layers then return end
                for index = #layers, 1, -1 do
                    if layers[index].Item == item then table.remove(layers, index) end
                end
                if #layers == 0 then column[z] = nil end
                if next(column) == nil then grid.Cells[x] = nil end
            end)
            touched[record.RootGridArea] = true
            placements[item] = nil
        end

        local links = relations[item]
        if links then
            for above in links.Above do
                if not items[above] then
                    node(above).Below[item] = nil
                    links.Above[above] = nil
                end
            end
            for below in links.Below do
                if not items[below] then
                    node(below).Above[item] = nil
                    links.Below[below] = nil
                end
            end
        end
        publish(item)
    end

    for area in touched do
        local grid = grids[area]
        grid.Version += 1
        if not grid.Owner or not items[grid.Owner] then continue end

        local remaining, owner = {}, nil
        for item, record in placements do
            if record.RootGridArea == area then
                table.insert(remaining, record)
                if not owner or record.Bottom < placements[owner].Bottom then owner = item end
            end
        end

        grids[area] = nil
        if not owner then continue end

        -- 기준 소포가 빠져도 남은 셀 좌표와 높이는 유지하고 참조 기준만 교체한다.
        local newArea = assert(State.GetTopGridArea(owner), "Missing remaining TopGridArea")
        local anchor = assert(Geometry.Handle(owner), "Missing remaining Handle")
        local frame = Geometry.GridFrame(area, grid)
            * CFrame.new(0, (area.Size.Y - newArea.Size.Y) / 2, 0)

        grid.Owner, grid.Anchor, grid.Offset = owner, anchor, anchor.CFrame:ToObjectSpace(frame)
        grids[newArea] = grid
        for _, record in remaining do
            record.RootGridArea = newArea
            publish(record.Item)
        end
    end
end

function State.UnregisterGridArea(area)
    if area then Tags:RemoveTag(area, "GridArea") end
end

-- 같은 셀의 [Bottom, Top)을 비교한다.
-- 면 접촉은 허용하고 부피 겹침은 거부한다.
function State.Validate(records, ignored, budget, existingRigidBundle, gridOverrides)
    local proposed, cells = {}, {}
    local function spend()
        if not budget then return true end
        budget.Left -= 1
        return budget.Left >= 0
    end

    for _, record in records do
        if proposed[record.Item] then return false end
        proposed[record.Item] = true
        local grid = gridOverrides and gridOverrides[record.RootGridArea]
            or grids[record.RootGridArea]

        if not grid or record.StartX < 1 or record.StartZ < 1
            or record.EndX < record.StartX or record.EndZ < record.StartZ
            or record.EndX > grid.GridSizeX or record.EndZ > grid.GridSizeZ
            or record.Bottom < 0 or record.Top <= record.Bottom or record.Top > grid.MaxHeight then
            return false
        end

        local byArea = cells[record.RootGridArea]
        if not byArea then byArea = {}; cells[record.RootGridArea] = byArea end
        for x = record.StartX, record.EndX do
            if not byArea[x] then byArea[x] = {} end
            for z = record.StartZ, record.EndZ do
                if not spend() then return false end
                if not byArea[x][z] then byArea[x][z] = {} end
                table.insert(byArea[x][z], record)
            end
        end
    end

    for _, record in records do
        local grid = gridOverrides and gridOverrides[record.RootGridArea]
            or grids[record.RootGridArea]

        for x = record.StartX, record.EndX do
            for z = record.StartZ, record.EndZ do
                local supported = record.Bottom == 0
                local function inspect(other)
                    if not spend() then return false end
                    if other.Item == record.Item then return true end
                    if other.Bottom < record.Top and record.Bottom < other.Top then return false end
                    if other.Top == record.Bottom then supported = true end
                    return true
                end

                for _, other in grid.Cells[x] and grid.Cells[x][z] or {} do
                    if not (ignored and ignored[other.Item]) and not inspect(other) then return false end
                end
                for _, other in cells[record.RootGridArea][x][z] do
                    if not inspect(other) then return false end
                end
                if not supported and not existingRigidBundle then return false end
            end
        end
    end
    return true
end

function State.TrackWorldBundle(bundle, rollbackManagedExternally: boolean?)
    local area = State.GetTopGridArea(bundle.Root)
    local anchor = Geometry.Handle(bundle.Root)
    if not area or not anchor then return false, "MissingHandleOrTopGridArea" end

    local allPlaced = true
    for _, item in bundle.Items do
        if not placements[item] then allPlaced = false end
    end
    if allPlaced then return true end
    for _, item in bundle.Items do
        if placements[item] then return false, "PartiallyRegisteredBundle" end
    end

    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxZ = -math.huge, -math.huge
    for _, item in bundle.Items do
        local handle = Geometry.Handle(item)
        if not handle then return false, "MissingHandle" end

        local frame = anchor.CFrame:ToObjectSpace(handle.CFrame)
        for _, x in { -0.5, 0.5 } do
            for _, y in { -0.5, 0.5 } do
                for _, z in { -0.5, 0.5 } do
                    local point = frame:PointToWorldSpace(handle.Size * Vector3.new(x, y, z))
                    minX = math.min(minX, point.X)
                    minY = math.min(minY, point.Y)
                    minZ = math.min(minZ, point.Z)
                    maxX = math.max(maxX, point.X)
                    maxZ = math.max(maxZ, point.Z)
                end
            end
        end
    end

    local sizeX = Geometry.Units(maxX - minX)
    local sizeZ = Geometry.Units(maxZ - minZ)
    if not sizeX or not sizeZ or sizeX < 1 or sizeZ < 1
        or sizeX * sizeZ > Config.MaxGridCells then
        return false, "InvalidWorldBundleFootprint"
    end

    local grid = {
        GridSizeX = sizeX,
        GridSizeZ = sizeZ,
        Width = sizeX * Config.CellSize,
        Depth = sizeZ * Config.CellSize,
        Anchor = anchor,
        Owner = bundle.Root,
        Offset = CFrame.new((minX + maxX) / 2, minY - area.Size.Y / 2, (minZ + maxZ) / 2),
        MaxHeight = math.huge,
        Cells = {},
        Version = 0,
    }

    local records = {}
    for _, item in bundle.Items do
        local record = Geometry.Box(item, Geometry.Handle(item).CFrame, area, grid)
        if not record then return false, "InvalidWorldBundleBox: " .. item.Name end
        table.insert(records, record)
    end

    -- 새 그리드는 아직 공개하지 않고 후보 상태로 검증한다.
    if not State.Validate(records, nil, nil, true, { [area] = grid }) then
        return false, "WorldBundleOverlap"
    end

    -- 독립 호출에서는 자체 Snapshot을 생성하고,
    -- 외부 transaction에서는 이미 생성된 Snapshot을 재사용한다.
    local snapshot = if rollbackManagedExternally
        then nil
        else State.Snapshot()

    local ok, message = pcall(function()
        grids[area] = grid
        insertRecords(records)
    end)

    if not ok then
        if snapshot then
            State.Restore(snapshot)
        end

        return false, tostring(message)
    end

    return true
end

-- 검증을 모두 통과한 뒤에만 점유와 관계를 변경한다.
-- 이 구간에서는 yield하지 않는다.
function State.Commit(records)
    for _, record in records do
        if placements[record.Item] then return false end
    end
    if not State.Validate(records) then return false end
    insertRecords(records)
    return true
end

function State.Plan(bundle, area, hit, rotated, reportFailure)
    local function reject(reason)
        if reportFailure then warn("[Placement] " .. reason) end
        return nil, reason
    end

    local parent = area:FindFirstAncestorOfClass("Tool")
    local support = parent and placements[parent]
    if parent and State.GetTopGridArea(parent) ~= area then
        return reject("InvalidTopGridArea")
    end
    if parent and not support then
        return reject("SupportNotRegistered: " .. parent:GetFullName())
    end

    local rootArea = State.ResolveRootGridArea(area)
    local grid = rootArea and grids[rootArea]
    if not grid or not rootArea:IsDescendantOf(workspace) then
        return reject("RootGridAreaNotRegistered")
    end
    for _, item in bundle.Items do
        if area:IsDescendantOf(item) then return reject("CannotPlaceInsideCarriedBundle") end
    end

    local areaHit = area.CFrame:PointToObjectSpace(hit)
    if math.abs(areaHit.X) > area.Size.X / 2 + Config.Epsilon
        or math.abs(areaHit.Z) > area.Size.Z / 2 + Config.Epsilon then
        return reject("HitOutsideTargetArea")
    end
    if math.abs(areaHit.Y - area.Size.Y / 2) > 0.3 then
        return reject("HitNotOnTargetTopFace")
    end

    local rootFrame = Geometry.GridFrame(rootArea, grid)
    local width = grid.Width or rootArea.Size.X
    local depth = grid.Depth or rootArea.Size.Z
    local position = rootFrame:PointToObjectSpace(hit)
    local column = math.floor((position.X + width / 2) / Config.CellSize) + 1
    local row = math.floor((position.Z + depth / 2) / Config.CellSize) + 1
    if column < 1 or column > grid.GridSizeX or row < 1 or row > grid.GridSizeZ then
        return reject("HitOutsideRootGrid")
    end

    if support then
        if column < support.StartX or column > support.EndX
            or row < support.StartZ or row > support.EndZ then
            return reject("HitOutsideSupportFootprint")
        end
    end

    local bottom = support and support.Top or 0
    local surfaceY = rootArea.Size.Y / 2 + bottom * Config.HeightUnit
    local handle = Geometry.Handle(bundle.Root)
    if not handle then return reject("MissingHandle") end

    local sizeX = Geometry.Units(rotated and handle.Size.Z or handle.Size.X)
    local sizeZ = Geometry.Units(rotated and handle.Size.X or handle.Size.Z)
    if not sizeX or not sizeZ or sizeX < 1 or sizeZ < 1 then
        return reject("HandleSizeNotOnHalfStudGrid: " .. tostring(handle.Size))
    end
    if sizeX * sizeZ > Config.MaxGridCells then return reject("FootprintTooLarge") end

    local candidates = {}
    local preferredX = column - math.ceil(sizeX / 2) + 1
    local preferredZ = row - math.ceil(sizeZ / 2) + 1
    for x = math.max(1, column - sizeX + 1), math.min(column, grid.GridSizeX - sizeX + 1) do
        for z = math.max(1, row - sizeZ + 1), math.min(row, grid.GridSizeZ - sizeZ + 1) do
            table.insert(candidates, {
                X = x,
                Z = z,
                Distance = math.abs(x - preferredX) + math.abs(z - preferredZ),
            })
        end
    end

    table.sort(candidates, function(a, b)
        if a.Distance ~= b.Distance then return a.Distance < b.Distance end
        if a.X ~= b.X then return a.X < b.X end
        return a.Z < b.Z
    end)

    local budget = { Left = Config.MaxPlanWork }
    local lastFailure = "NoSupportedFreeCandidate"
    for _, candidate in candidates do
        if budget.Left < 0 then return reject("PlanWorkLimit") end

        local target = rootFrame * CFrame.new(
            -width / 2 + (candidate.X - 1 + sizeX / 2) * Config.CellSize,
            surfaceY + handle.Size.Y / 2,
            -depth / 2 + (candidate.Z - 1 + sizeZ / 2) * Config.CellSize
        ) * CFrame.Angles(0, rotated and math.pi / 2 or 0, 0)

        local records = {}
        local validRecords = true
        for _, item in bundle.Items do
            local box = Geometry.Box(item, target * bundle.Offsets[item], rootArea, grid)
            if not box then
                local itemHandle = Geometry.Handle(item)
                lastFailure = "InvalidBundleBox: " .. item.Name
                    .. " Size=" .. tostring(itemHandle and itemHandle.Size)
                validRecords = false
                break
            end
            table.insert(records, box)
        end

        if validRecords and State.Validate(records, nil, budget) then
            return {
                RootGridArea = rootArea,
                TargetCFrame = target,
                Records = records,
                Version = grid.Version,
            }
        end
    end
    return reject(lastFailure)
end

function State.Initialize()
    local locations = workspace:FindFirstChild("Locations")
    for _, instance in workspace:GetDescendants() do
        if instance:IsA("BasePart") then
            local parent = instance.Parent
            local isStorage = parent and parent.Name == "GridAreas"
            local isDelivery = parent and locations and instance.Name == "DeliveryArea"
                and parent.Parent == locations
            if isStorage or isDelivery then State.RegisterGridArea(instance) end
        end
    end
    for _, item in Tags:GetTagged("PlaceItem") do
        if item:IsA("Tool") then State.RegisterItem(item) end
    end
end

-- 시작 시 실제 위치가 유효한 기존 소포를 배치 상태로 가져온다.
function State.ImportExisting()
    local candidates = {}
    for _, item in Tags:GetTagged("PlaceItem") do
        if not item:IsA("Tool") or not Geometry.Handle(item) or placements[item] then continue end
        for area in grids do
            local record = Geometry.Box(item, Geometry.Handle(item).CFrame, area)
            if record then table.insert(candidates, record) end
        end
    end
    table.sort(candidates, function(a, b)
        return a.Bottom < b.Bottom
    end)
    for _, record in candidates do
        if not placements[record.Item] and State.Validate({ record }) then
            State.Commit({ record })
        end
    end
end

return State