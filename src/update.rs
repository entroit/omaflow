//! Marketplace-gated updates for the OmaFlow checkout and bundled daemon.

mod installed_release;
mod notification;
mod release_manifest;
mod store;
mod update_offer;
mod update_transaction;
mod verified_snapshot;

pub use installed_release::InstalledRelease;
pub use release_manifest::ReleaseManifest;
pub use update_offer::UpdateOffer;
pub use update_transaction::UpdateTransaction;
pub use verified_snapshot::VerifiedSnapshot;

use crate::process::CommandExt;
use notification::{DeferralState, NotificationReceipt};
use std::{
    env, fs,
    io::{Read, Write},
    net::Shutdown,
    os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use store::UpdateLock;
use update_transaction::{TransactionIdentity, TransactionProgress, UpdateFailure, UpdateSuccess};
use verified_snapshot::{CANONICAL_REPOSITORY, CATALOG_URL, full_sha, parse_catalog};

pub const STATE_VERSION: u32 = 4;
pub const RUNNING_VERSION: &str = env!("CARGO_PKG_VERSION");
const STATE_LIMIT: usize = 256 * 1024;
const OMARCHY: &str = "/usr/share/omarchy/bin/omarchy";
const NOTIFY: &str = "/usr/share/omarchy/bin/omarchy-notification-send";
const SHELL: &str = "/usr/share/omarchy/bin/omarchy-shell";
const GIT_LOCAL_TIMEOUT: Duration = Duration::from_secs(30);
const GIT_NETWORK_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Default)]
pub struct RemoteStatus {
    pub behind: u32,
    pub remote_version: String,
    pub checked_at_ms: u64,
    pub error: String,
}

#[derive(Debug, Clone, Default)]
pub struct UpdateStatus {
    pub checkout_version: String,
    pub needs_rebuild: bool,
    pub remote: RemoteStatus,
}

pub fn repo_root() -> Option<PathBuf> {
    let from_plugin = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .map(|base| base.join("omarchy/plugins/entroit.omaflow"))
        .and_then(|path| fs::canonicalize(path).ok());
    from_plugin.filter(|root| root.join("manifest.json").is_file() && root.join(".git").exists())
}

fn checkout_version(root: &Path) -> Option<String> {
    manifest_version(&fs::read_to_string(root.join("manifest.json")).ok()?)
}

fn manifest_version(manifest: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(manifest)
        .ok()?
        .get("version")?
        .as_str()
        .map(ToOwned::to_owned)
}

pub fn status() -> UpdateStatus {
    let checkout_version = repo_root()
        .and_then(|root| checkout_version(&root))
        .unwrap_or_default();
    let offer: Option<UpdateOffer> = store::read(&store::offer_path(), STATE_LIMIT)
        .ok()
        .flatten();
    let transaction: Option<UpdateTransaction> =
        store::read(&store::transaction_path(), STATE_LIMIT)
            .ok()
            .flatten();
    let remote_version = offer
        .as_ref()
        .and_then(|offer| offer.target.as_ref())
        .map(|target| target.version.clone())
        .unwrap_or_default();
    let error = offer
        .as_ref()
        .and_then(|offer| offer.error.clone())
        .unwrap_or_default();
    let checked_at_ms = offer.as_ref().map_or(0, |offer| offer.checked_at_ms);
    UpdateStatus {
        needs_rebuild: transaction
            .as_ref()
            .is_some_and(UpdateTransaction::is_active),
        checkout_version,
        remote: RemoteStatus {
            behind: u32::from(!remote_version.is_empty()),
            remote_version,
            checked_at_ms,
            error,
        },
    }
}

pub fn check_remote() -> Result<RemoteStatus, String> {
    let offer = check()?;
    Ok(RemoteStatus {
        behind: u32::from(offer.target.is_some()),
        remote_version: offer
            .target
            .map(|target| target.version)
            .unwrap_or_default(),
        checked_at_ms: offer.checked_at_ms,
        error: offer.error.unwrap_or_default(),
    })
}

pub fn check() -> Result<UpdateOffer, String> {
    let _lock = UpdateLock::acquire()?;
    let checked_at_ms = now_ms();
    let previous: Option<UpdateOffer> = store::read(&store::offer_path(), STATE_LIMIT)?;
    let installed = read_installed();
    let result = discover_verified_snapshot_for(
        installed
            .as_ref()
            .ok()
            .map(|release| release.version.as_str()),
    );
    let external_checkout_warning = match (repo_root(), &installed) {
        (Some(root), Ok(installed)) => head(&root)
            .ok()
            .filter(|head| *head != installed.commit)
            .map(|_| "The plugin checkout changed outside OmaFlow. Updates are paused until that checkout is reviewed.".into()),
        _ => None,
    };
    let (target, error) = match result {
        Ok(Some(snapshot)) => {
            let target = match installed.as_ref() {
                Ok(installed) if installed.commit == snapshot.commit => None,
                Ok(installed)
                    if compare_versions(&snapshot.version, &installed.version).is_lt() =>
                {
                    None
                }
                _ => Some(snapshot),
            };
            (target, None)
        }
        Ok(None) => (None, None),
        Err(error) => {
            let target = if error == "the marketplace has no verified OmaFlow release" {
                None
            } else {
                previous.and_then(|offer| offer.target)
            };
            (target, Some(error))
        }
    };
    let offer = UpdateOffer {
        schema_version: 1,
        checked_at_ms,
        target,
        error,
        external_checkout_warning,
    };
    store::replace(&store::offer_path(), &offer)?;
    if let Some(target) = &offer.target {
        notify_once(target)?;
    }
    Ok(offer)
}

fn discover_verified_snapshot() -> Result<VerifiedSnapshot, String> {
    discover_verified_snapshot_for(None)?
        .ok_or_else(|| "the marketplace release is older than the installed release".to_string())
}

fn discover_verified_snapshot_for(
    installed_version: Option<&str>,
) -> Result<Option<VerifiedSnapshot>, String> {
    let catalog = download(CATALOG_URL, verified_snapshot::CATALOG_LIMIT)?;
    let (commit, method) =
        parse_catalog(&catalog)?.ok_or("the marketplace has no verified OmaFlow release")?;
    let root = repo_root().ok_or("could not locate the OmaFlow checkout")?;
    require_canonical_checkout(&root)?;
    fetch_exact(&root, &commit)?;
    let manifest_bytes = git_bytes(&root, &["show", &format!("{commit}:manifest.json")])?;
    #[derive(serde::Deserialize)]
    struct PluginManifest {
        id: String,
        version: String,
    }
    let manifest: PluginManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|_| "the verified plugin manifest is invalid")?;
    if manifest.id != "entroit.omaflow" {
        return Err("the verified manifest names another plugin".into());
    }
    release_manifest::validate_version(&manifest.version)?;
    if !release_metadata_required(&manifest.version, installed_version) {
        // Older marketplace snapshots predate the bundled release contract.
        // They cannot be installed by this updater and need no release.json.
        return Ok(None);
    }
    let release_bytes = git_bytes(&root, &["show", &format!("{commit}:dist/release.json")])?;
    let release = ReleaseManifest::parse(&release_bytes)?;
    if manifest.version != release.version {
        return Err("the verified manifest and release metadata do not match".into());
    }
    VerifiedSnapshot::from_release(commit, method, release).map(Some)
}

fn release_metadata_required(marketplace_version: &str, installed_version: Option<&str>) -> bool {
    !installed_version
        .is_some_and(|installed| compare_versions(marketplace_version, installed).is_lt())
}

fn notify_once(target: &VerifiedSnapshot) -> Result<(), String> {
    let path = store::notification_path();
    if !claim_notification(&path, &target.commit)? {
        return Ok(());
    }
    let body = format!("OmaFlow {} is ready in OmaFlow.", target.version);
    let _ = Command::new(NOTIFY)
        .args(notification_args("OmaFlow update available", &body))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    Ok(())
}

fn notification_args(title: &str, body: &str) -> Vec<String> {
    [
        "--app-name",
        "OmaFlow",
        title,
        body,
        "--exec",
        SHELL,
        "shell",
        "summon",
        "entroit.omaflow",
        "{}",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn claim_notification(path: &Path, commit: &str) -> Result<bool, String> {
    let mut receipt: NotificationReceipt = store::read(path, STATE_LIMIT)?.unwrap_or_default();
    if receipt.last_notified_commit.as_deref() == Some(commit) {
        return Ok(false);
    }
    receipt.schema_version = 1;
    receipt.last_notified_commit = Some(commit.into());
    receipt.claimed_at_ms = Some(now_ms());
    store::replace(path, &receipt)?;
    Ok(true)
}

pub fn later() -> Result<(), String> {
    let offer: UpdateOffer =
        store::read(&store::offer_path(), STATE_LIMIT)?.ok_or("no update is available")?;
    let target = offer.target.ok_or("no update is available")?;
    store::replace(
        &store::deferral_path(),
        &DeferralState {
            schema_version: 1,
            commit: Some(target.commit),
            until_ms: Some(now_ms().saturating_add(24 * 60 * 60 * 1000)),
        },
    )
}

pub fn request() -> Result<String, String> {
    let offer: UpdateOffer =
        store::read(&store::offer_path(), STATE_LIMIT)?.ok_or("check for updates first")?;
    if offer.error.is_some() {
        return Err("the last marketplace check failed; check again before updating".into());
    }
    let target = offer.target.ok_or("no verified update is available")?;
    if offer.external_checkout_warning.is_some() {
        return Err(
            "the plugin checkout changed outside OmaFlow; review it before updating".into(),
        );
    }
    let root = repo_root().ok_or("could not locate the OmaFlow checkout")?;
    require_canonical_checkout(&root)?;
    require_clean(&root)?;
    let original_commit = head(&root)?;
    let original_release = read_installed()?;
    validate_retained_release(&original_release)?;
    if original_commit != original_release.commit {
        return Err("the plugin checkout does not match the installed verified release".into());
    }
    let existing: Option<UpdateTransaction> = store::read(&store::transaction_path(), STATE_LIMIT)?;
    if let Some(existing) = existing.filter(UpdateTransaction::is_active) {
        if existing.identity().target_commit == target.commit {
            if let Err(error) = start_update_service() {
                mark_retryable_start_failure(existing.identity(), &error)?;
                return Err(error);
            }
            return Ok(existing.identity().id.clone());
        }
        return Err("another OmaFlow update is already queued".into());
    }
    let identity = TransactionIdentity {
        schema_version: 1,
        id: format!("{}-{}", now_ms(), &target.commit[..12]),
        target_commit: target.commit,
        target_version: target.version,
        original_commit,
        original_release,
        created_at_ms: now_ms(),
    };
    store::replace(
        &store::transaction_path(),
        &UpdateTransaction::Queued(identity.clone()),
    )?;
    let _ = fs::remove_file(store::deferral_path());
    if let Err(error) = start_update_service() {
        mark_retryable_start_failure(&identity, &error)?;
        return Err(error);
    }
    Ok(identity.id)
}

fn start_update_service() -> Result<(), String> {
    command_ok(
        Command::new("/usr/bin/systemctl").args([
            "--user",
            "--no-block",
            "start",
            "omaflow-update.service",
        ]),
        "could not start the OmaFlow updater",
        Duration::from_secs(20),
    )
}

fn mark_retryable_start_failure(identity: &TransactionIdentity, error: &str) -> Result<(), String> {
    store::replace(
        &store::transaction_path(),
        &UpdateTransaction::RolledBack(UpdateFailure {
            identity: identity.clone(),
            message: format!(
                "The update could not start. Retry when user services are available. {error}"
            ),
            failed_at_ms: now_ms(),
        }),
    )
}

pub fn run() -> Result<(), String> {
    let _lock = UpdateLock::acquire()?;
    let transaction: UpdateTransaction =
        store::read(&store::transaction_path(), STATE_LIMIT)?.ok_or("no update is queued")?;
    match run_disposition(&transaction) {
        RunDisposition::Terminal => return Ok(()),
        RunDisposition::Recover => {
            let identity = transaction.identity().clone();
            validate_transaction_identity(&identity)?;
            let message = match &transaction {
                UpdateTransaction::NeedsRecovery(_) => {
                    "Recovery of the interrupted update is still required."
                }
                _ => "The updater was interrupted after activation began.",
            };
            return finish_recovery(&identity, message, true).map(|_| ());
        }
        RunDisposition::Update => {}
    }
    let identity = transaction.identity().clone();
    validate_transaction_identity(&identity)?;
    match run_inner(&identity) {
        Ok(()) => Ok(()),
        Err(error) => {
            let observed: Option<UpdateTransaction> =
                store::read(&store::transaction_path(), STATE_LIMIT)?;
            let restart_service = observed.as_ref().is_some_and(recovery_may_restart_daemon);
            finish_recovery(&identity, &error, restart_service).and(Err(error))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RunDisposition {
    Update,
    Recover,
    Terminal,
}

fn run_disposition(transaction: &UpdateTransaction) -> RunDisposition {
    match transaction {
        UpdateTransaction::Queued(_)
        | UpdateTransaction::Preparing(_)
        | UpdateTransaction::WaitingForIdle(_) => RunDisposition::Update,
        UpdateTransaction::Activating(_)
        | UpdateTransaction::Verifying(_)
        | UpdateTransaction::NeedsRecovery(_) => RunDisposition::Recover,
        UpdateTransaction::Succeeded(_) | UpdateTransaction::RolledBack(_) => {
            RunDisposition::Terminal
        }
    }
}

fn recovery_may_restart_daemon(transaction: &UpdateTransaction) -> bool {
    matches!(
        transaction,
        UpdateTransaction::Activating(_) | UpdateTransaction::Verifying(_)
    )
}

fn transaction_blocks_dictation(transaction: &UpdateTransaction) -> bool {
    transaction.is_active() || matches!(transaction, UpdateTransaction::NeedsRecovery(_))
}

pub fn blocks_new_dictation() -> bool {
    match store::read::<UpdateTransaction>(&store::transaction_path(), STATE_LIMIT) {
        Ok(Some(transaction)) => transaction_blocks_dictation(&transaction),
        Ok(None) => false,
        Err(_) => true,
    }
}

fn run_inner(identity: &TransactionIdentity) -> Result<(), String> {
    progress(
        identity,
        UpdateStage::Preparing,
        "Downloading verified release",
    )?;
    let snapshot = discover_verified_snapshot()?;
    if snapshot.commit != identity.target_commit || snapshot.version != identity.target_version {
        return Err("the verified marketplace release changed; check again".into());
    }
    let root = repo_root().ok_or("could not locate the OmaFlow checkout")?;
    require_canonical_checkout(&root)?;
    require_clean_at(&root, &identity.original_commit)?;
    require_fast_forward(&root, &identity.original_commit, &snapshot.commit)?;
    require_disk_space(&snapshot)?;
    let stage = stage_snapshot(&root, &snapshot.commit)?;
    if let Err(error) = validate_candidate(&stage, &snapshot) {
        remove_stage(&root, &stage);
        return Err(error);
    }
    let release_dir = prepare_release(&stage, &snapshot)?;

    progress(
        identity,
        UpdateStage::WaitingForIdle,
        "Finishing your dictation first",
    )?;
    if quiesce_daemon(&identity.id)? {
        // Once the daemon accepts the handoff it is committed to exiting. Make
        // that boundary durable before waiting so every timeout/interruption
        // takes the recovery path that restarts the retained release.
        progress(
            identity,
            UpdateStage::Activating,
            "Stopping the previous version",
        )?;
        wait_for_daemon_exit(Duration::from_secs(30))?;
    }

    progress(identity, UpdateStage::Activating, "Installing update")?;
    require_clean_at(&root, &identity.original_commit)?;
    git_text(&root, &["merge", "--ff-only", &snapshot.commit])?;
    validate_plugin(&root)?;
    switch_current(&release_dir)?;
    command_ok(
        Command::new("/usr/bin/systemctl").args(["--user", "daemon-reload"]),
        "could not reload user services",
        Duration::from_secs(30),
    )?;

    progress(identity, UpdateStage::Verifying, "Checking the update")?;
    command_ok(
        Command::new("/usr/bin/systemctl").args(["--user", "start", "omaflow.service"]),
        "could not start the updated OmaFlow service",
        Duration::from_secs(30),
    )?;
    health_check(&snapshot)?;
    command_ok(
        Command::new(OMARCHY).args(["restart", "shell"]),
        "could not reload the Omarchy Shell",
        Duration::from_secs(30),
    )?;
    let installed = InstalledRelease {
        schema_version: 1,
        commit: snapshot.commit.clone(),
        version: snapshot.version.clone(),
        binary_sha256: snapshot.binary_sha256.clone(),
        installed_at_ms: now_ms(),
    };
    store::replace(&store::installed_path(), &installed)?;
    replace_trusted_runner(&release_dir.join("omaflow"))?;
    store::replace(
        &store::transaction_path(),
        &UpdateTransaction::Succeeded(UpdateSuccess {
            identity: identity.clone(),
            message: format!("OmaFlow {} is ready", snapshot.version),
            completed_at_ms: now_ms(),
        }),
    )?;
    store::replace(
        &store::offer_path(),
        &UpdateOffer {
            schema_version: 1,
            checked_at_ms: now_ms(),
            target: None,
            error: None,
            external_checkout_warning: None,
        },
    )?;
    let _ = fs::remove_file(store::deferral_path());
    let body = format!("OmaFlow {} is ready.", snapshot.version);
    let _ = Command::new(NOTIFY)
        .args(notification_args("OmaFlow updated", &body))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    remove_stage(&root, &stage);
    Ok(())
}

#[derive(Clone, Copy)]
enum UpdateStage {
    Preparing,
    WaitingForIdle,
    Activating,
    Verifying,
}

fn progress(
    identity: &TransactionIdentity,
    stage: UpdateStage,
    message: &str,
) -> Result<(), String> {
    let value = TransactionProgress {
        identity: identity.clone(),
        message: message.into(),
    };
    let transaction = match stage {
        UpdateStage::Preparing => UpdateTransaction::Preparing(value),
        UpdateStage::WaitingForIdle => UpdateTransaction::WaitingForIdle(value),
        UpdateStage::Activating => UpdateTransaction::Activating(value),
        UpdateStage::Verifying => UpdateTransaction::Verifying(value),
    };
    store::replace(&store::transaction_path(), &transaction)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecoveryOutcome {
    Running,
    AwaitingDaemon,
}

fn restore_original(
    identity: &TransactionIdentity,
    restart_service: bool,
) -> Result<RecoveryOutcome, String> {
    validate_transaction_identity(identity)?;
    let root = repo_root().ok_or("could not locate the OmaFlow checkout during recovery")?;
    require_canonical_checkout(&root)?;
    let observed = head(&root)?;
    if observed == identity.target_commit || observed == identity.original_commit {
        require_clean(&root).and_then(|_| {
            if observed == identity.original_commit {
                return Ok(());
            }
            git_text(&root, &["reset", "--hard", &identity.original_commit]).map(|_| ())
        })?;
    } else {
        return Err("the checkout changed during recovery".into());
    }
    validate_retained_release(&identity.original_release)?;
    let original_directory = release_root().join(&identity.original_release.commit);
    switch_current(&original_directory)?;
    replace_trusted_runner(&original_directory.join("omaflow"))?;
    store::replace(&store::installed_path(), &identity.original_release)?;

    if !restart_service {
        return if probe_daemon_health(
            &crate::runtime_dir().join("omaflow.sock"),
            &identity.original_commit,
        )
        .is_ok()
        {
            Ok(RecoveryOutcome::Running)
        } else {
            Ok(RecoveryOutcome::AwaitingDaemon)
        };
    }

    command_ok(
        Command::new("/usr/bin/systemctl").args(["--user", "daemon-reload"]),
        "could not reload user services during recovery",
        Duration::from_secs(30),
    )?;
    command_ok(
        Command::new("/usr/bin/systemctl").args(["--user", "restart", "omaflow.service"]),
        "could not restart OmaFlow during recovery",
        Duration::from_secs(30),
    )?;
    wait_for_daemon_commit(&identity.original_commit, Duration::from_secs(15))?;
    // Recovery is complete once the retained release is active and its daemon
    // proves the expected commit. The shell may still be starting during a
    // login session, so failure to refresh it must not put a healthy daemon
    // back behind a permanent NeedsRecovery gate.
    let _ = Command::new(OMARCHY)
        .args(["restart", "shell"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .bounded_status_for(Duration::from_secs(30));
    Ok(RecoveryOutcome::Running)
}

fn finish_recovery(
    identity: &TransactionIdentity,
    update_error: &str,
    restart_service: bool,
) -> Result<RecoveryOutcome, String> {
    let outcome = restore_original(identity, restart_service);
    let (transaction, result) = recovery_record(identity, update_error, outcome);
    store::replace(&store::transaction_path(), &transaction)?;
    result
}

fn recovery_record(
    identity: &TransactionIdentity,
    update_error: &str,
    outcome: Result<RecoveryOutcome, String>,
) -> (UpdateTransaction, Result<RecoveryOutcome, String>) {
    match outcome {
        Ok(RecoveryOutcome::Running) => (
            UpdateTransaction::RolledBack(UpdateFailure {
                identity: identity.clone(),
                message: format!(
                    "The update did not finish. Your previous version is still running. {update_error}"
                ),
                failed_at_ms: now_ms(),
            }),
            Ok(RecoveryOutcome::Running),
        ),
        Ok(RecoveryOutcome::AwaitingDaemon) => (
            UpdateTransaction::NeedsRecovery(UpdateFailure {
                identity: identity.clone(),
                message: format!(
                    "The previous release was restored. Recovery will finish when its daemon starts. {update_error}"
                ),
                failed_at_ms: now_ms(),
            }),
            Ok(RecoveryOutcome::AwaitingDaemon),
        ),
        Err(recovery_error) => (
            UpdateTransaction::NeedsRecovery(UpdateFailure {
                identity: identity.clone(),
                message: format!("{update_error}. Recovery also failed: {recovery_error}"),
                failed_at_ms: now_ms(),
            }),
            Err(recovery_error),
        ),
    }
}

pub fn reconcile() -> Result<(), String> {
    let _lock = match UpdateLock::acquire() {
        Ok(lock) => lock,
        Err(error) if error == "another OmaFlow update is already running" => return Ok(()),
        Err(error) => return Err(error),
    };
    let transaction: Option<UpdateTransaction> =
        store::read(&store::transaction_path(), STATE_LIMIT)?;
    let Some(transaction) = transaction.filter(UpdateTransaction::needs_reconciliation) else {
        return Ok(());
    };
    let identity = transaction.identity().clone();
    validate_transaction_identity(&identity)?;
    finish_recovery(&identity, "An interrupted update was recovered.", false).map(|_| ())
}

fn validate_transaction_identity(identity: &TransactionIdentity) -> Result<(), String> {
    if identity.schema_version != 1
        || !full_sha(&identity.target_commit)
        || !full_sha(&identity.original_commit)
        || identity.original_release.commit != identity.original_commit
        || identity.id.is_empty()
        || identity.id.len() > 96
        || !identity
            .id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err("the update journal identity is invalid".into());
    }
    release_manifest::validate_version(&identity.target_version)?;
    identity.original_release.validate()
}

pub fn health(expect_commit: &str) -> Result<(), String> {
    if !full_sha(expect_commit) {
        return Err("expected commit is invalid".into());
    }
    probe_daemon_health(&crate::runtime_dir().join("omaflow.sock"), expect_commit)
}

pub fn running_release_commit() -> Option<String> {
    let executable = fs::canonicalize(env::current_exe().ok()?).ok()?;
    let commit = executable
        .parent()
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .filter(|value| full_sha(value))?;
    Some(commit.to_owned())
}

fn probe_daemon_health(socket: &Path, expect_commit: &str) -> Result<(), String> {
    if !full_sha(expect_commit) {
        return Err("expected commit is invalid".into());
    }
    let mut stream = UnixStream::connect(socket)
        .map_err(|_| "the OmaFlow daemon health socket is unavailable".to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(format!("health:{expect_commit}").as_bytes())
        .map_err(|error| error.to_string())?;
    stream
        .shutdown(Shutdown::Write)
        .map_err(|error| error.to_string())?;
    let mut response = String::new();
    stream
        .take(128)
        .read_to_string(&mut response)
        .map_err(|_| "the OmaFlow daemon did not answer its health check".to_string())?;
    if response.trim() == format!("ready:{expect_commit}") {
        Ok(())
    } else {
        Err("the live OmaFlow daemon is not the expected release".into())
    }
}

pub fn version_json() -> serde_json::Value {
    serde_json::json!({
        "pluginId": "entroit.omaflow",
        "version": RUNNING_VERSION,
        "target": "x86_64-unknown-linux-gnu"
    })
}

fn validate_candidate(stage: &Path, snapshot: &VerifiedSnapshot) -> Result<(), String> {
    if head(stage)? != snapshot.commit {
        return Err("the staged checkout has the wrong commit".into());
    }
    require_clean(stage)?;
    require_regular_file(stage, Path::new("manifest.json"))?;
    require_regular_file(stage, Path::new("dist/release.json"))?;
    let manifest = fs::read_to_string(stage.join("manifest.json"))
        .map_err(|error| format!("could not read the plugin manifest: {error}"))?;
    if manifest_version(&manifest).as_deref() != Some(&snapshot.version) {
        return Err("the plugin manifest version does not match the marketplace".into());
    }
    let release = ReleaseManifest::parse(
        &fs::read(stage.join("dist/release.json"))
            .map_err(|error| format!("could not read release metadata: {error}"))?,
    )?;
    if release.version != snapshot.version
        || release.binary.sha256.to_ascii_lowercase() != snapshot.binary_sha256
        || release.binary.bytes != snapshot.binary_bytes
        || release.binary.path != snapshot.binary_path
    {
        return Err("the staged release does not match the marketplace snapshot".into());
    }
    let binary = stage.join(&snapshot.binary_path);
    require_regular_file(stage, Path::new(&snapshot.binary_path))?;
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
    validate_plugin(stage)
}

fn require_regular_file(root: &Path, relative: &Path) -> Result<(), String> {
    let path = root.join(relative);
    let metadata = fs::symlink_metadata(&path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.file_type().is_file() {
        return Err(format!("{} is not a regular file", path.display()));
    }
    let canonical_root = fs::canonicalize(root).map_err(|error| error.to_string())?;
    let canonical_path = fs::canonicalize(&path).map_err(|error| error.to_string())?;
    if !canonical_path.starts_with(canonical_root) {
        return Err(format!("{} escapes the staged release", path.display()));
    }
    Ok(())
}

fn validate_plugin(path: &Path) -> Result<(), String> {
    command_ok(
        Command::new(OMARCHY).args(["plugin", "validate"]).arg(path),
        "Omarchy rejected the staged plugin",
        Duration::from_secs(120),
    )
}

fn stage_snapshot(root: &Path, commit: &str) -> Result<PathBuf, String> {
    if !full_sha(commit) {
        return Err("the staged commit is invalid".into());
    }
    let stage = store::update_dir().join("stage").join(commit);
    if stage.exists() {
        clear_known_stage(root, &stage, commit)?;
    }
    if let Some(parent) = stage.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    git_text(
        root,
        &[
            "worktree",
            "add",
            "--detach",
            "--force",
            stage.to_str().ok_or("stage path is invalid")?,
            commit,
        ],
    )?;
    Ok(stage)
}

fn remove_stage(root: &Path, stage: &Path) {
    let _ = git_text(
        root,
        &[
            "worktree",
            "remove",
            "--force",
            stage.to_str().unwrap_or(""),
        ],
    );
    let _ = git_text(root, &["worktree", "prune"]);
}

fn clear_known_stage(root: &Path, stage: &Path, commit: &str) -> Result<(), String> {
    let expected = store::update_dir().join("stage").join(commit);
    if !full_sha(commit) || stage != expected {
        return Err("refusing to clear an unknown update stage".into());
    }
    let _ = git_text(
        root,
        &[
            "worktree",
            "remove",
            "--force",
            stage.to_str().ok_or("stage path is invalid")?,
        ],
    );
    if stage.exists() {
        fs::remove_dir_all(stage)
            .map_err(|error| format!("could not clear the known update stage: {error}"))?;
    }
    git_text(root, &["worktree", "prune"])?;
    Ok(())
}

fn prepare_release(stage: &Path, snapshot: &VerifiedSnapshot) -> Result<PathBuf, String> {
    let destination = release_root().join(&snapshot.commit);
    fs::create_dir_all(&destination).map_err(|error| error.to_string())?;
    fs::set_permissions(&destination, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    let source = stage.join(&snapshot.binary_path);
    let temporary = destination.join(format!(".omaflow.{}.tmp", std::process::id()));
    fs::copy(&source, &temporary)
        .map_err(|error| format!("could not stage the release binary: {error}"))?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    if sha256(&temporary)? != snapshot.binary_sha256 {
        let _ = fs::remove_file(&temporary);
        return Err("the copied release binary checksum does not match".into());
    }
    sync_file(&temporary)?;
    fs::rename(temporary, destination.join("omaflow")).map_err(|error| error.to_string())?;
    fs::copy(
        stage.join("dist/release.json"),
        destination.join("release.json"),
    )
    .map_err(|error| error.to_string())?;
    fs::write(destination.join("commit"), format!("{}\n", snapshot.commit))
        .map_err(|error| error.to_string())?;
    sync_file(&destination.join("omaflow"))?;
    sync_file(&destination.join("release.json"))?;
    sync_file(&destination.join("commit"))?;
    sync_dir(&destination)?;
    sync_dir(&release_root())?;
    Ok(destination)
}

fn quiesce_daemon(transaction_id: &str) -> Result<bool, String> {
    let marker = crate::runtime_dir().join(format!("omaflow-update-ready-{transaction_id}"));
    let _ = fs::remove_file(&marker);
    if !crate::send_command_quiet(&format!("prepare-update:{transaction_id}")) {
        return Ok(false);
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(75 * 60);
    while std::time::Instant::now() < deadline {
        if marker.is_file() {
            return Ok(true);
        }
        thread::sleep(Duration::from_millis(100));
    }
    cancel_update_handoff(transaction_id)?;
    Err("OmaFlow did not finish the active dictation before the 75-minute update timeout".into())
}

fn wait_for_daemon_exit(timeout: Duration) -> Result<(), String> {
    let socket = crate::runtime_dir().join("omaflow.sock");
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if !socket.exists() || UnixStream::connect(&socket).is_err() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err("the previous OmaFlow daemon acknowledged the update but did not exit".into())
}

fn cancel_update_handoff(transaction_id: &str) -> Result<(), String> {
    if transaction_id.is_empty()
        || transaction_id.len() > 96
        || !transaction_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err("the update transaction identity is invalid".into());
    }
    let mut stream = UnixStream::connect(crate::runtime_dir().join("omaflow.sock"))
        .map_err(|_| "could not cancel the daemon update handoff".to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(format!("cancel-update:{transaction_id}").as_bytes())
        .map_err(|error| error.to_string())?;
    stream
        .shutdown(Shutdown::Write)
        .map_err(|error| error.to_string())?;
    let mut response = String::new();
    stream
        .take(160)
        .read_to_string(&mut response)
        .map_err(|_| "the daemon did not acknowledge update cancellation".to_string())?;
    if response.trim() == format!("cancelled:{transaction_id}") {
        Ok(())
    } else {
        Err("the daemon did not acknowledge update cancellation".into())
    }
}

fn health_check(snapshot: &VerifiedSnapshot) -> Result<(), String> {
    wait_for_daemon_commit(&snapshot.commit, Duration::from_secs(15))
}

fn wait_for_daemon_commit(commit: &str, timeout: Duration) -> Result<(), String> {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if probe_daemon_health(&crate::runtime_dir().join("omaflow.sock"), commit).is_ok() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(250));
    }
    Err("the updated OmaFlow daemon did not prove its release identity".into())
}

fn require_disk_space(snapshot: &VerifiedSnapshot) -> Result<(), String> {
    fs::create_dir_all(release_root()).map_err(|error| error.to_string())?;
    let output = Command::new("/usr/bin/df")
        .args(["-Pk"])
        .arg(release_root())
        .bounded_output_for(Duration::from_secs(15))
        .map_err(|error| error.to_string())?;
    let available_kib = String::from_utf8_lossy(&output.stdout)
        .lines()
        .last()
        .and_then(|line| line.split_whitespace().nth(3))
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or("could not determine free disk space")?;
    let required_kib = snapshot.binary_bytes.div_ceil(1024) + 50 * 1024;
    if available_kib < required_kib {
        return Err("there is not enough disk space for the update".into());
    }
    Ok(())
}

fn require_clean(root: &Path) -> Result<(), String> {
    if git_text(root, &["status", "--porcelain=v1", "--untracked-files=all"])?.is_empty() {
        Ok(())
    } else {
        Err("the OmaFlow checkout has local changes".into())
    }
}

fn require_canonical_checkout(root: &Path) -> Result<(), String> {
    require_safe_git_config(root)?;
    let origin = git_text(root, &["remote", "get-url", "origin"])?;
    if origin == CANONICAL_REPOSITORY || origin == format!("{CANONICAL_REPOSITORY}.git") {
        Ok(())
    } else {
        Err("the OmaFlow checkout does not use the canonical repository".into())
    }
}

fn require_safe_git_config(root: &Path) -> Result<(), String> {
    let dot_git = root.join(".git");
    let metadata = fs::symlink_metadata(&dot_git)
        .map_err(|_| "the checkout Git directory is invalid".to_string())?;
    if !metadata.file_type().is_dir() {
        return Err("linked Git worktrees are not supported for trusted updates".into());
    }
    let git_dir = dot_git;
    for path in [git_dir.join("config"), git_dir.join("config.worktree")] {
        let Ok(contents) = fs::read_to_string(path) else {
            continue;
        };
        let lower = contents.to_ascii_lowercase();
        for unsafe_token in [
            "[include",
            "[url ",
            "insteadof",
            "[filter ",
            "smudge",
            "clean =",
            "helper =",
            "sshcommand",
            "proxycommand",
            "fsmonitor",
            "sslverify",
            "extraheader",
            "uploadpack",
            "receivepack",
        ] {
            if lower.contains(unsafe_token) {
                return Err("the checkout has unsafe repository-local Git configuration".into());
            }
        }
    }
    Ok(())
}

fn require_safe_target_attributes(root: &Path, commit: &str) -> Result<(), String> {
    let names = git_text(root, &["ls-tree", "-r", "--name-only", commit])?;
    if names
        .lines()
        .any(|path| path == ".gitattributes" || path.ends_with("/.gitattributes"))
    {
        return Err(
            "the verified release contains Git attributes that cannot be applied safely".into(),
        );
    }
    Ok(())
}

fn require_clean_at(root: &Path, expected: &str) -> Result<(), String> {
    require_clean(root)?;
    if head(root)? != expected {
        return Err("the OmaFlow checkout changed while the update was waiting".into());
    }
    Ok(())
}

fn require_fast_forward(root: &Path, old: &str, new: &str) -> Result<(), String> {
    let status = git_command(root, &["merge-base", "--is-ancestor", old, new])
        .bounded_status_for(GIT_LOCAL_TIMEOUT)
        .map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err("the verified release is not a fast-forward update".into())
    }
}

fn read_installed() -> Result<InstalledRelease, String> {
    let installed: InstalledRelease = store::read(&store::installed_path(), STATE_LIMIT)?
        .ok_or_else(|| "this installation has no trusted release receipt; reinstall OmaFlow once to enable in-app updates".to_string())?;
    installed.validate()?;
    Ok(installed)
}

fn validate_retained_release(installed: &InstalledRelease) -> Result<(), String> {
    installed.validate()?;
    let directory = release_root().join(&installed.commit);
    let binary = directory.join("omaflow");
    let metadata = fs::symlink_metadata(&binary)
        .map_err(|_| "the retained release binary is missing".to_string())?;
    if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err("the retained release binary is invalid".into());
    }
    if sha256(&binary)? != installed.binary_sha256.to_ascii_lowercase() {
        return Err("the retained release binary checksum does not match its receipt".into());
    }
    let commit = fs::read_to_string(directory.join("commit"))
        .map_err(|_| "the retained release commit marker is missing".to_string())?;
    if commit.trim() != installed.commit {
        return Err("the retained release commit marker does not match".into());
    }
    let release = ReleaseManifest::parse(
        &fs::read(directory.join("release.json"))
            .map_err(|_| "the retained release metadata is missing".to_string())?,
    )?;
    if release.version != installed.version
        || !release
            .binary
            .sha256
            .eq_ignore_ascii_case(&installed.binary_sha256)
    {
        return Err("the retained release metadata does not match its receipt".into());
    }
    Ok(())
}

pub fn finalize_recovery_for_running_daemon() -> Result<(), String> {
    let Some(transaction): Option<UpdateTransaction> =
        store::read(&store::transaction_path(), STATE_LIMIT)?
    else {
        return Ok(());
    };
    let UpdateTransaction::NeedsRecovery(failure) = transaction else {
        return Ok(());
    };
    let identity = failure.identity.clone();
    if running_release_commit().as_deref() != Some(&identity.original_commit) {
        return Ok(());
    }
    let root = repo_root().ok_or("could not locate the OmaFlow checkout during recovery")?;
    require_clean_at(&root, &identity.original_commit)?;
    validate_retained_release(&identity.original_release)?;
    let current =
        fs::canonicalize(install_root().join("current")).map_err(|error| error.to_string())?;
    if current
        != fs::canonicalize(release_root().join(&identity.original_commit))
            .map_err(|error| error.to_string())?
    {
        return Err("the active release link does not match the recovery receipt".into());
    }
    store::replace(
        &store::transaction_path(),
        &UpdateTransaction::RolledBack(UpdateFailure {
            identity,
            message: "The interrupted update was recovered. Your previous version is running."
                .into(),
            failed_at_ms: now_ms(),
        }),
    )?;
    // Recovery is complete once the prior daemon is live and the durable
    // checkout/release state agrees. A shell that is still starting must not
    // leave dictation blocked behind NeedsRecovery.
    let _ = Command::new(OMARCHY)
        .args(["restart", "shell"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    Ok(())
}

fn install_root() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join(".local/lib/omaflow")
}

fn release_root() -> PathBuf {
    install_root().join("releases")
}

fn switch_current(release: &Path) -> Result<(), String> {
    if !release.join("omaflow").is_file() {
        return Err("the release binary is missing".into());
    }
    fs::create_dir_all(install_root()).map_err(|error| error.to_string())?;
    let temporary = install_root().join(format!(".current.{}.tmp", std::process::id()));
    let _ = fs::remove_file(&temporary);
    symlink(release, &temporary).map_err(|error| error.to_string())?;
    fs::rename(temporary, install_root().join("current")).map_err(|error| error.to_string())?;
    sync_dir(&install_root())
}

fn replace_trusted_runner(source: &Path) -> Result<(), String> {
    let destination = install_root().join("trusted-runner");
    let temporary = install_root().join(format!(".trusted-runner.{}.tmp", std::process::id()));
    fs::copy(source, &temporary).map_err(|error| error.to_string())?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    sync_file(&temporary)?;
    fs::rename(temporary, destination).map_err(|error| error.to_string())?;
    sync_dir(&install_root())
}

fn sync_file(path: &Path) -> Result<(), String> {
    fs::File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("could not sync {}: {error}", path.display()))
}

fn sync_dir(path: &Path) -> Result<(), String> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("could not sync {}: {error}", path.display()))
}

fn download(url: &str, limit: usize) -> Result<Vec<u8>, String> {
    let directory = store::update_dir();
    fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    let path = directory.join(format!(".catalog.{}.tmp", std::process::id()));
    let _ = fs::remove_file(&path);
    fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .map_err(|error| format!("could not prepare the marketplace download: {error}"))?;
    let result = Command::new("/usr/bin/curl")
        .args([
            "--disable",
            "--fail",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--tlsv1.2",
            "--max-time",
            "15",
            "--max-redirs",
            "0",
            "--max-filesize",
            &limit.to_string(),
            "--output",
            path.to_str()
                .ok_or("marketplace download path is invalid")?,
            url,
        ])
        .env_clear()
        .env("PATH", "/usr/bin")
        .bounded_output_for(Duration::from_secs(25));
    let output = match result {
        Ok(output) => output,
        Err(error) => {
            let _ = fs::remove_file(&path);
            return Err(format!(
                "could not download the marketplace catalog: {error}"
            ));
        }
    };
    if !output.status.success() {
        let _ = fs::remove_file(&path);
        return Err("could not download the marketplace catalog".into());
    }
    let metadata = fs::metadata(&path).map_err(|error| error.to_string())?;
    if metadata.len() > limit as u64 {
        let _ = fs::remove_file(&path);
        return Err("the marketplace catalog is too large".into());
    }
    let bytes = fs::read(&path).map_err(|error| error.to_string())?;
    let _ = fs::remove_file(path);
    Ok(bytes)
}

fn fetch_exact(root: &Path, commit: &str) -> Result<(), String> {
    if !full_sha(commit) {
        return Err("the marketplace commit is invalid".into());
    }
    require_safe_git_config(root)?;
    git_text_for(
        root,
        &[
            "fetch",
            "--quiet",
            "--no-tags",
            CANONICAL_REPOSITORY,
            commit,
        ],
        GIT_NETWORK_TIMEOUT,
    )?;
    if git_text(root, &["rev-parse", &format!("{commit}^{{commit}}")])? != commit {
        return Err("Git did not fetch the requested marketplace commit".into());
    }
    require_safe_target_attributes(root, commit)?;
    Ok(())
}

fn head(root: &Path) -> Result<String, String> {
    git_text(root, &["rev-parse", "HEAD"])
}

fn git_text(root: &Path, args: &[&str]) -> Result<String, String> {
    git_text_for(root, args, GIT_LOCAL_TIMEOUT)
}

fn git_text_for(root: &Path, args: &[&str], timeout: Duration) -> Result<String, String> {
    let output = git_bytes_for(root, args, timeout)?;
    String::from_utf8(output)
        .map(|value| value.trim().to_string())
        .map_err(|_| "Git returned invalid text".into())
}

fn git_bytes(root: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    git_bytes_for(root, args, GIT_LOCAL_TIMEOUT)
}

fn git_bytes_for(root: &Path, args: &[&str], timeout: Duration) -> Result<Vec<u8>, String> {
    let output = git_command(root, args)
        .bounded_output_for(timeout)
        .map_err(|error| format!("could not run Git: {error}"))?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        let message = String::from_utf8_lossy(&output.stderr);
        Err(message.lines().next().unwrap_or("Git failed").into())
    }
}

fn git_command(root: &Path, args: &[&str]) -> Command {
    let mut command = Command::new("/usr/bin/git");
    command
        .arg("-C")
        .arg(root)
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "credential.helper=",
            "-c",
            "protocol.file.allow=never",
            "-c",
            "protocol.ext.allow=never",
            "-c",
            "http.followRedirects=false",
            "-c",
            "core.attributesFile=/dev/null",
            "-c",
            "core.autocrlf=false",
        ])
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .env("GIT_SSH_COMMAND", "/usr/bin/ssh -oBatchMode=yes")
        .stdin(Stdio::null());
    command
}

fn sha256(path: &Path) -> Result<String, String> {
    let output = Command::new("/usr/bin/sha256sum")
        .arg("--")
        .arg(path)
        .bounded_output_for(Duration::from_secs(30))
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        return Err("could not hash the release binary".into());
    }
    let digest = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("the release binary checksum is invalid".into());
    }
    Ok(digest)
}

fn command_ok(command: &mut Command, context: &str, timeout: Duration) -> Result<(), String> {
    let output = command
        .bounded_output_for(timeout)
        .map_err(|error| format!("{context}: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let detail = String::from_utf8_lossy(&output.stderr);
        Err(format!(
            "{context}: {}",
            detail.lines().next().unwrap_or("command failed")
        ))
    }
}

fn compare_versions(left: &str, right: &str) -> std::cmp::Ordering {
    fn parts(value: &str) -> [u64; 3] {
        let mut values = value.split('.').map(|part| part.parse().unwrap_or(0));
        [
            values.next().unwrap_or(0),
            values.next().unwrap_or(0),
            values.next().unwrap_or(0),
        ]
    }
    parts(left).cmp(&parts(right))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
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

    fn progress() -> TransactionProgress {
        TransactionProgress {
            identity: identity(),
            message: "working".into(),
        }
    }

    #[test]
    fn manifest_and_cargo_versions_match() {
        assert_eq!(
            manifest_version(include_str!("../manifest.json")).as_deref(),
            Some(RUNNING_VERSION)
        );
        assert!(release_manifest::validate_version(RUNNING_VERSION).is_ok());
    }

    #[test]
    fn compares_release_versions() {
        assert!(compare_versions("0.18.0", "0.17.9").is_gt());
        assert!(compare_versions("0.17.0", "0.17.0").is_eq());
        assert!(compare_versions("0.16.0", "0.17.0").is_lt());
    }

    #[test]
    fn older_marketplace_snapshots_do_not_need_release_metadata() {
        assert!(!release_metadata_required("0.16.0", Some("0.18.0")));
        assert!(release_metadata_required("0.18.0", Some("0.18.0")));
        assert!(release_metadata_required("0.19.0", Some("0.18.0")));
        assert!(release_metadata_required("0.16.0", None));
    }

    #[test]
    fn notification_is_claimed_once_before_delivery() {
        let directory =
            std::env::temp_dir().join(format!("omaflow-notification-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        let path = directory.join("notification.json");
        let commit = "a".repeat(40);
        assert!(claim_notification(&path, &commit).unwrap());
        assert!(!claim_notification(&path, &commit).unwrap());
        assert!(claim_notification(&path, &"b".repeat(40)).unwrap());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn notification_argv_uses_the_dnd_aware_omarchy_action() {
        assert_eq!(
            notification_args("Title", "Body"),
            vec![
                "--app-name",
                "OmaFlow",
                "Title",
                "Body",
                "--exec",
                SHELL,
                "shell",
                "summon",
                "entroit.omaflow",
                "{}"
            ]
        );
    }

    #[test]
    fn persisted_update_stages_dispatch_update_or_recovery_without_ambiguity() {
        assert_eq!(
            run_disposition(&UpdateTransaction::Queued(identity())),
            RunDisposition::Update
        );
        assert_eq!(
            run_disposition(&UpdateTransaction::Preparing(progress())),
            RunDisposition::Update
        );
        assert_eq!(
            run_disposition(&UpdateTransaction::WaitingForIdle(progress())),
            RunDisposition::Update
        );
        assert_eq!(
            run_disposition(&UpdateTransaction::Activating(progress())),
            RunDisposition::Recover
        );
        assert_eq!(
            run_disposition(&UpdateTransaction::Verifying(progress())),
            RunDisposition::Recover
        );
        let failure = UpdateFailure {
            identity: identity(),
            message: "recover".into(),
            failed_at_ms: 3,
        };
        assert_eq!(
            run_disposition(&UpdateTransaction::NeedsRecovery(failure)),
            RunDisposition::Recover
        );
        assert!(!recovery_may_restart_daemon(&UpdateTransaction::Preparing(
            progress()
        )));
        assert!(!recovery_may_restart_daemon(
            &UpdateTransaction::WaitingForIdle(progress())
        ));
        assert!(recovery_may_restart_daemon(&UpdateTransaction::Activating(
            progress()
        )));
    }

    #[test]
    fn prestart_reconcile_records_awaiting_daemon_without_failing() {
        let (transaction, result) = recovery_record(
            &identity(),
            "interrupted",
            Ok(RecoveryOutcome::AwaitingDaemon),
        );
        assert_eq!(result, Ok(RecoveryOutcome::AwaitingDaemon));
        assert!(matches!(transaction, UpdateTransaction::NeedsRecovery(_)));
        assert!(transaction_blocks_dictation(&transaction));
    }

    #[test]
    fn daemon_health_rejects_missing_and_stale_sockets() {
        let directory = std::env::temp_dir().join(format!("omaflow-health-{}", now_ms()));
        fs::create_dir_all(&directory).unwrap();
        let socket = directory.join("daemon.sock");
        assert!(probe_daemon_health(&socket, &"a".repeat(40)).is_err());
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        drop(listener);
        assert!(probe_daemon_health(&socket, &"a".repeat(40)).is_err());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn git_policy_requires_a_clean_fast_forward_checkout() {
        let directory = std::env::temp_dir().join(format!(
            "omaflow-git-policy-{}-{}",
            std::process::id(),
            now_ms()
        ));
        fs::create_dir_all(&directory).unwrap();
        let git = |args: &[&str]| {
            let status = Command::new("/usr/bin/git")
                .arg("-C")
                .arg(&directory)
                .args(args)
                .status()
                .unwrap();
            assert!(status.success(), "git {args:?}");
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.name", "Test"]);
        git(&["config", "user.email", "test@example.invalid"]);
        git(&["remote", "add", "origin", CANONICAL_REPOSITORY]);
        fs::write(directory.join("manifest.json"), "one").unwrap();
        git(&["add", "manifest.json"]);
        git(&["commit", "-qm", "one"]);
        let first = head(&directory).unwrap();
        assert!(require_clean(&directory).is_ok());
        fs::write(directory.join("manifest.json"), "two").unwrap();
        assert_eq!(
            require_clean(&directory).unwrap_err(),
            "the OmaFlow checkout has local changes"
        );
        git(&["add", "manifest.json"]);
        git(&["commit", "-qm", "two"]);
        let second = head(&directory).unwrap();
        assert!(require_fast_forward(&directory, &first, &second).is_ok());
        assert!(require_fast_forward(&directory, &second, &first).is_err());
        git(&[
            "remote",
            "set-url",
            "origin",
            "https://example.invalid/omaflow",
        ]);
        assert_eq!(
            require_canonical_checkout(&directory).unwrap_err(),
            "the OmaFlow checkout does not use the canonical repository"
        );
        git(&["remote", "set-url", "origin", CANONICAL_REPOSITORY]);
        git(&[
            "config",
            "url.https://attacker.invalid/.insteadOf",
            CANONICAL_REPOSITORY,
        ]);
        assert_eq!(
            require_canonical_checkout(&directory).unwrap_err(),
            "the checkout has unsafe repository-local Git configuration"
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn trusted_updates_reject_linked_git_worktrees() {
        let directory = std::env::temp_dir().join(format!("omaflow-linked-{}", now_ms()));
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join(".git"), "gitdir: /tmp/example\n").unwrap();
        assert_eq!(
            require_safe_git_config(&directory).unwrap_err(),
            "linked Git worktrees are not supported for trusted updates"
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
