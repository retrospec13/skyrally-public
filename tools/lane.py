#!/usr/bin/env python3
"""Optional Studio bridge helpers. No personal targets or publication workflow included.
Remote operations require explicit SKYRALLY_REMOTE_ENABLED=1 and operator environment settings.
"""
import base64
import datetime as _dt
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"

KEY = os.environ.get("SKYRALLY_SSH_KEY", "")
HOST = os.environ.get("SKYRALLY_SSH_HOST", "")
PCROOT = os.environ.get("SKYRALLY_PC_ROOT", "")
PCWIN = PCROOT.replace("/", chr(92))
PLACE = "skyrally_1.rbxlx"
TASK = "skyrally_1"

# Paths deployed to the PC deploy target (never its Git; it is a stale tree used as a target).
SYNC_PATHS = ["default.project.json", "src", "tools/windows", "map", "build", "assets/kits",
              "builder_dino4.luau", "tools/legacy-builders/builder_snow1.luau", "tools/legacy-builders/builder_forest1.luau"]


def utc():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


def sh(cmd, check=True, timeout=600, input=None):
    r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"CMD FAIL rc={r.returncode}: {cmd}\nSTDOUT: {r.stdout[-3000:]}\nSTDERR: {r.stderr[-3000:]}")
    return r.stdout


def ssh(cmd, check=True, timeout=600):
    if os.environ.get("SKYRALLY_REMOTE_ENABLED") != "1" or not all((KEY, HOST, PCROOT)):
        raise RuntimeError("Remote bridge disabled: configure explicit operator environment first")
    return sh(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-i", KEY, HOST, cmd], check=check, timeout=timeout)


def scp(src, dst, timeout=600):
    if os.environ.get("SKYRALLY_REMOTE_ENABLED") != "1" or not all((KEY, HOST, PCROOT)):
        raise RuntimeError("Remote bridge disabled: configure explicit operator environment first")
    sh(["scp", "-q", "-i", KEY, str(src), str(dst)], timeout=timeout)


def put(local, remote_rel):
    scp(local, f"{HOST}:{PCROOT}/{remote_rel}")


def get(remote_rel, local):
    scp(f"{HOST}:{PCROOT}/{remote_rel}", local)


def git_head():
    return sh(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip()


def git_dirty():
    return bool(sh(["git", "-C", str(ROOT), "status", "--porcelain", "--", *[p for p in SYNC_PATHS if (ROOT / p).exists()]]).strip())


def tree_hash(paths=None):
    """sha256 over the deployable files (path + bytes), so a capture can be stamped with what was deployed."""
    h = hashlib.sha256()
    for f in _sync_files(paths):
        h.update(str(f.relative_to(ROOT)).encode())
        h.update(f.read_bytes())
    return h.hexdigest()[:12]


def _sync_files(paths=None):
    files = []
    for p in (paths or SYNC_PATHS):
        q = ROOT / p
        if q.is_file():
            files.append(q)
        elif q.is_dir():
            files += sorted(x for x in q.rglob("*") if x.is_file() and "__pycache__" not in x.parts)
    return files


BUILDINFO = "src/shared/BuildInfo.luau"


def buildinfo_source(channel="studio"):
    head = git_head()
    commit = head + ("-dirty" if git_dirty() else "")
    return (f'--!strict\n-- STAMPED by tools/lane.py at deploy; the committed copy says "dev".\n'
            f'return {{\n\tCommit = "{commit}",\n\tTree = "{tree_hash()}",\n\tBuiltUtc = "{utc()}",\n\tChannel = "{channel}",\n}}\n')


def sync(paths=None, channel="studio"):
    """Tar the deployable tree (BuildInfo stamped with HEAD) and extract it on the PC deploy target. Returns the tree hash."""
    buf = io.BytesIO()
    stamped = buildinfo_source(channel).encode()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for f in _sync_files(paths):
            rel = str(f.relative_to(ROOT))
            if rel == BUILDINFO:
                ti = tarfile.TarInfo(rel)
                ti.size = len(stamped)
                ti.mtime = int(time.time())
                t.addfile(ti, io.BytesIO(stamped))
            else:
                t.add(f, arcname=rel)
    tmp = OUT / "lane_sync.tar"
    tmp.write_bytes(buf.getvalue())
    put(tmp, "out/lane_sync.tar")
    ssh(f"cmd /c \"cd /d {PCWIN} && tar -xf out\\lane_sync.tar\"")
    th = tree_hash(paths)
    (OUT / "last_sync.json").write_text(json.dumps({"utc": utc(), "head": git_head(), "dirty": git_dirty(), "tree": th}))
    return th


# ---------------- Studio MCP bridge (own window only) ----------------

def mcp_call_name(name, pid=None):
    """Per-process call-file stem (S3): two processes polling get_console_output both wrote win/calls/console.json
    and collided (EBUSY, one crashed). The suffix keeps every process on its own call, output and local files."""
    return f"{name}.p{os.getpid() if pid is None else pid}"


def mcp(calls, name="calls", timeout=600, keep=False):
    for c in calls:
        if "name" in c and c["name"] != "list_roblox_studios" and "studio" not in c:
            c["studio"] = "auto:" + PLACE
    stem = mcp_call_name(name)
    cf = OUT / f"{stem}.calls.json"
    cf.write_text(json.dumps(calls))
    put(cf, f"win/calls/{stem}.json")
    pcout = f"{PCWIN}\\out\\mcp\\{stem}.json"
    pccall = f"{PCWIN}\\win\\calls\\{stem}.json"
    local = OUT / f"{stem}.out.json"
    try:
        ssh(f"cmd /c \"if not exist {PCWIN}\\out\\mcp mkdir {PCWIN}\\out\\mcp\" & node {PCWIN}\\win\\skyrally_mcp.js {pccall} {pcout}", timeout=timeout)
        scp(f"{HOST}:{pcout.replace(chr(92), '/')}", local)
        return _mcp_collect(local)
    finally:
        # clean up this process's own call and output files (PC and local); never another process's names
        if not keep:
            ssh(f"cmd /c \"del /q {pccall} {pcout} 2>nul\"", check=False, timeout=60)
            for f in (cf, local):
                try:
                    f.unlink()
                except OSError:
                    pass


def _mcp_collect(local):
    res = json.loads(local.read_text())
    for r in res.get("results", []):
        for p in r.get("content", []) or []:
            if p.get("type") == "image" and p.get("file"):
                src = p["file"].replace("\\", "/")
                dst = OUT / os.path.basename(src)
                scp(f"{HOST}:{src}", dst)
                p["local"] = str(dst)
    return res


def text(res, i=0):
    r = res["results"][i]
    if r.get("error"):
        return "ERROR " + json.dumps(r["error"])
    parts = [p.get("text", "") for p in r.get("content", []) if p.get("type") == "text"]
    return ("ISERROR " if r.get("isError") else "") + "\n".join(parts)


def studios():
    t = text(mcp([{"name": "list_roblox_studios", "arguments": {}}], "list_studios"))
    try:
        return json.loads(t).get("studios", [])
    except Exception:
        return []


def own_studio_id():
    # CC1 (tandem agent, 2026-10-19) runs its own Studio on the same PC: two instances with our place name would make
    # the match ambiguous, so refuse rather than risk addressing its window.
    ours = [s.get("id") for s in studios() if s.get("name") == PLACE]
    if len(ours) > 1:
        raise RuntimeError(f"REFUSED: {len(ours)} Studio instances named {PLACE}; cannot tell ours from CC1's")
    return ours[0] if ours else None


DISCONNECTED = ("No Roblox Studio instances are connected", "is not connected")


def _retrying(call, tries=6, wait=10):
    """The shared PC's Studio MCP bridge drops every instance for tens of seconds under load: retry a call whose
    answer says so instead of acting on a no-op."""
    out = call()
    for _ in range(tries - 1):
        if not any(d in str(out) for d in DISCONNECTED):
            return out
        time.sleep(wait)
        out = call()
    return out


def luau(code, dm="Edit", name="luau", timeout=120):
    return _retrying(lambda: text(mcp([{"name": "execute_luau", "arguments": {"datamodel_type": dm, "code": code}, "timeout": timeout}], name, timeout=timeout + 60)))


def state():
    return text(mcp([{"name": "get_studio_state", "arguments": {}}], "state"))


def play(start=True):
    return _retrying(lambda: text(mcp([{"name": "start_stop_play", "arguments": {"is_start": start}, "timeout": 120}], "play_start" if start else "play_stop")))


def console():
    return _retrying(lambda: text(mcp([{"name": "get_console_output", "arguments": {}}], "console")))


def keys(actions, dm="Client", name="keys", timeout=600):
    """Real keyboard input through Studio's input path (user_keyboard_input), not attribute pokes."""
    return _retrying(lambda: text(mcp([{"name": "user_keyboard_input", "arguments": {"datamodel_type": dm, "actions": actions}, "timeout": timeout}], name, timeout=timeout + 60)))


# V1 D6: desktop viewport presets for L80/L82 captures (the lane's Studio window reads 1862x832). Same device-simulator
# calls as tools/e2e_skyrally.set_device (a custom SR_ device, no phone template). The simulator can switch the input
# family, so the readback reports TouchEnabled / KeyboardEnabled / PreferredInput: a row that needs KeyboardMouse must
# check them (and fall back to the window size, noted in the row) before trusting the capture.
DESKTOP_PRESETS = {"1080p": (1920, 1080), "768p": (1366, 768)}


def set_desktop_viewport(preset="1080p"):
    w, h = DESKTOP_PRESETS[preset]
    code = f"""
local svc = game:GetService('StudioDeviceSimulatorService')
local UIS = game:GetService('UserInputService')
local ok, err = pcall(function()
    local id
    for _, d in svc:GetDeviceListAsync() do
        local info = svc:GetDeviceInfoAsync(d)
        if info.Name == 'SR_Desktop_{w}x{h}' then id = d end
    end
    if not id then
        id = svc:CreateDeviceAsync({{Name = 'SR_Desktop_{w}x{h}', Width = {w}, Height = {h}, PixelDensity = 96}})
    end
    svc:SetDeviceAsync(id)
    task.wait(0.5)
end)
local okPref, pref = pcall(function() return tostring(UIS.PreferredInput) end)
return string.format('DESKTOP_%s ok=%s err=%s vp=%s touch=%s keyboard=%s preferred=%s', '{preset}', tostring(ok),
    tostring(err), tostring(workspace.CurrentCamera.ViewportSize), tostring(UIS.TouchEnabled), tostring(UIS.KeyboardEnabled),
    if okPref then pref else 'n/a')
"""
    return luau(code, dm="Edit", name=f"dev_desktop_{preset}")


def stop_device_simulation():
    code = """
local svc = game:GetService('StudioDeviceSimulatorService')
pcall(function() svc:StopSimulationAsync() end)
task.wait(0.3)
return 'WINDOW_VP=' .. tostring(workspace.CurrentCamera.ViewportSize)
"""
    return luau(code, dm="Edit", name="dev_stop")


def capture(tag, name=None):
    res = mcp([{"name": "screen_capture", "arguments": {"capture_id": tag}, "tag": tag}], name or f"cap_{tag}")
    for r in res["results"]:
        for p in r.get("content", []) or []:
            if p.get("local"):
                return p["local"]
    return None


def stamp(img, label, out=None):
    """Burn UTC, git HEAD, deployed tree hash and the owned studio id into the bottom of a capture."""
    last = json.loads((OUT / "last_sync.json").read_text()) if (OUT / "last_sync.json").exists() else {}
    s = f"{label}  UTC={utc()}  HEAD={git_head()[:7]}{'+dirty' if last.get('dirty') else ''}  TREE={last.get('tree', '?')}  PLACE={PLACE}"
    out = out or str(Path(img).with_name(Path(img).stem + "_stamped.png"))
    from PIL import Image, ImageDraw  # ImageMagick is not installed on the lane host
    src = Image.open(img).convert("RGB")
    canvas = Image.new("RGB", (src.width, src.height + 22), (0, 0, 0))
    canvas.paste(src, (0, 0))
    ImageDraw.Draw(canvas).text((6, src.height + 5), s, fill=(255, 255, 255))
    canvas.save(out)
    return out


def b64(path):
    return base64.b64encode(Path(path).read_bytes()).decode("ascii")


def launch(wait_s=240):
    """Launch the lane's own Studio window through the existing schtask (console session, rojo build first)."""
    before = own_studio_id()
    ssh("schtasks /Run /TN " + TASK)
    t0 = time.time()
    while time.time() - t0 < wait_s:
        time.sleep(15)
        sid = own_studio_id()
        if sid and sid != before:
            return sid
    return own_studio_id()


def run_log():
    return ssh(f"type {PCWIN}\\out\\run.log", check=False)


def critic_key():
    for line in Path(os.path.expanduser("~/.hermes/.env")).read_text().splitlines():
        if line.startswith("OPENROUTER_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError("OPENROUTER_API_KEY not found in ~/.hermes/.env")


# ---------------- Hot reload (Edit DataModel) from default.project.json ----------------

def _class_for(name):
    if name.endswith(".server.luau"):
        return "Script"
    if name.endswith(".client.luau"):
        return "LocalScript"
    return "ModuleScript"


def _stem(name):
    for suf in (".server.luau", ".client.luau", ".luau"):
        if name.endswith(suf):
            return name[: -len(suf)]
    return name


def script_map(project="default.project.json"):
    """[(instance_path_list, class, file)] for every .luau Rojo would sync, following Rojo's init rules."""
    tree = json.loads((ROOT / project).read_text())["tree"]
    out = []

    def walk(node, ipath):
        for k, v in node.items():
            if k.startswith("$") or not isinstance(v, dict):
                continue
            p = v.get("$path")
            here = ipath + [k]
            if p:
                f = ROOT / p
                if f.is_file() and f.name.endswith(".luau"):
                    out.append((here, _class_for(f.name), f))
                elif f.is_dir():
                    walk_dir(f, here)
            walk(v, here)

    def walk_dir(d, ipath):
        for f in sorted(d.iterdir()):
            if f.is_dir():
                walk_dir(f, ipath + [f.name])
            elif f.name.endswith(".luau"):
                if _stem(f.name) == "init":
                    out.append((ipath, _class_for(f.name), f))
                else:
                    out.append((ipath + [_stem(f.name)], _class_for(f.name), f))

    walk(tree, [])
    return out


HOT_RELOAD_LUA = r"""
local EncodingService = game:GetService('EncodingService')
local H = game:GetService('HttpService')
local function dec(s) return buffer.tostring(EncodingService:Base64Decode(buffer.fromstring(s))) end
local items = H:JSONDecode([==[%s]==])
local log = {}
local function ensure(path, cls)
	local cur = game:GetService(path[1])
	for i = 2, #path do
		local name = path[i]
		local want = (i == #path) and cls or nil
		local nxt = cur:FindFirstChild(name)
		if want and nxt and nxt.ClassName ~= want then
			local repl = Instance.new(want)
			repl.Name = name
			for _, ch in nxt:GetChildren() do ch.Parent = repl end
			nxt:Destroy()
			repl.Parent = cur
			nxt = repl
			table.insert(log, 'RECLASS ' .. name)
		elseif not nxt then
			nxt = Instance.new(want or 'Folder')
			nxt.Name = name
			nxt.Parent = cur
			table.insert(log, 'NEW ' .. name)
		end
		cur = nxt
	end
	return cur
end
local n = 0
for _, it in items do
	local inst = ensure(it.p, it.c)
	local b64 = it.s
	if it.chunks then
		-- A large module arrives in pieces (Studio caps an assigned Source at 200k characters): StringValues under
		-- ServerStorage.HotReloadChunks, concatenated here and removed.
		local folder = game:GetService('ServerStorage'):FindFirstChild('HotReloadChunks')
		local parts = {}
		for i = 1, it.chunks do
			local v = folder and folder:FindFirstChild(it.key .. '_' .. i)
			table.insert(parts, v and v.Value or '')
		end
		b64 = table.concat(parts)
		for i = 1, it.chunks do
			local v = folder and folder:FindFirstChild(it.key .. '_' .. i)
			if v then v:Destroy() end
		end
	end
	local src = dec(b64)
	if inst:IsA('ModuleScript') and not (it.p[#it.p] or ''):match('^_part_') then
		-- drop chunk children left by an earlier split of this module (the new chunks, if any, follow as items)
		for _, ch in inst:GetChildren() do
			if ch.Name:match('^_part_') then ch:Destroy() end
		end
	end
	if inst.Source ~= src then
		-- one failing module (e.g. a Source over Studio's 200k cap) is logged, not allowed to abort the batch
		local ok, err = pcall(function() inst.Source = src end)
		if ok then n += 1 else table.insert(log, 'FAIL ' .. inst.Name .. ' (' .. #src .. ' chars): ' .. tostring(err)) end
	end
end
return 'HOTRELOAD updated=' .. n .. ' of ' .. #items .. ' ' .. table.concat(log, ',')
"""

CHUNK_LUA = r"""
local f = game:GetService('ServerStorage'):FindFirstChild('HotReloadChunks')
if not f then f = Instance.new('Folder') f.Name = 'HotReloadChunks' f.Parent = game:GetService('ServerStorage') end
local v = f:FindFirstChild('%s') or Instance.new('StringValue')
v.Name = '%s'
v.Value = [==[%s]==]
v.Parent = f
return 'chunk ' .. v.Name
"""

HOT_RELOAD_BATCH = 150000  # characters of base64 per execute_luau call (Studio's limit is 200000)


SOURCE_CAP = 200000   # Studio refuses to assign a Script Source of this many characters or more
SPLIT_AT = 180000     # modules at or above this are split for hot reload
PART_TARGET = 120000

SPLIT_STUB = """--!nonstrict
-- HOT-RELOAD STUB (tools/lane.py): the real module was too large for one Source; its top-level fields live in the
-- _part_* child modules, merged here. A Rojo sync restores the single file.
local t: any = {}
local parts = {}
for _, c in script:GetChildren() do
	if c:IsA("ModuleScript") and c.Name:sub(1, 6) == "_part_" then table.insert(parts, c) end
end
table.sort(parts, function(a, b) return a.Name < b.Name end)
for _, c in parts do
	for k, v in (require(c) :: any) do t[k] = v end
end
return t
"""


def split_data_module(text, limit=SPLIT_AT, target=PART_TARGET):
    """Split a generated data module (tools/map/adapt.py shape: `local x: any = {` + one-tab top-level fields + `}` +
    `return x`) into (stub_source, [(part_name, part_source)]) whose merged tables equal the original. Returns None
    when the text is under `limit` or is not that shape."""
    if len(text) < limit:
        return None
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.startswith("local ") and l.endswith(" = {")), None)
    end = next((i for i in range(len(lines) - 1, -1, -1) if lines[i] == "}"), None)
    if start is None or end is None or end <= start:
        return None
    # Pure data only: nothing but comments/blank before the table, and only `return <name>` after it. Anything else
    # (a builder with code around its tables) must never be partially replaced.
    if any(l.strip() and not l.lstrip().startswith("--") for l in lines[:start]):
        return None
    name = lines[start].split()[1].rstrip(":")
    if [l.strip() for l in lines[end + 1:] if l.strip()] != ["return " + name]:
        return None
    fields, cur = [], None
    for l in lines[start + 1:end]:
        if l.startswith("\t") and not l.startswith("\t\t") and l[1:2] not in ("}", ")", " ") and " = " in l:
            cur = [l]
            fields.append(cur)
        elif cur is None:
            return None
        else:
            cur.append(l)
    groups, g, size = [], [], 0
    for f in fields:
        n = sum(len(x) + 1 for x in f)
        if g and size + n > target:
            groups.append(g)
            g, size = [], 0
        g.append(f)
        size += n
    if g:
        groups.append(g)
    parts = []
    for i, grp in enumerate(groups, 1):
        body = "\n".join(x for f in grp for x in f)
        src = "--!nonstrict\nreturn {\n" + body + "\n}\n"
        if len(src) >= SOURCE_CAP:
            return None
        parts.append((f"_part_{i:02d}", src))
    return SPLIT_STUB, parts


def is_splittable_path(rel):
    """Only generated data modules (build/<map>/TrackData.luau) may be chunk-split; builders are code."""
    parts = rel.replace("\\", "/").split("/")
    return len(parts) == 3 and parts[0] == "build" and parts[2] == "TrackData.luau"


def hot_reload(only=None):
    """Push every mapped script's source into the Edit DataModel (Play must be stopped), in batches under Studio's
    200k-character limit; a module larger than a batch is sent in chunks first."""
    items, skipped = [], []
    for ipath, cls, f in script_map():
        rel = str(f.relative_to(ROOT))
        if only and not any(rel.startswith(o) for o in only):
            continue
        src = buildinfo_source().encode() if rel == BUILDINFO else f.read_bytes()
        sp = (split_data_module(src.decode("utf-8"))
              if cls == "ModuleScript" and len(src) >= SPLIT_AT and is_splittable_path(rel) else None)
        if sp:
            stub, parts = sp
            items.append({"p": ipath, "c": cls, "s": base64.b64encode(stub.encode()).decode("ascii")})
            for name, psrc in parts:
                items.append({"p": ipath + [name], "c": cls, "s": base64.b64encode(psrc.encode()).decode("ascii")})
            continue
        if len(src.decode("utf-8")) >= SOURCE_CAP:
            skipped.append(rel)   # not splittable (e.g. a map builder); needs lane.launch() (Rojo rebuild)
            continue
        items.append({"p": ipath, "c": cls, "s": base64.b64encode(src).decode("ascii")})
    batches, cur, size, out = [], [], 0, []
    for k, it in enumerate(items):
        if len(it["s"]) > HOT_RELOAD_BATCH:
            b64 = it.pop("s")
            key = f"m{k}"
            pieces = [b64[i:i + HOT_RELOAD_BATCH] for i in range(0, len(b64), HOT_RELOAD_BATCH)]
            for i, piece in enumerate(pieces, 1):
                luau(CHUNK_LUA % (f"{key}_{i}", f"{key}_{i}", piece), dm="Edit", name="hot_reload_chunk", timeout=180)
            it["s"], it["key"], it["chunks"] = "", key, len(pieces)
        if cur and size + len(it["s"]) > HOT_RELOAD_BATCH:
            batches.append(cur)
            cur, size = [], 0
        cur.append(it)
        size += len(it["s"])
    if cur:
        batches.append(cur)
    for b in batches:
        out.append(str(luau(HOT_RELOAD_LUA % json.dumps(b), dm="Edit", name="hot_reload", timeout=180)).strip())
    res = " | ".join(out)
    if skipped:
        res = ("NEEDS_LAUNCH: " + ",".join(skipped) + " over the Source cap and not pure data; use lane.launch() "
               "(rojo rebuild), hot_reload cannot load them | " + res + " | SKIPPED_OVER_CAP " + ",".join(skipped))
    return res


# ---------------- Private checkpoint publish (D19) ----------------

def run_gate():
    """tools/gate.sh (lune twice incl. compile_spec, check_luau, python tests, map tests, offline preflight scan).
    Raises RuntimeError with the tail of the output on any failure."""
    g = subprocess.run(["bash", str(ROOT / "tools" / "gate.sh")], capture_output=True, text=True, timeout=1800)
    (OUT / "gate_last.log").write_text(g.stdout + g.stderr)
    if g.returncode != 0:
        raise RuntimeError("REFUSED: tools/gate.sh failed (full logs in out/gate_*.log):\n" + g.stdout[-3000:])
    return g.stdout






def read_g_list(gname, dm="Client", chunk=300, name="gread"):
    """Read a large _G list from a DataModel in chunks (MCP results are capped near 100 KB)."""
    n_raw = luau(f"return tostring(#(_G.{gname} or {{}}))", dm=dm, name=name + "_n")
    n = int("".join(ch for ch in n_raw if ch.isdigit()) or 0)
    out = []
    for a in range(1, n + 1, chunk):
        b = min(n, a + chunk - 1)
        raw = luau(f"local t={{}} for i={a},{b} do t[#t+1]=_G.{gname}[i] end return game:GetService('HttpService'):JSONEncode(t)", dm=dm, name=f"{name}_{a}")
        out += json.loads(raw[raw.index("["):])
    return out




