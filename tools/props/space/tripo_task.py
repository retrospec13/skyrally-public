# Print a Tripo task's metadata (no URLs, no key). Usage: py tripo_task.py <task_id>...
import json, os, sys, urllib.request
KEY = os.environ["TRIPO_API_KEY"]
for t in sys.argv[1:]:
    r = urllib.request.Request("https://openapi.tripo3d.ai/v3/tasks/" + t, headers={"Authorization": "Bearer " + KEY})
    d = json.loads(urllib.request.urlopen(r, timeout=60).read())["data"]
    d.pop("output", None); d.pop("result", None)
    print(json.dumps(d)[:1500])
