local RaycastUtil = {}
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

function RaycastUtil.DoRaycast()
    local camera = workspace.CurrentCamera
    if not camera then return nil, nil end

    local mousePosition = UserInputService:GetMouseLocation()
    local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
    raycastParams.FilterDescendantsInstances = { player.Character }

    local result = workspace:Raycast(ray.Origin, ray.Direction * 100, raycastParams)
    if result then return result.Instance, result.Position end
    return nil, nil
end

return RaycastUtil