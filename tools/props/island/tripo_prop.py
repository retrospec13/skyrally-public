# SkyRally prop runner (ISLAND props lane). Runs ON THE PC: one concept image -> Tripo v3 image-to-model
# (smart low poly, textured, PBR off, de-lit albedo). The key lives in the PC user env (TRIPO_API_KEY), never printed.
# Writes <out_dir>/tripo_job.json (own per-prop ledger; never the shared tripo_jobs_v2.json, other lanes write it).
# Usage: py tripo_prop.py <name> <image.png> <out_dir> face_limit=4000 [texture_quality=detailed] [balance_only=1]
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

BASE = "https://openapi.tripo3d.ai/v3"
KEY = os.environ.get("TRIPO_API_KEY", "")
if not KEY:
    sys.exit("TRIPO_FAIL no key in environment")


def req(method, path, data=None, files=None):
    hdrs = {"Authorization": "Bearer " + KEY}
    if files:
        boundary = uuid.uuid4().hex
        body = b""
        for field, filename, ctype, blob in files:
            body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                     % (boundary, field, filename, ctype)).encode() + blob + b"\r\n"
        body += ("--%s--\r\n" % boundary).encode()
        hdrs["Content-Type"] = "multipart/form-data; boundary=" + boundary
        r = urllib.request.Request(BASE + path, data=body, headers=hdrs, method=method)
    else:
        hdrs["Content-Type"] = "application/json"
        r = urllib.request.Request(BASE + path, data=json.dumps(data).encode() if data is not None else None,
                                   headers=hdrs, method=method)
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


if len(sys.argv) >= 2 and sys.argv[1] == "balance":
    print("TRIPO_BALANCE", json.dumps(req("GET", "/account/balance").get("data", {})), flush=True)
    sys.exit(0)

name, img, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
opts = dict(a.split("=", 1) for a in sys.argv[4:])
os.makedirs(out_dir, exist_ok=True)
bal0 = req("GET", "/account/balance").get("data", {})
ctype = "image/png" if img.lower().endswith(".png") else "image/jpeg"
up = req("POST", "/files", files=[("file", os.path.basename(img), ctype, open(img, "rb").read())])
token = up["data"]["file_token"]
payload = {
    "file": {"file_token": token},
    "model_version": opts.get("model", "v3.1-20260211"),
    "smart_low_poly": True,
    "face_limit": int(opts.get("face_limit", 4000)),
    "texture": True,
    "pbr": False,
    "texture_quality": opts.get("texture_quality", "detailed"),
    "texture_alignment": "original_image",
    "orientation": "default",
    "enable_image_autofix": False,
    "texture_version": "v3.5-20260815",
    "delight": True,
}
res = None
for attempt in range(12):  # Tripo returns 429 "exceeded the limit of generation" while other lanes' jobs run
    try:
        res = req("POST", "/generation/image-to-model", payload)
        break
    except urllib.error.HTTPError as e:
        if e.code != 429:
            raise
        print("RATE_LIMITED retry in 60s", attempt, flush=True)
        time.sleep(60)
if res is None:
    sys.exit("TRIPO_FAIL rate limited 12 times")
task = res["data"]["task_id"]
bal_submit = req("GET", "/account/balance").get("data", {})
print("MODEL_TASK_ID", task, json.dumps(bal0), json.dumps(bal_submit), flush=True)
t0 = time.time()
st = {}
while time.time() - t0 < 40 * 60:
    time.sleep(8)
    st = req("GET", "/tasks/" + task)["data"]
    print("[%ds] %s %s" % (time.time() - t0, st.get("status"), st.get("progress")), flush=True)
    if st.get("status") in ("success", "failed", "cancelled", "banned", "expired"):
        break
saved = []
if st.get("status") == "success":
    for k, v in walk(st.get("output") or {}):
        ext = os.path.splitext(v.split("?")[0])[1] or ".bin"
        dest = os.path.join(out_dir, k + ext)
        urllib.request.urlretrieve(v, dest)
        saved.append(dest)
        print("DOWNLOADED", dest, os.path.getsize(dest), flush=True)
bal1 = req("GET", "/account/balance").get("data", {})
entry = {"asset": name, "model_task_id": task, "status": st.get("status"), "input": img,
         "payload": {k: v for k, v in payload.items() if k != "file"}, "files": saved,
         "credits_consumed": st.get("credits_consumed"), "balance_before": bal0, "balance_after_submit": bal_submit,
         "balance_after": bal1, "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
json.dump(entry, open(os.path.join(out_dir, "tripo_job.json"), "w"), indent=2)
print("TRIPO_DONE" if st.get("status") == "success" else "TRIPO_FAIL", task, json.dumps(st)[:300] if st.get("status") != "success" else "", flush=True)
