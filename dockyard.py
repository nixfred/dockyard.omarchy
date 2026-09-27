#!/usr/bin/env python3
"""Dockyard collector: one JSON snapshot of the local Docker engine.

Talks to the Engine API over the unix socket (no forks, no docker CLI needed).
Read-only unless called as `dockyard.py start|stop|restart <id>`, which the
panel only does on a click.

CPU% comes from the container's own cgroup (cpu.stat usage_usec) with the
previous sample kept in $XDG_RUNTIME_DIR, so a poll costs a few file reads
instead of a 1 s `docker stats` round trip per container.
"""
import http.client
import json
import os
import re
import socket
import sys
import time

SOCK = os.environ.get("DOCKER_HOST", "unix:///var/run/docker.sock")
SOCK = SOCK[len("unix://"):] if SOCK.startswith("unix://") else "/var/run/docker.sock"
RUN = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
CPU_STATE = os.path.join(RUN, "dockyard-cpu.json")
DF_CACHE = os.path.join(RUN, "dockyard-df.json")
DF_TTL = 300
CDI_DIRS = ["/etc/cdi", "/var/run/cdi"]


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path, timeout=4):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._path)
        self.sock = s


def api(method, path, timeout=4):
    c = UnixHTTP(SOCK, timeout)
    try:
        c.request(method, path, headers={"Host": "docker"})
        r = c.getresponse()
        body = r.read()
        if r.status >= 400:
            try:
                msg = json.loads(body).get("message", "")
            except Exception:
                msg = body.decode(errors="replace")[:200]
            raise RuntimeError("HTTP %d %s" % (r.status, msg))
        return json.loads(body) if body.strip() else None
    finally:
        c.close()


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def save(path, obj):
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:
        pass


def cgroup_dir(cid):
    for p in ("/sys/fs/cgroup/system.slice/docker-%s.scope" % cid,
              "/sys/fs/cgroup/docker/%s" % cid):
        if os.path.isdir(p):
            return p
    return None


def read_int(path):
    try:
        with open(path) as f:
            v = f.read().strip()
        return None if v == "max" else int(v)
    except Exception:
        return None


def cpu_usec(d):
    try:
        with open(os.path.join(d, "cpu.stat")) as f:
            for line in f:
                if line.startswith("usage_usec"):
                    return int(line.split()[1])
    except Exception:
        pass
    return None


def human_age(secs):
    secs = max(0, int(secs))
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 86400:
        return "%dh%02dm" % (secs // 3600, secs % 3600 // 60)
    return "%dd%02dh" % (secs // 86400, secs % 86400 // 3600)


def parse_ts(s):
    # Docker gives RFC3339 with nanoseconds; strip to seconds.
    if not s or s.startswith("0001"):
        return None
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", s)
    if not m:
        return None
    import calendar
    return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))


def ports_of(c):
    out = []
    seen = set()
    for p in c.get("Ports") or []:
        if p.get("PublicPort"):
            ip = p.get("IP") or ""
            if ":" in ip:  # skip the IPv6 twin of an IPv4 binding
                continue
            s = "%s%d>%d" % ("" if ip in ("0.0.0.0", "") else ip + ":", p["PublicPort"], p["PrivatePort"])
        else:
            s = "%d/%s" % (p.get("PrivatePort", 0), p.get("Type", "tcp"))
        if s not in seen:
            seen.add(s)
            out.append(s)
    return out


def is_gpu(info):
    hc = (info or {}).get("HostConfig") or {}
    for r in hc.get("DeviceRequests") or []:
        caps = [x for grp in (r.get("Capabilities") or []) for x in grp]
        if "gpu" in caps or r.get("Driver") in ("nvidia", "cdi"):
            return True
        if any(str(d).startswith("nvidia.com/") for d in (r.get("DeviceIDs") or [])):
            return True
    for d in hc.get("Devices") or []:
        if "nvidia" in str(d.get("PathOnHost", "")):
            return True
    for d in hc.get("CDIDevices") or []:
        if "nvidia" in str(d):
            return True
    env = (info.get("Config") or {}).get("Env") or []
    return any(e.startswith("NVIDIA_VISIBLE_DEVICES=") and not e.endswith("=void") for e in env)


def cdi_check():
    """Compare every device major in the CDI specs with the live /dev node.

    A driver update can renumber nvidia-uvm; an old spec then hands containers
    the wrong device and CUDA fails with "unknown error"."""
    specs, stale = [], []
    for d in CDI_DIRS:
        try:
            names = sorted(os.listdir(d))
        except Exception:
            continue
        for n in names:
            if not (n.endswith(".yaml") or n.endswith(".json")):
                continue
            p = os.path.join(d, n)
            specs.append({"path": p, "mtime": int(os.path.getmtime(p))})
            try:
                txt = open(p).read()
            except Exception:
                continue
            for m in re.finditer(r"path:\s*(/dev/\S+)\s*\n\s*major:\s*(\d+)", txt):
                dev, maj = m.group(1), int(m.group(2))
                try:
                    real = os.major(os.stat(dev).st_rdev)
                except Exception:
                    continue
                if real != maj:
                    stale.append("%s %s: spec %d, live %d" % (n, dev, maj, real))
    return {"specs": specs, "stale": stale}


def img_name(i):
    tags = [t for t in (i.get("RepoTags") or []) if t != "<none>:<none>"]
    if tags:
        t = tags[0]
        if "@sha256:" in t:
            repo, h = t.split("@sha256:")
            t = "%s@%s" % (repo, h[:12])
        return t
    dig = i.get("RepoDigests") or []
    if dig and "@sha256:" in dig[0]:
        repo, h = dig[0].split("@sha256:")
        return "%s@%s" % (repo, h[:12])
    return "<dangling> %s" % i.get("Id", "")[7:19]


def disk_usage(now, nimages):
    c = load(DF_CACHE)
    if c and now - c.get("t", 0) < DF_TTL and c["df"].get("images") == nimages:
        return c["df"]
    try:
        df = api("GET", "/system/df", timeout=15)
    except Exception:
        return c["df"] if c else None
    imgs = df.get("Images") or []
    out = {
        "images": len(imgs),
        "imageSize": sum(i.get("Size", 0) for i in imgs),
        "shared": sum(i.get("SharedSize", 0) for i in imgs if i.get("SharedSize", 0) > 0),
        "unusedImages": sum(1 for i in imgs if i.get("Containers", 0) == 0),
        "reclaimable": sum(i.get("Size", 0) for i in imgs if i.get("Containers", 0) == 0),
        "volumes": len(df.get("Volumes") or []),
        "volumeSize": sum(max(0, (v.get("UsageData") or {}).get("Size", 0)) for v in df.get("Volumes") or []),
        "buildCache": sum(b.get("Size", 0) for b in df.get("BuildCache") or []),
        "layers": df.get("LayersSize", 0),
        "top": [{"tag": img_name(i), "size": i.get("Size", 0),
                 "used": i.get("Containers", 0)}
                for i in sorted(imgs, key=lambda i: -i.get("Size", 0))[:5]],
    }
    save(DF_CACHE, {"t": now, "df": out})
    return out


def snapshot():
    now = time.time()
    out = {"ok": True, "daemon": False, "error": "", "generated": time.strftime("%H:%M:%S"),
           "cdi": cdi_check()}
    if not os.path.exists(SOCK):
        out.update(error="docker not running (no %s)" % SOCK)
        return out
    try:
        ver = api("GET", "/version", timeout=3)
    except PermissionError:
        out.update(error="no permission on %s (join the docker group)" % SOCK)
        return out
    except Exception as e:
        out.update(error="docker not running (%s)" % e.__class__.__name__)
        return out
    out["daemon"] = True
    out["version"] = ver.get("Version", "")
    out["api"] = ver.get("ApiVersion", "")
    try:
        info = api("GET", "/info", timeout=4)
        out["host"] = {"ncpu": info.get("NCPU", 0), "mem": info.get("MemTotal", 0),
                       "driver": info.get("Driver", ""), "cgroup": info.get("CgroupDriver", ""),
                       "root": info.get("DockerRootDir", ""), "runtimes": sorted((info.get("Runtimes") or {}).keys())}
        conts = api("GET", "/containers/json?all=1", timeout=4)
        nimages = len(api("GET", "/images/json", timeout=4) or [])
        dangling = api("GET", "/images/json?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D", timeout=4)
    except Exception as e:
        out.update(ok=False, error="engine API: %s" % e)
        return out
    ncpu = max(1, out["host"]["ncpu"])

    prev = load(CPU_STATE) or {}
    nxt = {}
    rows = []
    for c in conts:
        cid = c["Id"]
        name = (c.get("Names") or ["/?"])[0].lstrip("/")
        lab = c.get("Labels") or {}
        row = {"id": cid[:12], "name": name, "image": c.get("Image", ""),
               "state": c.get("State", ""), "status": c.get("Status", ""),
               "ports": ports_of(c), "compose": lab.get("com.docker.compose.project", ""),
               "cpu": None, "mem": None, "memLimit": None, "uptime": "", "gpu": False,
               "restarts": 0, "health": "", "exit": None}
        try:
            ins = api("GET", "/containers/%s/json" % cid, timeout=3)
        except Exception:
            ins = {}
        st = ins.get("State") or {}
        row["gpu"] = is_gpu(ins)
        row["restarts"] = ins.get("RestartCount", 0)
        row["health"] = (st.get("Health") or {}).get("Status", "")
        row["policy"] = ((ins.get("HostConfig") or {}).get("RestartPolicy") or {}).get("Name", "")
        if row["image"].startswith("sha256:") or re.fullmatch(r"[0-9a-f]{12,}", row["image"]):
            row["image"] = (ins.get("Config") or {}).get("Image", row["image"])
        row["image"] = row["image"].split("@sha256:")[0]
        if row["state"] == "running":
            t0 = parse_ts(st.get("StartedAt"))
            if t0:
                row["uptime"] = human_age(now - t0)
            d = cgroup_dir(cid)
            if d:
                u = cpu_usec(d)
                if u is not None:
                    nxt[cid] = [u, now]
                    p = prev.get(cid)
                    if p and now > p[1]:
                        row["cpu"] = round(max(0.0, (u - p[0]) / 1e6 / (now - p[1]) * 100), 1)
                mem = read_int(os.path.join(d, "memory.current"))
                row["mem"] = mem
                lim = read_int(os.path.join(d, "memory.max"))
                row["memLimit"] = lim
        else:
            t1 = parse_ts(st.get("FinishedAt"))
            if t1:
                row["uptime"] = human_age(now - t1) + " ago"
            row["exit"] = st.get("ExitCode")
        rows.append(row)
    save(CPU_STATE, nxt)

    order = {"running": 0, "restarting": 1, "paused": 2, "created": 3, "exited": 4, "dead": 5}
    rows.sort(key=lambda r: (order.get(r["state"], 9), r["name"]))
    out["containers"] = rows
    out["running"] = sum(1 for r in rows if r["state"] == "running")
    out["total"] = len(rows)
    out["gpuCount"] = sum(1 for r in rows if r["gpu"] and r["state"] == "running")
    out["unhealthy"] = sum(1 for r in rows if r["health"] == "unhealthy" or r["state"] in ("restarting", "dead"))
    out["cpuTotal"] = round(sum(r["cpu"] or 0 for r in rows), 1)
    out["cpuNorm"] = round(out["cpuTotal"] / ncpu, 1)
    out["memTotal"] = sum(r["mem"] or 0 for r in rows)
    out["dangling"] = {"count": len(dangling or []), "size": sum(i.get("Size", 0) for i in dangling or [])}
    out["df"] = disk_usage(now, nimages)
    return out


def action(verb, cid):
    if verb not in ("start", "stop", "restart"):
        raise SystemExit("unknown action")
    if not re.fullmatch(r"[0-9a-f]{12,64}", cid):
        raise SystemExit("bad id")
    q = "?t=10" if verb in ("stop", "restart") else ""
    try:
        api("POST", "/containers/%s/%s%s" % (cid, verb, q), timeout=30)
        print(json.dumps({"ok": True, "action": verb, "id": cid}))
    except Exception as e:
        print(json.dumps({"ok": False, "action": verb, "id": cid, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) == 3:
        action(sys.argv[1], sys.argv[2])
    else:
        try:
            print(json.dumps(snapshot()))
        except Exception as e:
            print(json.dumps({"ok": False, "daemon": False, "error": "collector: %s" % e}))
