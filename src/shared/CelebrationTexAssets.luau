--!strict
-- Celebration textures (assets/vfx/celebration/*.png, made by tools/gen_celebration_tex.py): name -> Roblox image asset id
-- number. 0 = not uploaded yet; client/CelebrationFx then falls back to existing textures (spark_streak / sparkle_star).
return {
	fireworks_burst_4x4 = 122109252213420, -- 4x4 one-shot firework shell opening (white + alpha, tinted per shell)
} :: { [string]: number }
