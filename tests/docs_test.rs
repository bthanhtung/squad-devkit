use std::fs;

#[test]
fn test_english_squad_cli_doc_mentions_devkit_install() {
    let readme = fs::read_to_string("docs/squad-cli.md").unwrap();
    assert!(readme.contains("install-devkit.sh"));
    assert!(
        readme.contains("GitHub Releases")
            || readme.contains("Releases")
            || readme.contains("release")
    );
    assert!(!readme.contains("brew install mco-org"));
}

#[test]
fn test_chinese_squad_cli_doc_mentions_devkit_install() {
    let readme = fs::read_to_string("docs/squad-cli.zh-CN.md").unwrap();
    assert!(readme.contains("install-devkit.sh"));
    assert!(
        readme.contains("GitHub Releases")
            || readme.contains("Releases")
            || readme.contains("release")
    );
    assert!(!readme.contains("brew install mco-org"));
}
