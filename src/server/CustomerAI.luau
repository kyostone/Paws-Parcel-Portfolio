local CustomerAI = {}
CustomerAI.__index = CustomerAI

local ParcelManager = require(script.Parent:WaitForChild("ParcelManager"))

function CustomerAI.new(customer)
    local self = setmetatable({}, CustomerAI)
    
    self.customer = customer
    self.humanoid = customer:FindFirstChildOfClass("Humanoid")
    self.root = customer:FindFirstChild("HumanoidRootPart")
    return self
end

function CustomerAI:FindNearestSeat(Seats)
    table.sort(Seats, function(Slota, Slotb) -- 슬롯 a와 슬롯 b의 거리를 비교하여 가까운 순으로 정렬
        return (Slota.Position - self.root.Position).Magnitude < (Slotb.Position - self.root.Position).Magnitude 
    end)

    return Seats[1]
end

function CustomerAI:FindSeat()
    local Locations = workspace:WaitForChild("Locations")
    local Slots = Locations:GetChildren()

	local availableSlots = {}
    for _, slot in ipairs(Slots) do
        if slot:GetAttribute("Occupied") == false then
            table.insert(availableSlots, slot)
        end
    end
     
    return self:FindNearestSeat(availableSlots)
end

function CustomerAI:FindExitSeat()
    local ExitLocation = workspace:WaitForChild("ExitLocations")
    local ExitSlots = ExitLocation:GetChildren()

    return self:FindNearestSeat(ExitSlots)
end



function CustomerAI:MoveToSeat(seat)
    if not seat then return false end

    local PathfindingService = game:GetService("PathfindingService")
    local RunService = game:GetService("RunService")

    self.humanoid.AutoRotate = true

    -- 높이 차이를 제외한 수평 거리 계산
    local function GetDistance(a, b)
        return (Vector2.new(a.X, a.Z) - Vector2.new(b.X, b.Z)).Magnitude
    end

    -- 경로 생성
    local path = PathfindingService:CreatePath({
        AgentCanJump = false,
        AgentCanClimb = false,
    })

    -- 목적지까지 경로 계산 (1회)
    local success = pcall(function()
        path:ComputeAsync(self.root.Position, seat.Position)
    end)

    if not success or path.Status ~= Enum.PathStatus.Success then
        return false
    end

    local waypoints = path:GetWaypoints()

    -- Waypoint 순서대로 이동
    for i = 2, #waypoints do
        local target = waypoints[i].Position
        local arrivalDistance = (i == #waypoints) and 1.5 or 2.5
        local moveStartedAt = os.clock()

        while self.customer.Parent do
            local delta = target - self.root.Position
            local direction = Vector3.new(delta.X, 0, delta.Z)

            -- Waypoint에 가까워지면 다음 지점으로 이동
            if direction.Magnitude <= arrivalDistance then
                break
            end

            -- 무한 대기 방지
            if os.clock() - moveStartedAt > 8 then
                self.humanoid:Move(Vector3.zero, false)
                return false
            end

            -- 이동 방향 갱신
            self.humanoid:Move(direction.Unit, false)
            RunService.Heartbeat:Wait()
        end

        if not self.customer.Parent then
            return false
        end
    end

    -- 이동 종료
    self.humanoid:Move(Vector3.zero, false)

    -- 최종 목적지 도착 확인
    if GetDistance(self.root.Position, seat.Position) <= 2 then
        local targetCFrame = CFrame.lookAt(
            self.root.Position,
            self.root.Position + seat.CFrame.LookVector
        )

        self.humanoid.AutoRotate = false
        self:TurnToRotation(targetCFrame)

        return true
    end

    return false
end


function CustomerAI:TurnToRotation(TargetCFrame)
    local TweenService = game:GetService("TweenService")

    local tween = TweenService:Create(self.root, TweenInfo.new(0.5), {CFrame = TargetCFrame})

    tween:Play()
    tween.Completed:Wait()
end

-- NPC 말풍선
function CustomerAI:HandleTalk(message)
    local CustomerTalk = game:GetService("ReplicatedStorage")
        :WaitForChild("Remotes")
        :WaitForChild("CustomerTalk")

    CustomerTalk:FireAllClients(self.customer, message)
end

-- NPC 고객 업무 설정

function CustomerAI:Run(seat)
    -- 카운터 도착에 성공해야 요청을 시작한다.
    if not self:MoveToSeat(seat) then
        seat:SetAttribute("Occupied", false)
        self.customer:Destroy()
        return
    end

    local parcels = {}

    -- 50% 확률로 Pickup 손님
    if math.random() < 0.5 then
        parcels = ParcelManager.ReservePickupParcels(math.random(1, 3),self,seat)
    end

    if #parcels > 0 then
    local names = {}
    local seenNames = {}

    for _, parcelData in parcels do
        local name = parcelData.RecipientName

        if not seenNames[name] then
            seenNames[name] = true
            table.insert(names, name)
        end
    end

    local nameList = table.concat(names, ", ")

        if #parcels == 1 then
            self:HandleTalk(string.format("안녕하세요! %s의 소포를 찾으러 왔어요!",nameList))
        else
            self:HandleTalk(string.format("안녕하세요! %s의 소포 %d개를 찾으러 왔어요!",nameList,#parcels))
        end

        return
    end

    -- Dropoff 손님
    local parcelSpawn = seat:WaitForChild("ParcelSpawn")
    local parcel = ParcelManager.CreateParcel(parcelSpawn.WorldCFrame,self,seat)

    if not parcel then
        self:Exit(seat)
        return
    end

    self:HandleTalk("안녕하세요! 소포를 맡기러 왔어요!")
end



function CustomerAI:Exit(seat)
    if self.Exiting then return end
    self.Exiting = true

    if seat then
        seat:SetAttribute("Occupied", false)
    end

    if self.customer.Parent then
        self:MoveToSeat(self:FindExitSeat())
        self.customer:Destroy()
    end
end

return CustomerAI