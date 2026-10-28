use std::fs;

#[test]
fn test_english_readme_mentions_windows_zip_install() {
    let readme = fs::read_to_string("docs/squad-cli.md").unwrap();
    assert!(readme.contains("Windows"));
    assert!(readme.contains("GitHub Releases"));
    assert!(readme.contains("squad-x86_64-pc-windows-msvc.zip"));
    assert!(readme.contains("Extract squad.exe"));
    assert!(readme.contains("squad.exe"));
    assert!(readme.contains("PATH"));
}

#[test]
fn test_chinese_readme_mentions_windows_zip_install() {
    let readme = fs::read_to_string("docs/squad-cli.zh-CN.md").unwrap();
    assert!(readme.contains("Windows"));
    assert!(readme.contains("GitHub Releases"));
    assert!(readme.contains("squad-x86_64-pc-windows-msvc.zip"));
    assert!(readme.contains("squad.exe"));
    assert!(readme.contains("解压"));
    assert!(readme.contains("PATH"));
}
