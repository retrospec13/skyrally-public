--!strict
-- The livery painter moved to shared/LiveryPaint (REMARKABLE Batch 2 item 27: the Garage turntable paints its display
-- copy with the same palette). This re-export keeps FlightServer, CarServer and CosmeticService requiring kit.LiveryPaint.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LiveryPaint"))
