local Geometry = {}
local Config = require(script.Parent:WaitForChild("GridConfig"))

-- Handle 반환 함수
function Geometry.Handle(item)
    local handle = item:FindFirstChild("Handle")
    return handle and handle:IsA("BasePart") and handle or nil
end

-- item의 모든 Part를 반환하는 함수
function Geometry.Parts(item)
    local parts = {}
    for _, part in item:GetDescendants() do
        if part:IsA("BasePart") and part:FindFirstAncestorOfClass("Tool") == item then
            table.insert(parts, part)
        end
    end
    return parts
end

-- item의 크기를 정해진 스튜드 단위에서 grid cell 단위로 변환 및 보정하는 함수
function Geometry.Units(value)
    if value ~= value or math.abs(value) == math.huge then return nil end
    local units = math.round(value / Config.CellSize)
    return math.abs(value - units * Config.CellSize) <= Config.Epsilon and units or nil
end

-- Root를 기준으로 각 소포의 상대 위치·회전 및 기존 활성화 상태를 저장
function Geometry.Capture(root, items)
    local handle = Geometry.Handle(root)
    if not handle then return nil end

    local bundle = { Root = root, Items = items, Offsets = {}, Enabled = {} }
    for _, item in items do
        local itemHandle = Geometry.Handle(item)
        if not itemHandle then return nil end
        bundle.Offsets[item] = handle.CFrame:ToObjectSpace(itemHandle.CFrame)
        bundle.Enabled[item] = item.Enabled
    end
    return bundle
end

-- 모든 Part의 이동 결과를 먼저 계산한 뒤 함께 이동한다.
function Geometry.Move(bundle, target)
    local transforms = {}
    for _, item in bundle.Items do
        local handle = Geometry.Handle(item)
        local delta = target * bundle.Offsets[item] * handle.CFrame:Inverse()
        for _, part in Geometry.Parts(item) do
            table.insert(transforms, {
                Part = part,
                Frame = delta * part.CFrame,
                Anchored = part.Anchored,
            })
        end
    end

    for _, entry in transforms do entry.Part.Anchored = true end
    for _, entry in transforms do entry.Part.CFrame = entry.Frame end
    for _, entry in transforms do entry.Part.Anchored = entry.Anchored end
end

-- Handle을 루트 그리드 기준 셀과 높이 구간으로 변환한다.
function Geometry.GridFrame(area, grid)
    if grid and grid.Anchor then return grid.Anchor.CFrame * grid.Offset end
    return area.CFrame
end

function Geometry.Box(item, frame, area, grid)
    local handle = Geometry.Handle(item)
    if not handle then return nil end

    local localFrame = Geometry.GridFrame(area, grid):ToObjectSpace(frame)
    local right, up, look = localFrame.RightVector, localFrame.UpVector, localFrame.LookVector
    if math.abs(up.Y - 1) > Config.Epsilon
        or math.min(math.abs(right.X), math.abs(right.Z)) > Config.Epsilon
        or math.min(math.abs(look.X), math.abs(look.Z)) > Config.Epsilon then
        return nil
    end

    local width = math.abs(right.X) * handle.Size.X + math.abs(look.X) * handle.Size.Z
    local depth = math.abs(right.Z) * handle.Size.X + math.abs(look.Z) * handle.Size.Z
    local sizeX, sizeZ, height = Geometry.Units(width), Geometry.Units(depth), Geometry.Units(handle.Size.Y)
    if not sizeX or not sizeZ or not height or sizeX < 1 or sizeZ < 1 or height < 1 then
        return nil
    end

    local position = localFrame.Position
    local gridWidth = grid and grid.Width or area.Size.X
    local gridDepth = grid and grid.Depth or area.Size.Z
    local x = Geometry.Units(position.X - width / 2 + gridWidth / 2)
    local z = Geometry.Units(position.Z - depth / 2 + gridDepth / 2)
    local bottom = Geometry.Units(position.Y - handle.Size.Y / 2 - area.Size.Y / 2)
    if not x or not z or not bottom then return nil end

    return {
        Item = item,
        RootGridArea = area,
        StartX = x + 1,
        EndX = x + sizeX,
        StartZ = z + 1,
        EndZ = z + sizeZ,
        Bottom = bottom,
        Top = bottom + height,
        TargetCFrame = frame,
    }
end

return Geometry