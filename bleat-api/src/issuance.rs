use std::{
    collections::{HashMap, VecDeque},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    num::NonZeroU32,
    sync::Arc,
    time::Duration,
};

use governor::{
    Quota, RateLimiter,
    clock::{Clock, DefaultClock, Reference},
    state::{InMemoryState, direct::NotKeyed},
};
use tokio::sync::Mutex;

use crate::config::Config;

const CLEANUP_BATCH: usize = 64;
const CLEANUP_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum ClientKey {
    V4(Ipv4Addr),
    V6(Ipv6Addr),
}

impl From<IpAddr> for ClientKey {
    fn from(address: IpAddr) -> Self {
        match address.to_canonical() {
            IpAddr::V4(address) => Self::V4(address),
            IpAddr::V6(address) => Self::V6(Ipv6Addr::from(u128::from(address) & (!0_u128 << 64))),
        }
    }
}

impl fmt::Display for ClientKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::V4(address) => write!(formatter, "{address}"),
            Self::V6(prefix) => write!(formatter, "{prefix}/64"),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum AdmissionFailure {
    Quota { retry_seconds: u64 },
    Capacity,
}

struct ClientEntry<C: Clock> {
    limiter:
        RateLimiter<NotKeyed, InMemoryState, C, governor::middleware::NoOpMiddleware<C::Instant>>,
    last_used: C::Instant,
}

struct Clients<C: Clock> {
    entries: HashMap<ClientKey, ClientEntry<C>>,
    // Exactly one queue entry per map entry; rotation bounds each cleanup attempt.
    cleanup: VecDeque<ClientKey>,
}

pub(crate) struct IssuanceLimiter<C: Clock = DefaultClock> {
    clients: Mutex<Clients<C>>,
    clock: C,
    quota: Quota,
    maximum: usize,
    idle: Duration,
}

impl IssuanceLimiter {
    pub(crate) fn from_config(config: &Config) -> Option<Arc<Self>> {
        let rate = NonZeroU32::new(u32::try_from(config.challenge_issuance_per_minute).ok()?)?;
        let burst = NonZeroU32::new(u32::try_from(config.challenge_issuance_burst).ok()?)?;
        if config.challenge_max_clients == 0 {
            return None;
        }
        let limiter = Arc::new(Self::new(
            Quota::per_minute(rate).allow_burst(burst),
            config.challenge_max_clients,
            DefaultClock::default(),
        ));
        let weak = Arc::downgrade(&limiter);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(CLEANUP_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                let Some(limiter) = weak.upgrade() else { break };
                limiter.cleanup().await;
            }
        });
        Some(limiter)
    }
}

impl<C: Clock + Clone> IssuanceLimiter<C> {
    pub(crate) fn new(quota: Quota, maximum: usize, clock: C) -> Self {
        // Round UP using Governor's actual interval, including its nanosecond arithmetic.
        let idle = Duration::from_secs(ceil_seconds(quota.burst_size_replenished_in()));
        Self {
            clients: Mutex::new(Clients {
                entries: HashMap::new(),
                cleanup: VecDeque::new(),
            }),
            clock,
            quota,
            maximum,
            idle,
        }
    }

    pub(crate) async fn check(&self, key: ClientKey) -> Result<(), AdmissionFailure> {
        let mut clients = self.clients.lock().await;
        if !clients.entries.contains_key(&key) {
            if clients.entries.len() >= self.maximum {
                self.cleanup_batch(&mut clients);
            }
            if clients.entries.len() >= self.maximum {
                return Err(AdmissionFailure::Capacity);
            }
            clients.entries.insert(
                key,
                ClientEntry {
                    limiter: RateLimiter::direct_with_clock(self.quota, self.clock.clone()),
                    last_used: self.clock.now(),
                },
            );
            clients.cleanup.push_back(key);
        }
        // Admission and eviction share this short critical section. No limiter escapes it,
        // and no await occurs after acquiring the map. Governor checks never wait for quota.
        let Some(entry) = clients.entries.get_mut(&key) else {
            return Err(AdmissionFailure::Capacity);
        };
        let result = entry.limiter.check();
        entry.last_used = self.clock.now();
        result.map_err(|rejection| AdmissionFailure::Quota {
            retry_seconds: ceil_seconds(rejection.wait_time_from(self.clock.now())).max(1),
        })
    }

    async fn cleanup(&self) {
        let mut clients = self.clients.lock().await;
        self.cleanup_batch(&mut clients);
    }

    fn cleanup_batch(&self, clients: &mut Clients<C>) {
        let now = self.clock.now();
        for _ in 0..CLEANUP_BATCH.min(clients.cleanup.len()) {
            let Some(key) = clients.cleanup.pop_front() else {
                break;
            };
            let expired = clients.entries.get(&key).is_some_and(|entry| {
                Duration::from(now.duration_since(entry.last_used)) >= self.idle
            });
            if expired {
                clients.entries.remove(&key);
            } else {
                clients.cleanup.push_back(key);
            }
        }
    }
}

fn ceil_seconds(duration: Duration) -> u64 {
    duration
        .as_secs()
        .saturating_add(u64::from(duration.subsec_nanos() != 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use governor::clock::FakeRelativeClock;

    fn key(address: &str) -> ClientKey {
        ClientKey::from(address.parse::<IpAddr>().expect("test IP"))
    }

    fn limiter(rate: u32, burst: u32, capacity: usize) -> IssuanceLimiter<FakeRelativeClock> {
        IssuanceLimiter::new(
            Quota::per_minute(NonZeroU32::new(rate).expect("rate"))
                .allow_burst(NonZeroU32::new(burst).expect("burst")),
            capacity,
            FakeRelativeClock::default(),
        )
    }

    #[test]
    fn canonical_keys_preserve_ipv4_and_group_only_the_same_ipv6_prefix() {
        assert_eq!(key("192.0.2.1"), key("::ffff:192.0.2.1"));
        assert_ne!(key("192.0.2.1"), key("192.0.2.2"));
        assert_eq!(key("2001:db8:1:2::1"), key("2001:db8:1:2:ffff::9"));
        assert_ne!(key("2001:db8:1:2::1"), key("2001:db8:1:3::1"));
        assert_eq!(key("2001:db8:1:2:ffff::9").to_string(), "2001:db8:1:2::/64");
        assert_eq!(key("::ffff:192.0.2.1").to_string(), "192.0.2.1");
    }

    #[tokio::test]
    async fn burst_refill_independence_and_retry_rounding_use_the_same_clock() {
        let limiter = limiter(40, 2, 8); // One admission every 1.5 seconds.
        let client = key("192.0.2.1");
        assert_eq!(limiter.check(client).await, Ok(()));
        assert_eq!(limiter.check(client).await, Ok(()));
        assert_eq!(
            limiter.check(client).await,
            Err(AdmissionFailure::Quota { retry_seconds: 2 })
        );
        assert_eq!(limiter.check(key("192.0.2.2")).await, Ok(()));
        limiter.clock.advance(Duration::from_millis(500));
        assert_eq!(
            limiter.check(client).await,
            Err(AdmissionFailure::Quota { retry_seconds: 1 })
        );
        limiter.clock.advance(Duration::from_millis(999));
        assert_eq!(
            limiter.check(client).await,
            Err(AdmissionFailure::Quota { retry_seconds: 1 })
        );
        limiter.clock.advance(Duration::from_millis(1));
        assert_eq!(limiter.check(client).await, Ok(()));
        assert_eq!(
            limiter.check(client).await,
            Err(AdmissionFailure::Quota { retry_seconds: 2 })
        );
    }

    #[tokio::test]
    async fn full_map_preserves_depleted_entries_until_safe_rounded_idle_expiry() {
        let limiter = limiter(7, 2, 1);
        let first = key("192.0.2.1");
        let second = key("192.0.2.2");
        assert_eq!(limiter.idle, Duration::from_secs(18));
        assert_eq!(limiter.check(first).await, Ok(()));
        assert_eq!(limiter.check(first).await, Ok(()));
        assert_eq!(limiter.check(second).await, Err(AdmissionFailure::Capacity));
        assert!(matches!(
            limiter.check(first).await,
            Err(AdmissionFailure::Quota { .. })
        ));
        limiter.clock.advance(Duration::from_millis(17_999));
        limiter.cleanup().await;
        assert_eq!(limiter.check(second).await, Err(AdmissionFailure::Capacity));
        limiter.clock.advance(Duration::from_millis(1));
        assert_eq!(limiter.check(second).await, Ok(()));
        assert_eq!(limiter.clients.lock().await.entries.len(), 1);
    }

    #[tokio::test]
    async fn bounded_cleanup_rotates_and_periodic_work_reclaims_idle_entries() {
        let limiter = limiter(60, 1, CLEANUP_BATCH + 1);
        for index in 0..=CLEANUP_BATCH {
            let client = ClientKey::V4(Ipv4Addr::from(index as u32));
            assert_eq!(limiter.check(client).await, Ok(()));
        }
        limiter.clock.advance(Duration::from_secs(1));
        limiter.cleanup().await;
        assert_eq!(limiter.clients.lock().await.entries.len(), 1);
        limiter.cleanup().await;
        let clients = limiter.clients.lock().await;
        assert!(clients.entries.is_empty());
        assert!(clients.cleanup.is_empty());
    }

    #[tokio::test]
    async fn existing_keys_continue_refilling_while_the_map_is_full() {
        let limiter = limiter(60, 2, 1);
        let first = key("192.0.2.1");
        assert_eq!(limiter.check(first).await, Ok(()));
        assert_eq!(limiter.check(first).await, Ok(()));
        limiter.clock.advance(Duration::from_secs(1));
        assert_eq!(
            limiter.check(key("192.0.2.2")).await,
            Err(AdmissionFailure::Capacity)
        );
        assert_eq!(limiter.check(first).await, Ok(()));
        assert!(matches!(
            limiter.check(first).await,
            Err(AdmissionFailure::Quota { .. })
        ));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_checks_never_over_admit_or_exceed_capacity() {
        let shared = Arc::new(limiter(1, 3, 7));
        let mut tasks = tokio::task::JoinSet::new();
        for _ in 0..100 {
            let shared = Arc::clone(&shared);
            tasks.spawn(async move { shared.check(key("192.0.2.1")).await });
        }
        let mut admitted = 0;
        while let Some(result) = tasks.join_next().await {
            if result.expect("check task").is_ok() {
                admitted += 1;
            }
        }
        assert_eq!(admitted, 3);
        for index in 0..100 {
            let shared = Arc::clone(&shared);
            tasks.spawn(async move { shared.check(ClientKey::V4(Ipv4Addr::from(index))).await });
        }
        while let Some(result) = tasks.join_next().await {
            let _ = result.expect("check task");
        }
        let clients = shared.clients.lock().await;
        assert_eq!(clients.entries.len(), 7);
        assert_eq!(clients.cleanup.len(), 7);
    }
}
