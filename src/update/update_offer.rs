use super::verified_snapshot::VerifiedSnapshot;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateOffer {
    pub schema_version: u8,
    pub checked_at_ms: u64,
    pub target: Option<VerifiedSnapshot>,
    pub error: Option<String>,
    pub external_checkout_warning: Option<String>,
}
