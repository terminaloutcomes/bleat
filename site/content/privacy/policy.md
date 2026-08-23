+++
title = "Privacy Policy"
description = "How Bleat handles information on your device, with your Audiobookshelf server, and when you opt in to remote diagnostics."
template = "page.html"
+++

Last updated: 23 August 2026

Bleat is a client for an Audiobookshelf server run by you. Information
handled by Bleat stays on your device or travels directly between Bleat and
that server. Terminal Outcomes does not operate or control your Audiobookshelf
server and does not receive your library or account data through normal use of
the app.

## Information handled on your device

Bleat stores the information needed to provide its features, including your
saved server and account details, library cache, listening progress, bookmarks,
preferences, downloads, and any transcripts you create. Credentials and access
tokens are stored using Apple's Keychain. Downloaded audio remains in Bleat's
app-owned storage on your device.

Bleat may use your private iCloud account to synchronize supported settings and
records when iCloud synchronization is enabled. That data is
stored in your private CloudKit database on Apple's servers. It is not
available to Terminal Outcomes.

Local Diagnostics is available without sharing data with Terminal Outcomes.
Diagnostic snapshots are created only when you choose to export them. They can
include server hostnames and ports, so review a snapshot before sharing it.

You can remove an account and its account-owned local data in Bleat. Removing
the app also removes its app-container data, subject to the normal behavior of
device backups, iCloud, and your Audiobookshelf server.

## Information sent to your Audiobookshelf server

When you use Bleat, the app sends requests directly to the Audiobookshelf
server you selected. These requests can include credentials, account and
library requests, playback sessions, progress, bookmarks, searches, metadata
changes, and media downloads. The server operator's privacy practices apply to
that data.

Bleat uses HTTPS with system certificate validation for production
connections. It does not send Audiobookshelf credentials or access tokens to
Terminal Outcomes.

## Optional remote diagnostic telemetry on iOS

**Share diagnostic telemetry** is off by default. If you turn it on, Bleat may
send limited, anonymised technical information to Terminal Outcomes so we can
secure and improve the app.

The diagnostic information describes how Bleat is working, not what you are
listening to or who you are. Apple's App Store categories and purposes are:

- Device ID, linked to the installation, for app functionality;
- Product Interaction, not linked to the installation, for analytics;
- Performance Data, not linked to the installation, for app functionality;
- Other Diagnostic Data, linked to the installation, for app functionality.

Bleat reports only specific operations, such as app launch, account connection,
library refresh, playback, downloads, progress synchronization, transcription,
and private iCloud synchronization. A report can include the app and operating
system versions, whether the operation worked, how long it took, a general
error category, whether playback was "downloaded" or "streamed" (not where it
came from), and the number of retries. iCloud reports can also include Apple's
CloudKit error code and when a retry is allowed - but not the data.

Bleat uses a random installation identifier and Apple's App Attest state feature
to authenticate diagnostic uploads and limit attacks. The app keeps the
App Attest key identifier and random installation identifier in its
device-only Keychain. Upload tokens stay in memory and expire within ten
minutes. These identifiers, App Attest evidence, tokens, and token details are
not included in the diagnostic reports.

The service that protects uploads keeps a separate security record containing
the random installation identifier, App Attest key identifier and public key,
status, security counter, and timestamps. Its own security logs can include
the device's network address and the application name. This is why Device ID
and Other Diagnostic Data are declared as linked even though the diagnostic
reports themselves are anonymised.

Remote diagnostics exclude audiobook content and metadata, audio, cover art,
transcripts and subtitles, searches and other entered text, usernames and
account identifiers, credentials, tokens and cookies, Audiobookshelf server
addresses, media and playback URLs, local paths, hardware identifiers, and
advertising identifiers.

## Retention and access

On an opted-in iOS device, undelivered diagnostic reports may be kept in
protected local storage for up to two hours. Bleat deletes them after delivery
or when you turn sharing off. Some diagnostic events are held only in memory
and disappear when the app closes.

After the reports reach Terminal Outcomes, operation reports and diagnostic event
logs are deleted after a short period. No other permanent copy is
kept. The separate upload-security record does not currently expire
automatically. It remains until an operator deletes it or the service is shut
down.

Only the Terminal Outcomes operator can view diagnostics through the protected
diagnostics service. Direct database access is limited to the service itself
and the administrator with the required credentials.

## No tracking, advertising, or sale

Bleat does not use this information for advertising or tracking across apps or
websites. Terminal Outcomes does not sell it or share it with data brokers.

## Your choices and contact

You can enable or withdraw optional remote diagnostics at any time. See
[Your Privacy Choices](/privacy/your-choices/) for the control and the exact
effect of withdrawal.

For privacy questions or a request concerning an upload-security record,
email [bleat@terminaloutcomes.com](mailto:bleat@terminaloutcomes.com). We may
need information from you to identify the relevant installation record, and we
cannot identify data that the app never sends to us.

We may update this policy when Bleat's behavior changes. The current version
will remain available at this URL.
