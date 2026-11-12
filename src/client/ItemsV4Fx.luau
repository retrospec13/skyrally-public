--!strict
-- Items v4 client look (docs/design/ITEMS_V4.md; the server decides everything in server/kit/ItemEffects). ItemClient
-- forwards the item events it receives here: ItemFx for everyone ("rocket", "golden", "stormCloud", "stormStrike",
-- "bombBlast", "coinTake", "reflect", "slow") and ItemEffect for this player ("slow", "stormWarn", a special's "boost"). Each draws with ParticleEmitters on an Attachment of the vehicle's hull (or a pooled
-- burst at a point) for its seconds, never a mesh over the chase camera, and plays an existing Sfx cue (no new upload).
-- The charged items' ring (Orbit Missiles orbiters, Gift Box gifts) is drawn from the holders' ItemColor/ItemCharges
-- attributes (Player for a player, the bot's model for a bot), rescanned every ORBIT_FX.scan seconds, as sparks
-- circling low round the hull (ItemRules.orbitOffsets). Nothing here changes a speed, a hit or a rule.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local ItemFxRules = require(Shared:WaitForChild("ItemFxRules"))

local Sfx = require(script.Parent:WaitForChild("Sfx"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx37 = require(script.Parent:WaitForChild("Sfx37"))
local TrickJuice = require(script.Parent:WaitForChild("TrickJuice"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))

local LocalPlayer = Players.LocalPlayer

local ItemsV4Fx = {}

type Burst = (name: string, pos: Vector3, tint: Color3?, scale: number?) -> ()
local burst: Burst = function() end

local function rgb(id: string): Color3
	local t = ItemRules.COLOR_RGB[id] or { 255, 255, 255 }
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function hullOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local p = model.PrimaryPart
	return if p and p:IsA("BasePart") then p else nil
end

local function own(model: any): boolean
	return typeof(model) == "Instance"
		and (model.Name == "Car_" .. LocalPlayer.Name or model.Name == "Plane_" .. LocalPlayer.Name)
end

local function rate(base: number): number
	local k = Settings.particleScale()
	return base * math.clamp(k, 0.2, 1)
end

-- A particle aura on a hull for `seconds` (Attachment + emitter, removed after). offset in hull space.
local function aura(hull: BasePart, seconds: number, color: Color3, base: number, size: number, speed: number, offset: Vector3?, lifetime: number?): ()
	local att = Instance.new("Attachment")
	att.Name = "ItemsV4Aura"
	att.Position = offset or Vector3.zero
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(color)
	pe.LightEmission = 1
	pe.Rate = rate(base)
	pe.Lifetime = NumberRange.new((lifetime or 0.5) * 0.6, lifetime or 0.5)
	pe.Speed = NumberRange.new(speed * 0.5, speed)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new(size, 0)
	pe.Transparency = NumberSequence.new(0.15, 1)
	pe.Parent = att
	att.Parent = hull
	task.delay(math.clamp(seconds, 0.1, 10), function()
		pe.Enabled = false
		task.delay(1, function()
			att:Destroy()
		end)
	end)
end

------------------------------------------------------------------------------------------------------------------------
-- Everyone: ItemFx
------------------------------------------------------------------------------------------------------------------------

function ItemsV4Fx.onFx(fx: string, payload: { [string]: any })
	local model = payload.plane
	local hull = hullOf(model)
	local pos = payload.pos
	if fx == "rocket" then
		if hull then
			local secs = tonumber(payload.seconds) or 2
			-- Flame out of the tail and white streaks: behind the hull, never in front of the camera.
			aura(hull, secs, rgb("rocket_rush"), 60, 1.6, 14, Vector3.new(0, 0, 4), 0.35)
			aura(hull, secs, Color3.new(1, 1, 1), 24, 0.5, 30, Vector3.new(0, 0.5, 2), 0.25)
			if own(model) then
				Sfx.play("boost_overcharge", 1, 0.65)
			else
				Sfx.play3D("boost_overcharge", hull, Sfx.quiet(0.65))
			end
		end
	elseif fx == "golden" then
		if hull then
			local secs = tonumber(payload.seconds) or 4
			aura(hull, secs, rgb("golden_wings"), 30, 0.9, 4, Vector3.new(0, 1, 0), 0.7)
			-- The sting everyone hears: the power moment is public.
			if own(model) then
				Sfx.play("unlock_fanfare", 1.15, 0.5)
			else
				Sfx.play3D("shield_up", hull, Sfx.quiet(0.56), 1.2)
			end
		end
	elseif fx == "stormCloud" then
		if hull then
			local secs = tonumber(payload.seconds) or 4
			-- A dark cloud riding high over the target (visible from behind; it never sits on the lens of the target).
			aura(hull, secs, rgb("storm_bolt"), 18, 6, 1.5, Vector3.new(0, 16, 0), 1.2)
			aura(hull, secs, Color3.fromRGB(40, 40, 60), 12, 8, 1, Vector3.new(0, 18, 0), 1.4)
		end
	elseif fx == "stormStrike" then
		if typeof(pos) == "Vector3" then
			burst("missileBlast", pos, rgb("storm_bolt"), 1.2)
			Sfx.at("crash_hit", pos, if own(model) then 0.8 else Sfx.quiet(0.8), 1.3)
		end
	elseif fx == "bombBlast" then
		if typeof(pos) == "Vector3" then
			local r = tonumber(payload.radius) or 12
			burst("missileBlast", pos, rgb("rocket_rush"), math.clamp(r / 12, 1, 2))
			burst("hitRing", pos, nil, math.clamp(r / 10, 1, 2.4))
			Sfx.at("mine_blast", pos, 0.8)
		end
	elseif fx == "coinTake" then
		if typeof(pos) == "Vector3" then
			burst("pickupGlint", pos, rgb("coin_burst"))
			if own(model) then
				Sfx.play("coin_pickup", 1 + math.random() * 0.1, 0.5)
			end
		end
	elseif fx == "reflect" then
		if typeof(pos) == "Vector3" then
			burst(if own(model) then "blockedSelf" else "blocked", pos, rgb("bubble_guard"))
			Sfx.at("shield_block", pos, if own(model) then 0.8 else Sfx.quiet(0.8), 1.25)
		end
	elseif fx == "slow" then
		if hull then
			local frost = payload.source == "frost_shot"
			aura(hull, tonumber(payload.seconds) or 1, if frost then rgb("frost_shot") else Color3.fromRGB(200, 200, 210), 14, 0.7, 2, Vector3.new(0, 1, 0), 0.8)
		end
	end
	-- v39: Bubble Guard is retired (ItemRules.RETIRED); its aqua reflect-window glint and its callout are gone.
end

------------------------------------------------------------------------------------------------------------------------
-- This player: ItemEffect (the controllers apply the speed side; this is the HUD and sound side)
------------------------------------------------------------------------------------------------------------------------

local CALLOUT: { [string]: string } = {
	rocket_rush = "ROCKET RUSH",
	golden_wings = "GOLDEN WINGS",
}

function ItemsV4Fx.onEffect(kind: string, data: { [string]: any })
	if kind == "boost" then
		local item = data.item
		local text = if type(item) == "string" then CALLOUT[item] else nil
		if text then
			TrickJuice.callout(text, rgb(item), 1.2)
		end
	elseif kind == "slow" then
		TrickJuice.callout(if data.source == "frost_shot" then "FROZEN" else "SLOWED", Color3.fromRGB(170, 230, 255), 0.9)
	elseif kind == "stormWarn" then
		-- The siren: a rising alarm, and the answer for this vehicle (NotifySpec storm_warn_*).
		Sfx.play("wrong_way", 1.35, 0.7)
		task.delay(0.5, function()
			Sfx.play("wrong_way", 1.5, 0.7)
		end)
		NotifyKit.fromSpec(if data.vehicle == "car" then "storm_warn_block" else "storm_warn_roll")
	end
end

------------------------------------------------------------------------------------------------------------------------
-- The charged items' ring: Orbit Missiles orbiters and Gift Box gifts circling their holders
------------------------------------------------------------------------------------------------------------------------

type Ring = { hull: BasePart, atts: { Attachment }, tails: { Attachment }, id: string }
local rings: { [Model]: Ring } = {}
local scanAt = 0

local function heldOf(model: Model): (string?, number)
	local color: any, charges: any
	local planeName = model.Name
	local who = string.match(planeName, "^Car_(.+)$") or string.match(planeName, "^Plane_(.+)$")
	local player = if who then Players:FindFirstChild(who) else nil
	if player and player:IsA("Player") then
		color, charges = player:GetAttribute("ItemColor"), player:GetAttribute("ItemCharges")
	else
		color, charges = model:GetAttribute("ItemColor"), model:GetAttribute("ItemCharges")
	end
	if (color == "orbit_missiles" or color == "gift_box") and type(charges) == "number" and charges > 0 then
		return color, math.min(math.floor(charges), 5)
	end
	return nil, 0
end

local function dropRing(model: Model)
	local r = rings[model]
	if r then
		for _, a in r.atts do
			a:Destroy()
		end
		for _, a in r.tails do
			a:Destroy()
		end
		rings[model] = nil
	end
end

local function buildRing(model: Model, hull: BasePart, id: string, n: number)
	dropRing(model)
	local atts: { Attachment } = {}
	local tails: { Attachment } = {}
	local gift = id == "gift_box"
	for i = 1, n do
		local att = Instance.new("Attachment")
		att.Name = "ItemsV4Orbit"
		local pe = Instance.new("ParticleEmitter")
		-- Gifts sparkle in the classic colours they hold; orbiters burn the item's pink.
		local seq = ItemRules.GIFT_SEQUENCE
		local color = if gift then rgb(seq[((i - 1) % #seq) + 1]) else rgb(id)
		pe.Color = ColorSequence.new(color)
		pe.LightEmission = 1
		-- v37: orbiters you can see from behind the pack: a bigger, brighter core. (A ribbon tail was tried and dropped:
		-- at race speed it streamed 45 studs back through the chase camera.)
		pe.Rate = rate(45)
		pe.Lifetime = NumberRange.new(0.15, 0.25)
		pe.Speed = NumberRange.new(0, 0.5)
		pe.Size = NumberSequence.new(if gift then 1.4 else 1.9, 0)
		pe.Transparency = NumberSequence.new(0, 1)
		pe.LockedToPart = false
		pe.Parent = att
		att.Parent = hull
		table.insert(atts, att)
	end
	rings[model] = { hull = hull, atts = atts, tails = tails, id = id }
end

-- Coin Burst's coins are 2.4 stud server discs; Studio V9 showed one filling the chase view. Here each is drawn at
-- ItemFxRules.COIN_SCALE and fades out before it reaches the lens (client-only: LocalTransparencyModifier and a local
-- resize; the server's disc, its pickup radius and timings are untouched).
local COIN_FOLDER = "SkyRallyItemFX" -- ItemEffects.FX_FOLDER (server module; not reachable from the client)
local COIN_SCAN = 0.05
local coinAt = 0
local coinBase: { [BasePart]: Vector3? } = {}

local function stepCoins(now: number)
	if now < coinAt then
		return
	end
	coinAt = now + COIN_SCAN
	local folder = workspace:FindFirstChild(COIN_FOLDER)
	local cam = workspace.CurrentCamera
	if not folder or not cam then
		return
	end
	local camPos = cam.CFrame.Position
	for _, c in folder:GetChildren() do
		if c:IsA("BasePart") and c:GetAttribute("Kind") == "coin" then
			if coinBase[c] == nil then
				local full = c.Size
				coinBase[c] = full
				c.Size = full * ItemFxRules.COIN_SCALE
				c.AncestryChanged:Once(function()
					coinBase[c] = nil
				end)
			end
			c.LocalTransparencyModifier = ItemFxRules.coinTransparency((c.Position - camPos).Magnitude)
			for _, d in c:GetChildren() do
				if d:IsA("ParticleEmitter") then
					d.Enabled = c.LocalTransparencyModifier < 0.5
				end
			end
		end
	end
end

function ItemsV4Fx.step(_dt: number)
	local now = os.clock()
	stepCoins(now)
	if now >= scanAt then
		scanAt = now + ItemRules.ORBIT_FX.scan
		local planes = workspace:FindFirstChild("Planes")
		local seen: { [Model]: boolean } = {}
		if planes then
			for _, m in planes:GetChildren() do
				if m:IsA("Model") then
					local id, n = heldOf(m)
					local hull = hullOf(m)
					if id and hull then
						seen[m] = true
						local r = rings[m]
						if not r or r.hull ~= hull or r.id ~= id or #r.atts ~= n then
							buildRing(m, hull, id, n)
							local fresh = rings[m]
							if id == "orbit_missiles" and not r and fresh and fresh.atts[1] then
								-- A short spin-up hum when the orbiters appear (not a drone: it fades after 3 s).
								Sfx37.loopOn("orbit_hum", fresh.atts[1], 0.3, 3, 90)
							elseif id == "gift_box" and r and r.id == id and n < #r.atts then
								-- A gift leaves the ring: a pop at the holder.
								Sfx37.at("gift_pop", hull.Position, 0.5)
							end
						end
					end
				end
			end
		end
		for m in rings do
			if not seen[m] then
				local gone = rings[m]
				if gone and gone.id == "gift_box" and gone.hull.Parent then
					Sfx37.at("gift_pop", gone.hull.Position, 0.5) -- the last gift leaves the ring
				end
				dropRing(m)
			end
		end
	end
	if next(rings) == nil then
		return
	end
	local F = ItemRules.ORBIT_FX
	for _, r in rings do
		local offs = ItemRules.orbitOffsets(#r.atts, now)
		for i, att in r.atts do
			local o = offs[i]
			if o then
				att.Position = Vector3.new(o[1], F.height, o[2])
				local tail = r.tails[i]
				if tail then
					tail.Position = Vector3.new(o[1], F.height + 0.9, o[2])
				end
			end
		end
	end
end

function ItemsV4Fx.init(burstFn: Burst)
	burst = burstFn
end

return ItemsV4Fx
