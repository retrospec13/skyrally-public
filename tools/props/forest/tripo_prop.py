# SkyRally FOREST prop runner: one concept image -> Tripo image-to-model (smart low poly, textured, de-lit).
# Derived from win/tripo_image_views.py (model mode). Own ledger (props_forest/tripo_jobs_forest.json) so parallel zone
# agents never race on the shared ledger. Key from the PC user environment, never printed.
# Usage: py tripo_prop.py <name> <image.png> <out_dir> [face_limit=4000] [texture_quality=standard]
import json, os, sys, time, urllib.error, urllib.request, uuid

BASE = "https://openapi.tripo3d.ai/v3"
KEY = os.environ.get("TRIPO_API_KEY", "")
if not KEY:
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as h:
        KEY = winreg.QueryValueEx(h, "TRIPO_API_KEY")[0]
if not KEY:
    sys.exit("TRIPO_FAIL no key in environment")
name, img, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
opts = dict(a.split("=", 1) for a in sys.argv[4:])
os.makedirs(out_dir, exist_ok=True)
LEDGER = os.path.join(os.path.dirname(os.path.abspath(__file__)), name, "tripo_jobs.json")


def req(method, path, data=None, files=None):
    hdrs = {"Authorization": "Bearer " + KEY}
    if files:
        b = uuid.uuid4().hex
        body = b""
        for field, fn, ct, blob in files:
            body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n" % (b, field, fn, ct)).encode() + blob + b"\r\n"
        body += ("--%s--\r\n" % b).encode()
        hdrs["Content-Type"] = "multipart/form-data; boundary=" + b
        r = urllib.request.Request(BASE + path, data=body, headers=hdrs, method=method)
    else:
        hdrs["Content-Type"] = "application/json"
        r = urllib.request.Request(BASE + path, data=json.dumps(data).encode() if data is not None else None, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(r, timeout=180) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("HTTP_ERROR", e.code, e.read().decode("utf-8", "replace")[:900], flush=True)
        raise


def strip_urls(o):
    if isinstance(o, dict):
        return {k: strip_urls(v) for k, v in o.items() if not (isinstance(v, str) and v.startswith("http"))}
    return o


def walk(o, pre=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from walk(v, pre + k + "_")
    elif isinstance(o, str) and o.startswith("http"):
        yield pre.rstrip("_"), o


bal0 = req("GET", "/account/balance").get("data", {})
up = req("POST", "/files", files=[("file", os.path.basename(img), "image/png", open(img, "rb").read())])
payload = {
    "file": {"file_token": up["data"]["file_token"]},
    "model_version": opts.get("model", "v3.1-20260211"),
    "smart_low_poly": True,
    "face_limit": int(opts.get("face_limit", 4000)),
    "texture": True,
    "texture_quality": opts.get("texture_quality", "standard"),
    "texture_alignment": "original_image",
    "orientation": "default",
    "enable_image_autofix": False,
    "texture_version": "v3.5-20260815",
    "delight": True,
    "pbr": opts.get("pbr", "0") == "1",
}
for attempt in range(60):
    try:
        res = req("POST", "/generation/image-to-model", payload)
        break
    except urllib.error.HTTPError as e:
        if e.code != 429:
            raise
        print("RATE_LIMITED retry", attempt, flush=True)
        time.sleep(30)
else:
    sys.exit("TRIPO_FAIL rate limited too long")
task = res["data"]["task_id"]
print("MODEL_TASK_ID", task, flush=True)
t0 = time.time()
st = {}
while time.time() - t0 < 2400:
    time.sleep(8)
    st = req("GET", "/tasks/" + task)["data"]
    if st.get("status") in ("success", "failed", "cancelled", "banned", "expired"):
        break
print("STATUS", st.get("status"), int(time.time() - t0), "s", flush=True)
meta = strip_urls(st)
print("TASK_META", json.dumps(meta)[:1500], flush=True)
saved = []
if st.get("status") == "success":
    for k, v in walk(st.get("output") or {}):
        ext = os.path.splitext(v.split("?")[0])[1] or ".bin"
        dest = os.path.join(out_dir, k + ext)
        urllib.request.urlretrieve(v, dest)
        saved.append(dest)
        print("DOWNLOADED", dest, os.path.getsize(dest), flush=True)
bal1 = req("GET", "/account/balance").get("data", {})
ledger = json.load(open(LEDGER)) if os.path.exists(LEDGER) else {}
ledger.setdefault(name, []).append({"model_task_id": task, "status": st.get("status"), "payload": {k: v for k, v in payload.items() if k != "file"},
    "task_meta": meta, "files": saved, "balance_before": bal0, "balance_after": bal1, "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
tmp = LEDGER + "." + name + ".tmp"
json.dump(ledger, open(tmp, "w"), indent=2)
os.replace(tmp, LEDGER)
print("TRIPO_DONE", st.get("status"), task, json.dumps(bal0), json.dumps(bal1), flush=True)
sys.exit(0 if st.get("status") == "success" else 1)
