"""Helpers for scripts/release.sh: bump the app version and update source.json."""
import datetime
import json
import os
import plistlib
import sys


def bump_version(plist_path, version):
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)
    build = int(info.get("CFBundleVersion", "0")) + 1
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = str(build)
    with open(plist_path, "wb") as f:
        plistlib.dump(info, f)
    print(build)


def add_version(source_path, version, build, notes, url, ipa_path):
    with open(source_path) as f:
        source = json.load(f)
    app = source["apps"][0]
    entry = {
        "version": version,
        "buildVersion": build,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": notes,
        "downloadURL": url,
        "size": os.path.getsize(ipa_path),
        "minOSVersion": "17.0",
    }
    # Newest first, and replace an entry for the same version if re-released.
    app["versions"] = [entry] + [v for v in app["versions"] if v["version"] != version]
    with open(source_path, "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"bump-version": bump_version, "add-version": add_version}[command](*args)
