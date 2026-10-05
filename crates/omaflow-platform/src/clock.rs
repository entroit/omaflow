//! Local wall-clock time, which the journal files entries under.
use omaflow_core::date::Date;
use std::time::{SystemTime, UNIX_EPOCH};

/// Today's date and the time as "HH:MM", in the user's time zone.
pub fn local_now() -> (Date, String) {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as libc::time_t;
    // SAFETY: localtime_r only writes into the tm we hand it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let converted = unsafe { !libc::localtime_r(&seconds, &mut tm).is_null() };
    let fallback = || {
        let days = seconds.div_euclid(86_400);
        let minutes = seconds.rem_euclid(86_400) / 60;
        (
            Date::from_days_since_epoch(days),
            format!("{:02}:{:02}", minutes / 60, minutes % 60),
        )
    };
    if !converted {
        return fallback();
    }
    match Date::new(tm.tm_year + 1900, (tm.tm_mon + 1) as u8, tm.tm_mday as u8) {
        Some(date) => (date, format!("{:02}:{:02}", tm.tm_hour, tm.tm_min)),
        None => fallback(),
    }
}
