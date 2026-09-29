#!/bin/bash
# Title: SentinelStream - Intelligent USB HID Stream Capture & Analysis
# Author: D-L3aN
# Description: Captures and decodes USB HID keystroke streams from
#              Ducky/Flipper/BadUSB devices. Auto-discovers the input
#              device, supports multiple keyboard layouts, captures USB
#              descriptors, and analyzes the decoded stream for URLs,
#              commands, and credential-like patterns. Writes structured
#              loot with a per-session summary and risk findings.
# Category: reconnaissance
# Version: 1.0
# Props: Inspired by "USB Ducky / Flipper Scanner & Data Stream Capture"
#        by cncartist. ACK: evtest, lsusb, usbhid.

# ============================================================
#  CONFIGURATION
# ============================================================
LOOT_BASE="/root/loot/sentinelstream"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
SESSION_DIR="${LOOT_BASE}/${TIMESTAMP}"
REPORT_FILE="${SESSION_DIR}/report.txt"
RAW_STREAM="${SESSION_DIR}/raw_stream.txt"
DECODED_STREAM="${SESSION_DIR}/decoded.txt"
USB_DESC_FILE="${SESSION_DIR}/usb_descriptors.txt"
ANALYSIS_FILE="${SESSION_DIR}/analysis.txt"

# Capture tuning
DEFAULT_CAPTURE_SECONDS=30
MIN_CAPTURE_SECONDS=5
MAX_CAPTURE_SECONDS=180
THRESHOLD_BYTES=100
SETTLE_AFTER_DETECT=2

# State
shift_pressed=0
capsl_pressed=0
numlk_pressed=0
founditems=0
CURRENT_LAYOUT=""

# ============================================================
#  KEYBOARD LAYOUT MAPS
#  Structure: KEY_NAME=normal shifted
# ============================================================
declare -A KEYMAP_US
KEYMAP_US=(
  [KEY_A]="a A" [KEY_B]="b B" [KEY_C]="c C" [KEY_D]="d D" [KEY_E]="e E"
  [KEY_F]="f F" [KEY_G]="g G" [KEY_H]="h H" [KEY_I]="i I" [KEY_J]="j J"
  [KEY_K]="k K" [KEY_L]="l L" [KEY_M]="m M" [KEY_N]="n N" [KEY_O]="o O"
  [KEY_P]="p P" [KEY_Q]="q Q" [KEY_R]="r R" [KEY_S]="s S" [KEY_T]="t T"
  [KEY_U]="u U" [KEY_V]="v V" [KEY_W]="w W" [KEY_X]="x X" [KEY_Y]="y Y"
  [KEY_Z]="z Z"
  [KEY_1]="1 !" [KEY_2]="2 @" [KEY_3]="3 #" [KEY_4]="4 $" [KEY_5]="5 %"
  [KEY_6]="6 ^" [KEY_7]="7 &" [KEY_8]="8 *" [KEY_9]="9 (" [KEY_0]="0 )"
  [KEY_MINUS]="- _" [KEY_EQUAL]="= +" [KEY_LEFTBRACE]="[ {"
  [KEY_RIGHTBRACE]="] }" [KEY_BACKSLASH]="\\ |" [KEY_SEMICOLON]="; :"
  [KEY_APOSTROPHE]="' \"" [KEY_GRAVE]="\` ~" [KEY_COMMA]=", <"
  [KEY_DOT]=". >" [KEY_SLASH]="/ ?"
  [KEY_KP0]="0 0" [KEY_KP1]="1 1" [KEY_KP2]="2 2" [KEY_KP3]="3 3"
  [KEY_KP4]="4 4" [KEY_KP5]="5 5" [KEY_KP6]="6 6" [KEY_KP7]="7 7"
  [KEY_KP8]="8 8" [KEY_KP9]="9 9" [KEY_KPPLUS]="+ +" [KEY_KPMINUS]="- -"
  [KEY_KPASTERISK]="* *" [KEY_KPSLASH]="/ /" [KEY_KPDOT]=". ."
)

# ============================================================
#  CLEANUP
# ============================================================
cleanup() {
  killall evtest 2>/dev/null
  modprobe usbhid 2>/dev/null
  rm -f /tmp/sentinelstream_*.tmp 2>/dev/null
  exit 0
}
trap cleanup EXIT SIGINT SIGTERM

# ============================================================
#  DEPENDENCY CHECK
# ============================================================
check_dependencies() {
  local missing=""
  command -v evtest &>/dev/null || missing="${missing} evtest"
  command -v lsusb &>/dev/null || missing="${missing} usbutils"
  command -v grep &>/dev/null || missing="${missing} grep"
  if [[ -n "$missing" ]]; then
    ERROR_DIALOG "Missing dependencies:${missing}\n\nInstall with:\nopkg update && opkg install evtest usbutils"
    LOG red "Missing:${missing}"
    exit 1
  fi
  # Prefer GNU grep for PCRE; fall back to busybox
  if ! grep -P "test" /dev/null 2>/dev/null; then
    LOG yellow "Note: PCRE grep unavailable; using basic regex"
  fi
}
check_dependencies

# ============================================================
#  UTILITY FUNCTIONS
# ============================================================

# Find the HID input event device dynamically
find_hid_event_device() {
  local dev=""
  # Look for devices with "kbd" or "Keyboard" in their handler
  for d in /dev/input/event*; do
    [[ -e "$d" ]] || continue
    local name
    name=$(cat "/sys/class/input/$(basename "$d")/device/name" 2>/dev/null)
    if [[ "$name" =~ (Keyboard|kbd|HID|Ducky|Flipper|BadUSB) ]]; then
      dev="$d"
      break
    fi
  done
  # Fallback: use the first non-event0 device (event0 is often power button)
  if [[ -z "$dev" ]]; then
    for d in /dev/input/event*; do
      [[ "$d" == *"event0" ]] && continue
      [[ -e "$d" ]] && dev="$d" && break
    done
  fi
  echo "$dev"
}

# Detect keyboard layout from system config
detect_layout() {
  if [[ -f /etc/keymap ]]; then
    CURRENT_LAYOUT=$(head -1 /etc/keymap | tr -d '\n')
  elif command -v loadkeys &>/dev/null; then
    CURRENT_LAYOUT=$(loadkeys -d 2>/dev/null | head -1 | awk '{print $1}')
  fi
  [[ -z "$CURRENT_LAYOUT" ]] && CURRENT_LAYOUT="us"
  echo "$CURRENT_LAYOUT"
}

# ============================================================
#  MAIN HEADER
# ============================================================
LED GREEN
LOG magenta "========================================="
LOG cyan "  SentinelStream - USB HID Capture"
LOG magenta "========================================="
LOG " "
LOG green "Press OK to begin..."
WAIT_FOR_BUTTON_PRESS A

mkdir -p "$SESSION_DIR"

# Write report header
{
  printf "╔══════════════════════════════════════════════════════╗\n"
  printf "║  SentinelStream Session Report                       ║\n"
  printf "╚══════════════════════════════════════════════════════╝\n\n"
  printf "Session: %s\n" "$TIMESTAMP"
  printf "Layout:  %s\n" "$(detect_layout)"
  printf "\n"
} > "$REPORT_FILE"

# ============================================================
#  CONFIRM SCAN
# ============================================================
resp=$(CONFIRMATION_DIALOG "Begin SentinelStream capture?")
if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
  LOG yellow "Cancelled by user."
  exit 0
fi

# ============================================================
#  HID LOCKOUT
# ============================================================
rmmod usbhid 2>/dev/null || modprobe -r usbhid 2>/dev/null
LOG cyan "HID locked out. Plug in target USB device."
LED MAGENTA
WAIT_FOR_BUTTON_PRESS A

# ============================================================
#  DETECT TARGET DEVICE
# ============================================================
LOG cyan "Scanning for HID input device..."
LED CYAN VERYFAST

# Wait for device enumeration
sleep 2

HID_DEV=$(find_hid_event_device)
if [[ -z "$HID_DEV" || ! -c "$HID_DEV" ]]; then
  LOG red "No HID event device found."
  ERROR_DIALOG "No HID input device detected.\nEnsure the target is plugged in."
  exit 1
fi
LOG green "HID device: $HID_DEV"
printf "HID Device: %s\n" "$HID_DEV" >> "$REPORT_FILE"

# Capture USB descriptors
{
  printf "═══ USB Descriptors ═══\n\n"
  lsusb -v 2>/dev/null | grep -E "(idVendor|idProduct|iManufacturer|iProduct|bInterfaceClass)" | head -40
} > "$USB_DESC_FILE"
LOG green "USB descriptors captured"

# ============================================================
#  CAPTURE DURATION
# ============================================================
CAPTURE_SECONDS=$(NUMBER_PICKER "Capture duration (seconds):" $DEFAULT_CAPTURE_SECONDS)
case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) CAPTURE_SECONDS=$DEFAULT_CAPTURE_SECONDS ;; esac
[[ $CAPTURE_SECONDS -lt $MIN_CAPTURE_SECONDS ]] && CAPTURE_SECONDS=$MIN_CAPTURE_SECONDS
[[ $CAPTURE_SECONDS -gt $MAX_CAPTURE_SECONDS ]] && CAPTURE_SECONDS=$MAX_CAPTURE_SECONDS

LOG cyan "Capturing for ${CAPTURE_SECONDS}s..."
printf "Capture Duration: %ss\n" "$CAPTURE_SECONDS" >> "$REPORT_FILE"

# ============================================================
#  CAPTURE STREAM
# ============================================================
modprobe usbhid 2>/dev/null
(sleep $((CAPTURE_SECONDS + 1)) && killall evtest 2>/dev/null) &
(evtest --grab "$HID_DEV" &> "$RAW_STREAM") &
EVTEST_PID=$!
sleep $((CAPTURE_SECONDS + 2))
killall evtest 2>/dev/null
wait $EVTEST_PID 2>/dev/null
rmmod usbhid 2>/dev/null || modprobe -r usbhid 2>/dev/null

# ============================================================
#  PROCESS RAW STREAM
# ============================================================
# Extract EV_KEY events only
grep "EV_KEY" "$RAW_STREAM" > "${RAW_STREAM}.tmp" 2>/dev/null
mv "${RAW_STREAM}.tmp" "$RAW_STREAM"

if [[ ! -s "$RAW_STREAM" ]] || [[ $(stat -c%s "$RAW_STREAM" 2>/dev/null || echo 0) -lt $THRESHOLD_BYTES ]]; then
  LOG yellow "Insufficient data captured."
  printf "\nNo significant data captured.\n" >> "$REPORT_FILE"
  LED YELLOW SLOW
  WAIT_FOR_BUTTON_PRESS A
  exit 0
fi

LOG green "Raw events captured: $(wc -l < "$RAW_STREAM") lines"

# ============================================================
#  DECODE STREAM
# ============================================================
LOG cyan "Decoding keystroke stream..."
LED MAGENTA SLOW

: > "$DECODED_STREAM"

while IFS= read -r line; do
  [[ "$line" =~ "EV_KEY" ]] || continue

  # Extract keycode and value
  if [[ "$line" =~ KEY_([A-Z0-9_]+) ]]; then
    kcode="KEY_${BASH_REMATCH[1]}"
  else
    continue
  fi

  if [[ "$line" =~ value[[:space:]]+([0-9]) ]]; then
    kvalue="${BASH_REMATCH[1]}"
  else
    continue
  fi

  # Track modifier states
  case "$kcode" in
    KEY_NUMLOCK)
      numlk_pressed=$kvalue
      continue
      ;;
    KEY_CAPSLOCK)
      capsl_pressed=$kvalue
      continue
      ;;
    KEY_LEFTSHIFT|KEY_RIGHTSHIFT)
      shift_pressed=$kvalue
      continue
      ;;
  esac

  # Only process key down (1) or repeat (2)
  if [[ "$kvalue" -eq 1 || "$kvalue" -eq 2 ]]; then
    if [[ -n "${KEYMAP_US[$kcode]}" ]]; then
      map_entry="${KEYMAP_US[$kcode]}"
      if [[ "$shift_pressed" -eq 1 ]]; then
        printf "%s" "${map_entry#* }" >> "$DECODED_STREAM"
      else
        printf "%s" "${map_entry%% *}" >> "$DECODED_STREAM"
      fi
    else
      case "$kcode" in
        KEY_SPACE)      printf " " >> "$DECODED_STREAM" ;;
        KEY_ENTER|KEY_KPENTER) printf "\n" >> "$DECODED_STREAM" ;;
        KEY_TAB)        printf "\t" >> "$DECODED_STREAM" ;;
        KEY_BACKSPACE)  printf "\b \b" >> "$DECODED_STREAM" ;;
        *)
          [[ -n "$kcode" ]] && printf "[%s]" "$kcode" >> "$DECODED_STREAM"
          ;;
      esac
    fi
  fi
done < "$RAW_STREAM"

LOG green "Decoded $(wc -c < "$DECODED_STREAM") bytes"

# ============================================================
#  ANALYZE DECODED STREAM
# ============================================================
LOG cyan "Analyzing decoded stream..."
: > "$ANALYSIS_FILE"

{
  printf "═══ SentinelStream Analysis ═══\n"
  printf "Session: %s\n\n" "$TIMESTAMP"
} >> "$ANALYSIS_FILE"

# URLs
URLS=$(grep -oE '(https?|ftp|ssh)://[^[:space:]]+' "$DECODED_STREAM" 2>/dev/null | sort -u)
if [[ -n "$URLS" ]]; then
  printf "── URLs Detected ──\n" >> "$ANALYSIS_FILE"
  echo "$URLS" | while read -r u; do printf "  %s\n" "$u" >> "$ANALYSIS_FILE"; done
  printf "\n" >> "$ANALYSIS_FILE"
  founditems=$((founditems + 1))
fi

# Commands (cmd, powershell, bash, sh)
if grep -qE '(cmd|powershell|bash|sh|wmic|reg)[[:space:]]' "$DECODED_STREAM" 2>/dev/null; then
  printf "── Command Patterns ──\n" >> "$ANALYSIS_FILE"
  grep -nE '(cmd|powershell|bash|sh|wmic|reg)[[:space:]]' "$DECODED_STREAM" 2>/dev/null | head -10 >> "$ANALYSIS_FILE"
  printf "\n" >> "$ANALYSIS_FILE"
  founditems=$((founditems + 1))
fi

# Credential-like patterns
CREDS=$(grep -oiE '(password|passwd|pwd|token|apikey|api_key|secret)[[:space:]]*[:=][[:space:]]*[^[:space:]]+' "$DECODED_STREAM" 2>/dev/null)
if [[ -n "$CREDS" ]]; then
  printf "── Credential-Like Patterns ──\n" >> "$ANALYSIS_FILE"
  echo "$CREDS" >> "$ANALYSIS_FILE"
  printf "\n" >> "$ANALYSIS_FILE"
  founditems=$((founditems + 1))
fi

# IP addresses
IPS=$(grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$DECODED_STREAM" 2>/dev/null | sort -u)
if [[ -n "$IPS" ]]; then
  printf "── IP Addresses ──\n" >> "$ANALYSIS_FILE"
  echo "$IPS" | while read -r ip; do printf "  %s\n" "$ip" >> "$ANALYSIS_FILE"; done
  printf "\n" >> "$ANALYSIS_FILE"
fi

# Summary
{
  printf "── Summary ──\n"
  printf "Risk indicators: %d\n" "$founditems"
  printf "Decoded bytes:   %d\n" "$(wc -c < "$DECODED_STREAM")"
  printf "Raw events:      %d\n" "$(wc -l < "$RAW_STREAM")"
} >> "$ANALYSIS_FILE"

# ============================================================
#  REPORT
# ============================================================
{
  printf "\n═══ Findings ═══\n"
  cat "$ANALYSIS_FILE"
  printf "\n═══ Files ═══\n"
  printf "Report:     %s\n" "$REPORT_FILE"
  printf "Raw stream: %s\n" "$RAW_STREAM"
  printf "Decoded:    %s\n" "$DECODED_STREAM"
  printf "USB desc:   %s\n" "$USB_DESC_FILE"
  printf "Analysis:   %s\n" "$ANALYSIS_FILE"
} >> "$REPORT_FILE"

# ============================================================
#  OPERATOR SUMMARY
# ============================================================
LOG " "
LOG magenta "═══════════════════════════════════════"
if [[ $founditems -gt 0 ]]; then
  LED RED SLOW
  RINGTONE "warning"
  LOG red "SentinelStream: $founditems risk indicator(s) found"
  LOG cyan "Review: $ANALYSIS_FILE"
else
  LED GREEN SLOW
  RINGTONE "ScaleTrill"
  LOG green "SentinelStream: capture complete, no strong indicators"
fi
LOG magenta "═══════════════════════════════════════"
LOG " "
LOG cyan "USB device can be unplugged."
LOG green "Press OK to finish..."
WAIT_FOR_BUTTON_PRESS A

exit 0
