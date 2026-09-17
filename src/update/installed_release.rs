use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InstalledRelease {
    pub schema_version: u8,
    pub commit: String,
    pub version: String,
    pub binary_sha256: String,
    pub installed_at_ms: u64,
}

impl InstalledRelease {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err("installed release receipt uses an unsupported schema".into());
        }
        if !super::verified_snapshot::full_sha(&self.commit) {
            return Err("installed release receipt has an invalid commit".into());
        }
        super::release_manifest::validate_version(&self.version)?;
        if self.binary_sha256.len() != 64
            || !self
                .binary_sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
        {
            return Err("installed release receipt has an invalid binary checksum".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_receipt_identity_fields() {
        let mut receipt = InstalledRelease {
            schema_version: 1,
            commit: "a".repeat(40),
            version: "0.18.0".into(),
            binary_sha256: "b".repeat(64),
            installed_at_ms: 1,
        };
        assert!(receipt.validate().is_ok());
        receipt.commit = "main".into();
        assert_eq!(
            receipt.validate().unwrap_err(),
            "installed release receipt has an invalid commit"
        );
    }
}
