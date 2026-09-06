use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Recording {
        latched: bool,
        tap_deadline: Duration,
        stop_at: Option<Duration>,
        max_at: Duration,
    },
    Processing,
    Result,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    None,
    Start,
    Stop,
    Cancel,
}

#[derive(Debug)]
pub struct StateMachine {
    phase: Phase,
    double_tap_window: Duration,
    max_recording: Duration,
}

impl StateMachine {
    #[cfg(test)]
    pub fn new(double_tap_ms: u64) -> Self {
        Self::with_max_recording(double_tap_ms, 1_200)
    }

    pub fn with_max_recording(double_tap_ms: u64, max_recording_seconds: u64) -> Self {
        Self {
            phase: Phase::Idle,
            double_tap_window: Duration::from_millis(double_tap_ms),
            max_recording: Duration::from_secs(max_recording_seconds.max(1)),
        }
    }

    pub fn configure(&mut self, double_tap_ms: u64, max_recording_seconds: u64) {
        self.double_tap_window = Duration::from_millis(double_tap_ms);
        self.max_recording = Duration::from_secs(max_recording_seconds.max(1));
    }

    pub fn phase(&self) -> &Phase {
        &self.phase
    }

    pub fn next_deadline(&self) -> Option<Duration> {
        match self.phase {
            Phase::Recording {
                stop_at, max_at, ..
            } => Some(stop_at.map_or(max_at, |stop_at| stop_at.min(max_at))),
            _ => None,
        }
    }

    pub fn press(&mut self, now: Duration) -> Action {
        let overdue = self.tick(now);
        if overdue != Action::None {
            return overdue;
        }
        match &mut self.phase {
            Phase::Idle | Phase::Result | Phase::Error => {
                self.phase = Phase::Recording {
                    latched: false,
                    tap_deadline: now + self.double_tap_window,
                    stop_at: None,
                    max_at: now + self.max_recording,
                };
                Action::Start
            }
            Phase::Recording {
                latched, stop_at, ..
            } if stop_at.is_some() => {
                *latched = true;
                *stop_at = None;
                Action::None
            }
            Phase::Recording { latched: true, .. } => {
                self.phase = Phase::Processing;
                Action::Stop
            }
            _ => Action::None,
        }
    }

    pub fn release(&mut self, now: Duration) -> Action {
        if let Phase::Recording {
            latched,
            tap_deadline,
            stop_at,
            ..
        } = &mut self.phase
            && !*latched
            && stop_at.is_none()
        {
            if now >= *tap_deadline {
                self.phase = Phase::Processing;
                return Action::Stop;
            }
            *stop_at = Some(*tap_deadline);
        }
        Action::None
    }

    pub fn tick(&mut self, now: Duration) -> Action {
        let due = match self.phase {
            Phase::Recording {
                latched,
                stop_at,
                max_at,
                ..
            } => now >= max_at || (!latched && stop_at.is_some_and(|at| now >= at)),
            _ => false,
        };
        if due {
            self.phase = Phase::Processing;
            Action::Stop
        } else {
            Action::None
        }
    }

    pub fn stop(&mut self) -> Action {
        if matches!(self.phase, Phase::Recording { .. }) {
            self.phase = Phase::Processing;
            Action::Stop
        } else {
            Action::None
        }
    }

    pub fn cancel(&mut self) -> Action {
        if matches!(self.phase, Phase::Recording { .. } | Phase::Processing) {
            self.phase = Phase::Idle;
            Action::Cancel
        } else {
            Action::None
        }
    }

    pub fn completed(&mut self) {
        self.phase = Phase::Result;
    }

    pub fn failed(&mut self) {
        self.phase = Phase::Error;
    }

    pub fn close(&mut self) {
        self.phase = Phase::Idle;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    #[test]
    fn press_at_deadline_delivers_stop() {
        let mut state = StateMachine::new(260);
        state.press(ms(0));
        state.release(ms(80));
        assert_eq!(state.press(ms(260)), Action::Stop);
        assert_eq!(state.phase(), &Phase::Processing);
    }

    #[test]
    fn press_at_recording_cap_delivers_stop() {
        let mut state = StateMachine::with_max_recording(260, 1);
        state.press(ms(0));
        assert_eq!(state.press(ms(1000)), Action::Stop);
    }

    #[test]
    fn quick_tap_stops_when_the_double_tap_window_ends() {
        let mut state = StateMachine::new(260);
        assert_eq!(state.press(ms(0)), Action::Start);
        assert_eq!(state.release(ms(80)), Action::None);
        assert_eq!(state.tick(ms(259)), Action::None);
        assert_eq!(state.tick(ms(260)), Action::Stop);
        assert_eq!(state.phase(), &Phase::Processing);
    }

    #[test]
    fn long_hold_stops_immediately_despite_a_repeat_press_at_release() {
        let mut state = StateMachine::new(260);
        assert_eq!(state.press(ms(0)), Action::Start);
        assert_eq!(state.press(ms(5_000)), Action::None);
        assert_eq!(state.release(ms(5_000)), Action::Stop);
        assert_eq!(state.phase(), &Phase::Processing);
        assert_eq!(state.press(ms(5_001)), Action::None);
    }

    #[test]
    fn duplicate_release_event_does_not_delay_hold_to_talk() {
        let mut state = StateMachine::new(260);
        state.press(ms(0));
        state.release(ms(100));
        state.release(ms(250));
        assert_eq!(state.tick(ms(259)), Action::None);
        assert_eq!(state.tick(ms(260)), Action::Stop);
    }

    #[test]
    fn second_tap_latches_until_next_press() {
        let mut state = StateMachine::new(260);
        assert_eq!(state.press(ms(0)), Action::Start);
        state.release(ms(80));
        assert_eq!(state.press(ms(200)), Action::None);
        state.release(ms(240));
        assert_eq!(
            state.phase(),
            &Phase::Recording {
                latched: true,
                tap_deadline: ms(260),
                stop_at: None,
                max_at: ms(1_200_000)
            }
        );
        assert_eq!(state.tick(ms(2_000)), Action::None);
        assert_eq!(state.press(ms(2_100)), Action::Stop);
    }

    #[test]
    fn wooting_tap_hold_double_tap_latches_with_measured_timing() {
        let mut state = StateMachine::new(1_000);
        assert_eq!(state.press(ms(0)), Action::Start);
        assert_eq!(state.release(ms(414)), Action::None);
        assert_eq!(state.press(ms(761)), Action::None);
        state.release(ms(788));
        assert!(matches!(
            state.phase(),
            Phase::Recording { latched: true, .. }
        ));
        assert_eq!(state.tick(ms(2_000)), Action::None);
    }

    #[test]
    fn stop_button_stops_either_recording_mode() {
        let mut state = StateMachine::new(260);
        state.press(ms(0));
        assert_eq!(state.stop(), Action::Stop);

        state.completed();
        state.press(ms(1_000));
        state.release(ms(1_020));
        state.press(ms(1_100));
        assert_eq!(state.stop(), Action::Stop);
    }

    #[test]
    fn recording_stops_at_the_configured_limit() {
        let mut state = StateMachine::with_max_recording(260, 2);
        state.press(ms(0));
        assert_eq!(state.tick(ms(1_999)), Action::None);
        assert_eq!(state.tick(ms(2_000)), Action::Stop);
    }
}
