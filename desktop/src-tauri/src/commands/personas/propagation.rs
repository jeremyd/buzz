//! Pure helper that fans a persona definition respond-to edit out to the
//! agent instances minted from it. Extracted so it stays unit-testable
//! without a Tauri `AppHandle` (see the child
//! `respond_to_propagation_tests` module).

use crate::managed_agents::{ManagedAgentRecord, RespondTo};
use crate::util::now_iso;

#[cfg(test)]
mod respond_to_propagation_tests;

/// Apply a definition-level respond-to edit to every instance minted from
/// this persona. Definition respond-to otherwise only applies at mint time
/// (snapshot/team import), so without this pass an edit to "Who can talk to
/// this agent" is a silent no-op for agents that already exist.
///
/// The mode is applied as-is; in allowlist mode the definition's pubkeys are
/// merged additively into the instance's own list, so allowlist entries added
/// per-instance (channel members sidebar) survive a persona-level edit. In
/// non-allowlist modes the instance list is preserved untouched, mirroring
/// `update_managed_agent`'s across-mode-toggle preservation.
///
/// Returns the pubkeys of changed records; the caller persists them, and the
/// spawn-config drift badge / auto-restart machinery picks the change up.
pub(super) fn propagate_persona_respond_to(
    records: &mut [ManagedAgentRecord],
    persona_id: &str,
    definition_mode: RespondTo,
    definition_allowlist: &[String],
) -> Vec<String> {
    let mut changed = Vec::new();
    for record in records.iter_mut() {
        if record.persona_id.as_deref() != Some(persona_id) {
            continue;
        }
        let mut merged = record.respond_to_allowlist.clone();
        if definition_mode == RespondTo::Allowlist {
            for pubkey in definition_allowlist {
                if !merged
                    .iter()
                    .any(|entry| entry.eq_ignore_ascii_case(pubkey))
                {
                    merged.push(pubkey.clone());
                }
            }
        }
        if record.respond_to == definition_mode && record.respond_to_allowlist == merged {
            continue;
        }
        record.respond_to = definition_mode;
        record.respond_to_allowlist = merged;
        record.updated_at = now_iso();
        changed.push(record.pubkey.clone());
    }
    changed
}
