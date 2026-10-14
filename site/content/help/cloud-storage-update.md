+++
title = "Listening history and iCloud storage update"
description = "What changes in Bleat 2026.10.14, and how to keep your listening history syncing between devices."
template = "page.html"
+++

Bleat 2026.10.14 changes how listening history is stored and synced. Your existing history is preserved automatically when you update. You do not need to export it or clear your iCloud data.

## What changed?

Earlier versions created a new listening record about every five seconds. Long listening histories could make syncing slow because Bleat repeatedly saved a large amount of sync information in its preferences.

The new version keeps extending one record while you listen continuously. It saves your progress locally every five seconds and sends the completed record to iCloud when the listening segment ends, or when Bleat syncs. Pausing, seeking, changing playback speed, or changing chapters can start a new segment.

Sync information now lives in Bleat's local database. Each sync saves the information that changed, which avoids repeatedly rewriting the whole history's sync information.

## Should I update every device?

Yes. Update Bleat on your iPhone and iPad to **2026.10.14 or later** so each device benefits from the storage changes.

Older versions can still read the completed listening records from the new version, and the new version can read their existing records. We verified syncing in both directions with Bleat 0.1.3. An older device still uses the old storage method, so catching up on a large history may take time.

With iCloud sync enabled and the same iCloud account on your devices, history continues syncing between them. A record that is still growing stays on the device until it is finalized and synced. To send recent listening, pause playback and use **Settings → iCloud → Sync Now**.

## Why did I see “Cloud storage update”?

Bleat found older sync information or listening records. The message recommends updating all your devices; it does not mean Bleat detected another device running an old version. Tap **OK** to acknowledge it once on that installation.

## Do I need to clear my CloudKit data?

No. Clearing cloud data is not part of this update or its migration.

**Clear My CloudKit Data** is in its own section below **Diagnostics** in Bleat's Settings. It deletes Bleat's data from iCloud and turns off sync on that device while keeping local data. Other devices with sync enabled may upload their local data again. Use it only when you intend to remove the cloud copy.
