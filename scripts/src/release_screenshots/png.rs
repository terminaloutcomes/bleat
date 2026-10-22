/// The landscape pixels have already been rotated by the native exporter.
/// Drop its stale EXIF/XMP orientation and dimension metadata without decoding,
/// recompressing, or altering any pixel, color/profile, or unrelated text chunk.
pub(super) fn normalize_orientation_metadata(bytes: &[u8]) -> Result<Vec<u8>, &'static str> {
    const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
    if !bytes.starts_with(SIGNATURE) {
        return Err("screenshot PNG signature");
    }
    let mut output = SIGNATURE.to_vec();
    let mut at = SIGNATURE.len();
    while at < bytes.len() {
        let header = bytes
            .get(at..)
            .and_then(|rest| rest.get(..8))
            .ok_or("screenshot PNG chunk header")?;
        let length = usize::try_from(u32::from_be_bytes([
            header[0], header[1], header[2], header[3],
        ]))
        .map_err(|_| "screenshot PNG chunk length")?;
        let end = at
            .checked_add(12)
            .and_then(|start| start.checked_add(length))
            .filter(|end| *end <= bytes.len())
            .ok_or("screenshot PNG chunk boundary")?;
        let kind = &header[4..8];
        let data = &bytes[at + 8..end - 4];
        let stale =
            kind == b"eXIf" || (kind == b"iTXt" && data.starts_with(b"XML:com.adobe.xmp\0"));
        if !stale {
            output.extend_from_slice(&bytes[at..end]);
        }
        if kind == b"IEND" {
            if length != 0 || end != bytes.len() {
                return Err("screenshot PNG end chunk");
            }
            return Ok(output);
        }
        at = end;
    }
    Err("screenshot PNG missing end chunk")
}
