--!strict
-- Hub PAINT SHOP kiosk (economy v3 section 4): placement clearances against the other hub fixtures (portal arch sight lines, the
-- Storm stand, the leaderboard board, the fountain, plaza dressing, the hub loop road), the prompt -> Garage tab routing, the
-- vocabulary rule (never "livery" to players) and the owner's hard rules (visual only, no cliffs, nothing for driving changed).
-- Run: tools/tests/run_lune_tests.sh tools/tests/paint_shop_spec.luau
return function(h)
	local C = h.require("src/shared/PaintShopConfig.luau")
	local StormConfig = h.require("src/shared/StormConfig.luau")
	local LeaderboardRules = h.require("src/shared/LeaderboardRules.luau")
	local GarageModel = h.require("src/shared/GarageModel.luau")
	local planCache: any = nil
	local function planData(): any
		if not planCache then
			planCache = h.json(h.readFile("map/hub0/plan.json"))
		end
		return planCache
	end
	local S = C.STAND

	local function dist(ax: number, az: number, bx: number, bz: number): number
		return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
	end

	h.test("placement: at least 25 degrees off every portal arch from the hub approach views (the Storm stand's check)", function()
		local views = { { -8196, 8066 }, { -8180, 8050 }, { -8160, 8030 }, { -8150, 8010 }, { -8200, 8030 }, { -8120, 8010 }, { -8180, 8066 } }
		local arches = 0
		for _, inst in planData().instances do
			if string.sub(inst.pf, 1, 11) == "PortalArch_" then
				arches += 1
				for _, v in views do
					local toArch = math.atan2(inst.p[3] - v[2], inst.p[1] - v[1])
					local toKiosk = math.atan2(S.pos.Z - v[2], S.pos.X - v[1])
					local d = math.abs((toArch - toKiosk + math.pi) % (2 * math.pi) - math.pi)
					h.ok(d > math.rad(C.CLEARANCE.archSightDegrees), inst.pf .. " within 25 degrees of the kiosk from view " .. v[1] .. "," .. v[2])
				end
			end
		end
		h.eq(arches, 5)
	end)

	h.test("placement: clear of the Storm stand, the leaderboard board, the fountain, the spawn and all plaza dressing", function()
		local K = C.CLEARANCE
		h.ok(dist(S.pos.X, S.pos.Z, StormConfig.STAND.pos.X, StormConfig.STAND.pos.Z) >= K.stormStand, "Storm stand")
		local b = LeaderboardRules.BOARD.pos
		h.ok(dist(S.pos.X, S.pos.Z, b.X, b.Z) >= K.board, "leaderboard board")
		h.ok(dist(S.pos.X, S.pos.Z, S.faceToward.X, S.faceToward.Z) >= K.spawn, "spawn")
		local worst = math.huge
		for _, inst in planData().instances do
			local d = dist(S.pos.X, S.pos.Z, inst.p[1], inst.p[3])
			if inst.pf == "PlazaFountain" then
				h.ok(d >= K.fountain, "fountain")
			end
			worst = math.min(worst, d)
		end
		h.ok(worst >= K.plazaDressing + S.radius - 9, "nearest plan instance " .. worst)
	end)

	h.test("placement: far from the hub loop road, and not on the cliff terrain (flat grid, no secret-area ground touched)", function()
		local nearest = math.huge
		for _, n in planData().skyrally.route.nodes do
			nearest = math.min(nearest, dist(S.pos.X, S.pos.Z, n.pos[1], n.pos[3]))
		end
		h.ok(nearest >= C.CLEARANCE.loopRoad, "loop road node " .. nearest)
		local t = planData().terrain
		for dx = -S.radius, S.radius, 4 do
			for dz = -S.radius, S.radius, 4 do
				local i = math.floor((S.pos.X + dx - t.x0) / t.cell + 0.5)
				local j = math.floor((S.pos.Z + dz - t.z0) / t.cell + 0.5)
				local y = t.heights[j * t.nx + i + 1]
				h.ok(math.abs(y - S.pos.Y) <= 2, "terrain flat under the footprint (" .. y .. ")")
			end
		end
	end)

	h.test("routing: PAINT SHOP opens the TINTS tab, VEHICLES the VEHICLES tab, anything else nothing", function()
		local tabs = {}
		for _, t in GarageModel.ALL_TABS do
			tabs[t.id] = t.label
		end
		h.eq(tabs[C.PROMPTS.paint.tab], "TINTS")
		h.eq(tabs[C.PROMPTS.vehicles.tab], "VEHICLES")
		h.eq(C.tabFor("PaintShop_PAINT SHOP", "liveries"), "liveries")
		h.eq(C.tabFor("PaintShop_VEHICLES", "vehicles"), "vehicles")
		h.eq(C.tabFor("StormVendorPrompt", "liveries"), nil)
		h.eq(C.tabFor("PaintShop_PAINT SHOP", "shop"), nil, "a tampered tab id is ignored")
		h.eq(C.promptName("PAINT SHOP"), "PaintShop_PAINT SHOP")
	end)

	h.test("routing: the stand writes the tab attribute the client reads, the client opens the Garage on it, boot wires both", function()
		local server = h.readFile("src/server/PaintShopStand.luau")
		local client = h.readFile("src/client/PaintShop.luau")
		h.contains(server, "prompt:SetAttribute(Config.TAB_ATTR, spec.tab)")
		h.contains(server, "Config.promptName(spec.action)")
		h.contains(client, "prompt:GetAttribute(PaintShopConfig.TAB_ATTR)")
		h.contains(client, "openGarage(tab)")
		-- The client boot starts PaintShop from BootRules.INIT_ORDER with the Garage-opening callback (audit T1-1).
		h.contains(h.readFile("src/client/init.client.luau"), 'local g = mods.Garage\n\t\t\t\tif g then\n\t\t\t\t\tg.open(tab)')
		h.contains(h.readFile("src/client/init.client.luau"), 'if name == "PaintShop" then')
		h.contains(h.readFile("src/shared/BootRules.luau"), '{ name = "PaintShop", late = true }')
		h.contains(h.readFile("src/server/init.server.luau"), "require(script.PaintShopStand).start()")
		-- The TINTS tab shows the turntable of the player's own current vehicle (nothing else is previewed).
		h.contains(h.readFile("src/client/GarageTurntable.luau"), "DisplayCars.localVehicle()")
		h.contains(h.readFile("src/client/Garage.luau"), "GarageTurntable.mount(section(0)")
	end)

	h.test("vocabulary: no player-facing text says livery, and the kiosk's prompts are the named ones", function()
		for _, t in C.TEXTS do
			h.ok(not string.find(string.lower(t), "livery", 1, true), t)
		end
		h.eq(C.PROMPTS.paint.action, "PAINT SHOP")
		h.eq(C.PROMPTS.vehicles.action, "VEHICLES")
		local server = h.readFile("src/server/PaintShopStand.luau")
		for text in string.gmatch(server, 'Text = "([^"]*)"') do
			h.ok(not string.find(string.lower(text), "livery", 1, true), text)
		end
	end)

	h.test("build: visual only, block-built, warm MapLight lamp, no uploads, nothing touching driving rules", function()
		local server = h.readFile("src/server/PaintShopStand.luau")
		h.contains(server, "p.CanCollide = false")
		h.contains(server, "p.CanQuery = false")
		h.contains(server, 'light:SetAttribute("MapLight", true)')
		h.contains(server, "Instance.new(\"PointLight\")")
		h.ok(not string.find(server, ".CanCollide = true", 1, true), "no colliding part")
		h.ok(not string.find(server, "rbxassetid", 1, true), "no uploaded asset")
		h.ok(not string.find(server, "MeshPart", 1, true) and not string.find(server, "MeshId", 1, true), "block-built only")
		h.ok(not string.find(server, "Terrain", 1, true), "no terrain edit (cliffs / walls stay free for secret areas)")
		h.ok(not string.find(server, "UIStroke", 1, true), "no ink outline")
		for _, w in { "Barrier", "KillVolume", "Rescue", "Adhesion", "Respawn" } do
			h.ok(not string.find(server, w, 1, true), "does not touch " .. w)
		end
	end)
end
