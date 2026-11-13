
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local PhysicsService = game:GetService("PhysicsService")

local units = ServerStorage:WaitForChild("Units")
local dogTemplate = units:WaitForChild("Dog R6 Dummy")
local CustomerAI = require(script:WaitForChild("CustomerAI"))
local customerSpawn = workspace:WaitForChild("CustomerSpawn")

local CUSTOMER_COLLISION_GROUP = "Customers"
local MAX_CUSTOMER_COUNT = 4

local activeCustomerCount = Instance.new("IntValue")
activeCustomerCount.Value = 0

-- 손님 전용 충돌 그룹 초기화
if not PhysicsService:IsCollisionGroupRegistered(CUSTOMER_COLLISION_GROUP) then
    PhysicsService:RegisterCollisionGroup(CUSTOMER_COLLISION_GROUP)
end

PhysicsService:CollisionGroupSetCollidable(
    CUSTOMER_COLLISION_GROUP,
    CUSTOMER_COLLISION_GROUP,
    false
)

local function SetCustomerCollision(customer)
    for _, descendant in customer:GetDescendants() do
        if descendant:IsA("BasePart") then
            descendant.CollisionGroup = CUSTOMER_COLLISION_GROUP
        end
    end
end

local function SpawnCustomer()
    local customer = dogTemplate:Clone()

    SetCustomerCollision(customer)

    customer.Parent = workspace
    customer:PivotTo(customerSpawn.CFrame)

    local customerAI = CustomerAI.new(customer)
    local seat = customerAI:FindSeat()

    if seat then
        seat:SetAttribute("Occupied", true)
        activeCustomerCount.Value += 1

        customer.Destroying:Connect(function()
            activeCustomerCount.Value -= 1
        end)

        task.spawn(function()
            customerAI:Run(seat)
        end)
    else
        customer:Destroy()
        warn("No available seats found for the customer.")
    end

    return customerAI
end

activeCustomerCount.Changed:Connect(function(newValue)
    if newValue < MAX_CUSTOMER_COUNT then
        SpawnCustomer()
    end
end)

-- 배치 시스템과 초기 소포 등록이 완료되면 손님 생성 시작
while ServerScriptService:GetAttribute("PawsPlacementReady") ~= true do
    ServerScriptService:GetAttributeChangedSignal("PawsPlacementReady"):Wait()
end

SpawnCustomer()
