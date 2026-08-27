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

Run the host test suite with code coverage:

```sh
swift test --enable-code-coverage
```

Run the complete current validation gate—core unit tests with coverage, Release
build, and iOS Simulator application unit and UI tests:

```sh
./scripts/test-core.sh
```
