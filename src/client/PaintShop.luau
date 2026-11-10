--!strict
-- Routes the hub PAINT SHOP kiosk's prompts (server/PaintShopStand) to the Garage: PAINT SHOP opens it on the TINTS tab (the
-- turntable there shows the player's own current vehicle), VEHICLES on the VEHICLES tab. The prompts carry the tab id as an
-- attribute (PaintShopConfig.TAB_ATTR), so this module needs no remote and ignores every prompt that is not ours.
local ProximityPromptService = game:GetService("ProximityPromptService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local PaintShopConfig = require(Shared:WaitForChild("PaintShopConfig"))

local PaintShop = {}

local started = false

function PaintShop.init(openGarage: (tab: string?) -> ())
	if started then
		return
	end
	started = true
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, _player: Player)
		local tab = PaintShopConfig.tabFor(prompt.Name, prompt:GetAttribute(PaintShopConfig.TAB_ATTR))
		if tab then
			openGarage(tab)
		end
	end)
end

return PaintShop
