//! Read-only checks for repository Markdown, website routes, and task references.
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Component, Path, PathBuf},
};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiagnosticKind {
    MissingTarget,
    MissingAnchor,
    UnknownTask,
    UndefinedReference,
    InvalidNavigation,
    UnlistedChapter,
}
impl DiagnosticKind {
    pub fn code(&self) -> &'static str {
        match self {
            Self::MissingTarget => "missing_target",
            Self::MissingAnchor => "missing_anchor",
            Self::UnknownTask => "unknown_task",
            Self::UndefinedReference => "undefined_reference",
            Self::InvalidNavigation => "invalid_navigation",
            Self::UnlistedChapter => "unlisted_chapter",
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
    pub file: PathBuf,
    pub line: usize,
    pub kind: DiagnosticKind,
    pub target: String,
}
#[derive(Debug, Error)]
pub enum CheckError {
    #[error("cannot read repository file {file}")]
    Read {
        file: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid TOML configuration in {file}")]
    Configuration {
        file: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("mise.toml has no tasks table")]
    MissingTasks,
}
#[derive(Debug)]
struct Document {
    text: String,
    anchors: BTreeSet<String>,
    links: Vec<(String, usize)>,
    unresolved: Vec<(String, usize)>,
    invalid_navigation: Vec<usize>,
}
fn read(root: &Path, file: &Path) -> Result<String, CheckError> {
    fs::read_to_string(root.join(file)).map_err(|source| CheckError::Read {
        file: file.into(),
        source,
    })
}
fn line(text: &str, offset: usize) -> usize {
    text[..offset].bytes().filter(|b| *b == b'\n').count() + 1
}
fn slug(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .filter_map(|c| {
            if c.is_alphanumeric() || c == '_' || c == '-' {
                Some(c)
            } else if c.is_whitespace() {
                Some('-')
            } else {
                None
            }
        })
        .collect()
}
fn body(text: &str) -> (&str, usize) {
    if text.starts_with("+++\n") || text.starts_with("---\n") {
        let delimiter = &text[..3];
        if let Some(end) = text[4..].find(&format!("\n{delimiter}\n")) {
            let offset = 4 + end + 5;
            return (&text[offset..], offset);
        }
    }
    (text, 0)
}
fn document(text: String, navigation: bool) -> Document {
    let mut anchors = BTreeSet::new();
    let mut links = Vec::new();
    let mut unresolved = Vec::new();
    let mut invalid_navigation = Vec::new();
    let (content, base) = body(&text);
    let mut broken = |reference: pulldown_cmark::BrokenLink<'_>| {
        unresolved.push((
            reference.reference.to_string(),
            line(&text, base + reference.span.start),
        ));
        None
    };
    let parser = Parser::new_with_broken_link_callback(content, Options::all(), Some(&mut broken));
    let mut heading: Option<(String, Option<String>)> = None;
    let mut link_depth = 0;
    for (event, range) in parser.into_offset_iter() {
        match event {
            Event::Start(Tag::Heading { id, .. }) => {
                if navigation {
                    invalid_navigation.push(line(&text, base + range.start));
                }
                heading = Some((String::new(), id.map(|s| s.to_string())))
            }
            Event::End(TagEnd::Heading(_)) => {
                if let Some((title, explicit)) = heading.take() {
                    let name = explicit.unwrap_or_else(|| slug(&title));
                    let mut candidate = name.clone();
                    let mut duplicate = 1;
                    while anchors.contains(&candidate) {
                        candidate = format!("{name}-{duplicate}");
                        duplicate += 1;
                    }
                    anchors.insert(candidate);
                }
            }
            Event::Start(Tag::Link { dest_url, .. }) => {
                links.push((dest_url.to_string(), line(&text, base + range.start)));
                link_depth += 1;
            }
            Event::End(TagEnd::Link) => link_depth -= 1,
            Event::Start(Tag::Image { dest_url, .. }) => {
                links.push((dest_url.to_string(), line(&text, base + range.start)))
            }
            Event::Text(value) | Event::Code(value) => {
                if let Some((title, _)) = &mut heading {
                    title.push_str(&value);
                } else if navigation && link_depth == 0 && !value.trim().is_empty() {
                    invalid_navigation.push(line(&text, base + range.start));
                }
            }
            Event::Html(value) | Event::InlineHtml(value) => {
                for attribute in ["id=\"", "name=\"", "id='", "name='"] {
                    for tail in value.split(attribute).skip(1) {
                        let quote = attribute.chars().last().unwrap_or('"');
                        if let Some(end) = tail.find(quote) {
                            anchors.insert(tail[..end].into());
                        }
                    }
                }
                if navigation {
                    invalid_navigation.push(line(&text, base + range.start));
                }
            }
            Event::Start(Tag::CodeBlock(_)) | Event::Rule if navigation => {
                invalid_navigation.push(line(&text, base + range.start))
            }
            _ => {}
        }
    }
    Document {
        text,
        anchors,
        links,
        unresolved,
        invalid_navigation,
    }
}
fn collect(root: &Path, directory: &Path, files: &mut Vec<PathBuf>) -> Result<(), CheckError> {
    let entries = fs::read_dir(root.join(directory)).map_err(|source| CheckError::Read {
        file: directory.into(),
        source,
    })?;
    for entry in entries {
        let entry = entry.map_err(|source| CheckError::Read {
            file: directory.into(),
            source,
        })?;
        let path = directory.join(entry.file_name());
        let kind = entry.file_type().map_err(|source| CheckError::Read {
            file: path.clone(),
            source,
        })?;
        if kind.is_dir() {
            if !matches!(
                entry.file_name().to_str(),
                Some(
                    ".git"
                        | ".build"
                        | ".swiftpm"
                        | "target"
                        | "node_modules"
                        | "public"
                        | "book"
                        | ".venv"
                        | "artifacts"
                        | ".codex"
                )
            ) {
                collect(root, &path, files)?;
            }
        } else if kind.is_file()
            && path
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("md"))
        {
            files.push(path);
        }
    }
    Ok(())
}
fn normalized(path: &Path) -> Option<PathBuf> {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => result.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                if !result.pop() {
                    return None;
                }
            }
            _ => return None,
        }
    }
    Some(result)
}
fn route(file: &Path, text: &str) -> Option<String> {
    let relative = file.strip_prefix("site/content").ok()?;
    let (_, base) = body(text);
    let metadata = if base > 0 {
        toml::from_str::<toml::Value>(&text[4..base - 5]).ok()
    } else {
        None
    };
    let directory = relative.parent().unwrap_or(Path::new(""));
    let stem = relative.file_stem()?.to_str()?;
    if let Some(path) = metadata
        .as_ref()
        .and_then(|v| v.get("path"))
        .and_then(|v| v.as_str())
    {
        return Some(format!("/{}/", path.trim_matches('/')));
    }
    let name = metadata
        .as_ref()
        .and_then(|v| v.get("slug"))
        .and_then(|v| v.as_str())
        .unwrap_or(stem);
    let path = if stem == "_index" {
        directory.to_path_buf()
    } else {
        directory.join(name)
    };
    let value = path.to_string_lossy().replace('\\', "/");
    Some(if value.is_empty() {
        "/".into()
    } else {
        format!("/{value}/")
    })
}
fn external(target: &str) -> bool {
    target.starts_with("//")
        || target.split_once(':').is_some_and(|(scheme, _)| {
            !scheme.is_empty()
                && scheme
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        })
}
/// Checks current files without executing commands, accessing the network, or writing output files.
pub fn check(root: &Path) -> Result<Vec<Diagnostic>, CheckError> {
    let config = read(root, Path::new("mise.toml"))?;
    let config =
        toml::from_str::<toml::Value>(&config).map_err(|source| CheckError::Configuration {
            file: "mise.toml".into(),
            source,
        })?;
    let tasks = config
        .get("tasks")
        .and_then(|v| v.as_table())
        .ok_or(CheckError::MissingTasks)?;
    let mut files = Vec::new();
    collect(root, Path::new(""), &mut files)?;
    files.sort();
    let mut documents = BTreeMap::new();
    for file in files {
        let text = read(root, &file)?;
        let navigation = file == Path::new("docs/SUMMARY.md");
        documents.insert(file, document(text, navigation));
    }
    let routes: BTreeMap<String, PathBuf> = documents
        .iter()
        .filter_map(|(file, doc)| route(file, &doc.text).map(|r| (r, file.clone())))
        .collect();
    let chapters = documents.get(Path::new("docs/SUMMARY.md")).map(|summary| {
        summary
            .links
            .iter()
            .filter_map(|(target, _)| {
                let path = target.split('#').next().unwrap_or(target);
                normalized(&Path::new("docs").join(path))
            })
            .collect::<BTreeSet<_>>()
    });
    let mut diagnostics = Vec::new();
    for (file, doc) in &documents {
        let mut report = |line, kind, target: String| {
            diagnostics.push(Diagnostic {
                file: file.clone(),
                line,
                kind,
                target,
            })
        };
        for number in &doc.invalid_navigation {
            report(
                *number,
                DiagnosticKind::InvalidNavigation,
                "mdBook navigation must contain page links only".into(),
            );
        }
        for (target, number) in &doc.unresolved {
            report(*number, DiagnosticKind::UndefinedReference, target.clone());
        }
        for (target, number) in &doc.links {
            if external(target) {
                continue;
            }
            let (path, anchor) = target
                .split_once('#')
                .map_or((target.as_str(), None), |(p, a)| (p, Some(a)));
            let path = path.split('?').next().unwrap_or(path);
            let path = percent_encoding::percent_decode_str(path).decode_utf8_lossy();
            let website = file.starts_with("site/content");
            let destination = if path.is_empty() {
                Some(file.clone())
            } else if website && path.starts_with('@') {
                normalized(&Path::new("site/content").join(path.trim_start_matches("@/")))
            } else if website && path.starts_with('/') {
                let key = if path == "/" {
                    "/".into()
                } else {
                    format!("/{}/", path.trim_matches('/'))
                };
                routes.get(&key).cloned().or_else(|| {
                    normalized(&Path::new("site/static").join(path.trim_start_matches('/')))
                })
            } else if website && !path.ends_with(".md") && !path.starts_with('/') {
                let current = route(file, &doc.text).unwrap_or_else(|| "/".into());
                let key =
                    normalized(&Path::new(current.trim_start_matches('/')).join(path.as_ref()));
                key.and_then(|p| {
                    routes
                        .get(&format!("/{}/", p.to_string_lossy().trim_matches('/')))
                        .cloned()
                })
                .or_else(|| normalized(&file.parent().unwrap_or(Path::new("")).join(path.as_ref())))
            } else {
                normalized(&file.parent().unwrap_or(Path::new("")).join(path.as_ref()))
            };
            match destination {
                Some(destination) if root.join(&destination).exists() => {
                    if file.starts_with("docs")
                        && file != Path::new("docs/SUMMARY.md")
                        && destination.starts_with("docs")
                        && destination.extension().is_some_and(|e| e == "md")
                        && chapters
                            .as_ref()
                            .is_some_and(|listed| !listed.contains(&destination))
                    {
                        report(*number, DiagnosticKind::UnlistedChapter, target.clone());
                    }
                    if let Some(anchor) = anchor.filter(|a| !a.is_empty()) {
                        let anchor =
                            percent_encoding::percent_decode_str(anchor).decode_utf8_lossy();
                        if let Some(destination_doc) = documents.get(&destination)
                            && !destination_doc.anchors.contains(anchor.as_ref())
                        {
                            report(*number, DiagnosticKind::MissingAnchor, target.clone());
                        }
                    }
                }
                _ => report(*number, DiagnosticKind::MissingTarget, target.clone()),
            }
        }
        for (index, text) in doc.text.lines().enumerate() {
            for (_, tail) in text
                .match_indices("mise run ")
                .map(|(i, _)| (i, &text[i + 9..]))
            {
                let task = tail
                    .split_whitespace()
                    .next()
                    .unwrap_or("")
                    .trim_matches(|c: char| {
                        matches!(c, '`' | '\'' | '"' | ',' | ';' | ')' | '.' | ':')
                    });
                if !task.is_empty()
                    && !task.starts_with('-')
                    && !task.starts_with('$')
                    && !task.contains('*')
                    && !tasks.contains_key(task)
                {
                    report(index + 1, DiagnosticKind::UnknownTask, task.into());
                }
            }
        }
    }
    Ok(diagnostics)
}
