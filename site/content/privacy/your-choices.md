+++
title = "Your Privacy Choices"
description = "How to enable or withdraw optional remote diagnostic telemetry in Bleat."
template = "page.html"
+++

Bleat's remote diagnostic telemetry is optional and off by default. The choice
is stored on this device and is not synchronized through iCloud.

## Change diagnostic sharing

On iPhone or iPad:

1. Open **Settings** in Bleat.
2. Open **Diagnostics**.
3. Under **Privacy**, turn **Share diagnostic telemetry** on or off.

You can change this setting at any time, including while signed out or when
Bleat cannot finish starting.

## What happens when you turn it off

Bleat immediately records your withdrawal before it:

- stops creating and sending new diagnostic reports;
- stops requesting short-lived upload access and cancels any upload in
  progress;
- clears temporary upload credentials; and
- deletes any unsent diagnostic reports stored by Bleat.

Turning remote sharing off does not disable the local Diagnostics screen or
remove your Audiobookshelf accounts, library cache, downloads, progress,
bookmarks, preferences, or transcripts.

Withdrawal does not automatically delete the existing upload-security record.
Any current upload access expires within ten minutes, but the security record
does not currently expire automatically. It remains until an operator deletes
it or the service is shut down. Bleat does not send more security or diagnostic
data while sharing remains off.

If you later turn sharing on, Bleat does not contact Terminal Outcomes until it
has a diagnostic report to send. It can then reuse the device's existing
security record and request new short-lived upload access.

## Questions and deletion requests

Email [bleat@terminaloutcomes.com](mailto:bleat@terminaloutcomes.com) with a
privacy question or a request concerning an upload-security record. We may
need information from you to identify the relevant installation record, and we
cannot identify diagnostic data that Bleat never linked to your installation.

For more detail, read the [Privacy Policy](/privacy/policy/).
