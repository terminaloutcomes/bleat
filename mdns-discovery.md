# Audiobookshelf Bonjour Discovery

Bleat discovers Audiobookshelf servers advertised as
`_audiobookshelf._tcp` in the `local.` Bonjour domain and converts each valid
advertisement into an HTTPS base URL.

## Service contract

The SRV record supplies the authoritative hostname and port. HTTPS is implicit
in the service type. The optional TXT key `path` supplies the server path
prefix and defaults to `/`.

For example:

```text
Audiobookshelf._audiobookshelf._tcp.local.
  SRV 0 0 443 audiobookshelf.housenet.yaleman.org.
  TXT "path=/"
```

must resolve to:

```text
https://audiobookshelf.housenet.yaleman.org
```

The URL must use the SRV hostname, not a resolved IP address. This preserves
normal DNS lookup, TLS SNI, certificate hostname validation, and reverse-proxy
host routing. Bleat does not set a manual `Host` header or weaken system trust.

## Implementation contract

1. Browse with `NWBrowser.Descriptor.bonjourWithTXTRecord`, service type
   `_audiobookshelf._tcp`, and domain `local.`.
2. Identify a service by its instance name, type, domain, and interface index.
3. Resolve additions and material changes with `DNSServiceResolve`.
4. Pass the instance name, type, domain, and discovered interface index to
   `DNSServiceResolve` exactly as `NWBrowser` supplied them. Do not construct a
   full DNS name and pass it as the instance name.
5. Read `hosttarget`, the network-byte-order port, and the TXT record from the
   resolve callback. Stop and release the `DNSServiceRef` after success,
   failure, timeout, or cancellation.
6. Remove one trailing DNS root dot from `hosttarget`. Reject a missing or
   malformed hostname and port zero.
7. Parse TXT data with `NetService.dictionary(fromTXTRecord:)`. The `path`
   value must be UTF-8, begin with `/`, and contain no query, fragment, or
   authority override. Missing `path` means `/`.
8. Construct the HTTPS URL with `URLComponents`, omit port 443, then validate
   and normalize it with `NormalizedServerURL`.
9. Verify the candidate using `ServerDiscoveryClient`, which requests the
   server's `/status` route through ordinary `URLSession` system trust.
10. Resolve a service only once at a time. Cancel its resolution and discard
    its result when the browser removes or materially changes it.

Browser failures, malformed advertisements, resolution failures, and server
verification failures remain distinct typed states. A no-results timer must
not overwrite a browser failure.

## Application configuration

The generated application property list contains:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Bleat connects to your Audiobookshelf server on the local network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_audiobookshelf._tcp</string>
</array>
```

Bleat does not browse `_https._tcp`.

## Validation

Unit tests cover request arguments, URL construction, TXT parsing, invalid
advertisements, lifecycle handling, and result deduplication. The add-server
form automatically browses and shows verified results while retaining direct
HTTPS entry and typed retry states. Diagnostics on iPhone, iPad, and Mac run
the same production pipeline and show its non-secret resolution stages.

Physical-device validation on the advertising LAN resolved the documented SRV
hostname, port, and TXT path into the expected hostname-based URL and verified
`/status` with ordinary system trust. No IP URL, trust exception, custom
`Host` header, or alternate service type is used.
