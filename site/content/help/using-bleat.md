+++
title = "Using Bleat"
description = "Connect, browse, listen, and download audiobooks with Bleat."
template = "page.html"
+++

## Connect to your server

Enter the complete HTTPS address of your Audiobookshelf server, including any
path prefix, then sign in with your username and password. Verified nearby
servers can be selected from the add-server screen. Bleat requires
Audiobookshelf 2.26.0 or newer. If your server offers OpenID Connect, use its
sign-in button; see the [OIDC setup guide](/help/oidc-setup/).

Settings lets you add accounts, choose the browsing account, and edit a saved
account. Leave the password blank while editing to retain it. Switching the
browsing account stops playback and clears Now Playing; other accounts' downloads
continue.
An optional Local Network URL can provide access to the same server at home.

## Browse and listen

Home shows personalized shelves. Library supports browsing by title, author,
series, collection, or narrator, filtering finished status, and sorting.
Pull down to refresh. Open a book for its description, chapters, progress,
bookmarks, and available actions. Server permissions control editing and deletion.

Tapping the mini-player opens the full player, where you
can seek, choose chapters, change speed, and set a sleep timer. Now Playing and
CarPlay provide system playback controls; available CarPlay search depends on
the operating system. Opening downloaded books from Home opens their details.

### iPad keyboard shortcuts

With a keyboard connected, use Command-P for play/pause, Command-Left Arrow
and Command-Right Arrow to skip by your configured intervals, and
Command-Minus and Command-Plus to move through the featured playback speeds.
Command-F opens Search, retains your query, and focuses its text field.

Playback shortcuts leave text editing to the focused field and are unavailable
behind other sheets or confirmations. Command-F works while editing Search,
but does not dismiss another sheet or confirmation. Standard text-entry keys,
including Space and arrow keys, keep their usual meaning.

## Download and use offline

Use a book's download action to keep its audio locally. Settings provides
storage and download preferences. Large downloads on cellular may require
confirmation. Completed downloads remain playable without the server, including
when an account needs sign-in again. Progress and bookmark changes synchronize
when the account is reachable. Avoid removing an account if you want to keep
its account-owned downloads and history.

## Synchronization and statistics

Private iCloud synchronization is enabled by default and
can be turned off in Settings. Turning it off keeps local data; the confirmation
also offers deletion of the private cloud copy. Conflicting account or preference
changes require your choice before application.

Open "Listening Statistics" from Home to compare accounts and date ranges, view
listening history, and import or export an account's archive. Coverage labels
explain stale, local-only, or uncertain totals. Reset affects Bleat's selected
local history; later imports can restore sessions still held by the server.

## Transcripts and troubleshooting

Book chapters can be transcribed on-device when Apple's language support is
available. Transcript position controls and search results navigate the text
and can seek playback. Transcription may require downloading a language asset.

Settings > Diagnostics shows connection and synchronization status. Remote
diagnostic telemetry is controlled in iOS Settings > Apps > Bleat and is off by
default. See [Privacy Choices](/privacy/your-choices/) for what it includes.
Report problems with the app/build version and reproducible steps, without
sharing credentials, tokens, private server addresses, or playback routes.
