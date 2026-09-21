//! Correlate final resize acknowledgements. Old live geometry must not undo a
//! new drag, and an old host must eventually fall back to its actual geometry.
use std::time::{Duration, Instant};

#[derive(Default)]
pub struct ResizeSync {
    serial: u64,
    pending: Option<(u64, Instant)>,
}
impl ResizeSync {
    pub fn begin(&mut self) {
        self.pending = None;
    }
    pub fn commit(&mut self, now: Instant) -> u64 {
        self.serial += 1;
        self.pending = Some((self.serial, now));
        self.serial
    }
    pub fn complete(&mut self, request: u64) -> bool {
        if self.pending.map(|p| p.0) == Some(request) {
            self.pending = None;
            true
        } else {
            false
        }
    }
    pub fn waiting(&self) -> bool {
        self.pending.is_some()
    }
    pub fn expired(&mut self, now: Instant) -> bool {
        if self
            .pending
            .is_some_and(|(_, sent)| now.duration_since(sent) >= Duration::from_millis(1500))
        {
            self.pending = None;
            true
        } else {
            false
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn late_ack_cannot_finish_a_newer_drag() {
        let mut sync = ResizeSync::default();
        let now = Instant::now();
        let first = sync.commit(now);
        sync.begin();
        assert!(!sync.complete(first));
        let second = sync.commit(now);
        assert!(!sync.complete(first));
        assert!(sync.waiting());
        assert!(sync.complete(second));
        assert!(!sync.complete(second));
    }
    #[test]
    fn old_host_falls_back_once_without_an_infinite_wait() {
        let mut sync = ResizeSync::default();
        let now = Instant::now();
        sync.commit(now);
        assert!(!sync.expired(now + Duration::from_millis(1400)));
        assert!(sync.expired(now + Duration::from_millis(1500)));
        assert!(!sync.expired(now + Duration::from_secs(2)));
    }
}
