use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NotificationReceipt {
    pub schema_version: u8,
    pub last_notified_commit: Option<String>,
    pub claimed_at_ms: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeferralState {
    pub schema_version: u8,
    pub commit: Option<String>,
    pub until_ms: Option<u64>,
}
