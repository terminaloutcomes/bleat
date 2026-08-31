#!/usr/bin/env python3

import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path


class InspectionFailure(Exception):
    pass


EXPECTED_COLLECTION = {
    "NSPrivacyCollectedDataTypeDeviceID": (
        True,
        {"NSPrivacyCollectedDataTypePurposeAppFunctionality"},
    ),
    "NSPrivacyCollectedDataTypeProductInteraction": (
        True,
        {"NSPrivacyCollectedDataTypePurposeAnalytics"},
    ),
    "NSPrivacyCollectedDataTypePerformanceData": (
        True,
        {"NSPrivacyCollectedDataTypePurposeAppFunctionality"},
    ),
    "NSPrivacyCollectedDataTypeOtherDiagnosticData": (
        True,
        {"NSPrivacyCollectedDataTypePurposeAppFunctionality"},
    ),
}

RELEVANT_PACKAGES = {
    "appauth-ios",
    "opentelemetry-swift",
    "opentelemetry-swift-core",
    "swift-protobuf",
    "swift-nio",
    "swift-nio-ssl",
    "swift-crypto",
}

CARPLAY_ENTITLEMENT = "com.apple.developer.carplay-audio"


def load_plist(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise InspectionFailure(f"invalid property list: {path}") from error
    if not isinstance(value, dict):
        raise InspectionFailure(f"property list root is not a dictionary: {path}")
    return value


def load_plist_text(payload: str, description: str) -> dict:
    try:
        value = plistlib.loads(payload.encode())
    except plistlib.InvalidFileException as error:
        raise InspectionFailure(f"invalid {description} property list") from error
    if not isinstance(value, dict):
        raise InspectionFailure(f"{description} property list is not a dictionary")
    return value


def inspect_carplay_entitlement(
    entitlements: dict, *, mode: str, source: str, profile_values: bool = False
) -> None:
    value = entitlements.get(CARPLAY_ENTITLEMENT)
    if mode == "enabled":
        if value is not True:
            raise InspectionFailure(f"{source} does not enable CarPlay audio")
    elif not profile_values and CARPLAY_ENTITLEMENT in entitlements:
        raise InspectionFailure(f"{source} unexpectedly contains CarPlay audio")


def inspect_privacy_manifest(manifest: dict) -> None:
    if manifest.get("NSPrivacyTracking") is not False:
        raise InspectionFailure("app privacy manifest must disable tracking")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        raise InspectionFailure("app privacy manifest must have no tracking domains")

    entries = manifest.get("NSPrivacyCollectedDataTypes")
    if not isinstance(entries, list):
        raise InspectionFailure("collected data types must be an array")
    observed = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise InspectionFailure("collected data entry must be a dictionary")
        data_type = entry.get("NSPrivacyCollectedDataType")
        if not isinstance(data_type, str) or data_type in observed:
            raise InspectionFailure("collected data types must be unique strings")
        if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
            raise InspectionFailure(f"{data_type} must not be used for tracking")
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes")
        if not isinstance(purposes, list) or not all(
            isinstance(purpose, str) for purpose in purposes
        ):
            raise InspectionFailure(f"{data_type} purposes must be strings")
        observed[data_type] = (
            entry.get("NSPrivacyCollectedDataTypeLinked"),
            set(purposes),
        )
    if observed != EXPECTED_COLLECTION:
        raise InspectionFailure(
            "app privacy collection does not match the reviewed telemetry schema"
        )


def resolved_packages(path: Path) -> dict[str, str]:
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise InspectionFailure(f"invalid Package.resolved: {path}") from error
    pins = payload.get("pins")
    if not isinstance(pins, list):
        raise InspectionFailure("Package.resolved does not contain pins")
    result = {}
    for pin in pins:
        identity = pin.get("identity")
        state = pin.get("state", {})
        version = state.get("version") or state.get("revision")
        if isinstance(identity, str) and isinstance(version, str):
            result[identity] = version
    missing = RELEVANT_PACKAGES - result.keys()
    if missing:
        raise InspectionFailure(
            f"missing relevant package pins: {', '.join(sorted(missing))}"
        )
    return result


def run_checked(arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise InspectionFailure(f"command failed: {' '.join(arguments)}") from error
    return result.stdout


def inspect_linkage(app: Path, archive: Path) -> dict[str, str]:
    executable = app / "Bleat"
    dependencies = run_checked(["otool", "-L", str(executable)]).splitlines()[1:]
    non_system = [
        dependency.strip()
        for dependency in dependencies
        if not dependency.strip().startswith(("/System/", "/usr/lib/"))
    ]
    if non_system:
        raise InspectionFailure(
            f"unexpected non-system dynamic dependencies: {non_system}"
        )

    dwarf = archive / "dSYMs/Bleat.app.dSYM/Contents/Resources/DWARF/Bleat"
    symbols = run_checked(["nm", "-gjU", str(dwarf)])
    linked = {
        "AppAuth": "_OBJC_CLASS_$_OIDAuthorizationRequest",
        "OpenTelemetry Swift": "OpenTelemetryApi",
        "SwiftProtobuf": "SwiftProtobuf",
    }
    for package, marker in linked.items():
        if marker not in symbols:
            raise InspectionFailure(f"expected linked package is absent: {package}")
    absent = {
        "SwiftNIO": "$s7NIOCore",
        "NIOSSL": "$s6NIOSSL",
        "BoringSSL": "CNIOBoringSSL",
        "Swift Crypto": "$s6Crypto",
    }
    for package, marker in absent.items():
        if marker in symbols:
            raise InspectionFailure(
                f"unexpected linked crypto/network package: {package}"
            )
    return {
        **{package: "linked statically" for package in linked},
        **{package: "resolved but not linked" for package in absent},
    }


def inspect_archive(archive: Path, package_resolution: Path, carplay_mode: str) -> None:
    app = archive / "Products/Applications/Bleat.app"
    info = load_plist(app / "Info.plist")
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        raise InspectionFailure(
            "archive must declare that it uses only exempt encryption"
        )
    if info.get("BleatCarPlayMode") != carplay_mode:
        raise InspectionFailure("archive CarPlay mode does not match the requested mode")

    app_manifest = app / "PrivacyInfo.xcprivacy"
    inspect_privacy_manifest(load_plist(app_manifest))
    manifests = sorted(
        path.relative_to(app).as_posix() for path in app.rglob("PrivacyInfo.xcprivacy")
    )
    expected_manifests = {
        "PrivacyInfo.xcprivacy",
        "AppAuth_AppAuthCore.bundle/PrivacyInfo.xcprivacy",
        "SwiftProtobuf_SwiftProtobuf.bundle/PrivacyInfo.xcprivacy",
    }
    if set(manifests) != expected_manifests:
        raise InspectionFailure(
            f"archive privacy-manifest set changed: {', '.join(manifests)}"
        )
    for relative_path in expected_manifests - {"PrivacyInfo.xcprivacy"}:
        dependency_manifest = load_plist(app / relative_path)
        if dependency_manifest.get("NSPrivacyTracking") is not False:
            raise InspectionFailure(
                f"dependency manifest enables tracking: {relative_path}"
            )

    archive_info = load_plist(archive / "Info.plist")
    signing_identity = archive_info.get("ApplicationProperties", {}).get(
        "SigningIdentity"
    )
    if signing_identity:
        run_checked(["codesign", "--verify", "--deep", "--strict", str(app)])
        signed_entitlements = load_plist_text(
            run_checked(["codesign", "-d", "--entitlements", ":-", str(app)]),
            "signed entitlements",
        )
        inspect_carplay_entitlement(
            signed_entitlements,
            mode=carplay_mode,
            source="signed application",
        )
        embedded_profile = app / "embedded.mobileprovision"
        if not embedded_profile.is_file():
            raise InspectionFailure("signed iOS archive has no provisioning profile")
        profile = load_plist_text(
            run_checked(["security", "cms", "-D", "-i", str(embedded_profile)]),
            "embedded provisioning profile",
        )
        profile_entitlements = profile.get("Entitlements")
        if not isinstance(profile_entitlements, dict):
            raise InspectionFailure("embedded profile has no entitlements")
        inspect_carplay_entitlement(
            profile_entitlements,
            mode=carplay_mode,
            source="embedded profile",
            profile_values=True,
        )
    packages = resolved_packages(package_resolution)
    linkage = inspect_linkage(app, archive)

    print(
        f"Release archive inspection passed for "
        f"{info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})"
    )
    print("Privacy manifests:")
    for manifest in manifests:
        print(f"- {manifest}")
    print("Relevant package resolution and archive linkage:")
    for package in sorted(RELEVANT_PACKAGES):
        display_name = {
            "appauth-ios": "AppAuth",
            "opentelemetry-swift": "OpenTelemetry Swift",
            "opentelemetry-swift-core": "OpenTelemetry Swift",
            "swift-protobuf": "SwiftProtobuf",
            "swift-nio": "SwiftNIO",
            "swift-nio-ssl": "NIOSSL",
            "swift-crypto": "Swift Crypto",
        }[package]
        print(f"- {package} {packages[package]}: {linkage[display_name]}")
    if signing_identity:
        print("Code-signature verification passed.")
    else:
        print("Archive is unsigned; code-signature verification was not applicable.")
    print("No third-party dynamic frameworks are embedded.")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument(
        "--carplay-mode", required=True, choices=("enabled", "disabled")
    )
    parser.add_argument("--package-resolution", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        inspect_archive(
            arguments.archive, arguments.package_resolution, arguments.carplay_mode
        )
    except InspectionFailure as error:
        print(f"Release archive inspection failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
