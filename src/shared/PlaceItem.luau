local PlaceItem = {}
PlaceItem.__index = PlaceItem

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GridConfig")
)

function PlaceItem.new(tool)
    local self = setmetatable({}, PlaceItem)

    self.Tool = tool
    self.Handle = tool:FindFirstChild("Handle")

    self.Size = self.Handle.Size

    self.GridSize = {
        X = math.ceil(self.Size.X / GridConfig.CellSize),
        Z = math.ceil(self.Size.Z / GridConfig.CellSize),
    }

    self.Anchor = {
        X = math.ceil(self.GridSize.X / 2),
        Z = math.ceil(self.GridSize.Z / 2),
    }

    return self
end

-- 저장된 회전 상태 가져오기
function PlaceItem:GetRotation()
    return self.Tool:GetAttribute("IsRotated") == true
end

-- 회전 상태 저장하기
function PlaceItem:SetRotation(isRotated)
    self.Tool:SetAttribute("IsRotated", isRotated)
end

return PlaceItem