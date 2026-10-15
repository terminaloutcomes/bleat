use std::{fs, io, path::Path};

#[derive(Debug, thiserror::Error)]
pub enum SiteNewsError {
    #[error("could not read CHANGELOG.md: {0}")]
    Read(io::Error),
    #[error("CHANGELOG.md must begin with the Changelog heading")]
    MissingHeading,
    #[error("could not write site/content/news.md: {0}")]
    Write(io::Error),
}

pub fn generate(root: &Path) -> Result<(), SiteNewsError> {
    let changelog = fs::read_to_string(root.join("CHANGELOG.md")).map_err(SiteNewsError::Read)?;
    let body = changelog
        .strip_prefix("# Changelog\n")
        .ok_or(SiteNewsError::MissingHeading)?;
    let page = format!(
        "+++\ntitle = \"News\"\ndescription = \"The latest Bleat releases and improvements.\"\ntemplate = \"page.html\"\n+++\n{body}"
    );
    fs::write(root.join("site/content/news.md"), page).map_err(SiteNewsError::Write)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_news_from_current_changelog() {
        let root = tempfile::tempdir().expect("temporary repository");
        fs::create_dir_all(root.path().join("site/content")).expect("content directory");
        let source = root.path().join("CHANGELOG.md");
        fs::write(
            &source,
            "# Changelog\n\n## 1.0 - 2026-10-15\n\n- First release.\n",
        )
        .expect("changelog fixture");
        generate(root.path()).expect("generate news");
        let output = root.path().join("site/content/news.md");
        let page = fs::read_to_string(&output).expect("generated page");
        assert!(page.contains("template = \"page.html\""));
        assert!(page.contains("## 1.0 - 2026-10-15\n\n- First release."));
        assert!(!page.contains("# Changelog"));

        fs::write(&source, "# Changelog\n\n## 1.1\n\n- Updated release.\n")
            .expect("updated changelog");
        generate(root.path()).expect("regenerate news");
        let page = fs::read_to_string(output).expect("updated page");
        assert!(page.contains("## 1.1"));
        assert!(!page.contains("First release."));
    }

    #[test]
    fn rejects_invalid_changelog_without_replacing_news() {
        let root = tempfile::tempdir().expect("temporary repository");
        fs::create_dir_all(root.path().join("site/content")).expect("content directory");
        let output = root.path().join("site/content/news.md");
        fs::write(&output, "previous news").expect("existing page");
        assert!(matches!(generate(root.path()), Err(SiteNewsError::Read(_))));
        fs::write(root.path().join("CHANGELOG.md"), "unexpected heading")
            .expect("invalid changelog");
        assert!(matches!(
            generate(root.path()),
            Err(SiteNewsError::MissingHeading)
        ));
        assert_eq!(
            fs::read_to_string(output).expect("preserved page"),
            "previous news"
        );
    }
}
