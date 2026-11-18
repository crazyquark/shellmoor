#!/usr/bin/env bash
# Take App Store screenshots on the required simulator sizes (macOS + Xcode).
#
# Usage: scripts/screenshots.sh <path/to/Shellmoor.app (simulator build)> <output dir>
#
# The app's screenshot mode (Sources/Shellmoor/ScreenshotMode.swift) fills
# it with demo content and opens each screen.
set -euo pipefail
app="${1:?usage: scripts/screenshots.sh <Shellmoor.app> <output dir>}"
out="${2:?usage: scripts/screenshots.sh <Shellmoor.app> <output dir>}"
bundle=io.github.crazyquark.shellmoor
screens=(servers terminal keys settings)

# Newest available iOS runtime; download one if the selected Xcode has none.
latest_runtime() {
    xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(runtimes[-1]["identifier"] if runtimes else "")'
}
runtime=$(latest_runtime)
if [[ -z "$runtime" ]]; then
    xcodebuild -downloadPlatform iOS
    runtime=$(latest_runtime)
fi
echo "Runtime: $runtime"

# Newest device type whose name matches a regex: the one with the highest model
# number in its name (the simulator's list isn't in release order).
device_type() {
    xcrun simctl list devicetypes -j | python3 -I -c '
import json, re, sys
types = [t for t in json.load(sys.stdin)["devicetypes"] if re.search(sys.argv[1], t["name"])]
def model(t):
    return [int(n) for n in re.findall(r"\d+", t["name"])]
print(max(types, key=model)["identifier"] if types else "")' "$1"
}

# App Store Connect needs iPhone 6.9" and, since the app runs on iPad, iPad 13".
for spec in 'iphone-6.9|^iPhone \d+ Pro Max$' 'ipad-13|^iPad Pro 13-inch'; do
    label="${spec%%|*}"
    type=$(device_type "${spec#*|}")
    [[ -n "$type" ]] || { echo "No simulator matching ${spec#*|}" >&2; exit 1; }
    echo "== $label: $type"

    udid=$(xcrun simctl create "screenshots-$label" "$type" "$runtime")
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl ui "$udid" appearance dark
    xcrun simctl status_bar "$udid" override --time "9:41" \
        --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 \
        --batteryState charged --batteryLevel 100
    xcrun simctl install "$udid" "$app"

    mkdir -p "$out/$label"
    n=1
    for screen in "${screens[@]}"; do
        xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
        xcrun simctl launch "$udid" "$bundle" -ShellmoorScreenshot "$screen" >/dev/null
        sleep 6 # launch, push the screen, settle animations
        xcrun simctl io "$udid" screenshot "$out/$label/$n-$screen.png"
        n=$((n + 1))
    done

    xcrun simctl shutdown "$udid"
    xcrun simctl delete "$udid"
done
ls -R "$out"
