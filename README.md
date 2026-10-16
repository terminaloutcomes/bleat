# Bleat

<a href="https://apps.apple.com/app/id6802494228"><img src="site/static/Download_on_the_App_Store_Badge_US-UK_RGB_blk_092917.svg" alt="Download on the App Store" height="48"></a>
<a href="https://buymeacoffee.com/yaleman"><img src="site/static/bmc-button.svg" alt="Buy me a coffee" height="48"></a>

Bleat is a native [Audiobookshelf](https://www.audiobookshelf.org/) client for
iPhone and iPad running iOS 26 or newer, with a shared native macOS 26 target.

- Browse and search libraries, authors, series, collections, and narrators.
- Stream audiobooks, control playback from Now Playing and CarPlay, and keep
  downloaded books available offline.
- Use multiple accounts, native password or server-advertised OpenID Connect
  login, and optional private iCloud synchronization.
- Manage bookmarks, edit books when your server permissions allow it, and
  explore or export listening statistics.
- Generate chapter transcripts on device and navigate from transcript text.

## Get started

Install Bleat and connect to your Audiobookshelf server using its complete
HTTPS address. Follow the [user guide](https://bleat.terminaloutcomes.com/help/using-bleat/)
or [OpenID Connect setup guide](https://bleat.terminaloutcomes.com/help/oidc-setup/).

To build from source, use macOS 26 or newer, Xcode with Swift 6.2 or newer,
and the tools and local configuration described in
[contributor setup](docs/contributing.md). Then open `Bleat.xcodeproj`, select
the `Bleat` scheme and an installed iPhone or iPad simulator, and run the app.
Use the `BleatMac` scheme for the native Mac target.

## Project documentation

- [Development and validation](docs/development.md)
- [Architecture and feature ownership](docs/architecture.md)
- [Product and technical specification](docs/audiobookshelf-ios-app-spec.md)
- [Requirements and evidence](docs/requirements-traceability.md)
- [Audiobookshelf compatibility](docs/audiobookshelf-compatibility.md)
- [Website development](docs/website.md)
