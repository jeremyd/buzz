//! Profile fan-out target resolution (Phase 1.5).
//!
//! kind:0 profiles are per-relay and nothing republishes them across
//! communities — an edit that only reaches the active relay leaves every
//! other member community showing a stale or missing name. These helpers
//! compute the relay set a profile write must reach; the per-pair
//! spawn-refresh in `start_pair` heals the relays an agent is not currently
//! running on.

use std::collections::HashMap;

use crate::app_state::AppState;
use crate::managed_agents::{ManagedAgentPairRuntime, ManagedAgentRecord, ManagedAgentRuntimeKey};

/// One relay profile publish: (agent keys, relay URL, display name, avatar
/// URL, kind:0 about, auth tag).
pub(crate) type ProfileSyncRow = (
    nostr::Keys,
    String,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
);

/// Relay set a profile write must reach for this record.
///
/// A pinned record syncs only its pinned relay — the pin IS the community
/// (#2515), and publishing an instance's profile to foreign relays is exactly
/// the cross-community leak the pin exists to prevent. An unpinned record
/// (agents-everywhere, #2122) fans out to the active workspace relay plus
/// every relay the agent currently has a live pair runtime on.
///
/// Returns `(primary, secondaries)`: the primary is the record's effective
/// relay (pin, else workspace) and keeps whatever failure semantics the call
/// site already has; the secondaries are best-effort.
pub(crate) fn profile_fanout_relays(
    record_relay_url: &str,
    workspace_relay: &str,
    live_pair_relays: Vec<String>,
) -> (String, Vec<String>) {
    let pinned = record_relay_url.trim();
    if !pinned.is_empty() {
        return (pinned.to_string(), Vec::new());
    }
    let primary = workspace_relay.trim().to_string();
    let mut secondaries: Vec<String> = Vec::new();
    for relay in live_pair_relays {
        if !same_relay(&primary, &relay) && !secondaries.iter().any(|seen| same_relay(seen, &relay))
        {
            secondaries.push(relay);
        }
    }
    (primary, secondaries)
}

/// Compare two relay URLs in canonical form so `wss://relay.example/` and
/// `wss://relay.example` dedupe. Falls back to a trimmed string compare for
/// URLs the normalizer rejects.
fn same_relay(a: &str, b: &str) -> bool {
    let canon = |url: &str| {
        buzz_core_pkg::relay::normalize_relay_url(url)
            .unwrap_or_else(|_| url.trim().trim_end_matches('/').to_string())
    };
    canon(a) == canon(b)
}

/// Relay URLs of every live pair runtime for `pubkey`. Callers pass the
/// already-held runtimes guard — this must not lock, so it is safe inside
/// sections that hold `managed_agent_processes`.
pub(crate) fn live_pair_relay_urls(
    runtimes: &HashMap<ManagedAgentRuntimeKey, ManagedAgentPairRuntime>,
    pubkey: &str,
) -> Vec<String> {
    runtimes
        .keys()
        .filter(|key| key.pubkey.eq_ignore_ascii_case(pubkey))
        .map(|key| key.relay_url.clone())
        .collect()
}

/// Append one profile-publish row per fan-out relay for `record`: its
/// effective relay first, then (for unpinned records) every other relay it
/// has a live pair runtime on. Records whose key fails to parse contribute
/// nothing — matching the pre-fan-out behavior of the persona sync path,
/// whose publishes are all best-effort. The caller resolves the avatar and
/// kind:0 about to publish (the persona edit path computes them per-record).
pub(crate) fn push_profile_fanout_rows(
    state: &AppState,
    record: &ManagedAgentRecord,
    workspace_relay: &str,
    profile_avatar: Option<String>,
    about: Option<String>,
    rows: &mut Vec<ProfileSyncRow>,
) {
    let Ok(agent_keys) = nostr::Keys::parse(&record.private_key_nsec) else {
        return;
    };
    let live = state
        .managed_agent_processes
        .lock()
        .map(|runtimes| live_pair_relay_urls(&runtimes, &record.pubkey))
        .unwrap_or_default();
    let (primary, secondaries) = profile_fanout_relays(&record.relay_url, workspace_relay, live);
    for relay_url in std::iter::once(primary).chain(secondaries) {
        rows.push((
            agent_keys.clone(),
            relay_url,
            record.name.clone(),
            profile_avatar.clone(),
            about.clone(),
            record.auth_tag.clone(),
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::profile_fanout_relays;

    #[test]
    fn pinned_record_syncs_only_its_pin() {
        let (primary, secondaries) = profile_fanout_relays(
            "wss://pinned.example",
            "wss://workspace.example",
            vec!["wss://other.example".into()],
        );
        assert_eq!(primary, "wss://pinned.example");
        assert!(secondaries.is_empty());
    }

    #[test]
    fn unpinned_record_fans_out_workspace_primary_then_live_pairs() {
        let (primary, secondaries) = profile_fanout_relays(
            "",
            "wss://workspace.example",
            vec!["wss://other.example".into(), "wss://third.example".into()],
        );
        assert_eq!(primary, "wss://workspace.example");
        assert_eq!(
            secondaries,
            vec![
                "wss://other.example".to_string(),
                "wss://third.example".to_string(),
            ]
        );
    }

    #[test]
    fn unpinned_fanout_dedupes_workspace_variants() {
        let (primary, secondaries) = profile_fanout_relays(
            "  ",
            "wss://workspace.example",
            vec![
                "wss://workspace.example/".into(),
                "wss://other.example".into(),
                "wss://other.example".into(),
            ],
        );
        assert_eq!(primary, "wss://workspace.example");
        assert_eq!(secondaries, vec!["wss://other.example".to_string()]);
    }
}
