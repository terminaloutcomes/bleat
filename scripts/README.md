# App Store Connect analytics dump

`appstore-monitor` requests App Store Connect analytics reports and stores DAILY
instances locally. Apple generates reports asynchronously, usually after 1–2 days;
run the request command first and download later. Apple retains report instances for
35 days. The command ignores WEEKLY and MONTHLY instances.

## Access and credentials

Create one App Store Connect API key with access to the app. The caller supplies
that same key to every command. Request creation needs an Admin API key. Listing and downloading reports accepts
Admin, Sales and Reports, or Finance API keys.
Apple decides the effective authorization and the command reports HTTP 401/403
as an authorization failure. It does not inspect roles or switch keys.

Set these variables for every command:

- `APPSTORE_CONNECT_ISSUER_ID`: API issuer UUID.
- `APPSTORE_CONNECT_KEY_ID`: API key ID.
- `APPSTORE_CONNECT_PRIVATE_KEY_BASE64`: base64 encoding of the downloaded `.p8` key.
- `APPSTORE_CONNECT_APP_ID`: numeric App Store Connect app ID.

For `one-time-snapshot` and `download-reports`, also set
`APPSTORE_CONNECT_DOWNLOAD_DIR` to an absolute directory outside the repository.
The command has no default directory or directory flag. Keep this directory
between runs so snapshot reuse and verified-download state persist.

Create the API key in App Store Connect under Users and Access → Integrations →
App Store Connect API. Download the `.p8` file when Apple offers it; Apple only
allows one download. Store it in Keychain, not in this repository. For example,
with the repository's `keychain-secret` helper, provide the environment at
invocation time:

```sh
APPSTORE_CONNECT_ISSUER_ID="$(keychain-secret get appstore-issuer-id)" \
APPSTORE_CONNECT_KEY_ID="$(keychain-secret get appstore-key-id)" \
APPSTORE_CONNECT_PRIVATE_KEY_BASE64="$(keychain-secret get --base64 appstore-key-secret)" \
APPSTORE_CONNECT_APP_ID="$(keychain-secret get appstore-app-id)" \
cargo run --package scripts --bin appstore-monitor -- create-report
```

The same environment prefix works with each command below. The tool reads no
alternative credential variables for these commands.

## Commands

```text
appstore-monitor create-report
appstore-monitor one-time-snapshot
appstore-monitor download-reports --access-type ongoing
appstore-monitor download-reports --access-type one-time-snapshot
```

`create-report` reuses an active ONGOING request or creates one and prints its ID.
`one-time-snapshot` stores a request for the current UTC month and reuses that
request on subsequent invocations. Apple permits only one snapshot request per
month. Keep `snapshots.json` in the configured download directory between runs
so the same monthly request can be found. Request commands do not wait for
generation.

When several requests are eligible, the downloader retains each available DAILY
processing date for each report name and category. For an overlapping date, it
uses the request with the newest available processing date and includes ties.

Under `APPSTORE_CONNECT_DOWNLOAD_DIR`, compressed
segment bytes are stored in `segments/<request>/<report>/<instance>/<segment>.gz`;
corresponding typed JSON Lines are stored beside them as `.ndjson`.
`manifest.json` records segment IDs, checksums and relative file paths.
Downloads use temporary files and atomic renames. A rerun skips a segment only
when the manifest entry exists and the compressed file still passes size and
checksum verification. Incomplete temporary files are ignored on the next run.

Each NDJSON row contains request, access type, report, variant when identifiable,
instance, segment, granularity, checksum and processing date metadata, plus a
`columns` object with the original tab-delimited column names and values.
Unrecognized columns are retained. Report-specific metric typing is added by
the subsequent normalization work. No signed segment URL or credential is
written to the local dump.
