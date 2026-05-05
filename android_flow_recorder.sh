#!/usr/bin/env bash
set -euo pipefail

# Semi-auto Android flow recorder.
#
# It records taps performed on the connected Android device and generates a
# starter FLOW_JSON skeleton. You still usually refine labels / assert patterns
# afterward, but manual JSON writing becomes much easier.
#
# Usage:
#   PKG="com.example.app" bash scripts/android_flow_recorder.sh
#   PKG="com.example.app" FLOW_NAME="login_flow" bash scripts/android_flow_recorder.sh qa_configs/android_perf/my_flow.json
#
# Notes:
# - Keep the phone unlocked
# - Open the target app manually or through script
# - Perform taps on the phone
# - Press Ctrl+C in terminal when recording is enough

ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
PKG="${PKG:-}"
FLOW_NAME="${FLOW_NAME:-recorded_flow}"
WAIT_MS="${WAIT_MS:-1200}"
OUT_FILE="${1:-$(pwd)/qa_configs/android_perf/${FLOW_NAME}_$(date +%Y%m%d_%H%M%S).json}"

usage() {
  cat <<EOF
Usage:
  PKG="com.example.app" bash scripts/android_flow_recorder.sh

Optional env vars:
  ADB        Absolute path to adb
  PKG        Package name to mention in output metadata
  FLOW_NAME  Flow name inside output JSON (default: recorded_flow)
  WAIT_MS    Wait step inserted after each tap (default: 1200)

Output:
  Generates a FLOW_JSON starter config with recorded tap coordinates.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ ! -x "$ADB" ]]; then
  echo "adb not found at $ADB" >&2
  exit 1
fi

if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "No Android device detected by adb" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

TMP_EVENT_LOG="$(mktemp)"
TMP_JSON="$(mktemp)"
cleanup() {
  rm -f "$TMP_EVENT_LOG" "$TMP_JSON"
}
trap cleanup EXIT

SCREEN_SIZE="$($ADB shell wm size | tr -d '\r' | sed -n 's/.*Override size: //p; s/.*Physical size: //p' | head -1)"
if [[ -z "$SCREEN_SIZE" ]]; then
  echo "Could not determine screen size" >&2
  exit 1
fi
SCREEN_W="${SCREEN_SIZE%x*}"
SCREEN_H="${SCREEN_SIZE#*x}"

DEVICE_PATH="/dev/input/event3"

# DEVICE_PATH="$($ADB shell getevent -pl 2>/dev/null | python3 - <<'PY'
# import re, sys
# text = sys.stdin.read().splitlines()
# current = None
# has_x = False
# has_y = False
# xmax = None
# ymax = None
# candidates = []
# for line in text:
#     m = re.match(r'add device \d+: (.+)', line)
#     if m:
#         if current and (has_x or has_y):
#             candidates.append((current, xmax, ymax))
#         current = m.group(1).strip()
#         has_x = has_y = False
#         xmax = ymax = None
#         continue
#     if 'ABS_MT_POSITION_X' in line or 'ABS_X' in line:
#         has_x = True
#         m2 = re.search(r'max\s+(\d+)', line)
#         if m2:
#             xmax = int(m2.group(1))
#     if 'ABS_MT_POSITION_Y' in line or 'ABS_Y' in line:
#         has_y = True
#         m2 = re.search(r'max\s+(\d+)', line)
#         if m2:
#             ymax = int(m2.group(1))
# if current and has_x and has_y:
#     candidates.append((current, xmax, ymax))
# print(candidates[0][0] if candidates else '')
# PY
# )"

if [[ -z "$DEVICE_PATH" ]]; then
  echo "Could not auto-detect touchscreen input device via getevent -pl" >&2
  exit 1
fi

RANGES="$($ADB shell getevent -pl 2>/dev/null | python3 - <<'PY'
import re, sys
text = sys.stdin.read().splitlines()
current = None
xmax = ymax = None
want = None
for line in text:
    m = re.match(r'add device \d+: (.+)', line)
    if m:
        current = m.group(1).strip()
        continue
    if want is None and current:
        want = current
    if current != want:
        continue
    if 'ABS_MT_POSITION_X' in line or 'ABS_X' in line:
        m2 = re.search(r'max\s+(\d+)', line)
        if m2:
            xmax = int(m2.group(1))
    if 'ABS_MT_POSITION_Y' in line or 'ABS_Y' in line:
        m2 = re.search(r'max\s+(\d+)', line)
        if m2:
            ymax = int(m2.group(1))
print(f'{xmax or 4095},{ymax or 4095}')
PY
)"
RAW_MAX_X="${RANGES%,*}"
RAW_MAX_Y="${RANGES#*,}"

cat <<EOF
Android flow recorder started.

Phone requirements:
- USB connected
- USB debugging ON
- screen unlocked
- target app open or ready

Recording from input device: $DEVICE_PATH
Screen size: ${SCREEN_W}x${SCREEN_H}
Raw input range: ${RAW_MAX_X}x${RAW_MAX_Y}
Output file: $OUT_FILE

Now tap through the app on your phone.
When done, press Ctrl+C here.
EOF

python3 - "$ADB" "$DEVICE_PATH" "$SCREEN_W" "$SCREEN_H" "$RAW_MAX_X" "$RAW_MAX_Y" "$PKG" "$FLOW_NAME" "$WAIT_MS" "$TMP_JSON" <<'PY'
import json, re, signal, subprocess, sys, time
from pathlib import Path

adb, device_path, screen_w, screen_h, raw_max_x, raw_max_y, pkg, flow_name, wait_ms, out_path = sys.argv[1:]
screen_w = int(screen_w)
screen_h = int(screen_h)
raw_max_x = max(1, int(raw_max_x))
raw_max_y = max(1, int(raw_max_y))
wait_ms = int(wait_ms)

steps = [
    {
        'action': 'launch',
        'label': 'Launch app manually or replace with exact launch step',
        'continue_on_failure': True,
    }
]
state = {'x': None, 'y': None, 'count': 0}

proc = subprocess.Popen(
    [adb, 'shell', 'getevent', '-lt', device_path],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    bufsize=1,
)

hex_re = re.compile(r'\b(EV_ABS|EV_KEY)\s+(ABS_MT_POSITION_X|ABS_X|ABS_MT_POSITION_Y|ABS_Y|BTN_TOUCH)\s+([0-9a-fA-F]+|DOWN|UP)')


def scale(v, raw_max, out_max):
    return max(0, min(out_max, round((v / raw_max) * out_max)))


def dump_markers():
    try:
        subprocess.run([adb, 'shell', 'uiautomator', 'dump', '/sdcard/uidump.xml'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        xml = subprocess.check_output([adb, 'shell', 'cat', '/sdcard/uidump.xml'], text=True, stderr=subprocess.DEVNULL)
        matches = re.findall(r'(?:content-desc|text)="([^"]+)"', xml)
        cleaned = []
        for m in matches:
            m = m.strip()
            if m and m not in cleaned:
                cleaned.append(m)
            if len(cleaned) >= 6:
                break
        return cleaned
    except Exception:
        return []


def finalize_tap():
    if state['x'] is None or state['y'] is None:
        return
    state['count'] += 1
    x = scale(state['x'], raw_max_x, screen_w)
    y = scale(state['y'], raw_max_y, screen_h)
    time.sleep(0.8)
    markers = dump_markers()
    steps.append({
        'action': 'tap',
        'x': x,
        'y': y,
        'label': f'Recorded Tap {state["count"]}',
    })
    steps.append({
        'action': 'wait',
        'ms': wait_ms,
        'label': f'Wait after tap {state["count"]}',
    })
    steps.append({
        'action': 'assert_pattern',
        'pattern': 'TODO_ADD_PATTERN',
        'timeout_ms': 5000,
        'label': f'Verify screen after tap {state["count"]}',
        'continue_on_failure': True,
        'suggested_markers': markers,
    })
    state['x'] = None
    state['y'] = None
    print(f'Recorded tap {state["count"]}: ({x}, {y})', flush=True)
    if markers:
        print('  Suggested markers:', ' | '.join(markers), flush=True)


def save_and_exit(*_):
    data = {
        'meta': {
            'package': pkg,
            'generated_by': 'android_flow_recorder.sh',
            'generated_at_epoch': int(time.time()),
        },
        'flows': [
            {
                'name': flow_name,
                'steps': steps,
            }
        ],
    }
    Path(out_path).write_text(json.dumps(data, indent=2))
    try:
        proc.terminate()
    except Exception:
        pass
    print(f'\nSaved flow skeleton to: {out_path}', flush=True)
    sys.exit(0)

signal.signal(signal.SIGINT, save_and_exit)
signal.signal(signal.SIGTERM, save_and_exit)

for raw in proc.stdout:
    m = hex_re.search(raw)
    if not m:
        continue
    _, code, value = m.groups()
    if code in ('ABS_MT_POSITION_X', 'ABS_X'):
        try:
            state['x'] = int(value, 16)
        except ValueError:
            pass
    elif code in ('ABS_MT_POSITION_Y', 'ABS_Y'):
        try:
            state['y'] = int(value, 16)
        except ValueError:
            pass
    elif code == 'BTN_TOUCH' and value == 'UP':
        finalize_tap()

save_and_exit()
PY

cp "$TMP_JSON" "$OUT_FILE"

echo "Done. Review and edit $OUT_FILE to replace TODO patterns with exact screen markers."
