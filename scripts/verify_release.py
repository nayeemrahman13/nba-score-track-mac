#!/usr/bin/env python3
"""Check the signatures and update configuration of a distribution app."""
import argparse
import base64
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

BUNDLE_ID = "com.nayeemrahman.NBAScoreTracker"
REPOSITORY = "https://github.com/nayeemrahman13/nba-score-track-mac"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_signature(path, team_id, entitlement_reader):
    result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)], check=True, capture_output=True)
    details = result.stderr.decode()
    require(f"TeamIdentifier={team_id}" in details, f"Wrong signing team: {path}")
    require("Authority=Developer ID Application:" in details, f"Missing Developer ID signature: {path}")
    require("(runtime)" in details, f"Hardened Runtime is disabled: {path}")
    require("Timestamp=" in details, f"Missing secure timestamp: {path}")
    entitlements = plistlib.loads(run(str(entitlement_reader), "entitlements", str(path)))
    for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory"]:
        require(not entitlements.get(key, False), f"Unsafe release entitlement {key}: {path}")
    return entitlements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--team-id", default="E4Y8VJA2GT")
    parser.add_argument("--notarized", action="store_true")
    parser.add_argument("--appcast", type=pathlib.Path)
    parser.add_argument("--archive", type=pathlib.Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="nba-release-verification-") as temporary:
        reader = pathlib.Path(temporary) / "release-security"
        run("xcrun", "swiftc", "-module-cache-path", str(pathlib.Path(temporary) / "modules"),
            str(pathlib.Path(__file__).with_name("ReleaseSecurity.swift")), "-o", str(reader))
        verify(args, reader)


def verify(args, reader):
    app = args.app.resolve()
    run("codesign", "--verify", "--deep", "--strict", str(app))
    entitlements = check_signature(app, args.team_id, reader)
    require(entitlements.get("com.apple.security.app-sandbox") is True, "The app is not sandboxed")
    require(entitlements.get("com.apple.security.network.client") is True, "Missing outgoing network entitlement")
    require(set(entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name", []))
            == {BUNDLE_ID + "-spks", BUNDLE_ID + "-spki"}, "Incorrect Sparkle sandbox exceptions")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    for path in [framework, framework / "Versions/B/Autoupdate", framework / "Versions/B/Updater.app",
                 framework / "Versions/B/XPCServices/Installer.xpc", framework / "Versions/B/XPCServices/Downloader.xpc"]:
        require(path.exists(), f"Missing Sparkle component: {path}")
        check_signature(path, args.team_id, reader)
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    require(info["CFBundleIdentifier"] == BUNDLE_ID, "Unexpected bundle identifier")
    require(info.get("SUFeedURL") == REPOSITORY + "/releases/latest/download/appcast.xml", "Incorrect appcast URL")
    require(len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) == 32, "Invalid Sparkle public key")
    for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableInstallerLauncherService"]:
        require(info.get(key) is True, f"{key} must be enabled")
    require(info.get("SUEnableSystemProfiling") is False, "System profile uploads must be disabled")
    require((app / "Contents/Resources/PrivacyInfo.xcprivacy").is_file(), "Missing app privacy manifest")
    if args.notarized:
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", str(app))
    if args.appcast:
        require(args.archive is not None, "Appcast checks need --archive")
        data = args.appcast.read_bytes()
        # Sparkle 2.10 appends this signing block after the signed XML content.
        block = re.search(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?\Z", data)
        require(block is not None, "Missing Sparkle feed signature")
        content = data[:block.start()]
        require(int(block[2]) == len(content), "Signed feed size mismatch")
        content_path = reader.parent / "signed-feed.xml"
        content_path.write_bytes(content)
        run(str(reader), "verify", str(content_path), info["SUPublicEDKey"], block[1].decode("ascii"))
        root = ET.fromstring(content)
        items = root.findall("./channel/item")
        require(len(items) == 1, "Expected a single release in the appcast")
        namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
        item = items[0]
        enclosure = item.find("enclosure")
        require(enclosure is not None, "Missing update enclosure")
        version = item.findtext(namespace + "version") or enclosure.get(namespace + "version")
        require(version == info["CFBundleVersion"], "Appcast version does not match the app")
        parsed = urllib.parse.urlparse(enclosure.get("url", ""))
        require(parsed.scheme == "https" and parsed.netloc == "github.com", "Updates must use GitHub HTTPS")
        require(parsed.path.startswith("/nayeemrahman13/nba-score-track-mac/releases/download/"), "Unexpected update repository")
        require(pathlib.PurePosixPath(urllib.parse.unquote(parsed.path)).name == args.archive.name, "Archive filename mismatch")
        require(int(enclosure.get("length", "0")) == args.archive.stat().st_size, "Archive size mismatch")
        signature = enclosure.get(namespace + "edSignature")
        require(signature is not None, "The update archive is not signed")
        run(str(reader), "verify", str(args.archive), info["SUPublicEDKey"], signature)
    print("PASS: Developer ID signatures, runtime protections, sandbox permissions, and Sparkle configuration")
    if args.notarized:
        print("PASS: stapled notarization ticket and Gatekeeper assessment")
    if args.appcast:
        print("PASS: signed appcast and update archive match the app's key, version, URL, and archive size")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError, OSError, ET.ParseError) as error:
        print(f"Release verification failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)
