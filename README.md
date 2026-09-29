# SentinelStream---Intelligent-USB-HID-Stream-Capture-and-Analysis
Captures and decodes USB HID keystroke streams from Ducky, Flipper, and BadUSB devices. Auto-discovers the correct input event device, captures USB descriptors, decodes keystrokes, and analyzes the decoded stream for URLs, commands, and credential-like patterns. Writes structured loot to `/root/loot/sentinelstream/&lt;timestamp>/`.
# SentinelStream - Intelligent USB HID Stream Capture & Analysis

Captures and decodes USB HID keystroke streams from Ducky, Flipper, and BadUSB devices. Auto-discovers the correct input event device, captures USB descriptors, decodes keystrokes, and analyzes the decoded stream for URLs, commands, and credential-like patterns. Writes structured loot to `/root/loot/sentinelstream/<timestamp>/`.

- **Author:** D-L3aN
- **Version:** 1.0
- **Category:** reconnaissance
- **Props:** Inspired by "USB Ducky / Flipper Scanner & Data Stream Capture" by cncartist

---

## Authorised Use Only

This payload is intended for **authorised security testing, red team engagements, and incident response** only. Deploying it against systems you do not own or do not have explicit written permission to test is illegal in most jurisdictions.

SentinelStream is **passive and non-destructive**. It does not:

- Modify the target device
- Inject keystrokes or commands
- Exfiltrate data off-device
- Persist across reboots

---

## What It Does

| Stage | Action |
|---|---|
| Discovery | Auto-detects the HID event device from `/sys/class/input/*/device/name` |
| Descriptor Capture | Records USB VID, PID, manufacturer, product via `lsusb -v` |
| Stream Capture | Uses `evtest --grab` to capture all `EV_KEY` events |
| Decode | Maps keycodes to characters using a US layout keymap |
| Analysis | Scans decoded output for URLs, commands, credentials, IPs |
| Report | Writes structured session loot with per-session directory |

---

## Improvements Over Original

1. **Dynamic device discovery** — no hardcoded `/dev/input/event0` or `event1`
2. **Session-sequential loot** — each run creates a timestamped directory, no overwrites
3. **USB descriptor capture** — identifies vendor/product of the target device
4. **Automated analysis** — URLs, command patterns, credential-like strings, IPs
5. **Risk scoring** — counts strong indicators for quick triage
6. **Layout detection** — logs the system keyboard layout (decode uses US by default)
7. **Structured output** — separate files for raw events, decoded stream, descriptors, analysis

---

## Usage

1. Copy `payload.sh` to `/root/payloads/user/reconnaissance/sentinelstream/` on the Pager
2. Ensure dependencies are installed: `opkg update && opkg install evtest usbutils`
3. Launch from **Payloads → User → Reconnaissance → SentinelStream**
4. Follow on-screen prompts:
   - Confirm start
   - Plug in target USB device
   - Set capture duration (5–180 seconds)
5. Unplug device when prompted
6. Review findings on screen; loot is at `/root/loot/sentinelstream/<timestamp>/`

---
