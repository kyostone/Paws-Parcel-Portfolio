local PlacementMath = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GridConfig"))

function PlacementMath.IsGridArea(instance)
    return instance
        and instance:IsA("BasePart")
        and CollectionService:HasTag(
            instance,
            "GridArea"
        )
end

function PlacementMath.GetMouseHitCell(localPosition, gridArea)
    local column = math.floor((localPosition.X + gridArea.Size.X / 2) / GridConfig.CellSize) + 1
    local row = math.floor((localPosition.Z + gridArea.Size.Z / 2) / GridConfig.CellSize) + 1

    return row, column
end

function PlacementMath.CheckPlacement(isRotated, placeItem, gridArea, hitPosition)
    -- 배치 영역 크기
    local areaSizeX = gridArea:GetAttribute("GridSizeX")
    local areaSizeZ = gridArea:GetAttribute("GridSizeZ")

    if not areaSizeX or not areaSizeZ then
        return nil
    end

    -- 소포 크기
    local gridSizeX = placeItem.GridSize.X
    local gridSizeZ = placeItem.GridSize.Z

    -- 회전 상태에 따른 소포 크기 변경
    if isRotated then
        gridSizeX, gridSizeZ = gridSizeZ, gridSizeX
    end

    -- 월드 위치를 GridArea 기준 로컬 위치로 변환
    local localPosition =
        gridArea.CFrame:PointToObjectSpace(hitPosition)

    local row, column =
        PlacementMath.GetMouseHitCell(localPosition, gridArea)

    column = math.clamp(column, 1, areaSizeX)
    row = math.clamp(row, 1, areaSizeZ)

    -- 회전된 크기를 기준으로 Anchor 계산
    local anchorX = math.ceil(gridSizeX / 2)
    local anchorZ = math.ceil(gridSizeZ / 2)

    -- 점유 셀 범위 계산
    local startX = column - (anchorX - 1)
    local startZ = row - (anchorZ - 1)

    local endX = startX + gridSizeX - 1
    local endZ = startZ + gridSizeZ - 1

    -- 소포 중심 좌표 계산
    local centerX =
        -gridArea.Size.X / 2
        + (startX - 1) * GridConfig.CellSize
        + (gridSizeX * GridConfig.CellSize) / 2

    local centerZ =
        -gridArea.Size.Z / 2
        + (startZ - 1) * GridConfig.CellSize
        + (gridSizeZ * GridConfig.CellSize) / 2

    local centerY =
        gridArea.Size.Y / 2
        + placeItem.Size.Y / 2

    local targetCFrame =
        gridArea.CFrame
        * CFrame.new(centerX, centerY, centerZ)

    return targetCFrame, startX, endX, startZ, endZ
end


return PlacementMath