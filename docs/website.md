# Website

The Zola site source lives in `site/`. Install its pinned toolchain with
`mise install`, then use:

- `mise run site-css` to install the locked frontend packages and generate CSS;
- `mise run site-check` to validate the Zola project;
- `mise run site-build` to build `site/public`;
- `mise run site-serve` to preview it locally.

The published website includes the stable
[Audiobookshelf OIDC setup guide](https://bleat.terminaloutcomes.com/help/oidc-setup/)
linked from Bleat's add-server screen. It documents the canonical
`bleat://oauth2redirect` callback and the root-hosted and path-prefixed
Audiobookshelf provider callbacks.

The Help section also includes `site/content/help/cloud-storage-update.md`, a
plain-language guide to the 2026.10.14 listening-history and iCloud storage
changes, preserved history, mixed-version sync, the one-time notice, and the
separate clear-cloud-data control.

The [News page](https://bleat.terminaloutcomes.com/news/) renders the repository's
`CHANGELOG.md` at build time. The `site-news` task generates the ignored
`site/content/news.md` before site checks and builds. Edit the
changelog to update release news; no separate news copy needs maintaining. The
app's About page links to the website and News, while build date, developer, and
bundle identifier appear in Diagnostics.
