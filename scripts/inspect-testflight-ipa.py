#!/usr/bin/env python3

import argparse
import datetime
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


class InspectionFailure(Exception):
    pass


CARPLAY_ENTITLEMENT = "com.apple.developer.carplay-audio"


def load_plist_bytes(payload: bytes, description: str) -> dict:
    try:
        value = plistlib.loads(payload)
    except plistlib.InvalidFileException as error:
        raise InspectionFailure(f"invalid {description} property list") from error
    if not isinstance(value, dict):
        raise InspectionFailure(f"{description} property list is not a dictionary")
    return value


def load_plist(path: Path, description: str) -> dict:
    try:
        return load_plist_bytes(path.read_bytes(), description)
    except OSError as error:
        raise InspectionFailure(f"could not read {description}") from error


def run_checked(arguments: list[str]) -> bytes:
    try:
        result = subprocess.run(arguments, check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise InspectionFailure(f"command failed: {arguments[0]}") from error
    return result.stdout


def require_entitlements(
    entitlements: dict,
    *,
    application_identifier: str,
    source: str,
    profile_values: bool = False,
) -> None:
    if entitlements.get("application-identifier") != application_identifier:
        raise InspectionFailure(f"{source} application identifier does not match")
    app_attest_environment = entitlements.get(
        "com.apple.developer.devicecheck.appattest-environment"
    )
    if profile_values:
        if (
            not isinstance(app_attest_environment, list)
            or "production" not in app_attest_environment
        ):
            raise InspectionFailure(f"{source} does not permit production App Attest")
    elif app_attest_environment != "production":
        raise InspectionFailure(f"{source} does not use production App Attest")
    cloud_services = entitlements.get("com.apple.developer.icloud-services")
    if profile_values:
        if cloud_services != "*" and (
            not isinstance(cloud_services, list) or "CloudKit" not in cloud_services
        ):
            raise InspectionFailure(f"{source} does not permit the CloudKit service")
    elif cloud_services != ["CloudKit"]:
        raise InspectionFailure(f"{source} does not contain the CloudKit service")
    if entitlements.get("get-task-allow") is not False:
        raise InspectionFailure(f"{source} unexpectedly permits debugging")
    keychain_groups = entitlements.get("keychain-access-groups")
    team_identifier = application_identifier.split(".", maxsplit=1)[0]
    permitted_keychain_groups = {application_identifier}
    if profile_values:
        permitted_keychain_groups.add(f"{team_identifier}.*")
    if not isinstance(
        keychain_groups, list
    ) or not permitted_keychain_groups.intersection(keychain_groups):
        raise InspectionFailure(f"{source} Keychain group does not match")


def require_carplay_entitlement(
    entitlements: dict, *, mode: str, source: str, profile_values: bool = False
) -> None:
    value = entitlements.get(CARPLAY_ENTITLEMENT)
    if mode == "enabled":
        if value is not True:
            raise InspectionFailure(f"{source} does not enable CarPlay audio")
    elif not profile_values and CARPLAY_ENTITLEMENT in entitlements:
        raise InspectionFailure(f"{source} unexpectedly contains CarPlay audio")


def inspect_ipa(
    ipa: Path,
    *,
    team: str,
    bundle_identifier: str,
    version: str,
    build: str,
    carplay_mode: str,
) -> None:
    application_identifier = f"{team}.{bundle_identifier}"
    with tempfile.TemporaryDirectory(prefix="bleat-testflight-ipa.") as directory:
        destination = Path(directory)
        try:
            with zipfile.ZipFile(ipa) as archive:
                archive.extractall(destination)
        except (OSError, zipfile.BadZipFile) as error:
            raise InspectionFailure("invalid IPA archive") from error

        applications = list((destination / "Payload").glob("*.app"))
        if len(applications) != 1:
            raise InspectionFailure("IPA must contain exactly one application")
        app = applications[0]
        info = load_plist(app / "Info.plist", "application Info.plist")
        if info.get("CFBundleIdentifier") != bundle_identifier:
            raise InspectionFailure("IPA bundle identifier does not match")
        if info.get("CFBundleShortVersionString") != version:
            raise InspectionFailure("IPA marketing version does not match")
        if info.get("CFBundleVersion") != build:
            raise InspectionFailure("IPA build number does not match")
        if info.get("BleatCarPlayMode") != carplay_mode:
            raise InspectionFailure("IPA CarPlay mode does not match")

        run_checked(["codesign", "--verify", "--deep", "--strict", str(app)])
        signed_entitlements = load_plist_bytes(
            run_checked(["codesign", "-d", "--entitlements", ":-", str(app)]),
            "signed entitlements",
        )
        require_entitlements(
            signed_entitlements,
            application_identifier=application_identifier,
            source="signed application",
        )
        require_carplay_entitlement(
            signed_entitlements,
            mode=carplay_mode,
            source="signed application",
        )

        profile = load_plist_bytes(
            run_checked(
                ["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")]
            ),
            "embedded provisioning profile",
        )
        if (
            profile.get("ProvisionsAllDevices") is True
            or "ProvisionedDevices" in profile
        ):
            raise InspectionFailure("embedded profile is not an App Store profile")
        team_identifiers = profile.get("TeamIdentifier")
        if not isinstance(team_identifiers, list) or team not in team_identifiers:
            raise InspectionFailure("embedded profile team does not match")
        profile_entitlements = profile.get("Entitlements")
        if not isinstance(profile_entitlements, dict):
            raise InspectionFailure("embedded profile has no entitlements")
        require_entitlements(
            profile_entitlements,
            application_identifier=application_identifier,
            source="embedded profile",
            profile_values=True,
        )
        require_carplay_entitlement(
            profile_entitlements,
            mode=carplay_mode,
            source="embedded profile",
            profile_values=True,
        )
        cloudkit_environments = profile_entitlements.get(
            "com.apple.developer.icloud-container-environment"
        )
        if (
            not isinstance(cloudkit_environments, list)
            or "Production" not in cloudkit_environments
        ):
            raise InspectionFailure(
                "embedded profile does not permit production CloudKit"
            )
        expiration = profile.get("ExpirationDate")
        if not isinstance(expiration, datetime.datetime):
            raise InspectionFailure("embedded profile has no expiration date")
        if expiration.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(
            datetime.timezone.utc
        ):
            raise InspectionFailure("embedded profile has expired")

    print(f"TestFlight IPA inspection passed for Bleat {version} ({build}).")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--team", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument(
        "--carplay-mode", required=True, choices=("enabled", "disabled")
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        inspect_ipa(
            arguments.ipa,
            team=arguments.team,
            bundle_identifier=arguments.bundle_id,
            version=arguments.version,
            build=arguments.build,
            carplay_mode=arguments.carplay_mode,
        )
    except InspectionFailure as error:
        print(f"TestFlight IPA inspection failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
