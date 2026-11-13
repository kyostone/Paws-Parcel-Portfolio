local PlacementPreview = {}
local Geometry = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ParcelGeometry"))

local previewModel: Model? = nil
local previewParts: {BasePart} = {}
local previewGuis = {}

local function SetPreviewTransparency(transparency: number)
    for _, part in previewParts do
        part.LocalTransparencyModifier = transparency
    end
    for gui, enabled in previewGuis do
        gui.Enabled = enabled and transparency < 1
    end
end

function PlacementPreview.Begin(bundle)
    PlacementPreview.End()

    local item = bundle.Root
    local handle = item:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then return end

    local model = Instance.new("Model")
    model.Name = "PlacementPreview"

    local previewHandle: BasePart? = nil
    local sourceParts = {}
    for _, member in bundle.Items do
        for _, part in Geometry.Parts(member) do
            table.insert(sourceParts, part)
        end
    end

    for _, sourcePart in sourceParts do
        if not sourcePart:IsA("BasePart") then continue end
        if sourcePart.Name == "TopGridArea" or sourcePart.Name == "PlacementPreview" then continue end

        local clonedPart = sourcePart:Clone()
        if not clonedPart then continue end

        -- 중첩된 Part는 별도로 복제하므로 여기서는 제거한다.
        for _, descendant in clonedPart:GetDescendants() do
            if descendant:IsA("BasePart") then descendant:Destroy() end
        end

        -- 원본 소포로 향하는 Weld 참조도 남기지 않는다.
        for _, descendant in clonedPart:GetDescendants() do
            if descendant:IsA("Constraint") or descendant:IsA("WeldConstraint")
                or descendant:IsA("JointInstance") or descendant:IsA("Script")
                or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
                descendant:Destroy()
            end
        end

        for _, descendant in clonedPart:GetDescendants() do
            if descendant:IsA("SurfaceGui") or descendant:IsA("BillboardGui") then
                previewGuis[descendant] = descendant.Enabled
                descendant.Enabled = false
            end
        end

        clonedPart.Anchored = true
        clonedPart.CanCollide = false
        clonedPart.CanTouch = false
        clonedPart.CanQuery = false
        clonedPart.LocalTransparencyModifier = 1
        clonedPart.Parent = model
        table.insert(previewParts, clonedPart)

        if sourcePart == handle then previewHandle = clonedPart end
    end

    if not previewHandle then
        model:Destroy()
        table.clear(previewParts)
        return
    end

    previewHandle.PivotOffset = CFrame.new()
    model.PrimaryPart = previewHandle
    previewModel = model
    model.Parent = workspace
end

function PlacementPreview.Update(targetCFrame: CFrame)
    if not previewModel then return end
    previewModel:PivotTo(targetCFrame)
    SetPreviewTransparency(0.5)
end

function PlacementPreview.Hide()
    if not previewModel then return end
    SetPreviewTransparency(1)
end

function PlacementPreview.End()
    if previewModel then
        previewModel:Destroy()
        previewModel = nil
    end
    table.clear(previewParts)
    table.clear(previewGuis)
end

return PlacementPreview