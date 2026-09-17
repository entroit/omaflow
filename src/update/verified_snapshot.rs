use super::release_manifest::ReleaseManifest;
use serde::{Deserialize, Serialize};

pub const CATALOG_URL: &str =
    "https://raw.githubusercontent.com/omacom/omarchy-plugin-marketplace/main/site/catalog.json";
pub const CANONICAL_REPOSITORY: &str = "https://github.com/entroit/omaflow";
pub const CATALOG_LIMIT: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VerifiedSnapshot {
    pub commit: String,
    pub version: String,
    pub summary: String,
    pub changes: Vec<String>,
    pub repository: String,
    pub verification_method: String,
    pub binary_path: String,
    pub binary_bytes: u64,
    pub binary_sha256: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Catalog {
    state_schema_version: u32,
    plugins: Vec<CatalogPlugin>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogPlugin {
    id: String,
    repo: String,
    verification_snapshot_status: Option<String>,
    verification_commit: Option<String>,
    verification_method: Option<String>,
    listing_validated_commit: Option<String>,
}

pub fn parse_catalog(bytes: &[u8]) -> Result<Option<(String, String)>, String> {
    if bytes.len() > CATALOG_LIMIT {
        return Err("the marketplace catalog is too large".into());
    }
    let catalog: Catalog = serde_json::from_slice(bytes)
        .map_err(|error| format!("the marketplace catalog is invalid: {error}"))?;
    if catalog.state_schema_version != 2 {
        return Err("the marketplace catalog uses an unsupported schema".into());
    }
    let mut matches = catalog
        .plugins
        .into_iter()
        .filter(|plugin| plugin.id == "entroit.omaflow" && plugin.repo == CANONICAL_REPOSITORY);
    let Some(plugin) = matches.next() else {
        return Ok(None);
    };
    if matches.next().is_some() {
        return Err("the marketplace catalog contains duplicate OmaFlow entries".into());
    }
    let commit = plugin
        .verification_commit
        .ok_or("the marketplace entry has no verified commit")?;
    let listing = plugin
        .listing_validated_commit
        .ok_or("the marketplace entry has no validated commit")?;
    if plugin.verification_snapshot_status.as_deref() != Some("verified") {
        return Ok(None);
    }
    if !full_sha(&commit) || commit != listing {
        return Err("the marketplace commit identities do not match".into());
    }
    Ok(Some((
        commit.to_ascii_lowercase(),
        plugin.verification_method.unwrap_or_default(),
    )))
}

impl VerifiedSnapshot {
    pub fn from_release(
        commit: String,
        verification_method: String,
        release: ReleaseManifest,
    ) -> Result<Self, String> {
        Ok(Self {
            commit,
            version: release.version,
            summary: release.summary,
            changes: release.changes,
            repository: CANONICAL_REPOSITORY.into(),
            verification_method,
            binary_path: release.binary.path,
            binary_bytes: release.binary.bytes,
            binary_sha256: release.binary.sha256.to_ascii_lowercase(),
        })
    }
}

pub fn full_sha(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog(snapshot: &str, verified: &str, listed: &str) -> Vec<u8> {
        format!(r#"{{"stateSchemaVersion":2,"plugins":[{{"id":"entroit.omaflow","version":"99.0.0","repo":"https://github.com/entroit/omaflow","verificationSnapshotStatus":"{snapshot}","verificationCommit":"{verified}","listingValidatedCommit":"{listed}","verificationStatus":"update-unverified","verificationCoverage":"snapshot-verified"}}]}}"#).into_bytes()
    }

    #[test]
    fn accepts_the_verified_snapshot_even_when_head_coverage_is_unverified() {
        let sha = "a".repeat(40);
        let parsed = parse_catalog(&catalog("verified", &sha, &sha))
            .unwrap()
            .unwrap();
        assert_eq!(parsed.0, sha);
        assert_eq!(parsed.1, "");
    }

    #[test]
    fn rejects_a_listing_that_does_not_bind_the_verified_commit() {
        let error =
            parse_catalog(&catalog("verified", &"a".repeat(40), &"b".repeat(40))).unwrap_err();
        assert_eq!(error, "the marketplace commit identities do not match");
        assert!(
            parse_catalog(&catalog("revoked", &"a".repeat(40), &"a".repeat(40)))
                .unwrap()
                .is_none()
        );
    }
}
