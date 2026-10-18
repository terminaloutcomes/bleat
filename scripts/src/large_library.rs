//! Owned synthetic media fixtures for the large-library live harness.
use std::{
    fs::{self, OpenOptions},
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
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format: String,
    count: usize,
    audio_sha256: String,
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
    let mut file = if fs::read_dir(output)?.next().is_none() {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&marker)?;
        file.try_lock()
            .map_err(|_| ownership("generator is already running"))?;
        serde_json::to_writer(
            &mut file,
            &Manifest {
                format: FORMAT.into(),
                count: 0,
                audio_sha256: String::new(),
            },
        )?;
        file.sync_all()?;
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
    let manifest: Manifest = serde_json::from_slice(&bytes)?;
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
    // Remove only the two validated files, never a recursive book glob.
    // Interrupted publication leaves an inconsistent manifest and fails closed.
    for index in 0..manifest.count {
        let book = output.join(book_name(index));
        fs::remove_file(book.join("track.mp3"))?;
        fs::remove_file(book.join("metadata.json"))?;
        fs::remove_dir(book)?;
    }
    for index in 0..count {
        let name = book_name(index);
        fs::rename(stage.path().join(&name), output.join(name))?;
    }
    file.seek(SeekFrom::Start(0))?;
    file.set_len(0)?;
    serde_json::to_writer(
        &mut file,
        &Manifest {
            format: FORMAT.into(),
            count,
            audio_sha256: digest,
        },
    )?;
    file.sync_all()?;
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
