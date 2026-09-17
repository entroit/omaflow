use super::installed_release::InstalledRelease;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum UpdateTransaction {
    Queued(TransactionIdentity),
    Preparing(TransactionProgress),
    WaitingForIdle(TransactionProgress),
    Activating(TransactionProgress),
    Verifying(TransactionProgress),
    Succeeded(UpdateSuccess),
    RolledBack(UpdateFailure),
    NeedsRecovery(UpdateFailure),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TransactionIdentity {
    pub schema_version: u8,
    pub id: String,
    pub target_commit: String,
    pub target_version: String,
    pub original_commit: String,
    pub original_release: InstalledRelease,
    pub created_at_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TransactionProgress {
    #[serde(flatten)]
    pub identity: TransactionIdentity,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateSuccess {
    #[serde(flatten)]
    pub identity: TransactionIdentity,
    pub message: String,
    pub completed_at_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateFailure {
    #[serde(flatten)]
    pub identity: TransactionIdentity,
    pub message: String,
    pub failed_at_ms: u64,
}

impl UpdateTransaction {
    pub fn identity(&self) -> &TransactionIdentity {
        match self {
            Self::Queued(value) => value,
            Self::Preparing(value)
            | Self::WaitingForIdle(value)
            | Self::Activating(value)
            | Self::Verifying(value) => &value.identity,
            Self::Succeeded(value) => &value.identity,
            Self::RolledBack(value) | Self::NeedsRecovery(value) => &value.identity,
        }
    }

    pub fn is_active(&self) -> bool {
        matches!(
            self,
            Self::Queued(_)
                | Self::Preparing(_)
                | Self::WaitingForIdle(_)
                | Self::Activating(_)
                | Self::Verifying(_)
        )
    }

    pub fn needs_reconciliation(&self) -> bool {
        self.is_active() || matches!(self, Self::NeedsRecovery(_))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity() -> TransactionIdentity {
        TransactionIdentity {
            schema_version: 1,
            id: "123-aaaaaaaaaaaa".into(),
            target_commit: "a".repeat(40),
            target_version: "0.18.0".into(),
            original_commit: "b".repeat(40),
            original_release: InstalledRelease {
                schema_version: 1,
                commit: "b".repeat(40),
                version: "0.17.0".into(),
                binary_sha256: "c".repeat(64),
                installed_at_ms: 1,
            },
            created_at_ms: 2,
        }
    }

    #[test]
    fn terminal_states_cannot_be_mistaken_for_in_progress_work() {
        let queued = UpdateTransaction::Queued(identity());
        assert!(queued.is_active());
        let succeeded = UpdateTransaction::Succeeded(UpdateSuccess {
            identity: identity(),
            message: "OmaFlow 0.18.0 is ready".into(),
            completed_at_ms: 3,
        });
        assert!(!succeeded.is_active());
        let json = serde_json::to_value(succeeded).unwrap();
        assert_eq!(json["state"], "succeeded");
        assert_eq!(json["targetVersion"], "0.18.0");
        let recovery = UpdateTransaction::NeedsRecovery(UpdateFailure {
            identity: identity(),
            message: "retry".into(),
            failed_at_ms: 4,
        });
        assert!(!recovery.is_active());
        assert!(recovery.needs_reconciliation());
    }
}
