# SkyRally prop runner (derived from win/tripo_image_views.py model mode). Runs ON THE PC; TRIPO_API_KEY from the
# user environment, never printed. One concept image -> Tripo image-to-model (smart low poly, textured, de-lit).
# Writes <out_dir>/tripo_entry.json (task id, payload, balances) instead of a shared ledger (parallel zone agents).
# Usage: py tripo_prop.py <name> <image> <out_dir> face_limit=4000 [model=v3.1-20260211] [pbr=0|1] [texture_quality=detailed]
#        py tripo_prop.py balance
import json, os, sys, time, urllib.error, urllib.request, uuid

BASE = "https://openapi.tripo3d.ai/v3"
KEY = os.environ.get("TRIPO_API_KEY", "")
if not KEY:
    sys.exit("TRIPO_FAIL no key in environment")


def req(method, path, data=None, files=None):
    hdrs = {"Authorization": "Bearer " + KEY}
    if files:
        b = uuid.uuid4().hex
        body = b""
        for field, fn, ct, blob in files:
            body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                     % (b, field, fn, ct)).encode() + blob + b"\r\n"
        body += ("--%s--\r\n" % b).encode()
        hdrs["Content-Type"] = "multipart/form-data; boundary=" + b
        r = urllib.request.Request(BASE + path, data=body, headers=hdrs, method=method)
    else:
        hdrs["Content-Type"] = "application/json"
        r = urllib.request.Request(BASE + path, data=json.dumps(data).encode() if data is not None else None,
                                   headers=hdrs, method=method)
    # 429 (account-wide generation concurrency shared with other lanes) and dropped connections are retried with
    # backoff; a rejected submission creates no task and costs nothing.
    for attempt in range(40):
        try:
            with urllib.request.urlopen(r, timeout=180) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")[:900]
            if e.code == 429 or e.code >= 500:
                print("RETRY", e.code, attempt, flush=True)
                time.sleep(min(60, 10 + attempt * 5))
                continue
            print("HTTP_ERROR", e.code, body, flush=True)
            raise
        except urllib.error.URLError as e:
            print("RETRY urlerror", attempt, str(e)[:120], flush=True)
            time.sleep(15)
    sys.exit("TRIPO_FAIL retries exhausted " + path)


if len(sys.argv) == 2 and sys.argv[1] == "balance":
    print("BALANCE", json.dumps(req("GET", "/account/balance").get("data", {})))
    sys.exit(0)

name, img, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
opts = dict(a.split("=", 1) for a in sys.argv[4:])
os.makedirs(out_dir, exist_ok=True)
MODEL = opts.get("model", "v3.1-20260211")


def poll(task_id, minutes=40):
    t0 = time.time()
    while time.time() - t0 < minutes * 60:
        time.sleep(10)
        s = req("GET", "/tasks/" + task_id)["data"]
        print("[%ds] %s %s %s" % (time.time() - t0, task_id, s.get("status"), s.get("progress")), flush=True)
        if s.get("status") in ("success", "failed", "cancelled", "banned", "expired"):
            return s
    sys.exit("TRIPO_FAIL poll timeout " + task_id)


def walk(o, pre=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from walk(v, pre + k + "_")
    elif isinstance(o, str) and o.startswith("http"):
        yield pre.rstrip("_"), o


bal0 = req("GET", "/account/balance").get("data", {})
ct = "image/png" if img.lower().endswith(".png") else ("image/webp" if img.lower().endswith(".webp") else "image/jpeg")
up = req("POST", "/files", files=[("file", os.path.basename(img), ct, open(img, "rb").read())])
token = up["data"]["file_token"]
payload = {
    "file": {"file_token": token},
    "model_version": MODEL,
    "smart_low_poly": True,
    "face_limit": int(opts.get("face_limit", 4000)),
    "texture": True,
    "texture_quality": opts.get("texture_quality", "detailed"),
    "texture_alignment": "original_image",
    "orientation": opts.get("orientation", "default"),
    "enable_image_autofix": False,
    "texture_version": opts.get("texture_version", "v3.5-20260815"),
    "delight": True,
    "pbr": opts.get("pbr", "0") == "1",
}
res = req("POST", "/generation/image-to-model", payload)
task = res["data"]["task_id"]
print("MODEL_TASK_ID", task, flush=True)
entry = {"asset": name, "input": img, "model_task_id": task, "payload": {k: v for k, v in payload.items() if k != "file"},
         "balance_before": bal0, "utc_start": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
json.dump(entry, open(os.path.join(out_dir, "tripo_entry.json"), "w"), indent=2)
st = poll(task, 40)
entry["status"] = st.get("status")
saved = []
if st.get("status") == "success":
    for k, v in walk(st.get("output") or {}):
        ext = os.path.splitext(v.split("?")[0])[1] or ".bin"
        dest = os.path.join(out_dir, k + ext)
        urllib.request.urlretrieve(v, dest)
        saved.append(dest)
        print("DOWNLOADED", dest, os.path.getsize(dest), flush=True)
entry["files"] = saved
entry["balance_after"] = req("GET", "/account/balance").get("data", {})
entry["utc_end"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
json.dump(entry, open(os.path.join(out_dir, "tripo_entry.json"), "w"), indent=2)
print(("TRIPO_OK " if saved else "TRIPO_FAIL ") + task, json.dumps(bal0), json.dumps(entry["balance_after"]), flush=True)
