import datetime
import plistlib
from pathlib import Path

archive = plistlib.loads(Path("/tmp/bleat-cloud-state-inner.bin").read_bytes())
objects = archive["$objects"]


def resolve(value, stack=frozenset()):
    if isinstance(value, plistlib.UID):
        index = value.data
        if index in stack:
            return {"cycle": True}
        return resolve(objects[index], stack | {index})
    if isinstance(value, list):
        return [resolve(item, stack) for item in value]
    if not isinstance(value, dict):
        return value

    class_value = value.get("$class")
    class_name = None
    if isinstance(class_value, plistlib.UID):
        class_object = objects[class_value.data]
        if isinstance(class_object, dict):
            class_name = class_object.get("$classname")

    if class_name in {"NSArray", "NSMutableOrderedSet"}:
        return [resolve(item, stack) for item in value.get("NS.objects", [])]
    if class_name == "NSMutableDictionary":
        keys = value.get("NS.keys", [])
        values = value.get("NS.objects", [])
        return {
            str(resolve(key, stack)): resolve(item, stack)
            for key, item in zip(keys, values)
        }
    return {
        str(key): resolve(item, stack) for key, item in value.items() if key != "$class"
    }


root = resolve(archive["$top"]["root"])
interesting = {
    "hasInFlightUntrackedChanges",
    "hasPendingUntrackedChanges",
    "inFlightAssetSyncs",
    "inFlightRecordModifications",
    "inFlightZoneChanges",
    "lastFetchDatabaseChangesDate",
    "needsToFetchDatabaseChanges",
    "needsToSaveDatabaseSubscription",
    "pendingAssetSyncs",
    "pendingRecordModifications",
    "pendingZoneChanges",
    "zoneIDsNeedingToFetchChanges",
}


def summary(value):
    if isinstance(value, (bool, int, float)):
        return repr(value)
    if isinstance(value, list):
        return f"list_count={len(value)}"
    if isinstance(value, dict):
        if set(value) == {"NS.time"} and isinstance(value["NS.time"], (int, float)):
            timestamp = datetime.datetime(
                2001, 1, 1, tzinfo=datetime.timezone.utc
            ) + datetime.timedelta(seconds=value["NS.time"])
            return f"date={timestamp.isoformat()}"
        return f"dictionary_count={len(value)}"
    if isinstance(value, bytes):
        return f"bytes={len(value)}"
    if isinstance(value, str):
        return f"string_present={bool(value)} length={len(value)}"
    if value is None:
        return "none"
    return type(value).__name__


def walk(value, path="root"):
    if isinstance(value, dict):
        for key, item in value.items():
            child_path = f"{path}.{key}"
            if key in interesting:
                print(f"{child_path}: {summary(item)}")
            walk(item, child_path)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            walk(item, f"{path}[]")


walk(root)
