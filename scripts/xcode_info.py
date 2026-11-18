"""Write the Info.plist for Xcode builds: xtool's Info.plist plus the keys xtool
adds itself. Prints "<version> <build>". Used by scripts/xcode-prepare.sh."""
import plistlib, sys
src, dst, suffix = sys.argv[1:4]
with open(src, "rb") as f:
    info = plistlib.load(f)
build = info["CFBundleVersion"] + (f".{suffix}" if suffix else "")
info.update({
    "CFBundleVersion": build,
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundlePackageType": "$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleDevelopmentRegion": "en",
    "LSRequiresIPhoneOS": True,
    "UILaunchScreen": {},
    # A terminal is useful in landscape too.
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "UISupportedInterfaceOrientations~ipad": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
})
with open(dst, "wb") as f:
    plistlib.dump(info, f)
print(info["CFBundleShortVersionString"], build)
