//! Owned synthetic media fixtures for the large-library live harness.
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom},
    path::Path,
    process::Command,
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;

const MANIFEST: &str = ".bleat-large-library.json";
const FORMAT: &str = "bleat-large-library-v1";

#[derive(Debug, Error)]
pub enum GenerationError {
    #[error("count must be between 1 and 100000")]
    InvalidCount,
    #[error("fixture ownership validation failed: {0}")]
    Ownership(&'static str),
    #[error("fixture filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("fixture manifest is invalid: {0}")]
    Manifest(#[from] serde_json::Error),
    #[error("ffmpeg failed to generate silent audio")]
    Media,
    #[error("fixture publication was interrupted; inspect the retained fixture before retrying")]
    PublicationInterrupted,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format: String,
    count: usize,
    audio_sha256: String,
    state: PublicationState,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum PublicationState {
    Ready,
    Publishing,
}

/// Bounded one-second polling attempts for the live fixture scan.
///
/// A 10,000-item current-stable scan outlasted the former 620-attempt
/// allowance while still making progress. Allow ten items per attempt plus
/// startup overhead. Each HTTP request retains its separate timeout; this is
/// an attempt budget, not an elapsed-time guarantee.
pub fn scan_attempts(count: usize) -> Result<usize, GenerationError> {
    if !(1..=100_000).contains(&count) {
        return Err(GenerationError::InvalidCount);
    }
    Ok(count / 10 + 120)
}

fn write_manifest(file: &mut File, manifest: &Manifest) -> Result<(), GenerationError> {
    file.seek(SeekFrom::Start(0))?;
    file.set_len(0)?;
    serde_json::to_writer(&mut *file, manifest)?;
    file.sync_all()?;
    Ok(())
}

// These exact inert files are the checked-in default directory scaffold. Their
// bytes deliberately define the initialization contract; they remain unowned
// and are never replaced or deleted by generation.
fn can_initialize(output: &Path) -> Result<bool, GenerationError> {
    let entries = fs::read_dir(output)?.collect::<Result<Vec<_>, _>>()?;
    if entries.is_empty() {
        return Ok(true);
    }
    if entries.len() != 2 {
        return Ok(false);
    }
    for entry in entries {
        let expected: &[u8] = match entry.file_name().to_str() {
            Some(".gitignore") => {
                include_bytes!("../../TestSupport/ServerHarness/media-large/.gitignore")
            }
            Some(".gitkeep") => {
                include_bytes!("../../TestSupport/ServerHarness/media-large/.gitkeep")
            }
            _ => return Ok(false),
        };
        regular_file(&entry.path())?;
        if fs::read(entry.path())? != expected {
            return Ok(false);
        }
    }
    Ok(true)
}

fn ownership(reason: &'static str) -> GenerationError {
    GenerationError::Ownership(reason)
}

fn book_name(index: usize) -> String {
    format!("book-{index:05}")
}

fn metadata(index: usize) -> Value {
    let authors = [
        "Author One",
        "Author Two",
        "Author Three",
        "Author Four",
        "Co-Author Alpha",
        "Co-Author Beta",
        "Writer One",
        "Writer Two",
        "Historian",
        "Poet",
        "Scientist",
        "Explorer",
        "Philosopher",
        "Novelist",
        "Critic",
        "Dreamer",
        "Traveler",
        "Archivist",
    ];
    let genres = [
        "Fiction",
        "Non-Fiction",
        "Science Fiction",
        "Fantasy",
        "Mystery",
        "Biography",
        "History",
        "Romance",
        "Thriller",
        "Adventure",
        "Horror",
        "Drama",
        "Comedy",
    ];
    let mut result = json!({
        "metadata": {
            "title": format!("Book Title {index}"),
            "authors": [authors[index % authors.len()]],
            "narrators": [format!("Narrator {}", index % 7)],
            "genres": (1..=index % 3 + 1).map(|offset| genres[(index + offset) % genres.len()]).collect::<Vec<_>>(),
            "series": if index.is_multiple_of(12) { json!([]) } else {
                json!([{ "name": format!("Series {}", index % 12), "sequence": (index % 20).to_string() }])
            },
            "year": (["1950", "1970", "1990", "2010", "2020"][index % 5]),
            "explicit": index.is_multiple_of(10)
        },
        "tags": [format!("tag-{}", index % 9)]
    });
    if index.is_multiple_of(2) {
        result["metadata"]["publisher"] = json!(format!("Publisher {}", index % 6));
    }
    result
}

fn regular_file(path: &Path) -> Result<(), GenerationError> {
    let info = fs::symlink_metadata(path)?;
    if !info.is_file() || info.nlink() != 1 {
        return Err(ownership("expected an unlinked regular generated file"));
    }
    Ok(())
}

use std::os::unix::fs::MetadataExt;

fn audio_digest(path: &Path) -> Result<String, GenerationError> {
    regular_file(path)?;
    Ok(Sha256::digest(fs::read(path)?)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn validate(output: &Path, manifest: &Manifest, count: usize) -> Result<(), GenerationError> {
    match manifest.state {
        PublicationState::Publishing => return Err(GenerationError::PublicationInterrupted),
        PublicationState::Ready => {}
    }
    if manifest.format != FORMAT
        || manifest.count > 100_000
        || (manifest.count > 0
            && (manifest.audio_sha256.len() != 64
                || !manifest
                    .audio_sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())))
    {
        return Err(ownership("unrecognized manifest"));
    }
    // Check every resource before removing any resource. Unknown children of an
    // owned book are never recursively deleted, even when the book is stale.
    for index in 0..manifest.count {
        let book = output.join(book_name(index));
        if !fs::symlink_metadata(&book)?.is_dir() {
            return Err(ownership("generated book is not a directory"));
        }
        let entries = fs::read_dir(&book)?.collect::<Result<Vec<_>, _>>()?;
        if entries.len() != 2 {
            return Err(ownership("generated book contains unexpected resources"));
        }
        regular_file(&book.join("metadata.json"))?;
        let actual: Value = serde_json::from_slice(&fs::read(book.join("metadata.json"))?)?;
        if actual != metadata(index)
            || audio_digest(&book.join("track.mp3"))? != manifest.audio_sha256
        {
            return Err(ownership(
                "generated book content no longer matches ownership",
            ));
        }
    }
    for index in manifest.count..count {
        if output.join(book_name(index)).symlink_metadata().is_ok() {
            return Err(ownership("requested book collides with an unowned entry"));
        }
    }
    Ok(())
}

/// Generate media synchronously in this synchronous CLI workflow. The callback
/// boundary substitutes only media generation in filesystem regression tests.
pub fn generate(output: &Path, count: usize) -> Result<(), GenerationError> {
    generate_with(output, count, |track| {
        let status = Command::new("ffmpeg")
            .args([
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=channel_layout=mono:sample_rate=16000",
                "-t",
                "1",
                "-b:a",
                "32k",
            ])
            .arg(track)
            .status()?;
        if !status.success() {
            return Err(GenerationError::Media);
        }
        Ok(())
    })
}

fn generate_with(
    output: &Path,
    count: usize,
    media: impl FnOnce(&Path) -> Result<(), GenerationError>,
) -> Result<(), GenerationError> {
    generate_with_publication(output, count, media, |_| Ok(()))
}

fn generate_with_publication(
    output: &Path,
    count: usize,
    media: impl FnOnce(&Path) -> Result<(), GenerationError>,
    mut published: impl FnMut(usize) -> Result<(), GenerationError>,
) -> Result<(), GenerationError> {
    // Normalize trailing separators and `.` before checking the destination;
    // symlink_metadata on `link/` would otherwise follow the directory link.
    if output
        .components()
        .any(|part| part == std::path::Component::ParentDir)
    {
        return Err(ownership("destination must not contain parent traversal"));
    }
    let normalized: std::path::PathBuf = output.components().collect();
    let output = normalized.as_path();
    if !(1..=100_000).contains(&count) {
        return Err(GenerationError::InvalidCount);
    }
    if let Ok(info) = fs::symlink_metadata(output)
        && !info.is_dir()
    {
        return Err(ownership("destination must be a real directory"));
    }
    fs::create_dir_all(output)?;
    let marker = output.join(MANIFEST);
    let mut file = if can_initialize(output)? {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&marker)?;
        file.try_lock()
            .map_err(|_| ownership("generator is already running"))?;
        write_manifest(
            &mut file,
            &Manifest {
                format: FORMAT.into(),
                count: 0,
                audio_sha256: String::new(),
                state: PublicationState::Ready,
            },
        )?;
        file
    } else {
        regular_file(&marker)?;
        let file = OpenOptions::new().read(true).write(true).open(&marker)?;
        file.try_lock()
            .map_err(|_| ownership("generator is already running"))?;
        file
    };
    let mut bytes = Vec::new();
    file.seek(SeekFrom::Start(0))?;
    file.read_to_end(&mut bytes)?;
    let mut manifest: Manifest = serde_json::from_slice(&bytes)?;
    validate(output, &manifest, count)?;

    // Only this unique staging directory is automatically cleaned on failure.
    // Shared names such as .silent-template.mp3 are never touched.
    let stage = tempfile::Builder::new()
        .prefix(".bleat-stage-")
        .tempdir_in(output)?;
    let template = stage.path().join("template.mp3");
    media(&template)?;
    let digest = audio_digest(&template)?;
    for index in 0..count {
        let book = stage.path().join(book_name(index));
        fs::create_dir(&book)?;
        fs::copy(&template, book.join("track.mp3"))?;
        fs::write(
            book.join("metadata.json"),
            serde_json::to_vec_pretty(&metadata(index))?,
        )?;
    }
    validate(output, &manifest, count)?;
    // Persist fail-closed state before any destructive publication. A matching
    // old prefix cannot prove completion after an interrupted expansion.
    manifest.state = PublicationState::Publishing;
    write_manifest(&mut file, &manifest)?;
    File::open(output)?.sync_all()?;
    // Remove only the two validated files, never a recursive book glob.
    for index in 0..manifest.count {
        let book = output.join(book_name(index));
        fs::remove_file(book.join("track.mp3"))?;
        fs::remove_file(book.join("metadata.json"))?;
        fs::remove_dir(book)?;
    }
    for index in 0..count {
        let name = book_name(index);
        fs::rename(stage.path().join(&name), output.join(name))?;
        published(index + 1)?;
    }
    // Make directory publication durable before recording successful completion.
    File::open(output)?.sync_all()?;
    write_manifest(
        &mut file,
        &Manifest {
            format: FORMAT.into(),
            count,
            audio_sha256: digest,
            state: PublicationState::Ready,
        },
    )?;
    stage.close()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn run(output: &Path, count: usize) -> Result<(), GenerationError> {
        generate_with(output, count, |path| {
            fs::write(path, b"test audio")?;
            Ok(())
        })
    }

    fn snapshot(path: &Path) -> Vec<(std::path::PathBuf, Vec<u8>)> {
        fn collect(root: &Path, path: &Path, result: &mut Vec<(std::path::PathBuf, Vec<u8>)>) {
            for entry in fs::read_dir(path).expect("read fixture") {
                let entry = entry.expect("entry");
                let path = entry.path();
                if entry.file_type().expect("type").is_dir() {
                    collect(root, &path, result);
                } else {
                    result.push((
                        path.strip_prefix(root).expect("relative").to_owned(),
                        fs::read(path).expect("read"),
                    ));
                }
            }
        }
        let mut result = Vec::new();
        collect(path, path, &mut result);
        result.sort();
        result
    }

    #[test]
    fn initializes_new_and_empty_destinations_with_expected_metadata() {
        let root = tempfile::tempdir().expect("fixture");
        for output in [root.path().join("new"), root.path().join("empty")] {
            if output.ends_with("empty") {
                fs::create_dir(&output).expect("empty");
            }
            run(&output, 3).expect("generate");
            for index in 0..3 {
                let book = output.join(book_name(index));
                assert_eq!(
                    fs::read(book.join("track.mp3")).expect("audio"),
                    b"test audio"
                );
                let value: Value = serde_json::from_slice(
                    &fs::read(book.join("metadata.json")).expect("metadata"),
                )
                .expect("JSON");
                assert_eq!(value, metadata(index));
            }
            let first: Value = serde_json::from_slice(
                &fs::read(output.join("book-00000/metadata.json")).expect("metadata"),
            )
            .expect("JSON");
            assert_eq!(
                first,
                json!({"metadata": {"title":"Book Title 0", "authors":["Author One"], "narrators":["Narrator 0"], "genres":["Non-Fiction"], "series":[], "year":"1950", "publisher":"Publisher 0", "explicit":true}, "tags":["tag-0"]})
            );
            assert_eq!(fs::read_dir(output).expect("output").count(), 4);
        }
    }

    #[test]
    fn rejects_modified_or_augmented_checkout_scaffold_without_mutation() {
        for change in ["ignore", "keep", "extra", "symlink"] {
            let root = tempfile::tempdir().expect("fixture");
            fs::write(
                root.path().join(".gitignore"),
                include_bytes!("../../TestSupport/ServerHarness/media-large/.gitignore"),
            )
            .expect("ignore");
            fs::write(root.path().join(".gitkeep"), b"").expect("keep");
            match change {
                "ignore" => {
                    fs::write(root.path().join(".gitignore"), b"unrelated").expect("change")
                }
                "keep" => fs::write(root.path().join(".gitkeep"), b"unrelated").expect("change"),
                "extra" => fs::write(root.path().join("sentinel"), b"keep").expect("extra"),
                _ => {
                    fs::remove_file(root.path().join(".gitkeep")).expect("remove");
                    symlink(root.path().join(".gitignore"), root.path().join(".gitkeep"))
                        .expect("link");
                }
            }
            let before = snapshot(root.path());
            assert!(run(root.path(), 1).is_err(), "{change}");
            assert_eq!(snapshot(root.path()), before);
            assert!(!root.path().join(MANIFEST).exists());
        }
    }

    #[test]
    fn rejects_unowned_missing_and_malformed_manifests_without_mutation() {
        for marker in [
            None,
            Some("garbage"),
            Some(r#"{"format":"other","count":0,"audio_sha256":""}"#),
        ] {
            let root = tempfile::tempdir().expect("fixture");
            for name in ["book-00000", "book-notes"] {
                fs::create_dir(root.path().join(name)).expect("directory");
                fs::write(root.path().join(name).join("sentinel"), name).expect("sentinel");
            }
            fs::write(root.path().join("sentinel"), b"unchanged").expect("sentinel");
            fs::write(root.path().join(".silent-template.mp3"), b"unowned").expect("template");
            if let Some(marker) = marker {
                fs::write(root.path().join(MANIFEST), marker).expect("marker");
            }
            let before = snapshot(root.path());
            assert!(run(root.path(), 1).is_err());
            assert_eq!(snapshot(root.path()), before);
        }
    }

    #[test]
    fn shrinks_repeats_and_preserves_unrelated_entries_and_template() {
        let root = tempfile::tempdir().expect("fixture");
        run(root.path(), 3).expect("initial");
        for name in ["book-notes", "book-99999", "notes"] {
            fs::create_dir(root.path().join(name)).expect("directory");
            fs::write(root.path().join(name).join("sentinel"), b"keep").expect("sentinel");
        }
        fs::write(root.path().join(".silent-template.mp3"), b"keep").expect("template");
        for _ in 0..2 {
            run(root.path(), 1).expect("regenerate");
            assert!(root.path().join("book-00000/track.mp3").is_file());
            assert!(!root.path().join("book-00001").exists());
            assert!(!root.path().join("book-00002").exists());
            for name in ["book-notes", "book-99999", "notes"] {
                assert_eq!(
                    fs::read(root.path().join(name).join("sentinel")).expect("retained"),
                    b"keep"
                );
            }
            assert_eq!(
                fs::read(root.path().join(".silent-template.mp3")).expect("template"),
                b"keep"
            );
            assert_eq!(fs::read_dir(root.path()).expect("entries").count(), 6);
        }
    }

    #[test]
    fn rejects_collisions_and_modified_owned_resources_before_mutation() {
        for change in [
            "collision",
            "extra",
            "metadata",
            "audio",
            "missing-marker",
            "malformed-marker",
        ] {
            let root = tempfile::tempdir().expect("fixture");
            run(root.path(), 3).expect("initial");
            match change {
                "collision" => fs::create_dir(root.path().join("book-00003")).expect("collision"),
                "extra" => fs::write(root.path().join("book-00002/notes"), b"keep").expect("extra"),
                "metadata" => {
                    fs::write(root.path().join("book-00002/metadata.json"), b"{}").expect("change")
                }
                "audio" => {
                    fs::write(root.path().join("book-00002/track.mp3"), b"changed").expect("change")
                }
                "missing-marker" => fs::remove_file(root.path().join(MANIFEST)).expect("remove"),
                _ => fs::write(root.path().join(MANIFEST), b"{}").expect("marker"),
            }
            let before = snapshot(root.path());
            assert!(run(root.path(), if change == "collision" { 4 } else { 1 }).is_err());
            assert_eq!(snapshot(root.path()), before, "{change}");
        }
    }

    #[test]
    fn rejects_symlink_destinations_books_files_and_markers() {
        let outside = tempfile::tempdir().expect("external");
        fs::write(outside.path().join("sentinel"), b"keep").expect("sentinel");
        for target in [
            "destination",
            "trailing-destination",
            "book",
            "audio",
            "metadata",
            "marker",
        ] {
            let root = tempfile::tempdir().expect("fixture");
            let output = root.path().join("output");
            if target == "destination" || target == "trailing-destination" {
                symlink(outside.path(), &output).expect("link");
            } else {
                run(&output, 3).expect("initial");
                let path = match target {
                    "book" => output.join("book-00002"),
                    "audio" => output.join("book-00002/track.mp3"),
                    "metadata" => output.join("book-00002/metadata.json"),
                    _ => output.join(MANIFEST),
                };
                if target == "book" {
                    fs::remove_dir_all(&path).expect("remove fixture book");
                } else {
                    fs::remove_file(&path).expect("remove fixture file");
                }
                symlink(outside.path(), path).expect("link");
            }
            let requested = if target == "trailing-destination" {
                output.join(".")
            } else {
                output.clone()
            };
            assert!(run(&requested, 1).is_err(), "{target}");
            assert_eq!(
                fs::read(outside.path().join("sentinel")).expect("external"),
                b"keep"
            );
            assert_eq!(
                fs::read_dir(outside.path())
                    .expect("external entries")
                    .count(),
                1
            );
            if target != "destination" && target != "trailing-destination" {
                assert!(output.join("book-00000/track.mp3").exists());
            }
        }
    }

    #[test]
    fn invalid_counts_and_generation_failures_preserve_existing_data() {
        let root = tempfile::tempdir().expect("fixture");
        run(root.path(), 3).expect("initial");
        let before = snapshot(root.path());
        for count in [0, 100_001, usize::MAX] {
            assert!(matches!(
                run(root.path(), count),
                Err(GenerationError::InvalidCount)
            ));
            assert_eq!(snapshot(root.path()), before);
        }
        let result = generate_with(root.path(), 1, |track| {
            fs::write(track, b"partial")?;
            Err(GenerationError::Media)
        });
        assert!(matches!(result, Err(GenerationError::Media)));
        assert_eq!(snapshot(root.path()), before);
        assert_eq!(fs::read_dir(root.path()).expect("entries").count(), 4);
        let fresh = root.path().join("fresh");
        assert!(generate_with(&fresh, 1, |_| Err(GenerationError::Media)).is_err());
        run(&fresh, 1).expect("retry after initial media failure");
    }

    #[test]
    fn rejects_interrupted_expansion_when_retry_uses_old_or_smaller_count() {
        for original_count in [1, 2] {
            let root = tempfile::tempdir().expect("fixture");
            run(root.path(), original_count).expect("initial");
            fs::write(root.path().join("sentinel"), b"keep").expect("sentinel");
            let result = generate_with_publication(
                root.path(),
                original_count + 2,
                |track| {
                    fs::write(track, b"test audio")?;
                    Ok(())
                },
                |published| {
                    if published == original_count + 1 {
                        Err(GenerationError::Media)
                    } else {
                        Ok(())
                    }
                },
            );
            assert!(matches!(result, Err(GenerationError::Media)));
            assert!(
                root.path().join(book_name(original_count)).is_dir(),
                "interrupted expansion must have published an extra book"
            );
            let before = snapshot(root.path());
            for retry_count in [original_count, 1, original_count + 2] {
                assert!(
                    matches!(
                        run(root.path(), retry_count),
                        Err(GenerationError::PublicationInterrupted)
                    ),
                    "interrupted publication must reject retry count {retry_count}"
                );
                assert_eq!(
                    snapshot(root.path()),
                    before,
                    "retry must not mutate any retained resource"
                );
            }
            assert_eq!(
                fs::read(root.path().join("sentinel")).expect("sentinel"),
                b"keep"
            );
        }
    }

    #[test]
    fn rejects_concurrent_generator_before_media_or_mutation() {
        let root = tempfile::tempdir().expect("fixture");
        run(root.path(), 3).expect("initial");
        let before = snapshot(root.path());
        generate_with(root.path(), 1, |track| {
            assert!(matches!(
                run(root.path(), 2),
                Err(GenerationError::Ownership(_))
            ));
            assert_eq!(snapshot(root.path()), before);
            fs::write(track, b"test audio")?;
            Ok(())
        })
        .expect("owning generator");
    }
}
