//! OmaFlow without a desktop: configuration, the dictation state machine,
//! vocabulary, the dictation history, the journal and the to-do list. Nothing here starts a
//! process or touches the clipboard; that is `omaflow-platform`'s job.
pub mod config;
pub mod date;
pub mod fsutil;
pub mod history;
pub mod journal;
pub mod state;
pub mod todos;
pub mod vocabulary;
