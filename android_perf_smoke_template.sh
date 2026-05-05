#!/usr/bin/env bash
set -euo pipefail

# Android Performance Smoke Template
#
# Use this for any Android app, not just TripMeet.
#
# Before running:
# 1. Connect phone with USB debugging ON
# 2. Keep phone unlocked
# 3. Keep target app installed on device
# 4. Fill parameters below via env vars or inline before command
#
# Example:
#   PKG="com.example.app" \
#   ACT="com.example.app.MainActivity" \
#   APP_NAME="Example App" \
#   BASE_URL="https://api.example.com" \
#   PING_HOST="api.example.com" \
#   RUNS=5 \
#   FLOW_JSON="/absolute/path/flow.json" \
#   USER_JOURNEY_JSON="/absolute/path/user_journey.json" \
#   API_ENDPOINTS_JSON="/absolute/path/api_endpoints.json" \
#   bash scripts/android_perf_smoke_template.sh
#
# Optional custom output folder:
#   PKG="com.example.app" ACT="com.example.app.MainActivity" \
#   bash scripts/android_perf_smoke_template.sh reports/android_perf/example_app_run_01

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
PKG="${PKG:-}"
ACT="${ACT:-}"
APP_NAME="${APP_NAME:-Android App}"
BASE_URL="${BASE_URL:-}"
PING_HOST="${PING_HOST:-}"
RUNS="${RUNS:-5}"
FLOW_JSON="${FLOW_JSON:-}"
USER_JOURNEY_JSON="${USER_JOURNEY_JSON:-}"
API_ENDPOINTS_JSON="${API_ENDPOINTS_JSON:-}"
OUT_DIR="${1:-$ROOT_DIR/reports/android_perf/$(date +%Y%m%d_%H%M%S)_${PKG##*.}}"

usage() {
  cat <<EOF
Usage:
  PKG="com.example.app" ACT="com.example.MainActivity" bash scripts/android_perf_smoke_template.sh

Required env vars:
  PKG                 Android package name
  ACT                 Fully qualified launch activity

Optional env vars:
  APP_NAME            Friendly app name for summary output
  ADB                 Absolute path to adb
  BASE_URL            Base URL for API latency checks, e.g. https://api.example.com
  PING_HOST           Host to ping from device, e.g. api.example.com
  RUNS                Number of cold-start runs (default: 5)
  FLOW_JSON           Path to JSON file defining full tap-by-tap app flows
  USER_JOURNEY_JSON   Path to JSON file defining tappable screens to measure
  API_ENDPOINTS_JSON  Path to JSON file defining URLs/endpoints to latency test

JSON format for FLOW_JSON:
  {
    "flows": [
      {
        "name": "profile_flow",
        "steps": [
          {"action":"launch"},
          {"action":"tap","x":950,"y":2239,"label":"Open Profile"},
          {"action":"assert_pattern","pattern":"Profile|Account","timeout_ms":5000},
          {"action":"tap","x":540,"y":1800,"label":"Open Preferences"},
          {"action":"wait","ms":1500},
          {"action":"back"}
        ]
      }
    ]
  }

JSON format for USER_JOURNEY_JSON:
  [
    {"screen":"Home","tap":[120,2200],"pattern":"Home|Dashboard"},
    {"screen":"Profile","tap":[950,2200],"pattern":"Profile|My Account"}
  ]

JSON format for API_ENDPOINTS_JSON:
  [
    {"name":"health","url":"https://api.example.com/health"},
    {"name":"feed","url":"https://api.example.com/feed"}
  ]

EOF
}

if [[ -z "$PKG" || -z "$ACT" ]]; then
  usage
  exit 1
fi

mkdir -p "$OUT_DIR"

if [[ ! -x "$ADB" ]]; then
  echo "adb not found at $ADB" >&2
  exit 1
fi

if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "No Android device detected by adb" >&2
  exit 1
fi

if ! "$ADB" shell pm list packages | grep -q "$PKG"; then
  echo "Package $PKG is not installed on the connected device" >&2
  exit 1
fi

if [[ -z "$PING_HOST" && -n "$BASE_URL" ]]; then
  PING_HOST="$(python3 - <<PY
from urllib.parse import urlparse
print(urlparse('$BASE_URL').hostname or '')
PY
)"
fi

APP_UID="$($ADB shell dumpsys package "$PKG" | sed -n 's/.*userId=//p' | head -1 | tr -dc '0-9')"
DEVICE_MODEL="$($ADB shell getprop ro.product.model | tr -d '\r')"
ANDROID_VER="$($ADB shell getprop ro.build.version.release | tr -d '\r')"
VERSION_INFO="$($ADB shell dumpsys package "$PKG" | grep -E 'versionName=|versionCode=|lastUpdateTime=' | tr -d '\r')"

{
  echo "app_name=$APP_NAME"
  echo "device_model=$DEVICE_MODEL"
  echo "android_version=$ANDROID_VER"
  echo "package=$PKG"
  echo "activity=$ACT"
  echo "uid=$APP_UID"
  echo "base_url=$BASE_URL"
  echo "ping_host=$PING_HOST"
  echo "$VERSION_INFO"
} > "$OUT_DIR/device_info.txt"

"$ADB" shell dumpsys battery > "$OUT_DIR/battery_state.txt"
"$ADB" shell dumpsys gfxinfo "$PKG" reset >/dev/null 2>&1 || true
"$ADB" shell am force-stop "$PKG" || true

: > "$OUT_DIR/launch_runs.txt"
for i in $(seq 1 "$RUNS"); do
  {
    echo "RUN $i"
    "$ADB" shell am force-stop "$PKG"
    sleep 2
    "$ADB" shell am start -W -n "$PKG/$ACT"
    sleep 8
    "$ADB" shell input keyevent KEYCODE_HOME
    sleep 2
  } >> "$OUT_DIR/launch_runs.txt"
done

python3 - "$OUT_DIR/launch_runs.txt" <<'PY' > "$OUT_DIR/launch_summary.json"
import json, re, statistics, sys
text = open(sys.argv[1], 'r', encoding='utf-8').read()
total = [int(x) for x in re.findall(r'TotalTime:\s*(\d+)', text)]
wait = [int(x) for x in re.findall(r'WaitTime:\s*(\d+)', text)]

def summary(vals):
    s = sorted(vals)
    if not s:
        return {}
    def pct(p):
        idx = min(len(s)-1, max(0, round((p/100)*(len(s)-1))))
        return s[idx]
    return {
        'samples_ms': vals,
        'avg_ms': round(statistics.mean(vals), 2),
        'min_ms': min(vals),
        'p50_ms': pct(50),
        'p95_ms': pct(95),
        'p99_ms': pct(99),
        'max_ms': max(vals),
    }

print(json.dumps({'total_time': summary(total), 'wait_time': summary(wait)}, indent=2))
PY

python3 - "$ADB" "$PKG" "$ACT" "$FLOW_JSON" "$APP_UID" <<'PY' > "$OUT_DIR/flow_results.json"
import json, pathlib, re, subprocess, sys, time

adb, pkg, act, flow_path, app_uid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]


def normalize_flow_entries(config):
  if isinstance(config, dict):
    flows = config.get('flows', [])
  elif isinstance(config, list):
    flows = config
  else:
    flows = []

  normalized = []
  for index, flow in enumerate(flows, start=1):
    if not isinstance(flow, dict):
      normalized.append({
        'name': f'invalid_flow_{index}',
        'steps': [],
        'invalid_reason': f'Flow entry must be an object, got {type(flow).__name__}',
      })
      continue

    steps = flow.get('steps', [])
    if not isinstance(steps, list):
      steps = []

    normalized_steps = []
    for step_index, step in enumerate(steps, start=1):
      if isinstance(step, dict):
        normalized_steps.append(step)
      else:
        normalized_steps.append({
          'action': 'invalid_step',
          'label': f'Invalid step {step_index}',
          'continue_on_failure': True,
          'error': f'Step must be an object, got {type(step).__name__}',
          'raw_value': step,
        })

    normalized.append({
      'name': flow.get('name', f'unnamed_flow_{index}'),
      'steps': normalized_steps,
      'invalid_reason': flow.get('invalid_reason'),
    })

  return normalized

def run_cmd(args, quiet=False):
  return subprocess.run(args, stdout=subprocess.DEVNULL if quiet else None, stderr=subprocess.DEVNULL if quiet else None, text=True)

def dump_xml():
  run_cmd([adb, 'shell', 'uiautomator', 'dump', '/sdcard/uidump.xml'], quiet=True)
  return subprocess.check_output([adb, 'shell', 'cat', '/sdcard/uidump.xml'], text=True, stderr=subprocess.DEVNULL)

def shell_text(args):
  try:
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
  except Exception:
    return ''

def parse_meminfo(text):
  def grab(pattern):
    m = re.search(pattern, text)
    return int(m.group(1)) if m else None
  return {
    'pss_kb': grab(r'TOTAL PSS:\s+(\d+)'),
    'rss_kb': grab(r'TOTAL RSS:\s+(\d+)'),
    'swap_pss_kb': grab(r'TOTAL SWAP PSS:\s+(\d+)'),
  }

def parse_top_cpu(text):
  for line in text.splitlines():
    if pkg not in line:
      continue
    for token in line.split():
      cleaned = token.rstrip('%')
      try:
        return float(cleaned)
      except ValueError:
        continue
  return None

def parse_gfxinfo(text):
  def grab(pattern, cast=int):
    m = re.search(pattern, text)
    return cast(m.group(1)) if m else None
  def grab_pct(pattern):
    m = re.search(pattern, text)
    return m.group(2) if m else None
  return {
    'total_frames': grab(r'Total frames rendered:\s+(\d+)'),
    'janky_frames': grab(r'Janky frames:\s+(\d+)\s+\(([^)]+)\)'),
    'janky_pct': grab_pct(r'Janky frames:\s+(\d+)\s+\(([^)]+)\)'),
    'p50_ms': grab(r'50th percentile:\s+(\d+)ms'),
    'p90_ms': grab(r'90th percentile:\s+(\d+)ms'),
    'p95_ms': grab(r'95th percentile:\s+(\d+)ms'),
    'p99_ms': grab(r'99th percentile:\s+(\d+)ms'),
    'missed_vsync': grab(r'Number Missed Vsync:\s+(\d+)'),
    'high_input_latency': grab(r'Number High input latency:\s+(\d+)'),
    'slow_ui_thread': grab(r'Number Slow UI thread:\s+(\d+)'),
    'slow_draw_commands': grab(r'Number Slow issue draw commands:\s+(\d+)'),
  }

def parse_choreographer(text):
  skipped = [int(x) for x in re.findall(r'Skipped\s+(\d+)\s+frames', text, flags=re.IGNORECASE)]
  lines = [line for line in text.splitlines() if line.strip()]
  return {
    'warning_lines': len(lines),
    'max_skipped_frames': max(skipped) if skipped else None,
  }

def parse_netstats(text):
  rx_vals = [int(x) for x in re.findall(r'rxBytes[=:]\s*(\d+)', text)]
  tx_vals = [int(x) for x in re.findall(r'txBytes[=:]\s*(\d+)', text)]
  if not rx_vals and not tx_vals:
    return {'rx_bytes': None, 'tx_bytes': None}
  return {'rx_bytes': sum(rx_vals) if rx_vals else None, 'tx_bytes': sum(tx_vals) if tx_vals else None}

def capture_resource_snapshot():
  meminfo = parse_meminfo(shell_text([adb, 'shell', 'dumpsys', 'meminfo', pkg]))
  cpu_pct = parse_top_cpu(shell_text([adb, 'shell', 'top', '-b', '-n', '1']))
  gfx = parse_gfxinfo(shell_text([adb, 'shell', 'dumpsys', 'gfxinfo', pkg]))
  choreo = parse_choreographer(shell_text([adb, 'shell', 'logcat', '-d', '-s', 'Choreographer:I']))
  netstats = parse_netstats(shell_text([adb, 'shell', 'dumpsys', 'netstats', 'detail'])) if app_uid else {'rx_bytes': None, 'tx_bytes': None}
  return {
    'app_cpu_pct': cpu_pct,
    'app_memory': meminfo,
    'gfx': gfx,
    'choreographer': choreo,
    'network': netstats,
  }

def diff_metric(before, after):
  if before is None or after is None:
    return None
  return after - before

def build_resource_delta(before, after):
  return {
    'app_cpu_pct_before': before.get('app_cpu_pct'),
    'app_cpu_pct_after': after.get('app_cpu_pct'),
    'app_cpu_pct_delta': diff_metric(before.get('app_cpu_pct'), after.get('app_cpu_pct')),
    'app_pss_kb_before': before.get('app_memory', {}).get('pss_kb'),
    'app_pss_kb_after': after.get('app_memory', {}).get('pss_kb'),
    'app_pss_kb_delta': diff_metric(before.get('app_memory', {}).get('pss_kb'), after.get('app_memory', {}).get('pss_kb')),
    'app_rss_kb_before': before.get('app_memory', {}).get('rss_kb'),
    'app_rss_kb_after': after.get('app_memory', {}).get('rss_kb'),
    'app_rss_kb_delta': diff_metric(before.get('app_memory', {}).get('rss_kb'), after.get('app_memory', {}).get('rss_kb')),
    'gfx_total_frames_delta': diff_metric(before.get('gfx', {}).get('total_frames'), after.get('gfx', {}).get('total_frames')),
    'gfx_janky_frames_delta': diff_metric(before.get('gfx', {}).get('janky_frames'), after.get('gfx', {}).get('janky_frames')),
    'missed_vsync_delta': diff_metric(before.get('gfx', {}).get('missed_vsync'), after.get('gfx', {}).get('missed_vsync')),
    'slow_ui_thread_delta': diff_metric(before.get('gfx', {}).get('slow_ui_thread'), after.get('gfx', {}).get('slow_ui_thread')),
    'slow_draw_commands_delta': diff_metric(before.get('gfx', {}).get('slow_draw_commands'), after.get('gfx', {}).get('slow_draw_commands')),
    'choreographer_warning_lines_delta': diff_metric(before.get('choreographer', {}).get('warning_lines'), after.get('choreographer', {}).get('warning_lines')),
    'max_skipped_frames_after': after.get('choreographer', {}).get('max_skipped_frames'),
    'network_rx_bytes_delta': diff_metric(before.get('network', {}).get('rx_bytes'), after.get('network', {}).get('rx_bytes')),
    'network_tx_bytes_delta': diff_metric(before.get('network', {}).get('tx_bytes'), after.get('network', {}).get('tx_bytes')),
  }

def wait_for_pattern(pattern, timeout_ms=5000, interval_ms=250):
  start = time.time()
  polls = 0
  while (time.time() - start) * 1000 < timeout_ms:
    polls += 1
    time.sleep(interval_ms / 1000)
    xml = dump_xml()
    if re.search(pattern, xml):
      return {'matched': True, 'elapsed_ms': int((time.time() - start) * 1000), 'polls': polls}
  return {'matched': False, 'elapsed_ms': int((time.time() - start) * 1000), 'polls': polls}

def do_step(step):
  if not isinstance(step, dict):
    return {
      'action': 'invalid_step',
      'label': 'invalid_step',
      'ok': False,
      'error': f'Step must be an object, got {type(step).__name__}',
      'elapsed_ms': 0,
    }

  action = (step.get('action') or '').strip().lower()
  label = step.get('label') or action
  start = time.time()
  result = {'action': action, 'label': label, 'ok': True}

  if action == 'invalid_step':
    result['ok'] = False
    result['error'] = step.get('error', 'Invalid step entry')
    result['raw_value'] = step.get('raw_value')
    result['elapsed_ms'] = int((time.time() - start) * 1000)
    return result

  if action == 'launch':
    run_cmd([adb, 'shell', 'am', 'start', '-n', f'{pkg}/{act}'], quiet=True)
  elif action == 'force_stop':
    run_cmd([adb, 'shell', 'am', 'force-stop', pkg], quiet=True)
  elif action == 'home':
    run_cmd([adb, 'shell', 'input', 'keyevent', 'KEYCODE_HOME'], quiet=True)
  elif action == 'back':
    run_cmd([adb, 'shell', 'input', 'keyevent', 'KEYCODE_BACK'], quiet=True)
  elif action == 'tap':
    run_cmd([adb, 'shell', 'input', 'tap', str(step['x']), str(step['y'])], quiet=True)
  elif action == 'swipe':
    duration = str(step.get('duration_ms', 400))
    run_cmd([adb, 'shell', 'input', 'swipe', str(step['x1']), str(step['y1']), str(step['x2']), str(step['y2']), duration], quiet=True)
  elif action == 'text':
    text = str(step.get('text', '')).replace(' ', '%s')
    run_cmd([adb, 'shell', 'input', 'text', text], quiet=True)
  elif action == 'keyevent':
    run_cmd([adb, 'shell', 'input', 'keyevent', str(step['keycode'])], quiet=True)
  elif action == 'wait':
    time.sleep(int(step.get('ms', 1000)) / 1000)
  elif action == 'assert_pattern':
    outcome = wait_for_pattern(step.get('pattern', ''), int(step.get('timeout_ms', 5000)), int(step.get('interval_ms', 250)))
    result.update(outcome)
    result['ok'] = outcome['matched']
  elif action == 'wait_for_pattern':
    outcome = wait_for_pattern(step.get('pattern', ''), int(step.get('timeout_ms', 5000)), int(step.get('interval_ms', 250)))
    result.update(outcome)
    result['ok'] = outcome['matched']
  elif action == 'dump':
    xml = dump_xml()
    result['xml_excerpt'] = xml[:1000]
  else:
    result['ok'] = False
    result['error'] = f'Unknown action: {action}'

  result['elapsed_ms'] = int((time.time() - start) * 1000)
  time.sleep(0.4)
  return result

final = {'flows': [], 'note': ''}
if flow_path and pathlib.Path(flow_path).exists():
  config = json.loads(pathlib.Path(flow_path).read_text())
  flows = normalize_flow_entries(config)
  for flow in flows:
    flow_name = flow.get('name', 'unnamed_flow')
    steps = flow.get('steps', [])
    flow_result = {'name': flow_name, 'steps': [], 'success': True}
    if flow.get('invalid_reason'):
      flow_result['warning'] = flow['invalid_reason']
    for step in steps:
      before_snapshot = capture_resource_snapshot()
      step_result = do_step(step)
      after_snapshot = capture_resource_snapshot()
      step_result['resource_delta'] = build_resource_delta(before_snapshot, after_snapshot)
      flow_result['steps'].append(step_result)
      if not step_result.get('ok', False):
        flow_result['success'] = False
        if not step.get('continue_on_failure', False):
          break
    final['flows'].append(flow_result)
else:
  final['note'] = 'No FLOW_JSON provided, deep feature flow execution skipped'

print(json.dumps(final, indent=2))
PY

"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$ADB" shell input swipe 540 2000 540 800 300 >/dev/null 2>&1 || true
"$ADB" shell am start -n "$PKG/$ACT" >/dev/null 2>&1 || true
sleep 4

python3 - "$ADB" "$USER_JOURNEY_JSON" <<'PY' > "$OUT_DIR/user_journey_summary.json"
import json, pathlib, re, subprocess, sys, time

adb = sys.argv[1]
journey_path = sys.argv[2]

results = []

def dump_xml():
    subprocess.run([adb, 'shell', 'uiautomator', 'dump', '/sdcard/uidump.xml'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return subprocess.check_output([adb, 'shell', 'cat', '/sdcard/uidump.xml'], text=True, stderr=subprocess.DEVNULL)

if journey_path and pathlib.Path(journey_path).exists():
  sequence = json.loads(pathlib.Path(journey_path).read_text())
  if not isinstance(sequence, list):
    sequence = []
  for item in sequence:
    if not isinstance(item, dict):
      results.append({'screen': 'Unknown', 'load_ms_upper_bound': None, 'error': f'invalid config entry type: {type(item).__name__}'})
      continue
    name = item.get('screen', 'Unknown')
    tap = item.get('tap') or []
    pattern = item.get('pattern', '')
    if len(tap) != 2 or not pattern:
      results.append({'screen': name, 'load_ms_upper_bound': None, 'error': 'invalid config'})
      continue
    subprocess.run([adb, 'shell', 'input', 'tap', str(tap[0]), str(tap[1])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    start = time.time()
    value = None
    polls = 0
    for i in range(1, 41):
      polls = i
      time.sleep(0.25)
      xml = dump_xml()
      if re.search(pattern, xml):
        value = int((time.time() - start) * 1000)
        break
    results.append({'screen': name, 'load_ms_upper_bound': value, 'polls': polls})
else:
    results.append({'screen': 'user_journey', 'load_ms_upper_bound': None, 'note': 'No USER_JOURNEY_JSON provided, journey timing skipped'})

print(json.dumps(results, indent=2))
PY

"$ADB" shell dumpsys meminfo "$PKG" > "$OUT_DIR/meminfo.txt"
"$ADB" shell cat /proc/meminfo > "$OUT_DIR/system_meminfo.txt"
"$ADB" shell top -b -n 1 | grep "$PKG" > "$OUT_DIR/cpu_top_snapshot.txt" || true
"$ADB" shell dumpsys cpuinfo > "$OUT_DIR/system_cpuinfo.txt" || true

python3 - "$ADB" "$PKG" <<'PY' > "$OUT_DIR/cpu_idle_samples.json"
import json, statistics, subprocess, sys, time
adb, pkg = sys.argv[1], sys.argv[2]
vals = []
for _ in range(8):
    out = subprocess.check_output([adb, 'shell', 'top', '-b', '-n', '1'], text=True, stderr=subprocess.DEVNULL)
    for line in out.splitlines():
        if pkg in line:
            parts = line.split()
            try:
                vals.append(float(parts[8]))
            except Exception:
                pass
            break
    time.sleep(2)
print(json.dumps({'samples': vals, 'avg_cpu_pct': round(statistics.mean(vals), 2) if vals else None, 'max_cpu_pct': max(vals) if vals else None}, indent=2))
PY

APK_PATH="$($ADB shell pm path "$PKG" | head -1 | tr -d '\r' | sed 's/^package://')"
echo "$APK_PATH" > "$OUT_DIR/apk_path.txt"
"$ADB" shell ls -lh "$APK_PATH" > "$OUT_DIR/apk_size.txt"
"$ADB" shell dumpsys gfxinfo "$PKG" > "$OUT_DIR/gfxinfo.txt"
"$ADB" shell dumpsys batterystats "$PKG" > "$OUT_DIR/batterystats.txt"
"$ADB" shell dumpsys activity exit-info "$PKG" > "$OUT_DIR/exit_info.txt"
"$ADB" shell logcat -d | grep -i "ANR\|FATAL EXCEPTION\|$PKG" | tail -200 > "$OUT_DIR/stability_log_excerpt.txt" || true
"$ADB" shell logcat -d | grep -i "Choreographer\|Skipped [0-9].*frames" | tail -200 > "$OUT_DIR/choreographer_log_excerpt.txt" || true
"$ADB" shell dumpsys netstats | grep -n "${APP_UID}\|$PKG" | head -120 > "$OUT_DIR/netstats_excerpt.txt" || true

if [[ -n "$PING_HOST" ]]; then
  "$ADB" shell ping -c 5 "$PING_HOST" > "$OUT_DIR/ping_host.txt" || "$ADB" shell toybox ping -c 5 "$PING_HOST" > "$OUT_DIR/ping_host.txt" || true
else
  echo "PING skipped: no PING_HOST provided" > "$OUT_DIR/ping_host.txt"
fi

python3 - "$BASE_URL" "$API_ENDPOINTS_JSON" <<'PY' > "$OUT_DIR/api_latency_summary.json"
import json, pathlib, statistics, sys, time, urllib.request

base = sys.argv[1].rstrip('/')
config = sys.argv[2]
summary = {}
targets = []

if config and pathlib.Path(config).exists():
    targets = json.loads(pathlib.Path(config).read_text())
elif base:
    targets = [
        {'name': 'healthz', 'url': f'{base}/healthz'},
        {'name': 'readyz', 'url': f'{base}/readyz'},
    ]
else:
    print(json.dumps({'note': 'No BASE_URL or API_ENDPOINTS_JSON provided, API latency skipped'}, indent=2))
    raise SystemExit(0)

for item in targets:
    name = item.get('name', 'endpoint')
    url = item.get('url')
    if not url:
        continue
    vals = []
    statuses = []
    for _ in range(20):
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(url, timeout=20) as resp:
                resp.read(2048)
                statuses.append(resp.status)
        except Exception as exc:
            statuses.append(str(exc))
        vals.append((time.perf_counter() - start) * 1000)
    s = sorted(vals)
    def pct(p):
        idx = min(len(s)-1, max(0, round((p/100)*(len(s)-1))))
        return round(s[idx], 2)
    summary[name] = {
        'url': url,
        'count': len(vals),
        'statuses': sorted({str(x) for x in statuses}),
        'avg_ms': round(statistics.mean(vals), 2),
        'min_ms': round(min(vals), 2),
        'p50_ms': pct(50),
        'p95_ms': pct(95),
        'p99_ms': pct(99),
        'max_ms': round(max(vals), 2),
    }

print(json.dumps(summary, indent=2))
PY

python3 - "$OUT_DIR" "$APP_NAME" <<'PY' > "$OUT_DIR/SUMMARY.md"
import json, pathlib, re, sys

out = pathlib.Path(sys.argv[1])
app_name = sys.argv[2]
launch = json.loads((out / 'launch_summary.json').read_text())
journey = json.loads((out / 'user_journey_summary.json').read_text())
cpu_idle = json.loads((out / 'cpu_idle_samples.json').read_text())
api = json.loads((out / 'api_latency_summary.json').read_text())
flows = json.loads((out / 'flow_results.json').read_text())
mem = (out / 'meminfo.txt').read_text()
system_mem = (out / 'system_meminfo.txt').read_text() if (out / 'system_meminfo.txt').exists() else ''
ping = (out / 'ping_host.txt').read_text() if (out / 'ping_host.txt').exists() else ''
apk = (out / 'apk_size.txt').read_text() if (out / 'apk_size.txt').exists() else ''
exit_info = (out / 'exit_info.txt').read_text()
cpu_snap = (out / 'cpu_top_snapshot.txt').read_text() if (out / 'cpu_top_snapshot.txt').exists() else ''
system_cpu = (out / 'system_cpuinfo.txt').read_text() if (out / 'system_cpuinfo.txt').exists() else ''
choreo = (out / 'choreographer_log_excerpt.txt').read_text() if (out / 'choreographer_log_excerpt.txt').exists() else ''
gfx = (out / 'gfxinfo.txt').read_text() if (out / 'gfxinfo.txt').exists() else ''

pss = re.search(r'TOTAL PSS:\s+(\d+)', mem)
rss = re.search(r'TOTAL RSS:\s+(\d+)', mem)
swap = re.search(r'TOTAL SWAP PSS:\s+(\d+)', mem)
peak_cpu_match = re.search(r'\s([0-9]+\.?[0-9]*)\s+[0-9]+\.?[0-9]*\s+\S+\s+.*$', cpu_snap)
mem_total = re.search(r'MemTotal:\s+(\d+)\s+kB', system_mem)
mem_available = re.search(r'MemAvailable:\s+(\d+)\s+kB', system_mem)
mem_free = re.search(r'MemFree:\s+(\d+)\s+kB', system_mem)
system_cpu_total = re.search(r'Load:\s*([0-9.]+)\s*/\s*([0-9.]+)\s*/\s*([0-9.]+)', system_cpu)
total_frames = re.search(r'Total frames rendered:\s+(\d+)', gfx)
janky_frames = re.search(r'Janky frames:\s+(\d+)\s+\(([^)]+)\)', gfx)
janky_legacy = re.search(r'Janky frames \(legacy\):\s+(\d+)\s+\(([^)]+)\)', gfx)
p50_frame = re.search(r'50th percentile:\s+(\d+)ms', gfx)
p90_frame = re.search(r'90th percentile:\s+(\d+)ms', gfx)
p95_frame = re.search(r'95th percentile:\s+(\d+)ms', gfx)
p99_frame = re.search(r'99th percentile:\s+(\d+)ms', gfx)
missed_vsync = re.search(r'Number Missed Vsync:\s+(\d+)', gfx)
high_input_latency = re.search(r'Number High input latency:\s+(\d+)', gfx)
slow_ui = re.search(r'Number Slow UI thread:\s+(\d+)', gfx)
slow_draw = re.search(r'Number Slow issue draw commands:\s+(\d+)', gfx)
app_size_match = re.search(r'\s([0-9.]+[KMG])\s+\d{4}-\d{2}-\d{2}', apk)
ping_avg = re.search(r'= [0-9.]+/([0-9.]+)/', ping)
skipped_matches = [int(x) for x in re.findall(r'Skipped\s+(\d+)\s+frames', choreo, flags=re.IGNORECASE)]
choreo_lines = [line for line in choreo.splitlines() if line.strip()]

used_mem_kb = None
if mem_total and mem_available:
  used_mem_kb = int(mem_total.group(1)) - int(mem_available.group(1))

def as_int(match):
  return int(match.group(1)) if match else None

def health_icon(value, good=None, warn=None, lower_is_better=True):
  if value is None:
    return '⚪'
  try:
    value = float(value)
  except Exception:
    return '⚪'
  if lower_is_better:
    if good is not None and value <= good:
      return '🟢'
    if warn is not None and value <= warn:
      return '🟡'
    return '🔴'
  if good is not None and value >= good:
    return '🟢'
  if warn is not None and value >= warn:
    return '🟡'
  return '🔴'

def fmt(value, suffix=''):
  return f'{value}{suffix}' if value is not None else 'n/a'

def verdict_label(value, good=None, warn=None, lower_is_better=True):
  icon = health_icon(value, good, warn, lower_is_better)
  return {
    '🟢': 'Good',
    '🟡': 'Warning',
    '🔴': 'Poor',
    '⚪': 'Unknown',
  }.get(icon, 'Unknown')

def narrative_from_verdict(label, good_text, warn_text, poor_text, unknown_text='Not enough data'):
  return {
    'Good': good_text,
    'Warning': warn_text,
    'Poor': poor_text,
    'Unknown': unknown_text,
  }.get(label, unknown_text)

def print_table(headers, rows):
  print('| ' + ' | '.join(headers) + ' |')
  print('|' + '|'.join(['---'] * len(headers)) + '|')
  for row in rows:
    print('| ' + ' | '.join(str(cell) for cell in row) + ' |')

print(f'# {app_name} Android Performance Smoke Summary')
print()
print()
print(f'Output folder: {out}')
print()
launch_verdict = verdict_label(launch.get('total_time', {}).get('p95_ms'), 1800, 3000)
memory_verdict = verdict_label(as_int(pss), 250000, 450000)
cpu_verdict = verdict_label(cpu_idle.get('avg_cpu_pct'), 25, 55)
ui_jank_verdict = verdict_label(as_int(janky_frames), 10, 30)

launch_insight = narrative_from_verdict(
  launch_verdict,
  'App startup looks fast. Cold launch and TTI proxy are in a healthy range.',
  'App startup is usable but not fully optimized. Users may notice some delay on weaker devices.',
  'App startup is slow. Launch performance should be prioritized before release.',
)
ui_insight = narrative_from_verdict(
  ui_jank_verdict,
  'UI rendering looks reasonably light. Frame pacing appears stable for this run.',
  'UI looks somewhat heavy. Some screens or transitions may feel inconsistent under interaction.',
  'UI/rendering looks heavy. Jank and frame pacing issues are likely visible during real use.',
)
animation_insight = narrative_from_verdict(
  verdict_label(max(skipped_matches) if skipped_matches else as_int(janky_frames), 5, 20),
  'No strong animation instability signal was captured in this run.',
  'Animation or transition smoothness may need attention. There are moderate skipped-frame or jank signals.',
  'Animation/transition smoothness is likely problematic. High jank, skipped frames, or slow UI work suggest visible stutter.',
)
memory_insight = narrative_from_verdict(
  memory_verdict,
  'Memory usage looks acceptable for this snapshot.',
  'Memory usage is acceptable but on the heavier side. It should be watched on lower-end devices.',
  'Memory usage looks high and could become risky on constrained devices or longer sessions.',
)

top_findings = []
recommended_fixes = []

if launch_verdict == 'Good':
  top_findings.append(f'Launch performance is strong with cold start p95 at {fmt(launch.get("total_time", {}).get("p95_ms"), " ms")}.')
elif launch_verdict == 'Warning':
  top_findings.append(f'Launch performance is acceptable but could improve; cold start p95 is {fmt(launch.get("total_time", {}).get("p95_ms"), " ms")}.')
  recommended_fixes.append('Trim startup work on app launch, delay non-critical initialization, and profile app start-up tasks.')
else:
  top_findings.append(f'Launch performance is a concern; cold start p95 is {fmt(launch.get("total_time", {}).get("p95_ms"), " ms")}.')
  recommended_fixes.append('Prioritize startup optimization: defer heavy initialization, reduce synchronous work, and inspect startup traces.')

if ui_jank_verdict == 'Poor':
  top_findings.append(f'UI smoothness is weak: janky frames are {janky_frames.group(1) if janky_frames else "n/a"} ({janky_frames.group(2) if janky_frames else "n/a"}), with p95 frame time at {fmt(as_int(p95_frame), " ms")}.')
  recommended_fixes.append('Audit heavy screens and transitions, reduce overdraw, simplify layouts, and profile expensive rendering paths.')
elif ui_jank_verdict == 'Warning':
  top_findings.append(f'UI smoothness shows moderate strain with janky frames at {janky_frames.group(1) if janky_frames else "n/a"} ({janky_frames.group(2) if janky_frames else "n/a"}).')
  recommended_fixes.append('Review animation-heavy flows and optimize frame pacing on the busiest screens.')
else:
  top_findings.append('UI frame pacing looks stable in this run.')

if (max(skipped_matches) if skipped_matches else 0) and (max(skipped_matches) if skipped_matches else 0) > 0:
  top_findings.append(f'Choreographer captured skipped-frame signals, with max skipped frames at {fmt(max(skipped_matches))}.')
  recommended_fixes.append('Inspect animations and screen transitions for main-thread stalls, large image work, or expensive draw operations.')

if memory_verdict == 'Poor':
  top_findings.append(f'App memory is high with PSS at {fmt(as_int(pss), " KB")} and RSS at {fmt(as_int(rss), " KB")}.')
  recommended_fixes.append('Reduce retained objects, optimize image/cache usage, and verify memory behavior on lower-memory devices.')
elif memory_verdict == 'Warning':
  top_findings.append(f'App memory is on the heavier side with PSS at {fmt(as_int(pss), " KB")}.')
  recommended_fixes.append('Monitor memory across longer sessions and optimize large assets or caches where possible.')
else:
  top_findings.append('Memory usage is acceptable for the captured snapshot.')

if cpu_verdict in ('Warning', 'Poor'):
  top_findings.append(f'CPU usage is elevated with sampled average at {fmt(cpu_idle.get("avg_cpu_pct"), " %")}.')
  recommended_fixes.append('Profile repeated CPU-heavy work, move expensive operations off the main thread, and reduce unnecessary recomposition/redraw.')

if not recommended_fixes:
  recommended_fixes.append('No major issues were auto-detected in this run; repeat on more user journeys and weaker devices for confidence.')

print('## Final Verdict')
print_table(
  ['Area', 'Verdict'],
  [
    ['Launch', launch_verdict],
    ['Memory', memory_verdict],
    ['CPU', cpu_verdict],
    ['UI / Jank', ui_jank_verdict],
  ],
)
print()
print('💡🔦 Insight')
print_table(
  ['Area', 'Insight'],
  [
    ['App speed', launch_insight],
    ['UI heaviness', ui_insight],
    ['Animation smoothness', animation_insight],
    ['Memory risk', memory_insight],
  ],
)
print()
print('## Top Findings')
for finding in top_findings:
  print(f'- {finding}')
print()
print('## Recommended Fixes')
for fix in dict.fromkeys(recommended_fixes):
  print(f'- {fix}')
print()
print('## Overview')
overview_rows = [
  [health_icon(launch.get('total_time', {}).get('avg_ms'), 1200, 2500), 'Cold start avg', fmt(launch.get('total_time', {}).get('avg_ms'), ' ms')],
  [health_icon(launch.get('total_time', {}).get('p95_ms'), 1800, 3000), 'Cold start p95', fmt(launch.get('total_time', {}).get('p95_ms'), ' ms')],
  [health_icon(launch.get('wait_time', {}).get('avg_ms'), 1500, 3000), 'TTI proxy avg', fmt(launch.get('wait_time', {}).get('avg_ms'), ' ms')],
  [health_icon(as_int(janky_frames), 10, 30), 'Gfx janky frames', f"{janky_frames.group(1)} ({janky_frames.group(2)})" if janky_frames else 'n/a'],
  [health_icon(max(skipped_matches) if skipped_matches else None, 5, 20), 'Max skipped frames', fmt(max(skipped_matches) if skipped_matches else None)],
  ['🟢' if 'ANR' not in exit_info else '🔴', 'ANR seen in exit-info', 'No' if 'ANR' not in exit_info else 'Yes'],
]
print_table(['Status', 'Metric', 'Value'], overview_rows)
print()
print('## Resource Summary')
resource_rows = [
  [health_icon(as_int(pss), 250000, 450000), 'App memory PSS', fmt(as_int(pss), ' KB')],
  [health_icon(as_int(rss), 350000, 650000), 'App memory RSS', fmt(as_int(rss), ' KB')],
  [health_icon(cpu_idle.get('avg_cpu_pct'), 25, 55), 'App CPU avg', fmt(cpu_idle.get('avg_cpu_pct'), ' %')],
  [health_icon(float(peak_cpu_match.group(1)) if peak_cpu_match else None, 35, 70), 'App CPU peak snapshot', fmt(float(peak_cpu_match.group(1)) if peak_cpu_match else None, ' %')],
  ['ℹ️', 'Device memory total', fmt(as_int(mem_total), ' KB')],
  ['ℹ️', 'Device memory available', fmt(as_int(mem_available), ' KB')],
  ['ℹ️', 'Device memory approx used', fmt(used_mem_kb, ' KB')],
  ['ℹ️', 'Device CPU load (1m/5m/15m)', ' / '.join(system_cpu_total.groups()) if system_cpu_total else 'n/a'],
  ['ℹ️', 'App size on device', app_size_match.group(1) if app_size_match else 'n/a'],
]
print_table(['Status', 'Metric', 'Value'], resource_rows)
print()
print('## Flow Execution')
if isinstance(flows, dict) and flows.get('flows'):
  flow_rows = []
  for flow in flows['flows']:
    flow_rows.append(['🟢' if flow.get('success') else '🔴', flow.get('name'), len(flow.get('steps', [])), flow.get('success')])
  print_table(['Status', 'Flow', 'Steps', 'Success'], flow_rows)
else:
  print(flows.get('note', 'No flow data') if isinstance(flows, dict) else 'No flow data')
print()
print('## User Journey Upper Bounds')
if isinstance(journey, list):
  journey_rows = []
  for row in journey:
    upper = row.get('load_ms_upper_bound')
    journey_rows.append([health_icon(upper, 1200, 2500), row.get('screen'), fmt(upper, ' ms'), row.get('polls', 'n/a')])
  if journey_rows:
    print_table(['Status', 'Screen', 'Load upper bound', 'Polls'], journey_rows)
  else:
    print('No journey rows')
print()
print('## API Latency Samples')
if isinstance(api, dict):
  api_rows = []
  for name, row in api.items():
    if isinstance(row, dict):
      api_rows.append([health_icon(row.get('p95_ms'), 500, 1500), name, row.get('statuses'), fmt(row.get('p95_ms'), ' ms'), fmt(row.get('p99_ms'), ' ms')])
    else:
      api_rows.append(['ℹ️', name, row, 'n/a', 'n/a'])
  if api_rows:
    print_table(['Status', 'Endpoint', 'Statuses', 'p95', 'p99'], api_rows)
print()
print('## GfxInfo')
gfx_rows = [
  ['ℹ️', 'Total frames rendered', fmt(as_int(total_frames))],
  [health_icon(as_int(janky_frames), 10, 30), 'Janky frames', f"{janky_frames.group(1)} ({janky_frames.group(2)})" if janky_frames else 'n/a'],
  ['ℹ️', 'Legacy janky frames', f"{janky_legacy.group(1)} ({janky_legacy.group(2)})" if janky_legacy else 'n/a'],
  [health_icon(as_int(p50_frame), 16, 32), 'p50 frame', fmt(as_int(p50_frame), ' ms')],
  [health_icon(as_int(p90_frame), 24, 50), 'p90 frame', fmt(as_int(p90_frame), ' ms')],
  [health_icon(as_int(p95_frame), 32, 100), 'p95 frame', fmt(as_int(p95_frame), ' ms')],
  [health_icon(as_int(p99_frame), 50, 200), 'p99 frame', fmt(as_int(p99_frame), ' ms')],
  [health_icon(as_int(missed_vsync), 5, 20), 'Missed Vsync', fmt(as_int(missed_vsync))],
  [health_icon(as_int(high_input_latency), 5, 20), 'High input latency', fmt(as_int(high_input_latency))],
  [health_icon(as_int(slow_ui), 5, 20), 'Slow UI thread', fmt(as_int(slow_ui))],
  [health_icon(as_int(slow_draw), 5, 20), 'Slow draw commands', fmt(as_int(slow_draw))],
]
print_table(['Status', 'Metric', 'Value'], gfx_rows)
print()
print('## Choreographer')
if choreo_lines:
  print_table(['Status', 'Detail'], [[health_icon(max(skipped_matches) if skipped_matches else None, 5, 20), line] for line in choreo_lines[-10:]])
else:
  print('- No Choreographer warnings captured')
print()
print('## Flow Step Resource Deltas')
if isinstance(flows, dict) and flows.get('flows'):
  for flow in flows['flows']:
    print()
    print(f'### {flow.get("name")}')
    step_rows = []
    for step in flow.get('steps', []):
      delta = step.get('resource_delta', {}) if isinstance(step, dict) else {}
      step_rows.append([
        '🟢' if step.get('ok') else '🔴',
        step.get('label', step.get('action', 'step')),
        fmt(step.get('elapsed_ms'), ' ms'),
        fmt(delta.get('app_cpu_pct_after'), ' %'),
        fmt(delta.get('app_pss_kb_delta'), ' KB'),
        fmt(delta.get('gfx_janky_frames_delta')),
        fmt(delta.get('max_skipped_frames_after')),
        fmt(delta.get('network_rx_bytes_delta'), ' B'),
        fmt(delta.get('network_tx_bytes_delta'), ' B'),
      ])
    print_table(['Status', 'Step', 'Elapsed', 'App CPU after', 'PSS Δ', 'Janky Δ', 'Max skipped', 'RX Δ', 'TX Δ'], step_rows)
else:
  print('No FLOW_JSON provided, so no per-step deltas were generated')
PY

echo "Artifacts written to: $OUT_DIR"

# ── Auto-generate HTML report ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/generate_perf_html_report.sh" "$OUT_DIR"; then
  echo "HTML report: $OUT_DIR/REPORT.html"
else
  echo "Warning: HTML report generation failed (non-fatal)" >&2
fi
