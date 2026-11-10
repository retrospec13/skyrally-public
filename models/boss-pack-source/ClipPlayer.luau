local Math=require(script.Parent.ClipMath)
local Player={}
function Player.Apply(model,clipName,time)
local data=require(model.BakedClips);local clip=assert(data.clips[clipName],"Unknown clip");local bones={};for _,d in model:GetDescendants() do if d:IsA("Bone") then bones[d.Name]=d end end
for i,name in data.bones do local bone=assert(bones[name],"Missing bone "..name);local x,y,z,w,tx,ty,tz=Math.sample(clip,i,time,data.fps);local scale=model:GetAttribute("BossScale") or model:GetScale();bone.Transform=CFrame.new(tx*scale,ty*scale,tz*scale,x,y,z,w) end
end
function Player.Reset(model) for _,d in model:GetDescendants() do if d:IsA("Bone") then d.Transform=CFrame.identity end end end
return Player