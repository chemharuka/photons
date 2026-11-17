#!/usr/bin/env python3
"""Build/run/test the opt-in iPad preview without changing the Mac packaging workflow."""
import argparse
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Apps/iPad/PhotonsIPad.xcodeproj"
DERIVED = ROOT / ".build/ipad"
BUNDLE = "com.leoaokma.photons.ipad-preview"

def run(args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)

def device_id(requested):
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    devices = [d for entries in data["devices"].values() for d in entries if "iPad" in d["name"] and d.get("isAvailable", False)]
    if requested:
        match = next((d for d in devices if requested in (d["udid"], d["name"])), None)
        if not match:
            raise SystemExit("The requested iPad simulator is not installed: " + requested)
    else:
        match = next((d for d in devices if d["state"] == "Booted"), devices[0] if devices else None)
    if not match:
        raise SystemExit("Install an iPad simulator runtime in Xcode → Settings → Components, then retry.")
    return match

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "test", "run", "device-build"])
    parser.add_argument("--device", help="Installed simulator name or UUID")
    parser.add_argument("--samples", action="store_true", help="Load generated examples into an empty preview library")
    parser.add_argument("--release", action="store_true", help="Use optimized processing for interactive previews (not unit tests)")
    parser.add_argument("--boston", action="store_true", help="Load bundled local Boston RAW samples")
    args = parser.parse_args()
    if args.release and args.action == "test":
        parser.error("Use Debug for tests; --release is for optimized preview builds.")
    configuration = "Release" if args.release else "Debug"
    derived = ROOT / ".build/ipad-release" if args.release else DERIVED
    command = ["xcodebuild", "-project", str(PROJECT), "-scheme", "Photons iPad Preview", "-configuration", configuration, "-derivedDataPath", str(derived)]
    if args.boston:
        command += ["PHOTONS_INCLUDE_BOSTON_SAMPLES=YES"]
    if args.action == "device-build":
        run(command + ["-destination", "generic/platform=iOS", "build", "CODE_SIGNING_ALLOWED=NO"])
        return
    device = device_id(args.device)
    command += ["-destination", "platform=iOS Simulator,id=" + device["udid"]]
    if args.action == "test":
        result = ROOT / ".build" / ("ipad-tests-" + time.strftime("%Y%m%d-%H%M%S") + ".xcresult")
        run(command + ["-resultBundlePath", str(result), "test", "CODE_SIGNING_ALLOWED=NO"])
        print("Test results:", result)
        return
    run(command + ["build", "CODE_SIGNING_ALLOWED=NO"])
    if args.action == "run":
        if device["state"] != "Booted":
            run(["xcrun", "simctl", "boot", device["udid"]])
        run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"])
        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        simulator = developer / "Applications/Simulator.app"
        if not simulator.exists():
            simulator = developer.parent / "Applications/DeviceHub.app"
        if simulator.exists():
            run(["open", str(simulator), "--args", "-CurrentDeviceUDID", device["udid"]])
        run(["xcrun", "simctl", "install", device["udid"], str(derived / ("Build/Products/" + configuration + "-iphonesimulator/Photons iPad Preview.app"))])
        run(["xcrun", "simctl", "launch", device["udid"], BUNDLE] + (["--boston"] if args.boston else ["--demo"] if args.samples else []))
        print("Running on", device["name"])

if __name__ == "__main__":
    main()
