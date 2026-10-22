use super::{Error, Result, native::Native};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Component, Path, PathBuf},
};

pub(super) const SCREEN_TEST: &str =
    "BleatUITests/BleatReleaseScreenshotTests/testReleaseScreenshots";
pub(super) const CADDY_IMAGE: &str =
    "caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d";
const SCREENS: [&str; 10] = [
    "00-login.png",
    "01-home.png",
    "02-library.png",
    "03-goat-sounds-detail.png",
    "04-goat-sounds-chapters.png",
    "05-mini-player.png",
    "06-now-playing.png",
    "07-downloads.png",
    "08-search.png",
    "09-settings.png",
];
pub(super) fn invalid<T>(label: &'static str) -> Result<T> {
    Err(Error::Invalid(label))
}
pub(super) fn read_json(path: &Path) -> Result<Value> {
    serde_json::from_slice(&fs::read(path)?).map_err(|_| Error::Invalid("malformed JSON document"))
}
pub(super) fn write_json(path: &Path, value: &Value) -> Result<()> {
    let data =
        serde_json::to_vec_pretty(value).map_err(|_| Error::Invalid("JSON serialization"))?;
    fs::write(path, [data.as_slice(), b"\n"].concat())?;
    Ok(())
}
pub(super) fn required<'a>(
    env: &'a BTreeMap<String, String>,
    key: &'static str,
) -> Result<&'a str> {
    env.get(key)
        .map(String::as_str)
        .filter(|s| !s.is_empty())
        .ok_or(Error::Invalid(key))
}
pub(super) fn required_path(env: &BTreeMap<String, String>, key: &'static str) -> Result<PathBuf> {
    Ok(PathBuf::from(required(env, key)?))
}
pub(super) fn text<'a>(v: &'a Value, key: &'static str) -> Result<&'a str> {
    v.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or(Error::Invalid(key))
}
pub(super) fn relative_file(value: &str) -> Result<()> {
    if value.is_empty()
        || Path::new(value)
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return invalid("fixture/attachment path must be relative without traversal");
    }
    Ok(())
}
#[derive(Clone)]
pub(super) struct Configuration {
    pub(super) fixture: PathBuf,
    pub(super) appearances: Vec<String>,
    pub(super) orientations: Vec<String>,
    pub(super) devices: Vec<String>,
    pub(super) runtime: Option<String>,
    pub(super) locale: String,
    pub(super) port: u16,
    pub(super) video: bool,
    pub(super) image: String,
    pub(super) profile: Value,
    pub(super) carplay: String,
}
fn selections(raw: &str, allowed: &[&str]) -> Result<Vec<String>> {
    let mut result = Vec::new();
    for part in raw.split(',') {
        let part = part
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect::<String>();
        if !allowed.contains(&part.as_str()) {
            return invalid("unsupported or empty screenshot selection");
        }
        if !result.contains(&part) {
            result.push(part);
        }
    }
    if result.is_empty() {
        return invalid("empty screenshot selection");
    }
    Ok(result)
}
impl Configuration {
    pub(super) fn from_environment(root: &Path, env: &BTreeMap<String, String>) -> Result<Self> {
        let get =
            |key: &str, default: &str| env.get(key).cloned().unwrap_or_else(|| default.to_owned());
        let appearances = selections(
            &get("BLEAT_SCREENSHOT_APPEARANCES", "light,dark"),
            &["light", "dark"],
        )?;
        let orientations = selections(
            &get("BLEAT_SCREENSHOT_ORIENTATIONS", "portrait,landscapeLeft"),
            &["portrait", "landscapeLeft"],
        )?;
        let devices = get("BLEAT_SCREENSHOT_DEVICES", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max,com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB").split(',').map(|s| s.trim().to_owned()).collect::<Vec<_>>();
        if !(1..=2).contains(&devices.len())
            || devices.iter().filter(|s| s.contains("iPhone")).count() != 1
            || devices.iter().filter(|s| s.contains("iPad")).count() > 1
            || devices
                .iter()
                .any(|s| !s.contains("iPhone") && !s.contains("iPad"))
        {
            return invalid("select exactly one iPhone and at most one iPad");
        }
        let locale = get("BLEAT_SCREENSHOT_LOCALE", "en_AU");
        let bytes = locale.as_bytes();
        if bytes.len() != 5
            || !bytes[..2].iter().all(u8::is_ascii_lowercase)
            || bytes[2] != b'_'
            || !bytes[3..].iter().all(u8::is_ascii_uppercase)
        {
            return invalid("locale must use language_REGION");
        }
        let port = match env.get("BLEAT_SCREENSHOT_PORT").filter(|s| !s.is_empty()) {
            Some(value) => value
                .parse::<u16>()
                .ok()
                .filter(|p| *p > 0)
                .ok_or(Error::Invalid("screenshot TCP port"))?,
            None => 0,
        };
        let video = match get("BLEAT_SCREENSHOT_RECORD_VIDEO", "0").as_str() {
            "0" => false,
            "1" => true,
            _ => return invalid("record video must be 0 or 1"),
        };
        let profile =
            read_json(&root.join("TestSupport/ServerHarness/profiles/current-stable.json"))?;
        validate_profile(&profile)?;
        let image = get("BLEAT_SCREENSHOT_ABS_IMAGE", text(&profile, "image")?);
        let fixture = root.join(get(
            "BLEAT_SCREENSHOT_FIXTURE",
            "TestSupport/ReleaseScreenshots/fixtures.json",
        ));
        Ok(Self {
            fixture,
            appearances,
            orientations,
            devices,
            runtime: env
                .get("BLEAT_SCREENSHOT_RUNTIME")
                .filter(|s| !s.is_empty())
                .cloned(),
            locale,
            port,
            video,
            image,
            profile,
            carplay: get("BLEAT_CARPLAY_MODE", "enabled"),
        })
    }
}
pub(super) fn validate_profile(v: &Value) -> Result<()> {
    let version = text(v, "serverVersion")?;
    let numeric = version.split('.').count() == 3
        && version
            .split('.')
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
    let prefix = format!("ghcr.io/advplyr/audiobookshelf:{version}@sha256:");
    if v["id"] != "current-stable"
        || !numeric
        || v["seedVersion"] != version
        || !text(v, "image")?.strip_prefix(&prefix).is_some_and(|d| {
            d.len() == 64
                && d.bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        })
    {
        return invalid("pinned current-stable profile");
    }
    Ok(())
}
pub(super) struct Fixture {
    pub(super) value: Value,
    pub(super) directory: PathBuf,
}
impl Fixture {
    pub(super) fn load(path: &Path, root: &Path, native: &Native) -> Result<Self> {
        let value = read_json(path)?;
        validate_fixture(&value)?;
        // Cover paths remain relative to the versioned fixture assets, including override manifests.
        let directory = root.join("TestSupport/ReleaseScreenshots");
        for book in value["books"].as_array().ok_or(Error::Invalid("books"))? {
            let dims = native.dimensions(&directory.join(text(book, "cover")?))?;
            if dims.0 < 600 || dims.0 != dims.1 {
                return invalid("cover must be square and at least 600 pixels");
            }
        }
        Ok(Self { value, directory })
    }
    pub(super) fn names(&self, appearance: &str) -> Vec<String> {
        SCREENS
            .iter()
            .map(|s| screenshot_name(s, appearance))
            .collect()
    }
}
pub(super) fn screenshot_name(base: &str, appearance: &str) -> String {
    if appearance == "dark" {
        format!("{}-dark.png", base.trim_end_matches(".png"))
    } else {
        base.to_owned()
    }
}
pub(super) fn validate_fixture(v: &Value) -> Result<()> {
    if v["schemaVersion"] != 2
        || v["server"]["friendlyName"] != "Barnyard"
        || v["server"]["hostname"] != "barnyard.terminaloutcomes.com"
        || v["server"]["pathPrefix"] != "/audiobookshelf"
        || v["account"]["username"] != "kid"
    {
        return invalid("screenshot fixture identity/schema");
    }
    let books = v["books"]
        .as_array()
        .filter(|b| b.len() == 5)
        .ok_or(Error::Invalid("five fixture books required"))?;
    for key in ["key", "title", "cover"] {
        let unique = books
            .iter()
            .map(|b| text(b, key))
            .collect::<Result<BTreeSet<_>>>()?;
        if unique.len() != 5 {
            return invalid("duplicate book key/title/cover");
        }
    }
    for book in books {
        for path in ["cover", "folder", "mediaFile"] {
            relative_file(text(book, path)?)?;
        }
        let duration = book["duration"]
            .as_f64()
            .filter(|d| *d > 0.0)
            .ok_or(Error::Invalid("book duration"))?;
        for key in ["authors", "narrators", "genres", "tags"] {
            if !book[key]
                .as_array()
                .is_some_and(|a| a.iter().all(Value::is_string))
            {
                return invalid("book metadata arrays");
            }
        }
        text(book, "description")?;
        if let Some(progress) = book.get("progress") {
            let time = progress["currentTime"]
                .as_f64()
                .ok_or(Error::Invalid("book progress"))?;
            if !(0.0..=duration).contains(&time) || !progress["isFinished"].is_boolean() {
                return invalid("book progress outside duration");
            }
        }
    }
    let names = v["screenshots"]
        .as_array()
        .ok_or(Error::Invalid("screenshots"))?
        .iter()
        .map(|s| text(s, "file"))
        .collect::<Result<Vec<_>>>()?;
    if names != SCREENS {
        return invalid("ordered ten screenshot names");
    }
    let hero = books
        .iter()
        .find(|b| b["key"] == "thirteen-hours-of-goat-sounds")
        .ok_or(Error::Invalid("hero book"))?;
    let chapters = hero["chapters"]
        .as_array()
        .filter(|a| a.len() == 13)
        .ok_or(Error::Invalid("thirteen hero chapters"))?;
    if hero["duration"] != 46800
        || hero["progress"]["currentTime"] != 19800
        || hero["progress"]["isFinished"] != false
        || chapters
            .iter()
            .enumerate()
            .any(|(i, c)| c["start"] != i * 3600 || c["end"] != (i + 1) * 3600)
        || chapters[5]["title"] != "romantic goats"
        || chapters[10]["title"] != "oh no leave each other alone"
    {
        return invalid("hero duration/progress/chapter contract");
    }
    let mut sequences = books
        .iter()
        .filter(|b| b["series"]["name"] == "Barnyard Skills")
        .map(|b| text(&b["series"], "sequence"))
        .collect::<Result<Vec<_>>>()?;
    sequences.sort_unstable();
    if sequences != ["1", "2"] {
        return invalid("Barnyard Skills sequence");
    }
    Ok(())
}
pub(super) fn validate_orientation(value: &str) -> Result<()> {
    if ["portrait", "landscapeLeft"].contains(&value) {
        Ok(())
    } else {
        invalid("screenshot orientation")
    }
}
pub(super) fn parse_dimensions(value: &str) -> Result<(u32, u32)> {
    let (w, h) = value
        .split_once('x')
        .ok_or(Error::Invalid("pixel dimensions"))?;
    Ok((
        w.parse()
            .ok()
            .filter(|v| *v > 0)
            .ok_or(Error::Invalid("pixel width"))?,
        h.parse()
            .ok()
            .filter(|v| *v > 0)
            .ok_or(Error::Invalid("pixel height"))?,
    ))
}
pub(super) fn validate_dimensions(
    actual: (u32, u32),
    expected: (u32, u32),
    orientation: &str,
) -> Result<()> {
    validate_orientation(orientation)?;
    if actual != expected
        || (orientation == "portrait" && actual.1 <= actual.0)
        || (orientation == "landscapeLeft" && actual.0 <= actual.1)
    {
        return invalid("screenshot pixel dimensions/orientation");
    }
    Ok(())
}
pub(super) fn attachment_files(
    manifest: &Value,
    expected: &[String],
) -> Result<BTreeMap<String, String>> {
    let rows = manifest
        .as_array()
        .ok_or(Error::Invalid("attachment manifest array"))?;
    let attachments = rows
        .iter()
        .flat_map(|r| r["attachments"].as_array().into_iter().flatten())
        .collect::<Vec<_>>();
    let files: BTreeMap<String, String> = expected
        .iter()
        .map(|name| {
            let prefix = format!("{}_", name.trim_end_matches(".png"));
            let matches = attachments
                .iter()
                .filter(|a| {
                    a["suggestedHumanReadableName"].as_str().is_some_and(|s| {
                        s == name || (s.starts_with(&prefix) && s.ends_with(".png"))
                    })
                })
                .collect::<Vec<_>>();
            if matches.len() != 1 {
                return invalid("missing or duplicate named screenshot attachment");
            }
            let file = text(matches[0], "exportedFileName")?;
            relative_file(file)?;
            Ok((name.clone(), file.to_owned()))
        })
        .collect::<Result<_>>()?;
    if files.values().collect::<BTreeSet<_>>().len() != files.len() {
        return invalid("different screenshot names reference the same exported file");
    }
    Ok(files)
}
pub(super) fn validate_public_manifest(v: &Value) -> Result<()> {
    fn check(v: &Value) -> Result<()> {
        match v {
            Value::Object(map) => {
                for (key, value) in map {
                    let key = key.to_ascii_lowercase();
                    if ["token", "password", "credential", "resolved", "response"]
                        .iter()
                        .any(|s| key.contains(s))
                    {
                        return invalid("public manifest contains sensitive key");
                    }
                    check(value)?;
                }
            }
            Value::Array(values) => {
                for v in values {
                    check(v)?;
                }
            }
            Value::String(value) => {
                let lower = value.to_ascii_lowercase();
                if [
                    "http://",
                    "https://",
                    "/users/",
                    "access_token",
                    "access-token",
                    "accesstoken",
                    "refresh_token",
                    "refresh-token",
                    "refreshtoken",
                ]
                .iter()
                .any(|s| lower.contains(s))
                    || lower
                        .as_bytes()
                        .windows(7)
                        .any(|s| s.starts_with(b"bearer") && s[6].is_ascii_whitespace())
                {
                    return invalid("public manifest contains sensitive value");
                }
            }
            _ => {}
        }
        Ok(())
    }
    check(v)
}
