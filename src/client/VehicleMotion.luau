--!strict
-- Propellers for every plane on this client (owner 2026-10-19: "The plane should have it's propeller if it has one
-- rotate"; audit H1/H3: remote players' and bots' props were only ever turned on the server, frame by frame). Each
-- plane carries a welded rotor on the Motor6D "PropMotor" (server/PlaneBuilder); this module turns it through
-- Motor6D.Transform, which never replicates, so every client animates every plane locally:
--   - speed = the plane's replicated Speed attribute (players' clients sync it, AIRacers sets it for bots at 10 Hz),
--     or, for this player's own plane, the live speed FlightController hands in each frame (setLocalSpeed: the grid
--     revs and boosts show at once, no round trip);
--   - the blades turn at most MAX_STEP radians per rendered frame: faster than that a four-armed cross aliases into a
--     slow or backwards wheel, so past it the PropDisc blur fades in instead and carries the speed;
--   - planes beyond CULL_DISTANCE from the camera are skipped (a prop there is a few pixels).
-- Car wheels are CarController's (rigs for the local car and every other car, bots included).
local RunService = game:GetService("RunService")
local Prof = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)

local VehicleMotion = {}

VehicleMotion.IDLE_RATE = 9 -- rad/s at speed 0 (engine idling on the grid)
VehicleMotion.RATE_PER_SPEED = 0.28 -- rad/s per stud/s
VehicleMotion.MAX_STEP = 0.5 -- rad per rendered frame (a quarter turn is the cross's period; stay well under half of it)
VehicleMotion.DISC_FROM = 70 -- speed at which the blur disc starts to show
VehicleMotion.DISC_FULL = 200 -- speed of the strongest blur
VehicleMotion.DISC_MIN_TRANSPARENCY = 0.72
VehicleMotion.CULL_DISTANCE = 700
VehicleMotion.SCAN_INTERVAL = 0.5

type Prop = { model: Model, motor: Motor6D, disc: BasePart?, angle: number, discAlpha: number }
local props: { [Model]: Prop } = {}
local localSpeed: { [Model]: number } = {}
local scanClock = 0
local initialized = false

-- FlightController calls this every frame for the player's own plane.
function VehicleMotion.setLocalSpeed(model: Model, speed: number)
	localSpeed[model] = speed
end

local function scan()
	local folder = workspace:FindFirstChild("Planes")
	if not folder then
		return
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and not props[m] then
			local hull = m:FindFirstChild("Hull")
			local motor = if hull then hull:FindFirstChild("PropMotor") else nil
			if motor and motor:IsA("Motor6D") then
				local disc = m:FindFirstChild("PropDisc")
				props[m] = {
					model = m,
					motor = motor,
					disc = if disc and disc:IsA("BasePart") then disc else nil,
					angle = math.random() * math.pi,
					discAlpha = 1,
				}
			end
		end
	end
end

local function step(dt: number)
	scanClock -= dt
	if scanClock <= 0 then
		scanClock = VehicleMotion.SCAN_INTERVAL
		scan()
	end
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	for model, p in props do
		if not model.Parent or not p.motor.Parent then
			props[model] = nil
			localSpeed[model] = nil
		else
			local part1 = p.motor.Part1
			if part1 and (part1.Position - camPos).Magnitude <= VehicleMotion.CULL_DISTANCE then
				local speed = localSpeed[model]
				if speed == nil then
					local a = model:GetAttribute("Speed")
					speed = if type(a) == "number" then a else 0
				end
				local s = math.abs(speed :: number)
				local stepAngle = math.min((VehicleMotion.IDLE_RATE + s * VehicleMotion.RATE_PER_SPEED) * dt, VehicleMotion.MAX_STEP)
				p.angle = (p.angle + stepAngle) % (math.pi * 2)
				p.motor.Transform = CFrame.Angles(0, 0, p.angle)
				local disc = p.disc
				if disc then
					local k = math.clamp((s - VehicleMotion.DISC_FROM) / (VehicleMotion.DISC_FULL - VehicleMotion.DISC_FROM), 0, 1)
					local alpha = 1 - k * (1 - VehicleMotion.DISC_MIN_TRANSPARENCY)
					if math.abs(alpha - p.discAlpha) > 0.02 then
						p.discAlpha = alpha
						disc.Transparency = alpha
					end
				end
			end
		end
	end
end

function VehicleMotion.init()
	if initialized then
		return
	end
	initialized = true
	RunService.RenderStepped:Connect(Prof.wrap("SR_VehicleMotion", step))
end

return VehicleMotion
