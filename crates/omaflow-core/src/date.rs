//! Calendar dates without a time zone. The caller supplies "today"; this
//! module only does the arithmetic the journal needs.
use std::{fmt, str::FromStr};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date {
    pub year: i32,
    pub month: u8,
    pub day: u8,
}

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];
const WEEKDAYS: [&str; 7] = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
];

impl Date {
    pub fn new(year: i32, month: u8, day: u8) -> Option<Self> {
        ((1..=12).contains(&month)
            && day >= 1
            && day <= days_in_month(year, month)
            && (1..=9999).contains(&year))
        .then_some(Self { year, month, day })
    }

    /// Days since 1970-01-01, from Howard Hinnant's `days_from_civil`.
    pub fn days_since_epoch(self) -> i64 {
        let year = i64::from(self.year) - i64::from(self.month <= 2);
        let era = year.div_euclid(400);
        let year_of_era = year - era * 400;
        let month = i64::from(self.month);
        let day_of_year =
            (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + i64::from(self.day) - 1;
        let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
        era * 146_097 + day_of_era - 719_468
    }

    pub fn from_days_since_epoch(days: i64) -> Self {
        let days = days + 719_468;
        let era = days.div_euclid(146_097);
        let day_of_era = days - era * 146_097;
        let year_of_era =
            (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
        let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
        let shifted_month = (5 * day_of_year + 2) / 153;
        let day = (day_of_year - (153 * shifted_month + 2) / 5 + 1) as u8;
        let month = if shifted_month < 10 {
            shifted_month + 3
        } else {
            shifted_month - 9
        } as u8;
        let year = (year_of_era + era * 400 + i64::from(month <= 2)) as i32;
        Self { year, month, day }
    }

    /// Monday is 0, as in ISO 8601 and in the calendar the journal draws.
    pub fn weekday(self) -> usize {
        (self.days_since_epoch() + 3).rem_euclid(7) as usize
    }

    pub fn weekday_name(self) -> &'static str {
        WEEKDAYS[self.weekday()]
    }

    pub fn month_name(self) -> &'static str {
        MONTHS[usize::from(self.month) - 1]
    }

    /// "Friday, 25 September 2026", the heading of a day's file.
    pub fn long(self) -> String {
        format!(
            "{}, {} {} {}",
            self.weekday_name(),
            self.day,
            self.month_name(),
            self.year
        )
    }

    /// The same calendar day a year earlier; 29 February becomes the 28th.
    pub fn a_year_earlier(self) -> Self {
        let year = self.year - 1;
        Self {
            year,
            month: self.month,
            day: self.day.min(days_in_month(year, self.month)),
        }
    }
}

pub fn days_in_month(year: i32, month: u8) -> u8 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        _ => 0,
    }
}

impl fmt::Display for Date {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{:04}-{:02}-{:02}",
            self.year, self.month, self.day
        )
    }
}

impl FromStr for Date {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let invalid = || format!("{value} is not a date like 2026-09-25");
        let mut parts = value.split('-');
        let (Some(year), Some(month), Some(day), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(invalid());
        };
        if year.len() != 4 || month.len() != 2 || day.len() != 2 {
            return Err(invalid());
        }
        Self::new(
            year.parse().map_err(|_| invalid())?,
            month.parse().map_err(|_| invalid())?,
            day.parse().map_err(|_| invalid())?,
        )
        .ok_or_else(invalid)
    }
}

#[cfg(test)]
mod tests {
    use super::Date;

    #[test]
    fn round_trips_through_days_and_names_the_weekday() {
        let date: Date = "2026-09-25".parse().unwrap();
        assert_eq!(date.weekday_name(), "Friday");
        assert_eq!(date.long(), "Friday, 25 September 2026");
        assert_eq!(Date::from_days_since_epoch(date.days_since_epoch()), date);
        assert_eq!(Date::from_days_since_epoch(0).to_string(), "1970-01-01");
        let leap: Date = "2024-02-29".parse().unwrap();
        assert_eq!(leap.a_year_earlier().to_string(), "2023-02-28");
        assert_eq!(leap.weekday_name(), "Thursday");
    }

    #[test]
    fn rejects_dates_that_do_not_exist_or_are_not_padded() {
        for bad in [
            "2026-02-30",
            "2026-13-01",
            "2026-9-25",
            "../etc",
            "2026-09-25-x",
        ] {
            assert!(bad.parse::<Date>().is_err(), "{bad}");
        }
    }
}
