# App Store Connect analytics dump

`appstore-monitor` requests App Store Connect analytics reports and stores DAILY
instances locally. Apple generates reports asynchronously, usually after 1–2 days;
run the request command first and download later. Apple retains report instances for
35 days. The command ignores WEEKLY and MONTHLY instances.

## Access and credentials

The caller supplies a key through the same environment variables for every
command. Request creation needs an Admin API key. Listing and downloading
reports accepts Admin, Sales and Reports, or Finance API keys. The
`appstore:connect-admin` and `appstore:connect-download` Mise tasks select their
respective keys from Keychain.
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
appstore-monitor download-reports --access-type one-time-snapshot --list
```

`create-report` reuses an active ONGOING request or creates one and prints its ID.
`one-time-snapshot` stores a request for the current UTC month and reuses that
local request ID on subsequent invocations. It does not list requests with the
creation key before posting. Apple permits only one snapshot request per month;
keep `snapshots.json` in the configured download directory so reruns do not
submit a duplicate. Request commands do not wait for generation.

`download-reports --list` reads the selected request's report inventory without
downloading or changing local files. It prints every generated report's DAILY
instance, other-granularity instance, and DAILY segment counts plus the latest
DAILY processing date. If Apple has not
generated reports yet, it says so explicitly. Apple does not expose a pending
status for individual reports; an absent report or instance may also mean no
eligible or privacy-permitted data exists.

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
Unrecognized columns are retained. App Store Downloads Standard and Detailed
rows also contain a typed `download` object with the report variant, event date,
app identity, download type, dimensions, count, and `total_downloads` contribution.
The latter is the count for first-time downloads and redownloads and zero for
updates and restores. Query one variant at a time: Standard and Detailed are
separate aggregates and must not be summed together. Detailed attribution
(`source_info`, `campaign`, and `page_title`) is optional and remains null for
Standard rows. Unknown download types and missing or malformed required values
reject the entire segment. No signed segment URL or credential is written to
the local dump.

App Store Discovery and Engagement Standard and Detailed rows contain a typed
`discovery` object. It records the event as impression, page view, or tap, with
numeric `count` and `unique_count` fields. Detailed source info, campaign, and
page title remain absent on Standard rows. Engagement type may be absent when
there was no user action. A privacy-suppressed report row is absent data; the
tool does not invent a zero row. Do not sum unique counts across dimensional
rows, combine Standard and Detailed counts, or derive a conversion rate from a
single report row. Match date and source and page dimensions with Downloads
before calculating conversion rates downstream.

App Store Purchases Standard and Detailed rows contain a typed `purchase` object
with purchase and content identities, attribution, signed `purchases`, exact
decimal `proceeds_usd` and `sales_usd` JSON numbers, and `paying_users`. Negative
values retain refund evidence; zero purchases with negative money retains
partial-refund evidence. Treat purchase count, proceeds, sales, and paying users
as separate metrics. Paying users cannot be summed across dimensional rows,
and Standard and Detailed totals cannot be combined. An empty daily Purchases
segment is a successful empty result for an app without purchase activity.

App Store Installations and Deletions Standard and Detailed rows contain a
typed `installation` object with distinct install/delete events and App Store
download types. The download type describes the store action, while the event
describes the device installation state. Counts and numeric `unique_devices`
cover only users who opted to share analytics with Apple and developers. Apple
provides the report only when events exist from at least five users, and
Detailed reports apply additional privacy measures. A missing or suppressed
row is absent data, never zero. `app_download_date` is null when the download
was more than 30 days ago. Detailed attribution is optional and remains null
in Standard rows. Unique devices are non-additive across dimensional rows;
install and delete counts remain separate, and Standard and Detailed totals
must never be combined.

App Sessions Standard and Detailed rows contain a typed `session` object with
session count, unique devices, and total session duration in seconds as separate
metrics. Detailed attribution fields are optional. Apple's App Crashes report
has a single variant; its rows contain a separate typed `crash` object with
crash count and unique devices. Both retain the Apple processing date and
report variant. Their metadata states that only opted-in users are represented,
Apple provides data only when events exist from at least five users, and missing or
privacy-suppressed rows do not mean zero. Keep Standard and Detailed aggregates
separate; unique devices are non-additive across dimensional rows.
