use super::{VerifiedSnapshot, require_regular_file, sha256};
use crate::process::CommandExt;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Command, Stdio},
    time::Duration,
};

const VERIFIER: &str = include_str!("../../scripts/release_artifact.py");

pub(super) fn acquire(destination: &Path, snapshot: &VerifiedSnapshot) -> Result<(), String> {
    let output = Command::new("/usr/bin/python3")
        .args([
            "-I",
            "-c",
            VERIFIER,
            "--commit",
            &snapshot.commit,
            "--version",
            &snapshot.version,
            "--bytes",
            &snapshot.binary_bytes.to_string(),
            "--sha256",
            &snapshot.binary_sha256,
            "--destination",
        ])
        .arg(destination)
        .env_clear()
        .env("PATH", "/usr/bin")
        .stdin(Stdio::null())
        .bounded_output_for(Duration::from_secs(7 * 60))
        .map_err(|error| format!("could not verify the release artifact: {error}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "could not verify the release artifact: {}",
            detail.lines().next().unwrap_or("verification failed")
        ));
    }
    validate_download(destination, snapshot)
}

fn validate_download(destination: &Path, snapshot: &VerifiedSnapshot) -> Result<(), String> {
    require_regular_file(destination, Path::new("omaflow"))?;
    require_regular_file(destination, Path::new("omaflow.sigstore.json"))?;
    let binary = destination.join("omaflow");
    let metadata = fs::metadata(&binary)
        .map_err(|error| format!("could not inspect the release binary: {error}"))?;
    if metadata.len() != snapshot.binary_bytes || metadata.permissions().mode() & 0o111 == 0 {
        return Err("the release binary has the wrong size or permissions".into());
    }
    if sha256(&binary)? != snapshot.binary_sha256 {
        return Err("the release binary checksum does not match".into());
    }
    let output = Command::new(&binary)
        .args(["version", "--json"])
        .bounded_output_for(Duration::from_secs(15))
        .map_err(|error| format!("could not inspect the release binary: {error}"))?;
    let version: serde_json::Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| "the release binary returned invalid version data".to_string())?;
    if !output.status.success()
        || version["pluginId"] != "entroit.omaflow"
        || version["version"] != snapshot.version
        || version["target"] != "x86_64-unknown-linux-gnu"
    {
        return Err("the release binary identity does not match".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn download_fixture() -> (std::path::PathBuf, VerifiedSnapshot) {
        let directory = std::env::temp_dir().join(format!(
            "omaflow-release-artifact-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        fs::write(
            directory.join("omaflow"),
            r#"#!/usr/bin/bash
/usr/bin/touch "$0.executed"
printf '%s\n' '{"pluginId":"entroit.omaflow","version":"0.21.3","target":"x86_64-unknown-linux-gnu"}'
"#,
        )
        .unwrap();
        fs::set_permissions(directory.join("omaflow"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(directory.join("omaflow.sigstore.json"), "{}").unwrap();
        let snapshot = VerifiedSnapshot {
            commit: "a".repeat(40),
            version: "0.21.3".into(),
            summary: "Update from a public build.".into(),
            changes: vec!["Verify release provenance.".into()],
            repository: "https://github.com/entroit/omaflow".into(),
            verification_method: "test".into(),
            binary_path: "dist/bin/x86_64-unknown-linux-gnu/omaflow".into(),
            binary_bytes: fs::metadata(directory.join("omaflow")).unwrap().len(),
            binary_sha256: sha256(&directory.join("omaflow")).unwrap(),
        };
        (directory, snapshot)
    }

    #[test]
    fn checks_downloaded_bytes_before_executing_their_version_command() {
        let (directory, mut snapshot) = download_fixture();
        let actual_sha256 = snapshot.binary_sha256.clone();
        snapshot.binary_sha256 = "b".repeat(64);
        assert_eq!(
            validate_download(&directory, &snapshot).unwrap_err(),
            "the release binary checksum does not match"
        );
        assert!(!directory.join("omaflow.executed").exists());
        snapshot.binary_sha256 = actual_sha256;
        validate_download(&directory, &snapshot).unwrap();
        assert!(directory.join("omaflow.executed").is_file());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_a_downloaded_binary_with_the_wrong_release_identity() {
        let (directory, mut snapshot) = download_fixture();
        snapshot.version = "0.21.4".into();
        assert_eq!(
            validate_download(&directory, &snapshot).unwrap_err(),
            "the release binary identity does not match"
        );
        assert!(directory.join("omaflow.executed").is_file());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_linked_artifacts_before_executing_them() {
        let (directory, snapshot) = download_fixture();
        fs::rename(directory.join("omaflow"), directory.join("real-omaflow")).unwrap();
        symlink("real-omaflow", directory.join("omaflow")).unwrap();
        let error = validate_download(&directory, &snapshot).unwrap_err();
        assert!(error.ends_with("omaflow is not a regular file"), "{error}");
        assert!(!directory.join("omaflow.executed").exists());
        fs::remove_file(directory.join("omaflow")).unwrap();
        fs::rename(directory.join("real-omaflow"), directory.join("omaflow")).unwrap();
        validate_download(&directory, &snapshot).unwrap();
        assert!(directory.join("omaflow.executed").is_file());
        fs::remove_dir_all(directory).unwrap();
    }
}
