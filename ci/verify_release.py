"""Verify the actual iPhone Archive and exported IPA before an Apple upload."""
import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

BUNDLE_ID = "com.rookiei1.ykcam"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    require(result.returncode == 0, f"Package verification command failed: {args[0]}\n{result.stderr.decode(errors='replace')}")
    return result.stdout


def read_plist(data):
    # codesign can prepend a non-plist diagnostic on older macOS releases.
    xml_start = data.find(b"<?xml")
    if xml_start >= 0:
        data = data[xml_start:]
    return plistlib.loads(data)


def read_signed_entitlements(app):
    # Modern codesign defaults to a human-readable representation of DER
    # entitlements. Apple TN3125 requires --xml for machine-readable plist data.
    data = command("/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app))
    try:
        entitlements = read_plist(data)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise RuntimeError("codesign did not return a valid XML entitlements plist; refusing upload") from error
    require(isinstance(entitlements, dict), "Signed entitlements must be a plist dictionary")
    return entitlements


def verify_app(app, team_id, version, build_number, label):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundlePackageType": "APPL",
        "DTPlatformName": "iphoneos",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
    }
    for key, value in expected.items():
        require(info.get(key) == value, f"{label}: {key} must be {value!r}; got {info.get(key)!r}")
    require("iPhoneOS" in info.get("CFBundleSupportedPlatforms", []), f"{label}: iPhoneOS platform is missing")
    executable = info.get("CFBundleExecutable", "")
    require(executable and Path(executable).name == executable and (app / executable).is_file(), f"{label}: app executable is missing")
    require(not list(app.rglob("*.app")) and not list(app.rglob("*.appex")), f"{label}: unexpected embedded app or extension; update the signing target map first")
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))

    profile_path = app / "embedded.mobileprovision"
    require(profile_path.is_file(), f"{label}: embedded App Store profile is missing")
    profile = read_plist(command("/usr/bin/security", "cms", "-D", "-i", str(profile_path)))
    require(team_id in profile.get("TeamIdentifier", []), f"{label}: provisioning profile Team does not match")
    require("iOS" in profile.get("Platform", []), f"{label}: provisioning profile is not for iOS")
    require(not profile.get("ProvisionsAllDevices", False) and "ProvisionedDevices" not in profile, f"{label}: profile must be App Store distribution")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, dt.datetime), f"{label}: profile expiration is missing")
    require(expiry.replace(tzinfo=dt.timezone.utc) > dt.datetime.now(dt.timezone.utc), f"{label}: provisioning profile has expired")

    profile_entitlements = profile.get("Entitlements", {})
    signed_entitlements = read_signed_entitlements(app)
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    expected_app_ids = {f"{prefix}.{BUNDLE_ID}" for prefix in prefixes}
    require(profile_entitlements.get("application-identifier") in expected_app_ids, f"{label}: profile Bundle ID is incorrect or wildcard")
    require(signed_entitlements.get("application-identifier") == profile_entitlements.get("application-identifier"), f"{label}: signed application identifier does not match the profile")
    require(profile_entitlements.get("com.apple.developer.team-identifier") == team_id, f"{label}: profile entitlement Team is incorrect")
    require(signed_entitlements.get("com.apple.developer.team-identifier") == team_id, f"{label}: signed entitlement Team is incorrect")
    require(profile_entitlements.get("get-task-allow") is False and signed_entitlements.get("get-task-allow") is False, f"{label}: debugging must be disabled")
    # This version has no special capabilities. Adding any requires reviewing both
    # the project and its App ID/profile rather than silently ignoring it here.
    permitted = {"application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "beta-reports-active", "keychain-access-groups"}
    require(set(signed_entitlements) <= permitted, f"{label}: unexpected signed capability; review its App ID/profile mapping")
    if "keychain-access-groups" in signed_entitlements:
        require(signed_entitlements["keychain-access-groups"] == [signed_entitlements["application-identifier"]], f"{label}: unexpected shared keychain group")
    if "beta-reports-active" in signed_entitlements:
        require(signed_entitlements["beta-reports-active"] == profile_entitlements.get("beta-reports-active"), f"{label}: beta entitlement is not allowed by the profile")

    with tempfile.TemporaryDirectory(prefix="ykcam-certificate-") as directory:
        prefix = str(Path(directory) / "signer")
        command("/usr/bin/codesign", "--display", f"--extract-certificates={prefix}", str(app))
        leaf = Path(prefix + "0")
        require(leaf.is_file(), f"{label}: signing certificate is missing")
        digest = hashlib.sha256(leaf.read_bytes()).digest()
        allowed = {hashlib.sha256(cert).digest() for cert in profile.get("DeveloperCertificates", [])}
        require(digest in allowed, f"{label}: signing certificate is not included in the provisioning profile")
    print(f"{label}: signature, certificate, App Store profile, Team, Bundle ID, platform and {version} ({build_number}) passed.")


def verify(archive, ipa, team_id, version, build_number):
    apps = list((archive / "Products" / "Applications").glob("*.app"))
    require(len(apps) == 1, "Archive must contain exactly one iPhone app")
    verify_app(apps[0], team_id, version, build_number, "Archive")
    require(ipa.is_file(), "Exported IPA does not exist")
    with tempfile.TemporaryDirectory(prefix="ykcam-ipa-") as directory:
        command("/usr/bin/ditto", "-x", "-k", str(ipa), directory)
        exported = list((Path(directory) / "Payload").glob("*.app"))
        require(len(exported) == 1, "Exported IPA Payload must contain exactly one iPhone app")
        verify_app(exported[0], team_id, version, build_number, "Exported IPA")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Signed package verification passed\nArchive and exported IPA match `{BUNDLE_ID}`, Team `{team_id}`, version `{version}` build `{build_number}`.\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    arguments = parser.parse_args()
    verify(arguments.archive, arguments.ipa, arguments.team_id, arguments.version, arguments.build_number)
