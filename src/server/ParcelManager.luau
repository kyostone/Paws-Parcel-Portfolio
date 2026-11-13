local ParcelManager = {}
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local ParcelConfig = require(script.Parent:WaitForChild("ParcelConfig"))
local PlacementState = require(script.Parent:WaitForChild("PlacementState"))
local ParcelTemplates = ServerStorage:WaitForChild("ParcelTemplates")

local availableTruckInfo = {}

local pickupParcels = {}          -- 요청 가능한 소포
local requestedPickupParcels = {} -- 손님에게 배정된 소포
local dropoffParcels = {}

local truckInitialized = false

local function MakeParcelCode(nameIndex, sizeIndex)
    return string.format("%03d%d", nameIndex, sizeIndex)
end

local function InitializeParcelPool()
    for _, size in ipairs(ParcelConfig.BoxSizes) do
        availableTruckInfo[size] = {}
    end
    for nameIndex, recipientName in ipairs(ParcelConfig.Names) do
        for sizeIndex, size in ipairs(ParcelConfig.BoxSizes) do
            table.insert(availableTruckInfo[size], {
                ParcelCode = MakeParcelCode(nameIndex, sizeIndex),
                RecipientName = recipientName,
                Size = size,
            })
        end
    end
end

InitializeParcelPool()

local function TakeTruckParcelInfo(size)
    local available = availableTruckInfo[size]
    if not available or #available == 0 then return nil end
    return table.remove(available, math.random(1, #available))
end

local function GenerateDropoffInfo()
    if #ParcelConfig.Names == 0 or #ParcelConfig.BoxSizes == 0 then return nil end
    local nameIndex = math.random(1, #ParcelConfig.Names)
    local sizeIndex = math.random(1, #ParcelConfig.BoxSizes)
    return {
        ParcelCode = MakeParcelCode(nameIndex, sizeIndex),
        RecipientName = ParcelConfig.Names[nameIndex],
        Size = ParcelConfig.BoxSizes[sizeIndex],
    }
end

local function RegisterParcel(parcel, parcelInfo)
    parcel:SetAttribute("ParcelCode", parcelInfo.ParcelCode)
    parcel:SetAttribute("RecipientName", parcelInfo.RecipientName)
    parcel:SetAttribute("Size", parcelInfo.Size)

    local handle = parcel:FindFirstChild("Handle")
    local surfaceGui = handle and handle:FindFirstChild("SurfaceGui")
    local textLabel = surfaceGui and surfaceGui:FindFirstChild("TextLabel")
    if textLabel then textLabel.Text = parcelInfo.RecipientName end

    local parcelData = {
        Parcel = parcel,
        ParcelCode = parcelInfo.ParcelCode,
        RecipientName = parcelInfo.RecipientName,
        Size = parcelInfo.Size,
        Reserved = false,
    }
    CollectionService:AddTag(parcel, "PlaceItem")
    PlacementState.RegisterItem(parcel)
    return parcelData
end

local function CountRequested(customer)
    local count = 0

    for _, parcelData in requestedPickupParcels do
        if parcelData.PickupCustomer == customer then
            count += 1
        end
    end

    return count
end

local function ReleaseTruckParcel(parcelData)
    if parcelData.Released then return end
    parcelData.Released = true

    local customer = parcelData.PickupCustomer
    local seat = parcelData.PickupSeat

    pickupParcels[parcelData.ParcelCode] = nil
    requestedPickupParcels[parcelData.ParcelCode] = nil

    parcelData.PickupCustomer = nil
    parcelData.PickupSeat = nil

    table.insert(
        availableTruckInfo[parcelData.Size],
        parcelData.SourceInfo
    )

    -- 마지막 소포까지 처리됐다면 손님 퇴장
    if customer and CountRequested(customer) == 0 then
        task.defer(function()
            if customer.customer.Parent then
                customer:Exit(seat)
            end
        end)
    end
end


function ParcelManager.CreateParcel(spawnCFrame, customer, seat)
    local parcelInfo = GenerateDropoffInfo()
    if not parcelInfo then return nil end

    local template = ParcelTemplates:FindFirstChild(parcelInfo.Size .. "Box")
    if not template then return nil end

    local parcel = template:Clone()
    local handle = parcel:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then
        parcel:Destroy()
        return nil
    end

    handle.Anchored = true
    parcel.PrimaryPart = handle
    parcel:PivotTo(spawnCFrame * CFrame.new(0, handle.Size.Y / 2, 0))
    parcel.Parent = workspace
    handle.CanCollide = false
    RegisterParcel(parcel, parcelInfo)
    local tracked, reason = PlacementState.TrackWorldBundle({ Root = parcel, Items = { parcel } })
    if not tracked then warn("[Placement] World registration failed:", reason) end

    dropoffParcels[parcel] = { Customer = customer, Seat = seat }
    parcel.Destroying:Connect(function()
        dropoffParcels[parcel] = nil
    end)
    return parcel
end

function ParcelManager.InitializeTruckParcels()
    if truckInitialized then return end
    local folder = workspace:WaitForChild("TruckParcels")
    truckInitialized = true

    for _, parcel in ipairs(folder:GetChildren()) do
        if not parcel:IsA("Tool") then continue end

        local size = parcel.Name:match("^(%u+)Box$")
        if not size or not availableTruckInfo[size] then continue end

        local handle = parcel:FindFirstChild("Handle")
        if not handle or not handle:IsA("BasePart") then continue end

        local parcelInfo = TakeTruckParcelInfo(size)
        if not parcelInfo then
            warn("[ParcelManager] 소포 정보 부족:", size)
            continue
        end

        handle.Anchored = true
        handle.CanCollide = false

        local parcelData = RegisterParcel(parcel, parcelInfo)
        parcelData.SourceInfo = parcelInfo
        pickupParcels[parcelInfo.ParcelCode] = parcelData

        parcel.Destroying:Connect(function()
            ReleaseTruckParcel(parcelData)
        end)
    end
end


function ParcelManager.ReservePickupParcels(count, customer, seat)
    if typeof(count) ~= "number"
        or not customer
        or not customer.customer
        or not customer.customer.Parent
        or not seat then
        return {}
    end

    -- 이미 요청한 손님에게 중복 배정하지 않는다.
    if CountRequested(customer) > 0 then
        return {}
    end

    local available = {}

    for _, parcelData in pickupParcels do
        if not parcelData.Released
            and PlacementState.GetPlacement(parcelData.Parcel) then
            table.insert(available, parcelData)
        end
    end

    if #available == 0 then return {} end

    local amount = math.min(
        math.clamp(math.floor(count), 1, 3),
        #available
    )

    local selected = {}

    for i = 1, amount do
        local index = math.random(i, #available)

        available[i], available[index] = available[index], available[i]
        local parcelData = available[i]

        -- 요청 가능 목록에서 실제로 제거
        pickupParcels[parcelData.ParcelCode] = nil

        -- 전달을 기다리는 목록으로 이동
        requestedPickupParcels[parcelData.ParcelCode] = parcelData

        parcelData.PickupCustomer = customer
        parcelData.PickupSeat = seat

        table.insert(selected, parcelData)
    end

    -- 손님이 비정상적으로 사라지면
    -- 아직 전달되지 않은 소포를 다시 요청 가능 상태로 전환
    customer.customer.Destroying:Once(function()
        for code, parcelData in requestedPickupParcels do
            if parcelData.PickupCustomer == customer then
                requestedPickupParcels[code] = nil

                parcelData.PickupCustomer = nil
                parcelData.PickupSeat = nil

                if not parcelData.Released then
                    pickupParcels[code] = parcelData
                end
            end
        end
    end)

    return selected
end


function ParcelManager.OnParcelPickedUp(parcel)
    local dropoffInfo = dropoffParcels[parcel]
    if not dropoffInfo then return end
    dropoffParcels[parcel] = nil

    task.spawn(function()
        dropoffInfo.Customer:Exit(dropoffInfo.Seat)
    end)
end


function ParcelManager.CanDeliverPickupParcel(parcel, seat)
    if not parcel or not parcel:IsA("Tool") then
        return false
    end

    local parcelCode = parcel:GetAttribute("ParcelCode")
    local parcelData = requestedPickupParcels[parcelCode]

    if not parcelData or parcelData.Parcel ~= parcel then
        return false
    end

    if parcelData.Released
        or parcelData.PickupSeat ~= seat
        or not parcelData.PickupCustomer then
        return false
    end

    return true
end


-- 해당 손님의 소포만 선별하며 아직 삭제하지 않는다.
function ParcelManager.GetDeliverableParcels(items, seat)
    local selected = {}
    for _, parcel in items do
        if ParcelManager.CanDeliverPickupParcel(parcel, seat) then
            table.insert(selected, parcel)
        end
    end
    return selected
end

function ParcelManager.CompletePickupDelivery(items, seat)
    -- 전달 전 전체 소포 검증
    for _, parcel in items do
        assert(
            ParcelManager.CanDeliverPickupParcel(parcel, seat),
            "Delivery reservation changed"
        )
    end

    local customers = {}

    for _, parcel in items do
        local parcelCode = parcel:GetAttribute("ParcelCode")
        local parcelData = requestedPickupParcels[parcelCode]
        local customer = parcelData.PickupCustomer

        customers[customer] = true

        PlacementState.UnregisterGridArea(
            PlacementState.GetTopGridArea(parcel)
        )

        ReleaseTruckParcel(parcelData)
        parcel:Destroy()
    end

    -- 소포가 남았다면 대기, 모두 처리됐다면
    -- ReleaseTruckParcel에서 퇴장을 예약한다.
    for customer in customers do
        local remaining = CountRequested(customer)

        if remaining > 0 and customer.customer.Parent then
            customer:HandleTalk(
                string.format(
                    "아직 소포 %d개가 남았어요!",
                    remaining
                )
            )
        end
    end

    return true
end


function ParcelManager.DeliverPickupParcel(parcel, seat)
    if not ParcelManager.CanDeliverPickupParcel(parcel, seat) then return false end
    return ParcelManager.CompletePickupDelivery({ parcel }, seat)
end

return ParcelManager