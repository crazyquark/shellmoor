"""Wait until an uploaded build finishes processing in App Store Connect.

Usage: python3 scripts/asc_build_status.py <build number, e.g. 3.4> [max minutes]
Env:   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (needs: pip install "pyjwt[crypto]")

Exits 0 when the build is VALID (ready in TestFlight), 1 if processing failed
or the build is invalid, 2 if it's still processing when time runs out.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import jwt

BUNDLE_ID = "io.github.crazyquark.tether"
API = "https://api.appstoreconnect.apple.com/v1"


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        os.environ["ASC_KEY_P8"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def get(path, **params):
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)["data"]


def main():
    build = sys.argv[1]
    deadline = time.time() + 60 * int(sys.argv[2] if len(sys.argv) > 2 else 60)

    apps = get("apps", **{"filter[bundleId]": BUNDLE_ID})
    if not apps:
        sys.exit(f"No app with bundle ID {BUNDLE_ID} in App Store Connect.")
    app_id = apps[0]["id"]

    while True:
        builds = get("builds", **{
            "filter[app]": app_id,
            "filter[version]": build,
            "fields[builds]": "version,processingState,uploadedDate",
        })
        state = builds[0]["attributes"]["processingState"] if builds else "NOT_FOUND_YET"
        print(f"{time.strftime('%H:%M:%S')} build {build}: {state}", flush=True)
        if state == "VALID":
            print(f"::notice::Build {build} finished processing and is available in TestFlight.")
            return 0
        if state in ("FAILED", "INVALID"):
            print(f"::error::Build {build} is {state}. Check App Store Connect and your email for details.")
            return 1
        if time.time() > deadline:
            print(f"::warning::Build {build} is still {state}; stopped waiting.")
            return 2
        time.sleep(60)


if __name__ == "__main__":
    sys.exit(main())
