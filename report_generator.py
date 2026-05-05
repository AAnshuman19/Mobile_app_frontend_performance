#!/usr/bin/env python3
# generate_perf_html_report.py  <OUT_DIR> <HTML_OUT>
import sys, json, re
from pathlib import Path

OUT_DIR  = Path(sys.argv[1])
HTML_OUT = sys.argv[2]

def read(name, default=""):
    p = OUT_DIR / name
    return p.read_text(errors="replace").strip() if p.exists() else default

def readj(name, default=None):
    p = OUT_DIR / name
    if not p.exists(): return default
    try: return json.loads(p.read_text())
    except: return default

def fv(v, suffix=""):
    if v is None: return "n/a"
    try: return f"{float(v):.1f}{suffix}"
    except: return str(v)

def fi(v, suffix=""):
    if v is None: return "n/a"
    try: return f"{int(float(v))}{suffix}"
    except: return str(v)

summary_md  = read("SUMMARY.md")
gfx_raw     = read("gfxinfo.txt")
meminfo_raw = read("meminfo.txt")
apk_size    = read("apk_size.txt")
ping_raw    = read("ping_tripmeet.txt") or read("ping_host.txt")
device_raw  = read("device_info.txt")
sys_mem_raw = read("system_meminfo.txt")
runs_raw    = read("launch_runs.txt")

launch   = readj("launch_summary.json", {})
api_lat  = readj("api_latency_summary.json", {})
cpu_data = readj("cpu_idle_samples.json", {})
user_j   = readj("user_journey_summary.json", {})
flows    = readj("flow_results.json", {})

device_info = {}
for line in device_raw.splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        device_info[k.strip()] = v.strip()
app_pkg     = device_info.get("package", "")
app_name_di = device_info.get("app_name", "")
device_mdl  = device_info.get("device_model", "")
android_ver = device_info.get("android_version", "")
app_version = ""
ver_m = re.search(r"versionName=([\w.]+)", device_raw)
if ver_m: app_version = ver_m.group(1)

app_name_m = re.search(r"^#\s*(.+?)(?:\s+Android|\s+Performance|\s+Smoke)", summary_md, re.I | re.M)
app_name   = app_name_m.group(1).strip() if app_name_m else (app_name_di or "App")
run_id     = OUT_DIR.name

cold_avg = None; cold_p95 = None; cold_p99 = None; cold_min = None; tti_avg = None
cold_runs_raw = []
if isinstance(launch, dict):
    total = launch.get("total_time", {}) or {}
    wait  = launch.get("wait_time", {})  or {}
    cold_avg = total.get("avg_ms")  or launch.get("cold_start_avg_ms") or launch.get("avg_ms")
    cold_p95 = total.get("p95_ms")  or launch.get("cold_start_p95_ms") or launch.get("p95_ms")
    cold_p99 = total.get("p99_ms")  or launch.get("cold_start_p99_ms") or launch.get("p99_ms")
    cold_min = total.get("min_ms")  or launch.get("cold_start_min_ms") or launch.get("min_ms")
    tti_avg  = wait.get("avg_ms")   or launch.get("tti_proxy_avg_ms")  or launch.get("tti_avg_ms")
    cold_runs_raw = total.get("samples_ms", [])
if not cold_runs_raw and runs_raw:
    cold_runs_raw = [int(x) for x in re.findall(r"(\d+)", runs_raw) if 100 < int(x) < 30000]

pss_m  = re.search(r"TOTAL PSS[\s:]+([\d]+)", meminfo_raw, re.I)
rss_m  = re.search(r"TOTAL RSS[\s:]+([\d]+)", meminfo_raw, re.I)
pss_kb = int(pss_m.group(1)) if pss_m else None
rss_kb = int(rss_m.group(1)) if rss_m else None
pss_mb = round(pss_kb / 1024) if pss_kb else None
rss_mb = round(rss_kb / 1024) if rss_kb else None
sys_mem_total = None; sys_mem_avail = None
m = re.search(r"MemTotal[\s:]+([\d]+)", sys_mem_raw)
if m: sys_mem_total = int(m.group(1))
m = re.search(r"MemAvailable[\s:]+([\d]+)", sys_mem_raw)
if m: sys_mem_avail = int(m.group(1))
sys_mem_used_pct = 0
if sys_mem_total and sys_mem_avail:
    sys_mem_used_pct = round((sys_mem_total - sys_mem_avail) / sys_mem_total * 100)

def _gm(pat): return re.search(pat, gfx_raw, re.I)
total_frames = int(_gm(r"Total frames rendered[\s:]+([\d]+)").group(1)) if _gm(r"Total frames rendered[\s:]+([\d]+)") else None
_jm = _gm(r"Janky frames[\s:]+([\d]+)\s*\(([^)]+)\)")
janky_cnt = int(_jm.group(1)) if _jm else None
janky_pct = _jm.group(2).strip() if _jm else None
p50_ms = int(_gm(r"50th percentile[\s:]+([\d]+)\s*ms").group(1)) if _gm(r"50th percentile[\s:]+([\d]+)\s*ms") else None
p90_ms = int(_gm(r"90th percentile[\s:]+([\d]+)\s*ms").group(1)) if _gm(r"90th percentile[\s:]+([\d]+)\s*ms") else None
p95_ms = int(_gm(r"95th percentile[\s:]+([\d]+)\s*ms").group(1)) if _gm(r"95th percentile[\s:]+([\d]+)\s*ms") else None
p99_ms = int(_gm(r"99th percentile[\s:]+([\d]+)\s*ms").group(1)) if _gm(r"99th percentile[\s:]+([\d]+)\s*ms") else None
missed_vs = int(_gm(r"Number Missed Vsync[\s:]+([\d]+)").group(1)) if _gm(r"Number Missed Vsync[\s:]+([\d]+)") else None
high_inp  = int(_gm(r"Number High input latency[\s:]+([\d]+)").group(1)) if _gm(r"Number High input latency[\s:]+([\d]+)") else None
slow_ui   = int(_gm(r"Number Slow UI thread[\s:]+([\d]+)").group(1)) if _gm(r"Number Slow UI thread[\s:]+([\d]+)") else None
slow_draw = int(_gm(r"Number Slow draw[\s:]+([\d]+)").group(1)) if _gm(r"Number Slow draw[\s:]+([\d]+)") else None

cpu_busy_arr = []; cpu_avg_busy = None
if isinstance(cpu_data, dict):
    raw_samples = cpu_data.get("samples", cpu_data.get("idle_pct", []))
    avg_field   = cpu_data.get("avg_cpu_pct")
    if avg_field is not None and float(avg_field) > 50:
        cpu_busy_arr = [round(float(x), 1) for x in raw_samples if x is not None]
    else:
        cpu_busy_arr = [round(100 - float(x), 1) for x in raw_samples if x is not None]
    cpu_avg_busy = float(avg_field) if avg_field is not None else (
        round(sum(cpu_busy_arr) / len(cpu_busy_arr), 1) if cpu_busy_arr else None)
elif isinstance(cpu_data, list):
    cpu_busy_arr = [round(float(x), 1) for x in cpu_data if x is not None]
    cpu_avg_busy = round(sum(cpu_busy_arr) / len(cpu_busy_arr), 1) if cpu_busy_arr else None

anr_in_exit  = bool(re.search(r"ANR.*True|ANR seen.*Yes", summary_md, re.I))
apk_size_str = re.sub(r"\s+", " ", apk_size.replace("\n", " ")).strip() or "n/a"

journey_rows = []
if isinstance(user_j, list):
    for j in user_j:
        if isinstance(j, dict):
            ms = j.get("load_ms_upper_bound") or j.get("upper_bound_ms") or j.get("elapsed_ms")
            journey_rows.append((j.get("screen") or j.get("name", "?"), ms))
elif isinstance(user_j, dict):
    for j in (user_j.get("journeys") or user_j.get("screens") or []):
        if isinstance(j, dict):
            journey_rows.append((j.get("name", "?"), j.get("upper_bound_ms") or j.get("elapsed_ms")))
journey_valid = [(n, float(ms)) for n, ms in journey_rows if ms is not None]

api_rows = []
if isinstance(api_lat, dict):
    for ep, data in api_lat.items():
        if ep == "note": continue
        if isinstance(data, dict):
            api_rows.append({"endpoint": ep, "avg": data.get("avg_ms"),
                "p50": data.get("p50_ms"), "p95": data.get("p95_ms"),
                "p99": data.get("p99_ms"), "max": data.get("max_ms"),
                "statuses": data.get("statuses", [])})
all_403 = bool(api_rows and all("403" in " ".join(r["statuses"]) for r in api_rows))

flow_steps = []
if isinstance(flows, dict) and flows.get("flows"):
    for flow in flows["flows"]:
        for step in flow.get("steps", []):
            if isinstance(step, dict):
                d = step.get("resource_delta", {}) or {}
                flow_steps.append({"ok": step.get("ok", True),
                    "label": step.get("label", step.get("action", "step")),
                    "elapsed_ms": step.get("elapsed_ms"),
                    "cpu": d.get("app_cpu_pct_after"),
                    "pss_delta": d.get("app_pss_kb_delta")})

def tc(val, good, warn):
    if val is None: return "#6b7280"
    return "#22c55e" if val <= good else ("#f59e0b" if val <= warn else "#ef4444")
def tchi(val, warn, bad):
    if val is None: return "#6b7280"
    return "#22c55e" if val <= warn else ("#f59e0b" if val <= bad else "#ef4444")
def sc(val, good=80, warn=60):
    if val is None: return "#6b7280"
    return "#22c55e" if val >= good else ("#f59e0b" if val >= warn else "#ef4444")

cold_color = tc(cold_p95, 1000, 2000)
tti_color  = tc(tti_avg, 1200, 2500)
pss_color  = tc(pss_kb, 200000, 400000) if pss_kb else "#6b7280"
jp_val     = (janky_cnt / total_frames * 100) if (janky_cnt is not None and total_frames) else None
jank_color = tc(jp_val, 20, 50)
anr_c      = "#ef4444" if anr_in_exit else "#22c55e"
anr_str    = "YES" if anr_in_exit else "NO"
cpu_color  = tc(cpu_avg_busy, 50, 70)

def compute_score():
    s = []
    if cold_p95     is not None: s.append(max(0, min(100, int((2000 - cold_p95) / 20))))
    if pss_kb       is not None: s.append(max(0, min(100, int((400000 - pss_kb) / 3000))))
    if jp_val       is not None: s.append(max(0, min(100, int(100 - jp_val * 1.5))))
    if cpu_avg_busy is not None: s.append(max(0, min(100, int(100 - cpu_avg_busy))))
    return round(sum(s) / len(s)) if s else None

perf_score = compute_score()
score_c    = sc(perf_score)
score_dash = str(round(314 - 314 * (perf_score or 0) / 100))

verdicts = []
if cold_p95 is not None:
    verdicts.append(("Launch", "Good" if cold_p95<1000 else ("Fair" if cold_p95<2000 else "Poor"), tc(cold_p95,1000,2000)))
if pss_kb is not None:
    verdicts.append(("Memory", "Good" if pss_kb<200000 else ("Warning" if pss_kb<400000 else "Critical"), tc(pss_kb,200000,400000)))
if jp_val is not None:
    verdicts.append(("UI Jank", "Good" if jp_val<20 else ("Fair" if jp_val<50 else "Poor"), tc(jp_val,20,50)))
if cpu_avg_busy is not None:
    verdicts.append(("CPU", "Good" if cpu_avg_busy<50 else ("Warning" if cpu_avg_busy<70 else "High"), tc(cpu_avg_busy,50,70)))
verdicts.append(("Stability", "No ANR" if not anr_in_exit else "ANR Found!", anr_c))

verdict_html = "".join(
    f'<div class="vc" style="background:{c}18;border:1px solid {c}60;color:{c}">' +
    f'{"&#9989;" if c=="#22c55e" else ("&#9888;&#65039;" if c=="#f59e0b" else "&#10060;")} {lbl}: <strong>{txt}</strong></div>'
    for lbl, txt, c in verdicts)

insights = []
if cold_p95 is not None:
    if cold_p95 < 800:
        insights.append(("&#128640;","Blazing Fast Launch",f"Cold start p95 <strong>{fi(cold_p95)} ms</strong> \u2014 elite startup. Top 10% of apps.","Good","#22c55e","#03150a"))
    elif cold_p95 < 1500:
        insights.append(("&#9989;","Acceptable Launch Speed",f"Cold start p95 <strong>{fi(cold_p95)} ms</strong>. Target &lt;1000 ms for premium feel.","Monitor","#22c55e","#03150a"))
    elif cold_p95 < 2500:
        insights.append(("&#9888;","Slow Cold Start \u2014 Optimise",f"p95 <strong>{fi(cold_p95)} ms</strong> exceeds 1.5 s. <strong>Actions:</strong> Defer plugin init, lazy DI providers, move I/O off main thread.","Needs Fix","#f59e0b","#1a1000"))
    else:
        insights.append(("&#128308;","Critical Startup Latency",f"Cold start p95 <strong>{fi(cold_p95)} ms</strong>. <strong>Actions:</strong> Profile with Android Studio Startup, reduce ContentProviders, switch to lazy injection.","P0 Fix","#ef4444","#150000"))

if cpu_avg_busy is not None:
    if cpu_avg_busy > 75:
        insights.append(("&#128308;","Critical CPU Utilisation",f"CPU averaging <strong>{fv(cpu_avg_busy)}%</strong>. Thermal throttling imminent. <strong>Actions:</strong> Profile CPU Profiler, stop animation loops in background, check runaway coroutines.","P0 Fix","#ef4444","#150000"))
    elif cpu_avg_busy > 55:
        insights.append(("&#128993;","Elevated CPU Usage",f"CPU averaging <strong>{fv(cpu_avg_busy)}%</strong>. <strong>Actions:</strong> Move image decoding off main thread, reduce Compose recompositions, audit timers.","Needs Fix","#f59e0b","#1a1000"))
    else:
        insights.append(("&#9989;","Healthy CPU Utilisation",f"CPU averaging <strong>{fv(cpu_avg_busy)}%</strong> \u2014 app is not CPU-bound.","Good","#22c55e","#03150a"))

if pss_kb is not None:
    _mb = pss_kb / 1024
    if _mb > 350:
        insights.append(("&#128308;","Memory Pressure \u2014 OOM Risk",f"PSS <strong>{_mb:.0f} MB</strong>. High OOM risk. <strong>Actions:</strong> Audit Glide/Coil cache, check Bitmap leaks, reduce retained ViewModels.","P0 Fix","#ef4444","#150000"))
    elif _mb > 200:
        insights.append(("&#128993;","Moderate Memory Footprint",f"PSS <strong>{_mb:.0f} MB</strong>. Monitor on &lt;4 GB devices after prolonged navigation.","Monitor","#f59e0b","#1a1000"))
    else:
        insights.append(("&#128154;","Lean Memory Footprint",f"PSS <strong>{_mb:.0f} MB</strong> \u2014 comfortable on 2 GB devices.","Good","#22c55e","#03150a"))

if jp_val is not None:
    if jp_val < 10:
        insights.append(("&#127916;","Silky Smooth UI",f"Only <strong>{jp_val:.1f}%</strong> janky frames \u2014 fluid, premium experience.","Good","#22c55e","#03150a"))
    elif jp_val < 35:
        insights.append(("&#9888;","Occasional UI Jank",f"<strong>{jp_val:.1f}%</strong> janky. <strong>Actions:</strong> Add RepaintBoundary, reduce overdraw, profile GPU bars.","Needs Fix","#f59e0b","#1a1000"))
    else:
        insights.append(("&#128308;","Critical UI Jank",f"<strong>{jp_val:.1f}%</strong> janky. <strong>Actions:</strong> Profile with Perfetto, fix synchronous ops on Rasterizer thread immediately.","P0 Fix","#ef4444","#150000"))

if p99_ms is not None and p99_ms > 50:
    _ic = "#ef4444" if p99_ms > 200 else "#f59e0b"
    _ib = "#150000" if p99_ms > 200 else "#1a1000"
    _is = "P1 Fix"  if p99_ms > 200 else "Needs Fix"
    _ie = "&#128308;" if p99_ms > 200 else "&#128993;"
    insights.append((_ie,"Long-Tail Frame Spikes",f"p99 frame <strong>{p99_ms} ms</strong>. <strong>Actions:</strong> StrictMode disk/network checks, audit serialisation on main thread.",_is,_ic,_ib))

if journey_valid:
    _slow_scr, _slow_ms = max(journey_valid, key=lambda x: x[1])
    _avg_jms = sum(x[1] for x in journey_valid) / len(journey_valid)
    if _slow_ms > 3000:
        insights.append(("&#128308;",f"Slow Screen: {_slow_scr}",f"<strong>{_slow_scr}</strong> takes up to <strong>{fi(_slow_ms)} ms</strong>. <strong>Actions:</strong> Show skeletons immediately, paginate data, preload on tab hover.","P1 Fix","#ef4444","#150000"))
    elif _avg_jms > 2000:
        insights.append(("&#128993;","All Screens Loading Slowly",f"Average screen load <strong>{fi(_avg_jms)} ms</strong>. <strong>Actions:</strong> Cache last-seen state, optimistic rendering, reduce first-load API surface.","Needs Fix","#f59e0b","#1a1000"))

if api_rows:
    _worst = max(api_rows, key=lambda r: float(r.get("p95") or 0))
    _wp95  = _worst.get("p95")
    if _wp95 and float(_wp95) > 600:
        insights.append(("&#9888;","API Latency Elevated",f"Endpoint <code>{_worst['endpoint']}</code> p95=<strong>{fi(_wp95)} ms</strong>. <strong>Actions:</strong> Add response caching, check DB query plan, move to edge CDN.","Monitor","#f59e0b","#1a1000"))
    if all_403:
        insights.append(("&#128274;","API Probes Unauthenticated (403)","All API probes returned HTTP 403. Latency numbers are valid network-level measurements but real data was not served. Configure <code>API_ENDPOINTS_JSON</code> with auth tokens for full coverage.","Info","#3b82f6","#0a1520"))

if anr_in_exit:
    insights.append(("&#128680;","ANR Detected \u2014 P0","Exit-info contains ANR. Main thread blocked 5+ sec. <strong>Actions:</strong> Investigate deadlocks, enable StrictMode, move all I/O and locks off main thread.","P0 Fix","#ef4444","#150000"))
else:
    insights.append(("&#9989;","No ANR or Crash Events","Exit-info shows clean sessions \u2014 no main thread blocking events detected.","Good","#22c55e","#03150a"))

SEV_ICON = {"Good":"&#9989;","Monitor":"&#128270;","Needs Fix":"&#9888;&#65039;","P1 Fix":"&#128308;","P0 Fix":"&#128680;","Info":"&#8505;&#65039;"}

insight_html = "".join(
    f'<div class="icard" style="background:{bg};border-left:4px solid {c}">' +
    f'<div class="iicon">{icon}</div>' +
    f'<div style="flex:1"><div class="ihead">' +
    f'<span class="ititle" style="color:{c}">{title}</span>' +
    f'<span class="isev" style="background:{c}22;border:1px solid {c}55;color:{c}">{SEV_ICON.get(sev,"")} {sev}</span>' +
    f'</div><div class="idesc">{desc}</div></div></div>'
    for icon, title, desc, sev, c, bg in insights)

def tr(n, v, c): return f'<tr><td>{n}</td><td style="color:{c};font-weight:600">{v}</td></tr>'
gfx_html = "".join([
    tr("Total Frames",       fi(total_frames),               "#94a3b8"),
    tr("Janky Frames",       f"{fi(janky_cnt)} ({janky_pct or 'n/a'})", jank_color),
    tr("p50 Frame Time",     fi(p50_ms, " ms"),              tc(p50_ms, 16, 32)),
    tr("p90 Frame Time",     fi(p90_ms, " ms"),              tc(p90_ms, 24, 50)),
    tr("p95 Frame Time",     fi(p95_ms, " ms"),              tc(p95_ms, 32, 100)),
    tr("p99 Frame Time",     fi(p99_ms, " ms"),              tc(p99_ms, 50, 200)),
    tr("Missed VSync",       fi(missed_vs),                  tchi(missed_vs, 5, 20)),
    tr("High Input Latency", fi(high_inp),                   tchi(high_inp, 5, 20)),
    tr("Slow UI Thread",     fi(slow_ui),                    tchi(slow_ui, 5, 20)),
    tr("Slow Draw Commands", fi(slow_draw),                  tchi(slow_draw, 5, 20)),
])

api_table_html = ""
for r in api_rows:
    st    = ", ".join(r["statuses"][:1]) if r["statuses"] else "OK"
    is403 = "403" in " ".join(r["statuses"])
    bg403 = "#451a1a" if is403 else "#1e2235"
    fg403 = "#fc8181" if is403 else "#94a3b8"
    api_table_html += (
        f'<tr><td><code>{r["endpoint"]}</code></td>' +
        f'<td style="color:{tc(float(r["avg"]) if r["avg"] else None,200,500)}">{fv(r["avg"]," ms")}</td>' +
        f'<td style="color:{tc(float(r["p50"]) if r["p50"] else None,200,500)}">{fv(r["p50"]," ms")}</td>' +
        f'<td style="color:{tc(float(r["p95"]) if r["p95"] else None,200,500)}">{fv(r["p95"]," ms")}</td>' +
        f'<td style="color:{tc(float(r["p99"]) if r["p99"] else None,300,700)}">{fv(r["p99"]," ms")}</td>' +
        f'<td style="color:#94a3b8">{fv(r["max"]," ms")}</td>' +
        f'<td><span class="tag" style="background:{bg403};color:{fg403}">{st}</span></td></tr>')

api_403_note = ""
if all_403:
    api_403_note = ('<div class="note403"><strong>&#9888;&#65039; All endpoints returned HTTP 403.</strong>'
        ' These probes ran without auth headers. Latency numbers are valid network-level measurements.'
        ' Configure <code>API_ENDPOINTS_JSON</code> with auth tokens for full coverage.</div>')

journey_table_html = ""; journey_stats_html = ""
if journey_valid:
    max_ms_v = max(x[1] for x in journey_valid)
    slowest  = max(journey_valid, key=lambda x: x[1])
    fastest  = min(journey_valid, key=lambda x: x[1])
    avg_ms   = sum(x[1] for x in journey_valid) / len(journey_valid)
    for n, ms in journey_valid:
        pct = round(ms / max(max_ms_v, 1) * 100)
        col = tc(ms, 1500, 3000)
        journey_table_html += (
            f'<tr><td style="min-width:120px;font-weight:600">{n}</td>'
            f'<td style="padding:.5rem 1rem"><div style="display:flex;align-items:center;gap:.75rem">'
            f'<div style="flex:1;height:18px;background:#1e2035;border-radius:4px;overflow:hidden">'
            f'<div style="width:{pct}%;height:100%;background:{col};border-radius:4px"></div></div>'
            f'<span style="color:{col};font-weight:700;min-width:80px">{fi(ms)} ms</span></div></td></tr>')
    c_s = tc(slowest[1], 1500, 3000)
    c_f = tc(fastest[1], 1500, 3000)
    c_a = tc(avg_ms,     1500, 3000)
    journey_stats_html = (
        '<div class="jstats">'
        f'<div class="jstat"><div class="jstat-lbl">SLOWEST SCREEN</div>'
        f'<div class="jstat-name" style="color:{c_s}">{slowest[0]}</div>'
        f'<div class="jstat-val" style="color:{c_s}">{fi(slowest[1])} ms</div></div>'
        f'<div class="jstat"><div class="jstat-lbl">FASTEST SCREEN</div>'
        f'<div class="jstat-name" style="color:{c_f}">{fastest[0]}</div>'
        f'<div class="jstat-val" style="color:{c_f}">{fi(fastest[1])} ms</div></div>'
        f'<div class="jstat"><div class="jstat-lbl">AVERAGE LOAD</div>'
        f'<div class="jstat-name" style="color:{c_a}">All screens avg</div>'
        f'<div class="jstat-val" style="color:{c_a}">{fi(avg_ms)} ms</div></div>'
        '</div>')

flow_html = ""
if flow_steps:
    flow_html = "".join(
        f'<tr><td>{"&#9989;" if s["ok"] else "&#10060;"}</td><td>{s["label"]}</td>'
        f'<td style="color:{tc(float(s["elapsed_ms"]) if s["elapsed_ms"] else None,500,2000)}">{fi(s["elapsed_ms"]," ms")}</td>'
        f'<td style="color:{tc(s["cpu"] if s["cpu"] else None,50,80)}">{fv(s["cpu"]," %")}</td>'
        f'<td>{fi(s["pss_delta"]," KB")}</td></tr>'
        for s in flow_steps)

cold_json  = json.dumps(cold_runs_raw)
cpu_l_json = json.dumps([str(i+1) for i in range(len(cpu_busy_arr))])
cpu_d_json = json.dumps(cpu_busy_arr)
frame_json = json.dumps([p50_ms or 0, p90_ms or 0, p95_ms or 0, p99_ms or 0])
api_l_json = json.dumps([r["endpoint"] for r in api_rows])
api_p50_j  = json.dumps([float(r["p50"]) if r["p50"] else 0 for r in api_rows])
api_p95_j  = json.dumps([float(r["p95"]) if r["p95"] else 0 for r in api_rows])
api_p99_j  = json.dumps([float(r["p99"]) if r["p99"] else 0 for r in api_rows])
jny_l_json = json.dumps([r[0] for r in journey_valid])
jny_d_json = json.dumps([float(r[1]) for r in journey_valid])
jank_good_v = (total_frames - janky_cnt) if (total_frames and janky_cnt) else 0
jank_bad_v  = janky_cnt if janky_cnt is not None else 0

cold_chart_div = ('<div class="ccard"><h3>Cold Start \u2014 All Runs (ms)</h3><div class="cw"><canvas id="coldChart"></canvas></div></div>') if cold_runs_raw else ""
jank_pie_div   = (f'<div class="ccard"><h3>Jank Distribution ({total_frames or ""} frames)</h3><div class="cw"><canvas id="jankPie"></canvas></div></div>') if (janky_cnt is not None and total_frames) else ""
cpu_div        = ('<div class="ccard"><h3>CPU Busy % \u2014 Timeline</h3><div class="cw"><canvas id="cpuChart"></canvas></div></div>') if cpu_busy_arr else ""
api_chart_div  = ('<div class="ccard"><h3>API Latency \u2014 p95/p99 (ms)</h3><div class="cw"><canvas id="apiChart"></canvas></div></div>') if api_rows else ""
frame_chart_div = '<div class="ccard"><h3>Frame Time Percentiles (ms)</h3><div class="cw"><canvas id="frameChart"></canvas></div></div>'

tag_apk = f'<span class="hdr-tag">&#128230; {apk_size_str}</span>' if apk_size_str != "n/a" else ""
tag_dev = f'<span class="hdr-tag">&#128241; {device_mdl}</span>' if device_mdl else ""
tag_and = f'<span class="hdr-tag">&#129302; Android {android_ver}</span>' if android_ver else ""
tag_ver = f'<span class="hdr-tag">v{app_version}</span>' if app_version else ""
tag_pkg = f'<span class="hdr-tag"><code>{app_pkg}</code></span>' if app_pkg else ""

api_section = ""
if api_rows:
    _ah = min(300, 80 + len(api_rows) * 40)
    api_section = (
        f'<div class="section fi d3"><div class="stitle">&#127760; API Latency \u2014 {app_name}</div>'
        f'<div class="ccard" style="margin-bottom:1.2rem"><div class="cw" style="height:{_ah}px"><canvas id="apiChartFull"></canvas></div></div>'
        f'<div class="tcard"><table><thead><tr><th>Endpoint</th><th>Avg</th><th>P50</th><th>P95</th><th>P99</th><th>Max</th><th>Status</th></tr></thead><tbody>{api_table_html}</tbody></table></div>'
        f'{api_403_note}</div>')

journey_section = ""
if journey_valid:
    _jh = min(380, 80 + len(journey_valid) * 55)
    journey_section = (
        f'<div class="section fi d3"><div class="stitle">&#127939; User Journey Load Times \u2014 {app_name}</div>'
        f'<div class="ccard" style="margin-bottom:1.2rem"><div class="cw" style="height:{_jh}px"><canvas id="journeyChartFull"></canvas></div></div>'
        f'{journey_stats_html}</div>')

flow_section = ""
if flow_steps:
    flow_section = (
        '<div class="section fi d4"><div class="stitle">&#127939; Flow Step Breakdown</div>'
        f'<div class="tcard"><table><thead><tr><th></th><th>Step</th><th>Elapsed</th><th>CPU After</th><th>PSS Delta</th></tr></thead><tbody>{flow_html}</tbody></table></div></div>')

mem_bar_device = ""
if sys_mem_total:
    mem_bar_device = (
        f'<div class="mbar-row"><div class="mbar-label"><span>Device RAM Used</span><span style="color:#f59e0b;font-weight:700">{sys_mem_used_pct}%</span></div>'
        f'<div class="mbar-bg"><div class="mbar-fg" style="width:{sys_mem_used_pct}%;background:#f59e0b"></div></div></div>')

pss_bar_w = min(100, round(pss_mb / 6)) if pss_mb else 0
rss_bar_w = min(100, round(rss_mb / 6)) if rss_mb else 0

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{app_name} Performance Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:'Inter',system-ui,sans-serif;background:#0b0e1a;color:#e2e8f0;min-height:100vh}}
.hdr{{background:linear-gradient(135deg,#1a1f35 0%,#0f1628 60%,#1a1028 100%);padding:2rem 2.5rem 1.5rem;border-bottom:1px solid #2a2f4a}}
.hdr-title{{font-size:1.7rem;font-weight:800;background:linear-gradient(90deg,#60a5fa,#a78bfa,#f472b6);-webkit-background-clip:text;-webkit-text-fill-color:transparent;margin-bottom:.4rem}}
.hdr-sub{{color:#64748b;font-size:.85rem;margin-bottom:.8rem}}
.hdr-tags{{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.5rem}}
.hdr-tag{{background:#1e2235;border:1px solid #2a2f4a;border-radius:999px;padding:.2rem .75rem;font-size:.78rem;color:#94a3b8}}
.main{{padding:1.5rem 2rem;max-width:1400px;margin:0 auto}}
.section{{background:#111827;border:1px solid #1e2235;border-radius:1rem;padding:1.5rem;margin-bottom:1.5rem;animation:fadeUp .5s ease both}}
.section.fi{{opacity:0}}
@keyframes fadeUp{{from{{opacity:0;transform:translateY(20px)}}to{{opacity:1;transform:translateY(0)}}}}
.section.d1{{animation-delay:.1s}}.section.d2{{animation-delay:.2s}}.section.d3{{animation-delay:.3s}}.section.d4{{animation-delay:.4s}}
.stitle{{font-size:1.05rem;font-weight:700;color:#c4b5fd;margin-bottom:1rem;display:flex;align-items:center;gap:.5rem}}
.kgrid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:1rem}}
.kcard{{background:#1a1f35;border:1px solid #2a2f4a;border-radius:.75rem;padding:1rem;text-align:center}}
.kval{{font-size:1.5rem;font-weight:800;line-height:1.1}}
.klbl{{font-size:.72rem;color:#64748b;margin-top:.3rem;text-transform:uppercase;letter-spacing:.05em}}
.vrow{{display:flex;flex-wrap:wrap;gap:.75rem;margin-bottom:1rem}}
.vc{{border-radius:.5rem;padding:.5rem 1rem;font-size:.85rem;font-weight:500}}
.charts{{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:1rem;margin-top:1rem}}
.ccard{{background:#1a1f35;border:1px solid #2a2f4a;border-radius:.75rem;padding:1rem}}
.ccard h3{{font-size:.85rem;color:#94a3b8;margin-bottom:.75rem;font-weight:600}}
.cw{{position:relative;height:200px}}
.tcard{{overflow-x:auto}}
table{{width:100%;border-collapse:collapse;font-size:.85rem}}
th{{text-align:left;padding:.6rem 1rem;color:#64748b;font-weight:600;border-bottom:1px solid #1e2235;font-size:.78rem;text-transform:uppercase}}
td{{padding:.55rem 1rem;border-bottom:1px solid #1a1f35;color:#cbd5e1}}
tr:last-child td{{border-bottom:none}}
tr:hover td{{background:#1e2235}}
.tag{{border-radius:.3rem;padding:.15rem .5rem;font-size:.75rem;font-weight:600}}
.mbar-row{{margin-bottom:.8rem}}
.mbar-label{{display:flex;justify-content:space-between;font-size:.8rem;color:#94a3b8;margin-bottom:.3rem}}
.mbar-bg{{background:#1e2235;border-radius:4px;height:10px;overflow:hidden}}
.mbar-fg{{height:100%;border-radius:4px;transition:width .8s ease}}
.score-ring{{display:flex;flex-direction:column;align-items:center;justify-content:center}}
.score-ring svg{{width:120px;height:120px}}
.score-num{{font-size:1.8rem;font-weight:900}}
.score-lbl{{font-size:.7rem;color:#64748b;text-transform:uppercase;letter-spacing:.05em}}
.igrid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:1rem}}
.icard{{border-radius:.75rem;padding:1rem;display:flex;gap:.75rem;align-items:flex-start}}
.iicon{{font-size:1.4rem;line-height:1;flex-shrink:0;padding-top:.1rem}}
.ihead{{display:flex;justify-content:space-between;align-items:center;margin-bottom:.3rem;flex-wrap:wrap;gap:.4rem}}
.ititle{{font-weight:700;font-size:.9rem}}
.isev{{border-radius:999px;padding:.1rem .6rem;font-size:.72rem;font-weight:700}}
.idesc{{font-size:.82rem;color:#94a3b8;line-height:1.5}}
.note403{{background:#451a1a22;border:1px solid #ef444455;border-radius:.5rem;padding:.75rem 1rem;margin-top:.75rem;font-size:.82rem;color:#fc8181;line-height:1.5}}
.jstats{{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:1rem;margin-top:1rem}}
.jstat{{background:#1a1f35;border:1px solid #2a2f4a;border-radius:.75rem;padding:1.1rem;text-align:center}}
.jstat-lbl{{font-size:.7rem;color:#64748b;text-transform:uppercase;letter-spacing:.07em;margin-bottom:.35rem}}
.jstat-name{{font-size:.85rem;font-weight:600;margin-bottom:.25rem}}
.jstat-val{{font-size:1.7rem;font-weight:800}}
footer{{text-align:center;padding:2rem;color:#374151;font-size:.8rem;border-top:1px solid #1e2235;margin-top:1rem}}
footer strong{{color:#6366f1}}
</style>
</head>
<body>
<div class="hdr">
  <div class="hdr-title">{app_name} \u2014 Performance Report</div>
  <div class="hdr-sub">Run ID: {run_id}</div>
  <div class="hdr-tags">{tag_ver}{tag_pkg}{tag_dev}{tag_and}{tag_apk}</div>
</div>
<div class="main">

<!-- VERDICTS -->
<div class="section d1">
  <div class="stitle">&#127942; Overall Verdict</div>
  <div class="vrow">{verdict_html}</div>
  <div style="display:flex;align-items:center;gap:2rem;flex-wrap:wrap">
    <div class="score-ring">
      <svg viewBox="0 0 120 120">
        <circle cx="60" cy="60" r="50" fill="none" stroke="#1e2235" stroke-width="12"/>
        <circle cx="60" cy="60" r="50" fill="none" stroke="{score_c}" stroke-width="12"
          stroke-dasharray="314" stroke-dashoffset="{score_dash}"
          stroke-linecap="round" transform="rotate(-90 60 60)"
          style="transition:stroke-dashoffset 1s ease"/>
      </svg>
      <div class="score-num" style="color:{score_c}">{perf_score if perf_score is not None else "?"}</div>
      <div class="score-lbl">Perf Score</div>
    </div>
    <div style="flex:1;min-width:220px">
      <div class="kgrid">
        <div class="kcard"><div class="kval" style="color:{cold_color}">{fi(cold_avg," ms")}</div><div class="klbl">Cold Start Avg</div></div>
        <div class="kcard"><div class="kval" style="color:{cold_color}">{fi(cold_p95," ms")}</div><div class="klbl">Cold Start p95</div></div>
        <div class="kcard"><div class="kval" style="color:{tti_color}">{fi(tti_avg," ms")}</div><div class="klbl">TTI Proxy Avg</div></div>
        <div class="kcard"><div class="kval" style="color:{pss_color}">{fi(pss_mb," MB")}</div><div class="klbl">PSS Memory</div></div>
        <div class="kcard"><div class="kval" style="color:{jank_color}">{fv(jp_val," %")}</div><div class="klbl">Jank Rate</div></div>
        <div class="kcard"><div class="kval" style="color:{cpu_color}">{fv(cpu_avg_busy," %")}</div><div class="klbl">CPU Busy Avg</div></div>
        <div class="kcard"><div class="kval" style="color:{anr_c}">{anr_str}</div><div class="klbl">ANR</div></div>
      </div>
    </div>
  </div>
</div>

<!-- ENGINEERING INSIGHTS -->
<div class="section fi d1">
  <div class="stitle">&#128161; Engineering Insights &amp; Action Items</div>
  <div class="igrid">{insight_html}</div>
</div>

<!-- LAUNCH + GFX CHARTS -->
<div class="section fi d2">
  <div class="stitle">&#128640; Launch &amp; Rendering Performance</div>
  <div class="charts">
    {cold_chart_div}
    {frame_chart_div}
    {jank_pie_div}
    {cpu_div}
    {api_chart_div}
  </div>
</div>

<!-- GFX TABLE -->
<div class="section fi d2">
  <div class="stitle">&#127916; Frame Rendering Details</div>
  <div class="tcard"><table><tbody>{gfx_html}</tbody></table></div>
</div>

<!-- MEMORY -->
<div class="section fi d2">
  <div class="stitle">&#129504; Memory Profile</div>
  <div style="max-width:520px">
    <div class="mbar-row">
      <div class="mbar-label"><span>App PSS</span><span style="color:{pss_color};font-weight:700">{fi(pss_mb," MB")}</span></div>
      <div class="mbar-bg"><div class="mbar-fg" style="width:{pss_bar_w}%;background:{pss_color}"></div></div>
    </div>
    <div class="mbar-row">
      <div class="mbar-label"><span>App RSS</span><span style="color:{tc(rss_kb,200000,350000)};font-weight:700">{fi(rss_mb," MB")}</span></div>
      <div class="mbar-bg"><div class="mbar-fg" style="width:{rss_bar_w}%;background:{tc(rss_kb,200000,350000)}"></div></div>
    </div>
    {mem_bar_device}
  </div>
</div>

{api_section}
{journey_section}
{flow_section}

</div><!-- /main -->

<footer>Design and Developed by <strong>Abhinav Anshuman</strong></footer>

<script>
Chart.defaults.color = '#64748b';
Chart.defaults.borderColor = '#1e2235';

(function(){{
  var el = document.getElementById('coldChart');
  if(!el) return;
  new Chart(el, {{
    type:'bar',
    data:{{
      labels:{cold_json}.map((_,i)=>'Run '+(i+1)),
      datasets:[{{
        label:'Cold Start (ms)',
        data:{cold_json},
        backgroundColor:'rgba(96,165,250,0.7)',
        borderColor:'#60a5fa',
        borderWidth:1,
        borderRadius:4
      }}]
    }},
    options:{{
      responsive:true,maintainAspectRatio:false,
      plugins:{{legend:{{display:false}}}},
      scales:{{
        x:{{grid:{{color:'#1e2235'}}}},
        y:{{grid:{{color:'#1e2235'}},title:{{display:true,text:'ms',color:'#64748b'}}}}
      }}
    }}
  }});
}})();

(function(){{
  var el = document.getElementById('frameChart');
  if(!el) return;
  new Chart(el, {{
    type:'bar',
    data:{{
      labels:['p50','p90','p95','p99'],
      datasets:[{{
        label:'Frame Time (ms)',
        data:{frame_json},
        backgroundColor:['rgba(34,197,94,0.7)','rgba(251,191,36,0.7)','rgba(251,146,60,0.7)','rgba(239,68,68,0.7)'],
        borderColor:['#22c55e','#fbbf24','#fb923c','#ef4444'],
        borderWidth:1,
        borderRadius:4
      }}]
    }},
    options:{{
      responsive:true,maintainAspectRatio:false,
      plugins:{{legend:{{display:false}}}},
      scales:{{
        x:{{grid:{{color:'#1e2235'}}}},
        y:{{grid:{{color:'#1e2235'}},title:{{display:true,text:'ms',color:'#64748b'}}}}
      }}
    }}
  }});
}})();

(function(){{
  var el = document.getElementById('jankPie');
  if(!el) return;
  new Chart(el, {{
    type:'doughnut',
    data:{{
      labels:['Smooth','Janky'],
      datasets:[{{
        data:[{jank_good_v},{jank_bad_v}],
        backgroundColor:['rgba(34,197,94,0.8)','rgba(239,68,68,0.8)'],
        borderColor:['#22c55e','#ef4444'],
        borderWidth:2
      }}]
    }},
    options:{{
      responsive:true,maintainAspectRatio:false,
      plugins:{{legend:{{position:'bottom',labels:{{padding:16,font:{{size:12}}}}}}}}
    }}
  }});
}})();

(function(){{
  var el = document.getElementById('cpuChart');
  if(!el) return;
  new Chart(el, {{
    type:'line',
    data:{{
      labels:{cpu_l_json},
      datasets:[{{
        label:'CPU Busy %',
        data:{cpu_d_json},
        borderColor:'#a78bfa',
        backgroundColor:'rgba(167,139,250,0.15)',
        tension:0.4,
        fill:true,
        pointRadius:2
      }}]
    }},
    options:{{
      responsive:true,maintainAspectRatio:false,
      plugins:{{legend:{{display:false}}}},
      scales:{{
        x:{{grid:{{color:'#1e2235'}},title:{{display:true,text:'Sample',color:'#64748b'}}}},
        y:{{grid:{{color:'#1e2235'}},min:0,max:100,title:{{display:true,text:'%',color:'#64748b'}}}}
      }}
    }}
  }});
}})();

(function(){{
  var el = document.getElementById('apiChart');
  if(!el) return;
  new Chart(el, {{
    type:'bar',
    data:{{
      labels:{api_l_json},
      datasets:[
        {{label:'p95',data:{api_p95_j},backgroundColor:'rgba(251,146,60,0.7)',borderColor:'#fb923c',borderWidth:1,borderRadius:3}},
        {{label:'p99',data:{api_p99_j},backgroundColor:'rgba(239,68,68,0.7)',borderColor:'#ef4444',borderWidth:1,borderRadius:3}}
      ]
    }},
    options:{{
      responsive:true,maintainAspectRatio:false,
      plugins:{{legend:{{position:'bottom'}}}},
      scales:{{
        x:{{grid:{{color:'#1e2235'}}}},
        y:{{grid:{{color:'#1e2235'}},title:{{display:true,text:'ms',color:'#64748b'}}}}
      }}
    }}
  }});
}})();

(function(){{
  var el = document.getElementById('apiChartFull');
  if(!el) return;
  new Chart(el, {{
    type:'bar',
    data:{{
      labels:{api_l_json},
      datasets:[
        {{label:'P50',data:{api_p50_j},backgroundColor:'rgba(34,197,94,0.7)',borderColor:'#22c55e',borderWidth:1,borderRadius:3}},
        {{label:'P95',data:{api_p95_j},backgroundColor:'rgba(251,146,60,0.7)',borderColor:'#fb923c',borderWidth:1,borderRadius:3}},
        {{label:'P99',data:{api_p99_j},backgroundColor:'rgba(239,68,68,0.7)',borderColor:'#ef4444',borderWidth:1,borderRadius:3}}
      ]
    }},
    options:{{
      responsive:true,maintainAspectRatio:false,
      plugins:{{legend:{{position:'bottom'}}}},
      scales:{{
        x:{{grid:{{color:'#1e2235'}}}},
        y:{{grid:{{color:'#1e2235'}},title:{{display:true,text:'ms',color:'#64748b'}}}}
      }}
    }}
  }});
}})();

(function(){{
  var el = document.getElementById('journeyChartFull');
  if(!el) return;
  new Chart(el, {{
    type:'bar',
    data:{{
      labels:{jny_l_json},
      datasets:[{{
        label:'Load Time (ms)',
        data:{jny_d_json},
        backgroundColor:'rgba(167,139,250,0.7)',
        borderColor:'#a78bfa',
        borderWidth:1,
        borderRadius:4
      }}]
    }},
    options:{{
      indexAxis:'y',
      responsive:true,maintainAspectRatio:false,
      plugins:{{legend:{{display:false}}}},
      scales:{{
        x:{{grid:{{color:'#1e2235'}},title:{{display:true,text:'ms',color:'#64748b'}}}},
        y:{{grid:{{color:'#1e2235'}}}}
      }}
    }}
  }});
}})();

document.querySelectorAll('.fi').forEach(function(el,i){{
  el.style.animationDelay=(0.08*i+0.1)+'s';
  el.style.opacity='0';
  setTimeout(function(){{el.style.opacity=''}}, 50);
}});
</script>
</body>
</html>"""

Path(HTML_OUT).write_text(html, encoding="utf-8")
print(f"Report written to {HTML_OUT} ({len(html)} chars)")
