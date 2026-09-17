use serde::{Deserialize, Serialize};
use std::path::{Component, Path};

pub const RELEASE_MANIFEST_LIMIT: usize = 32 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReleaseManifest {
    pub schema_version: u8,
    pub plugin_id: String,
    pub version: String,
    pub summary: String,
    pub changes: Vec<String>,
    pub binary: BundledBinary,
    pub state_schema_version: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BundledBinary {
    pub target: String,
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
}

impl ReleaseManifest {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > RELEASE_MANIFEST_LIMIT {
            return Err("release metadata is too large".into());
        }
        let value: Self = serde_json::from_slice(bytes)
            .map_err(|error| format!("release metadata is invalid: {error}"))?;
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err("release metadata uses an unsupported schema".into());
        }
        if self.plugin_id != "entroit.omaflow" {
            return Err("release metadata names another plugin".into());
        }
        validate_version(&self.version)?;
        validate_text(&self.summary, 120, "release summary")?;
        if self.changes.is_empty() || self.changes.len() > 3 {
            return Err("release metadata must contain one to three changes".into());
        }
        for change in &self.changes {
            validate_text(change, 120, "release change")?;
        }
        if self.binary.target != "x86_64-unknown-linux-gnu" {
            return Err("this release does not support this computer".into());
        }
        let path = Path::new(&self.binary.path);
        if path.is_absolute()
            || path
                .components()
                .any(|component| !matches!(component, Component::Normal(_)))
            || self.binary.path != "dist/bin/x86_64-unknown-linux-gnu/omaflow"
        {
            return Err("release metadata contains an unsafe binary path".into());
        }
        if self.binary.bytes == 0 || self.binary.bytes > 128 * 1024 * 1024 {
            return Err("release binary size is invalid".into());
        }
        if self.binary.sha256.len() != 64
            || !self
                .binary
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
        {
            return Err("release binary checksum is invalid".into());
        }
        Ok(())
    }
}

pub fn validate_version(version: &str) -> Result<(), String> {
    let parts: Vec<_> = version.split('.').collect();
    if parts.len() != 3
        || parts.iter().any(|part| {
            part.is_empty()
                || !part.bytes().all(|byte| byte.is_ascii_digit())
                || (part.len() > 1 && part.starts_with('0'))
        })
    {
        return Err("release version is invalid".into());
    }
    Ok(())
}

fn validate_text(value: &str, limit: usize, name: &str) -> Result<(), String> {
    if value.is_empty() || value.chars().count() > limit || value.chars().any(char::is_control) {
        return Err(format!("{name} is invalid"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid() -> ReleaseManifest {
        ReleaseManifest {
            schema_version: 1,
            plugin_id: "entroit.omaflow".into(),
            version: "0.18.0".into(),
            summary: "Updates install inside OmaFlow.".into(),
            changes: vec!["Adds verified updates.".into()],
            binary: BundledBinary {
                target: "x86_64-unknown-linux-gnu".into(),
                path: "dist/bin/x86_64-unknown-linux-gnu/omaflow".into(),
                bytes: 42,
                sha256: "a".repeat(64),
            },
            state_schema_version: 4,
        }
    }

    #[test]
    fn rejects_paths_and_release_copy_outside_the_contract() {
        assert!(valid().validate().is_ok());
        let mut release = valid();
        release.binary.path = "../omaflow".into();
        assert_eq!(
            release.validate().unwrap_err(),
            "release metadata contains an unsafe binary path"
        );
        let mut release = valid();
        release.changes = vec!["x".repeat(121)];
        assert_eq!(release.validate().unwrap_err(), "release change is invalid");
    }
}
