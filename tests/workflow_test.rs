use std::fs;
use std::path::Path;

#[test]
fn test_ci_workflow_includes_windows_latest() {
    let ci = fs::read_to_string(".github/workflows/ci.yml").unwrap();
    assert!(ci.contains("windows-latest"));
}

#[test]
fn test_release_workflow_builds_four_targets() {
    assert!(!Path::new(".github/workflows/release.yml").exists());
    let release = fs::read_to_string(".github/workflows/devkit-release.yml").unwrap();
    assert!(release.contains("target: aarch64-apple-darwin"));
    assert!(release.contains("target: x86_64-apple-darwin"));
    assert!(release.contains("target: x86_64-unknown-linux-musl"));
    assert!(release.contains("target: aarch64-unknown-linux-musl"));
}

#[test]
fn test_release_workflow_archives_are_tar_gz() {
    let release = fs::read_to_string(".github/workflows/devkit-release.yml").unwrap();
    assert!(
        release.contains("squad-$TARGET.tar.gz")
            || release.contains("squad-${{ matrix.target }}.tar.gz")
    );
}

#[test]
fn test_release_workflow_checksums_and_gh_release() {
    let release = fs::read_to_string(".github/workflows/devkit-release.yml").unwrap();
    assert!(release.contains("SHA256SUMS"));
    assert!(release.contains("gh release create"));
}
