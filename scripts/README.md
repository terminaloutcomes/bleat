# Repository scripts

The Rust `scripts` package contains repository tooling. Put reusable logic in
`scripts/src/` and keep `scripts/src/bin/` entry points thin. Add dependencies
with Cargo; existing shell and Python workflows remain supported, but new or
substantially changed scripting logic belongs in Rust.

Run tasks from the repository root with the required ignored `.envrc` present.

| Work | Entry point | Reference |
| --- | --- | --- |
| Documentation references | `mise run docs:check` | [Contributor guide](../docs/contributing.md#documentation-checks) |
| Release metadata | `mise run release:check` | [Release packaging](../docs/development.md#release-packaging) |
| Device installation | `mise run iphone`, `mise run ipad` | [Device workflows](../docs/developer-tools.md#install-on-a-personal-iphone-or-ipad) |
| Live fixtures | `mise run fixtures:live` | [Compatibility](../docs/audiobookshelf-compatibility.md) |
| App Store operations | `mise run appstore:status` | [Development](../docs/development.md#release-packaging) |
| Analytics ingestion | Cargo analytics commands | [Analytics guide](../docs/appstore-analytics.md) |

For validation selection, artifacts, and command side effects, see the
[validation matrix](../docs/contributing.md#choose-validation).
