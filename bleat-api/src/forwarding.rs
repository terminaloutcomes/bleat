use std::{
    net::{IpAddr, Ipv6Addr, SocketAddr},
    str::FromStr,
};

use axum::http::{HeaderMap, HeaderName};

use crate::config::{ForwardingHeader, TrustedProxyConfig};

pub(crate) const FORWARDING_DEBUG_TARGET: &str = "bleat_api::forwarding_debug";
const MAX_HEADER_BYTES: usize = 8 * 1024;
const MAX_HOPS: usize = 32;
const CF_CONNECTING_IP: HeaderName = HeaderName::from_static("cf-connecting-ip");
const CF_CONNECTING_IPV6: HeaderName = HeaderName::from_static("cf-connecting-ipv6");
const FORWARDED: HeaderName = HeaderName::from_static("forwarded");
const X_FORWARDED_FOR: HeaderName = HeaderName::from_static("x-forwarded-for");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ForwardingFailure {
    Conflict,
    ExcessiveHops(ForwardingHeader),
    ExhaustedChain(ForwardingHeader),
    Hostname(ForwardingHeader),
    Malformed(ForwardingHeader),
    MissingFor(ForwardingHeader),
    Multiplicity(ForwardingHeader),
    NonUtf8(ForwardingHeader),
    Obfuscated(ForwardingHeader),
    Oversized(ForwardingHeader),
    Unknown(ForwardingHeader),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ClientAddressDecision {
    NoForwardingConfigured,
    NoForwardingHeaders,
    Resolved(ForwardingHeader),
    ResolvedMultiple,
    UntrustedPeer,
    Fallback(ForwardingFailure),
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) struct ClientAddressResolution {
    pub client: IpAddr,
    pub decision: ClientAddressDecision,
    pub parsed_hops: Vec<IpAddr>,
}

#[derive(Debug)]
struct FamilyResolution {
    family: ForwardingHeader,
    client: IpAddr,
    hops: Vec<IpAddr>,
}

pub(crate) fn resolve_client_address(
    config: &TrustedProxyConfig,
    peer: SocketAddr,
    headers: &HeaderMap,
) -> ClientAddressResolution {
    let resolution = resolve(config, peer.ip(), headers);
    if config.debug {
        log_forwarding_debug(config, peer, headers, &resolution);
    }
    resolution
}

fn resolve(
    config: &TrustedProxyConfig,
    peer: IpAddr,
    headers: &HeaderMap,
) -> ClientAddressResolution {
    if config.forwarding_headers().is_empty() {
        return socket_resolution(peer, ClientAddressDecision::NoForwardingConfigured);
    }
    if !is_trusted(config, peer) {
        return socket_resolution(peer, ClientAddressDecision::UntrustedPeer);
    }

    let mut resolved = Vec::new();
    for family in config.forwarding_headers() {
        let family_result = match family {
            ForwardingHeader::Cloudflare => resolve_cloudflare(headers),
            ForwardingHeader::Forwarded => resolve_forwarded(config, headers),
            ForwardingHeader::XForwardedFor => resolve_x_forwarded_for(config, headers),
        };
        match family_result {
            Ok(Some(value)) => resolved.push(value),
            Ok(None) => {}
            Err(error) => {
                return socket_resolution(peer, ClientAddressDecision::Fallback(error));
            }
        }
    }

    let Some(first) = resolved.first() else {
        return socket_resolution(peer, ClientAddressDecision::NoForwardingHeaders);
    };
    if resolved.iter().any(|value| value.client != first.client) {
        return socket_resolution(
            peer,
            ClientAddressDecision::Fallback(ForwardingFailure::Conflict),
        );
    }

    let mut parsed_hops = Vec::new();
    for value in &resolved {
        parsed_hops.extend(value.hops.iter().copied());
    }
    ClientAddressResolution {
        client: first.client,
        decision: if resolved.len() == 1 {
            ClientAddressDecision::Resolved(first.family)
        } else {
            ClientAddressDecision::ResolvedMultiple
        },
        parsed_hops,
    }
}

fn socket_resolution(peer: IpAddr, decision: ClientAddressDecision) -> ClientAddressResolution {
    ClientAddressResolution {
        client: peer,
        decision,
        parsed_hops: Vec::new(),
    }
}

fn resolve_cloudflare(headers: &HeaderMap) -> Result<Option<FamilyResolution>, ForwardingFailure> {
    ensure_family_size(
        headers,
        &[&CF_CONNECTING_IP, &CF_CONNECTING_IPV6],
        ForwardingHeader::Cloudflare,
    )?;
    let ipv4_or_ipv6 =
        single_header_value(headers, &CF_CONNECTING_IP, ForwardingHeader::Cloudflare)?;
    let ipv6 = single_header_value(headers, &CF_CONNECTING_IPV6, ForwardingHeader::Cloudflare)?;
    if ipv4_or_ipv6.is_none() && ipv6.is_none() {
        return Ok(None);
    }

    let normal = ipv4_or_ipv6
        .map(|value| parse_address(value, ForwardingHeader::Cloudflare))
        .transpose()?;
    let preferred_ipv6 = ipv6
        .map(|value| parse_address(value, ForwardingHeader::Cloudflare))
        .transpose()?;
    if preferred_ipv6.is_some_and(|address| !address.is_ipv6()) {
        return Err(ForwardingFailure::Malformed(ForwardingHeader::Cloudflare));
    }
    let client = preferred_ipv6
        .or(normal)
        .ok_or(ForwardingFailure::Malformed(ForwardingHeader::Cloudflare))?;
    Ok(Some(FamilyResolution {
        family: ForwardingHeader::Cloudflare,
        client,
        hops: vec![client],
    }))
}

fn resolve_forwarded(
    config: &TrustedProxyConfig,
    headers: &HeaderMap,
) -> Result<Option<FamilyResolution>, ForwardingFailure> {
    let Some(values) = header_values(headers, &FORWARDED, ForwardingHeader::Forwarded)? else {
        return Ok(None);
    };
    let mut hops = Vec::new();
    for value in values {
        for element in split_quoted(value, ',', ForwardingHeader::Forwarded)? {
            let mut address = None;
            for parameter in split_quoted(element, ';', ForwardingHeader::Forwarded)? {
                let Some((name, value)) = parameter.split_once('=') else {
                    return Err(ForwardingFailure::Malformed(ForwardingHeader::Forwarded));
                };
                if name.trim().eq_ignore_ascii_case("for") {
                    if address.is_some() {
                        return Err(ForwardingFailure::Malformed(ForwardingHeader::Forwarded));
                    }
                    address = Some(parse_forwarded_address(value.trim())?);
                }
            }
            hops.push(address.ok_or(ForwardingFailure::MissingFor(ForwardingHeader::Forwarded))?);
            ensure_hop_limit(hops.len(), ForwardingHeader::Forwarded)?;
        }
    }
    finish_chain(config, ForwardingHeader::Forwarded, hops).map(Some)
}

fn resolve_x_forwarded_for(
    config: &TrustedProxyConfig,
    headers: &HeaderMap,
) -> Result<Option<FamilyResolution>, ForwardingFailure> {
    let Some(values) = header_values(headers, &X_FORWARDED_FOR, ForwardingHeader::XForwardedFor)?
    else {
        return Ok(None);
    };
    let mut hops = Vec::new();
    for value in values {
        for token in value.split(',') {
            hops.push(parse_address(
                token.trim(),
                ForwardingHeader::XForwardedFor,
            )?);
            ensure_hop_limit(hops.len(), ForwardingHeader::XForwardedFor)?;
        }
    }
    finish_chain(config, ForwardingHeader::XForwardedFor, hops).map(Some)
}

fn finish_chain(
    config: &TrustedProxyConfig,
    family: ForwardingHeader,
    hops: Vec<IpAddr>,
) -> Result<FamilyResolution, ForwardingFailure> {
    let client = hops
        .iter()
        .rev()
        .find(|address| !is_trusted(config, **address))
        .copied()
        .ok_or(ForwardingFailure::ExhaustedChain(family))?;
    Ok(FamilyResolution {
        family,
        client,
        hops,
    })
}

fn is_trusted(config: &TrustedProxyConfig, address: IpAddr) -> bool {
    config.cidrs().iter().any(|cidr| cidr.contains(&address))
}

fn ensure_hop_limit(count: usize, family: ForwardingHeader) -> Result<(), ForwardingFailure> {
    if count > MAX_HOPS {
        return Err(ForwardingFailure::ExcessiveHops(family));
    }
    Ok(())
}

fn ensure_family_size(
    headers: &HeaderMap,
    names: &[&HeaderName],
    family: ForwardingHeader,
) -> Result<(), ForwardingFailure> {
    let size = names
        .iter()
        .flat_map(|name| headers.get_all(*name))
        .map(|value| value.as_bytes().len())
        .sum::<usize>();
    if size > MAX_HEADER_BYTES {
        return Err(ForwardingFailure::Oversized(family));
    }
    Ok(())
}

fn header_values<'headers>(
    headers: &'headers HeaderMap,
    name: &HeaderName,
    family: ForwardingHeader,
) -> Result<Option<Vec<&'headers str>>, ForwardingFailure> {
    let mut size = 0;
    let mut values = Vec::new();
    for value in headers.get_all(name) {
        size += value.as_bytes().len();
        if size > MAX_HEADER_BYTES {
            return Err(ForwardingFailure::Oversized(family));
        }
        values.push(
            value
                .to_str()
                .map_err(|_| ForwardingFailure::NonUtf8(family))?,
        );
    }
    Ok((!values.is_empty()).then_some(values))
}

fn single_header_value<'headers>(
    headers: &'headers HeaderMap,
    name: &HeaderName,
    family: ForwardingHeader,
) -> Result<Option<&'headers str>, ForwardingFailure> {
    let values = header_values(headers, name, family)?;
    let Some(values) = values else {
        return Ok(None);
    };
    if values.len() != 1 {
        return Err(ForwardingFailure::Multiplicity(family));
    }
    Ok(values.first().copied())
}

fn split_quoted(
    value: &str,
    delimiter: char,
    family: ForwardingHeader,
) -> Result<Vec<&str>, ForwardingFailure> {
    let mut quoted = false;
    let mut start = 0;
    let mut parts = Vec::new();
    for (index, character) in value.char_indices() {
        match character {
            '"' => quoted = !quoted,
            '\\' if quoted => return Err(ForwardingFailure::Malformed(family)),
            _ if character == delimiter && !quoted => {
                parts.push(value[start..index].trim());
                start = index + character.len_utf8();
            }
            _ => {}
        }
    }
    if quoted {
        return Err(ForwardingFailure::Malformed(family));
    }
    parts.push(value[start..].trim());
    if parts.iter().any(|part| part.is_empty()) {
        return Err(ForwardingFailure::Malformed(family));
    }
    Ok(parts)
}

fn parse_forwarded_address(value: &str) -> Result<IpAddr, ForwardingFailure> {
    let value = if value.starts_with('"') && value.ends_with('"') && value.len() >= 2 {
        &value[1..value.len() - 1]
    } else if value.contains('"') {
        return Err(ForwardingFailure::Malformed(ForwardingHeader::Forwarded));
    } else {
        value
    };
    parse_address(value, ForwardingHeader::Forwarded)
}

fn parse_address(value: &str, family: ForwardingHeader) -> Result<IpAddr, ForwardingFailure> {
    if value.eq_ignore_ascii_case("unknown") {
        return Err(ForwardingFailure::Unknown(family));
    }
    if value.starts_with('_') {
        return Err(ForwardingFailure::Obfuscated(family));
    }
    if let Ok(address) = IpAddr::from_str(value) {
        return Ok(address);
    }
    if let Ok(address) = SocketAddr::from_str(value) {
        return Ok(address.ip());
    }
    if let Some(bracketed) = value.strip_prefix('[')
        && let Some((address, suffix)) = bracketed.split_once(']')
    {
        let address = Ipv6Addr::from_str(address)
            .map(IpAddr::V6)
            .map_err(|_| ForwardingFailure::Malformed(family))?;
        if !suffix.is_empty() && (!suffix.starts_with(':') || suffix[1..].parse::<u16>().is_err()) {
            return Err(ForwardingFailure::Malformed(family));
        }
        return Ok(address);
    }
    if value
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '-'))
    {
        return Err(ForwardingFailure::Hostname(family));
    }
    Err(ForwardingFailure::Malformed(family))
}

fn log_forwarding_debug(
    config: &TrustedProxyConfig,
    peer: SocketAddr,
    headers: &HeaderMap,
    resolution: &ClientAddressResolution,
) {
    let enabled = config
        .forwarding_headers()
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let cloudflare = debug_header_values(headers, &[&CF_CONNECTING_IP, &CF_CONNECTING_IPV6]);
    let forwarded = debug_header_values(headers, &[&FORWARDED]);
    let x_forwarded_for = debug_header_values(headers, &[&X_FORWARDED_FOR]);
    tracing::info!(
        target: "bleat_api::forwarding_debug",
        event_name = "forwarding.debug",
        network_peer_address = %peer.ip(),
        network_peer_port = peer.port(),
        client_address = %resolution.client,
        forwarding_enabled_families = %enabled,
        forwarding_decision = ?resolution.decision,
        forwarding_parsed_hops = ?resolution.parsed_hops,
        forwarding_cloudflare = %cloudflare,
        forwarding_forwarded = %forwarded,
        forwarding_x_forwarded_for = %x_forwarded_for,
        "forwarding diagnostics"
    );
}

fn debug_header_values(headers: &HeaderMap, names: &[&HeaderName]) -> String {
    let mut output = String::new();
    let mut remaining = MAX_HEADER_BYTES;
    for name in names {
        for value in headers.get_all(*name) {
            let prefix = if output.is_empty() { "" } else { " | " };
            let rendered = value.to_str().unwrap_or("<non-utf8>");
            let entry = format!("{prefix}{name}={rendered}");
            if entry.len() > remaining {
                output.push_str("<truncated>");
                return output;
            }
            output.push_str(&entry);
            remaining -= entry.len();
        }
    }
    if output.is_empty() {
        output.push_str("<absent>");
    }
    output
}

#[cfg(test)]
mod tests {
    use axum::http::HeaderValue;

    use super::*;

    fn config(cidrs: &[&str], families: &[ForwardingHeader]) -> TrustedProxyConfig {
        TrustedProxyConfig::new(
            cidrs.iter().map(|value| (*value).to_owned()).collect(),
            families.to_vec(),
            false,
        )
        .expect("test trusted proxy configuration should validate")
    }

    fn peer() -> SocketAddr {
        "10.0.0.9:43123"
            .parse()
            .expect("test socket address should parse")
    }

    #[test]
    fn untrusted_peer_cannot_spoof_client_address() {
        let config = config(&["192.168.0.0/16"], &[]);
        let mut headers = HeaderMap::new();
        headers.insert(&X_FORWARDED_FOR, HeaderValue::from_static("203.0.113.7"));

        assert_eq!(
            resolve_client_address(&config, peer(), &headers),
            ClientAddressResolution {
                client: peer().ip(),
                decision: ClientAddressDecision::UntrustedPeer,
                parsed_hops: Vec::new(),
            }
        );
    }

    #[test]
    fn cloudflare_prefers_real_ipv6_over_pseudo_ipv4() {
        let config = config(&["10.0.0.0/8"], &[ForwardingHeader::Cloudflare]);
        let mut headers = HeaderMap::new();
        headers.insert(&CF_CONNECTING_IP, HeaderValue::from_static("240.0.0.7"));
        headers.insert(&CF_CONNECTING_IPV6, HeaderValue::from_static("2001:db8::7"));

        let resolution = resolve_client_address(&config, peer(), &headers);
        assert_eq!(
            resolution.client,
            "2001:db8::7"
                .parse::<IpAddr>()
                .expect("test IPv6 address should parse")
        );
        assert_eq!(
            resolution.decision,
            ClientAddressDecision::Resolved(ForwardingHeader::Cloudflare)
        );
    }

    #[test]
    fn forwarded_and_x_forwarded_for_walk_repeated_trusted_hops_from_the_right() {
        let forwarded_config = config(
            &["10.0.0.0/8", "192.168.0.0/16", "2001:db8:ffff::/48"],
            &[ForwardingHeader::Forwarded],
        );
        let mut forwarded = HeaderMap::new();
        forwarded.append(
            &FORWARDED,
            HeaderValue::from_static("for=203.0.113.8:1234;proto=https"),
        );
        forwarded.append(
            &FORWARDED,
            HeaderValue::from_static("for=192.168.2.4;by=10.0.0.9"),
        );
        let resolution = resolve_client_address(&forwarded_config, peer(), &forwarded);
        assert_eq!(
            resolution.client,
            "203.0.113.8"
                .parse::<IpAddr>()
                .expect("test IPv4 address should parse")
        );

        let xff_config = config(
            &["10.0.0.0/8", "2001:db8:ffff::/48"],
            &[ForwardingHeader::XForwardedFor],
        );
        let mut x_forwarded = HeaderMap::new();
        x_forwarded.append(&X_FORWARDED_FOR, HeaderValue::from_static("2001:db8::8"));
        x_forwarded.append(
            &X_FORWARDED_FOR,
            HeaderValue::from_static("[2001:db8:ffff::4]:443"),
        );
        let resolution = resolve_client_address(&xff_config, peer(), &x_forwarded);
        assert_eq!(
            resolution.client,
            "2001:db8::8"
                .parse::<IpAddr>()
                .expect("test IPv6 address should parse")
        );
    }

    #[test]
    fn enabled_families_must_agree() {
        let config = config(&["10.0.0.0/8"], &[]);
        let mut headers = HeaderMap::new();
        headers.insert(&CF_CONNECTING_IP, HeaderValue::from_static("203.0.113.10"));
        headers.insert(&X_FORWARDED_FOR, HeaderValue::from_static("203.0.113.11"));
        let resolution = resolve_client_address(&config, peer(), &headers);
        assert_eq!(resolution.client, peer().ip());
        assert_eq!(
            resolution.decision,
            ClientAddressDecision::Fallback(ForwardingFailure::Conflict)
        );

        headers.insert(&X_FORWARDED_FOR, HeaderValue::from_static("203.0.113.10"));
        let resolution = resolve_client_address(&config, peer(), &headers);
        assert_eq!(
            resolution.client,
            "203.0.113.10"
                .parse::<IpAddr>()
                .expect("test IPv4 address should parse")
        );
        assert_eq!(resolution.decision, ClientAddressDecision::ResolvedMultiple);
    }

    #[test]
    fn hostile_forwarding_values_have_typed_failures() {
        let forwarded_config = config(&["10.0.0.0/8"], &[ForwardingHeader::Forwarded]);
        for (value, failure) in [
            (
                "for=unknown",
                ForwardingFailure::Unknown(ForwardingHeader::Forwarded),
            ),
            (
                "for=_hidden",
                ForwardingFailure::Obfuscated(ForwardingHeader::Forwarded),
            ),
            (
                "for=proxy.example",
                ForwardingFailure::Hostname(ForwardingHeader::Forwarded),
            ),
            (
                "proto=https",
                ForwardingFailure::MissingFor(ForwardingHeader::Forwarded),
            ),
            (
                "for=203.0.113.1;for=203.0.113.2",
                ForwardingFailure::Malformed(ForwardingHeader::Forwarded),
            ),
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(
                &FORWARDED,
                HeaderValue::from_str(value).expect("test header should validate"),
            );
            assert_eq!(
                resolve_client_address(&forwarded_config, peer(), &headers).decision,
                ClientAddressDecision::Fallback(failure)
            );
        }

        let cloudflare_config = config(&["10.0.0.0/8"], &[ForwardingHeader::Cloudflare]);
        let mut headers = HeaderMap::new();
        headers.append(&CF_CONNECTING_IP, HeaderValue::from_static("203.0.113.1"));
        headers.append(&CF_CONNECTING_IP, HeaderValue::from_static("203.0.113.2"));
        assert_eq!(
            resolve_client_address(&cloudflare_config, peer(), &headers).decision,
            ClientAddressDecision::Fallback(ForwardingFailure::Multiplicity(
                ForwardingHeader::Cloudflare
            ))
        );

        let mut headers = HeaderMap::new();
        headers.insert(
            &CF_CONNECTING_IP,
            HeaderValue::from_str(&"1".repeat(MAX_HEADER_BYTES / 2 + 1))
                .expect("large Cloudflare header should be representable"),
        );
        headers.insert(
            &CF_CONNECTING_IPV6,
            HeaderValue::from_str(&"2".repeat(MAX_HEADER_BYTES / 2 + 1))
                .expect("large Cloudflare IPv6 header should be representable"),
        );
        assert_eq!(
            resolve_client_address(&cloudflare_config, peer(), &headers).decision,
            ClientAddressDecision::Fallback(ForwardingFailure::Oversized(
                ForwardingHeader::Cloudflare
            ))
        );

        let xff_config = config(&["10.0.0.0/8"], &[ForwardingHeader::XForwardedFor]);
        let mut headers = HeaderMap::new();
        headers.insert(
            &X_FORWARDED_FOR,
            HeaderValue::from_str(&"1".repeat(MAX_HEADER_BYTES + 1))
                .expect("oversized test header should be representable"),
        );
        assert_eq!(
            resolve_client_address(&xff_config, peer(), &headers).decision,
            ClientAddressDecision::Fallback(ForwardingFailure::Oversized(
                ForwardingHeader::XForwardedFor
            ))
        );

        let mut headers = HeaderMap::new();
        let hops = std::iter::repeat_n("192.168.1.1", MAX_HOPS + 1)
            .collect::<Vec<_>>()
            .join(",");
        headers.insert(
            &X_FORWARDED_FOR,
            HeaderValue::from_str(&hops).expect("long test chain should be representable"),
        );
        assert_eq!(
            resolve_client_address(&xff_config, peer(), &headers).decision,
            ClientAddressDecision::Fallback(ForwardingFailure::ExcessiveHops(
                ForwardingHeader::XForwardedFor
            ))
        );

        let mut headers = HeaderMap::new();
        headers.insert(&X_FORWARDED_FOR, HeaderValue::from_static("10.1.2.3"));
        assert_eq!(
            resolve_client_address(&xff_config, peer(), &headers).decision,
            ClientAddressDecision::Fallback(ForwardingFailure::ExhaustedChain(
                ForwardingHeader::XForwardedFor
            ))
        );
    }

    #[test]
    fn forwarding_debug_rendering_is_bounded() {
        let mut headers = HeaderMap::new();
        headers.insert(
            &X_FORWARDED_FOR,
            HeaderValue::from_str(&"1".repeat(MAX_HEADER_BYTES + 100))
                .expect("oversized test header should be representable"),
        );
        let rendered = debug_header_values(&headers, &[&X_FORWARDED_FOR]);
        assert!(rendered.ends_with("<truncated>"));
        assert!(rendered.len() <= MAX_HEADER_BYTES + "<truncated>".len());
    }
}
