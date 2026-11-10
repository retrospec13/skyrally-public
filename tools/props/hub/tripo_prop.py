# SkyRally HUB prop runner: one concept image -> Tripo image-to-model (smart low poly, textured, PBR off).
# Runs ON THE PC (TRIPO_API_KEY in the user environment; never printed). Writes its own ledger next to out_dir.
# Usage: py tripo_prop.py <name> <image.png> <out_dir> face_limit=4000 [texture_quality=standard] [smart=1|0] [task=<id> to resume]
import json, os, sys, time, urllib.error, urllib.request, uuid
BASE = "https://openapi.tripo3d.ai/v3"
KEY = os.environ.get("TRIPO_API_KEY", "")
if not KEY:
    sys.exit("TRIPO_FAIL no key in environment")
name, img, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
opts = dict(a.split("=", 1) for a in sys.argv[4:])
os.makedirs(out_dir, exist_ok=True)
LEDGER = os.path.join(os.path.dirname(os.path.abspath(out_dir)), "tripo_props_hub.json")

def req(method, path, data=None, files=None):
    hdrs = {"Authorization": "Bearer " + KEY}
    if files:
        b = uuid.uuid4().hex
        body = b""
        for field, fn, ct, blob in files:
            body += ('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\nContent-Type: %s\r\n\r\n' % (b, field, fn, ct)).encode() + blob + b"\r\n"
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

def walk(o, pre=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from walk(v, pre + k + "_")
    elif isinstance(o, str) and o.startswith("http"):
        yield pre.rstrip("_"), o

bal0 = req("GET", "/account/balance").get("data", {})
up = {"data": {"file_token": None}} if any(x.startswith("task=") for x in sys.argv[4:]) else req("POST", "/files", files=[("file", os.path.basename(img), "image/png", open(img, "rb").read())])
payload = {
    "file": {"file_token": up["data"]["file_token"]},
    "model_version": opts.get("model", "v3.1-20260211"),
    "smart_low_poly": opts.get("smart", "1") == "1",
    "face_limit": int(opts.get("face_limit", 4000)),
    "texture": True,
    "pbr": False,
    "texture_quality": opts.get("texture_quality", "standard"),
    "texture_alignment": "original_image",
    "orientation": "default",
    "enable_image_autofix": False,
}
def safe_get(path):
    for i in range(30):
        try:
            return req("GET", path)
        except (urllib.error.URLError, OSError) as e:
            if isinstance(e, urllib.error.HTTPError) and e.code not in (429, 500, 502, 503, 504):
                raise
            print("TRANSIENT", path, str(e)[:120], flush=True)
            time.sleep(15)
    raise SystemExit("TRIPO_FAIL transient " + path)

task = opts.get("task")
for attempt in range(0 if task else 60):
    try:
        task = req("POST", "/generation/image-to-model", payload)["data"]["task_id"]
        break
    except urllib.error.HTTPError as e:
        if e.code != 429:
            raise
        print("RATE_LIMITED retry in 45s", attempt, flush=True)
        time.sleep(45)
else:
    if not task:
        sys.exit("TRIPO_FAIL rate limited")
print("MODEL_TASK_ID", task, flush=True)
t0 = time.time()
while True:
    time.sleep(8)
    st = safe_get("/tasks/" + task)["data"]
    if st.get("status") in ("success", "failed", "cancelled", "banned", "expired"):
        break
    if time.time() - t0 > 2400:
        sys.exit("TRIPO_FAIL poll timeout " + task)
print("STATUS", st.get("status"), "secs", int(time.time() - t0), "keys", sorted(k for k in st if k != "output"), flush=True)
for k in st:
    if "credit" in k or "cost" in k:
        print("COST_FIELD", k, st[k])
saved = []
if st.get("status") == "success":
    for k, v in walk(st.get("output") or {}):
        ext = os.path.splitext(v.split("?")[0])[1] or ".bin"
        dest = os.path.join(out_dir, k + ext)
        urllib.request.urlretrieve(v, dest)
        saved.append(dest)
        print("DOWNLOADED", dest, os.path.getsize(dest), flush=True)
bal1 = safe_get("/account/balance").get("data", {})
led = json.load(open(LEDGER)) if os.path.exists(LEDGER) else {}
led.setdefault(name, []).append({"model_task_id": task, "status": st.get("status"),
    "payload": {k: v for k, v in payload.items() if k != "file"}, "files": saved,
    "balance_before": bal0, "balance_after": bal1, "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
json.dump(led, open(LEDGER, "w"), indent=2)
print("TRIPO_DONE", st.get("status"), task, json.dumps(bal0), json.dumps(bal1), flush=True)
