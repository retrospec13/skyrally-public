-- Finish stage lighting (shared/FinishLightingRules): a dark map comes up to hub-midday readability, a bright one is left
-- alone, and the wiring (FinishShow apply/release, opaque results card, stage lights) is in place.
return function(h)
	local R = h.require("src/shared/FinishLightingRules.luau")
	local profiles = {}
	for _, f in { "space4", "hub0" } do
		for id, p in h.require("src/shared/lighting/" .. f .. ".luau") do
			profiles[id] = p
		end
	end

	local function snapshotOf(id: string)
		local p = profiles[id]
		local s: any = { Brightness = 1, ClockTime = 14, ExposureCompensation = 0, Ambient = Color3.new(0, 0, 0), OutdoorAmbient = Color3.new(0, 0, 0) }
		for _, pair in p.lighting do
			if s[pair[1]] ~= nil then
				s[pair[1]] = pair[2]
			end
		end
		for _, e in p.effects do
			for _, pair in e.props do
				if e.className == "Atmosphere" and pair[1] == "Density" then
					s.atmosphereDensity = pair[2]
				elseif e.className == "Atmosphere" and pair[1] == "Haze" then
					s.atmosphereHaze = pair[2]
				elseif e.className == "ColorCorrectionEffect" and pair[1] == "Brightness" then
					s.ccBrightness = pair[2]
				end
			end
		end
		return s
	end

	h.test("SPACE-4 stage lighting is at least as lit as the hub at midday", function()
		local hub = R.litness(snapshotOf("HUB-0"))
		local night = R.litness(snapshotOf("SPACE-4"))
		local stage = R.litness(R.target(snapshotOf("SPACE-4")))
		h.ok(night < 0.6 * hub, "SPACE-4 raw is dark: " .. night .. " vs hub " .. hub)
		h.ok(stage >= hub, "stage " .. stage .. " vs hub " .. hub)
	end)

	h.test("SPACE-4 and the hub finish stages read at least as lit as the hub, with the haze cut back", function()
		local hub = R.litness(snapshotOf("HUB-0"))
		for id in profiles do
			local t = R.target(snapshotOf(id))
			h.ok(R.litness(t) >= hub, id .. " stage litness " .. R.litness(t))
			if t.atmosphereDensity then
				h.ok(t.atmosphereDensity <= R.DENSITY_MAX, id .. " density")
			end
			h.ok(t.ClockTime >= R.CLOCK_DAY_FROM and t.ClockTime <= R.CLOCK_DAY_TO, id .. " clock " .. t.ClockTime)
		end
	end)

	h.test("target only raises: a bright map keeps its own values", function()
		local s: any = { Brightness = 5, ClockTime = 12, ExposureCompensation = 0.5, Ambient = Color3.new(1, 1, 1), OutdoorAmbient = Color3.new(1, 1, 1), atmosphereDensity = 0.02, atmosphereHaze = 0.1, ccBrightness = 0.2 }
		local t = R.target(s)
		h.eq(t.Brightness, 5)
		h.eq(t.ClockTime, 12)
		h.eq(t.ExposureCompensation, 0.5)
		h.eq(t.atmosphereDensity, 0.02)
		h.eq(t.ccBrightness, 0.2)
		local none = R.target({ Brightness = 1, ClockTime = 3, ExposureCompensation = 0, Ambient = Color3.new(0, 0, 0), OutdoorAmbient = Color3.new(0, 0, 0) })
		h.eq(none.atmosphereDensity, nil)
		h.eq(none.ccBrightness, nil)
	end)

	h.test("stage rig has a key, a fill and a rim light per step, inside the world's light range", function()
		local names = {}
		for _, d in R.STAGE_LIGHTS do
			names[d.name] = true
			h.ok(d.range <= 60 and d.brightness > 0, d.name)
		end
		h.ok(names.Key and names.Fill and names.RimL and names.RimC and names.RimR)
	end)

	h.test("wiring: FinishShow applies and releases, the card is solid, the podium builds its lights", function()
		local show = h.readFile("src/client/FinishShow.luau")
		h.contains(show, "FinishLighting.apply()")
		h.contains(show, "FinishLighting.release()")
		h.contains(h.readFile("src/client/PodiumCeremony.luau"), "FinishLighting.buildStageLights(m)")
		h.contains(h.readFile("src/client/RaceUI.luau"), "fModal.BackgroundTransparency = 0 ")
	end)
end
