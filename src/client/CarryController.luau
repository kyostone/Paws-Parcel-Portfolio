local Carry = {}
local RunService = game:GetService("RunService")

local TRANSPARENCY = 0.5
local BIND_NAME = "PawsAndPa_CarryTransparency"
local originals: {[Instance]: {[string]: number}} = {}
local connections: {RBXScriptConnection} = {}
local watched: {[Instance]: boolean} = {}
local generation = 0

local function save(instance: any, property: string)
    local properties = originals[instance]
    if not properties then
        properties = {}
        originals[instance] = properties
    end
    if properties[property] == nil then
        properties[property] = instance[property]
    end
end

local function collect(instance: Instance)
    if instance:IsA("BasePart") then
        if instance.Name ~= "TopGridArea" and instance.Name ~= "PlacementPreview" then
            save(instance, "LocalTransparencyModifier")
        end
    elseif instance:IsA("Decal") then
        save(instance, "LocalTransparencyModifier")
    elseif instance:IsA("GuiObject") then
        save(instance, "BackgroundTransparency")
        if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
            save(instance, "TextTransparency")
            save(instance, "TextStrokeTransparency")
        elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
            save(instance, "ImageTransparency")
        end
    elseif instance:IsA("UIStroke") then
        save(instance, "Transparency")
    end
end

local function apply()
    for instance, properties in originals do
        if instance.Parent then
            local object: any = instance
            for property, original in properties do
                local value = if property == "LocalTransparencyModifier"
                    then math.max(original, TRANSPARENCY)
                    else 1 - (1 - original) * (1 - TRANSPARENCY)
                if object[property] ~= value then
                    object[property] = value
                end
            end
        end
    end
end

local function watch(item: Instance)
    if watched[item] then return end
    watched[item] = true

    local currentGeneration = generation
    table.insert(connections, item.DescendantAdded:Connect(function(descendant)
        if generation == currentGeneration then collect(descendant) end
    end))

    for _, descendant in item:GetDescendants() do collect(descendant) end
end

function Carry.Clear()
    generation += 1
    RunService:UnbindFromRenderStep(BIND_NAME)

    for _, connection in connections do connection:Disconnect() end
    table.clear(connections)
    table.clear(watched)

    for instance, properties in originals do
        if instance.Parent then
            local object: any = instance
            for property, original in properties do
                object[property] = original
            end
        end
    end
    table.clear(originals)
end

function Carry.Show(bundle)
    Carry.Clear()
    if not bundle then return end

    watch(bundle.Root)
    for _, item in bundle.Items do watch(item) end

    apply()
    RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, apply)
end

return Carry