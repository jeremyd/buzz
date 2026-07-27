//! Tests for `propagate_persona_respond_to` — the helper that applies a
//! persona definition's respond-to edit to linked agent instances.

use super::*;
use crate::managed_agents::RespondTo;

fn agent(persona_id: &str, name: &str, mode: RespondTo, allowlist: &[&str]) -> ManagedAgentRecord {
    ManagedAgentRecord {
        pubkey: format!("pubkey-{name}"),
        name: name.to_string(),
        persona_id: Some(persona_id.to_string()),
        private_key_nsec: String::new(),
        auth_tag: None,
        relay_url: String::new(),
        avatar_url: None,
        description: None,
        acp_command: String::new(),
        agent_command: String::new(),
        agent_command_override: None,
        agent_args: vec![],
        mcp_command: String::new(),
        turn_timeout_seconds: 0,
        idle_timeout_seconds: None,
        max_turn_duration_seconds: None,
        parallelism: 1,
        system_prompt: None,
        model: None,
        provider: None,
        effort_level: None,
        provider_policy_pending: false,
        persona_source_version: None,
        env_vars: std::collections::BTreeMap::new(),
        start_on_app_launch: false,
        auto_restart_on_config_change: true,
        runtime_pid: None,
        backend: Default::default(),
        backend_agent_id: None,
        provider_binary_path: None,
        team_id: None,
        persona_team_dir: None,
        persona_name_in_team: None,
        created_at: String::new(),
        updated_at: String::new(),
        last_started_at: None,
        last_stopped_at: None,
        last_exit_code: None,
        last_error: None,
        last_error_code: None,
        respond_to: mode,
        respond_to_allowlist: allowlist.iter().map(|s| s.to_string()).collect(),
        display_name: None,
        slug: None,
        runtime: None,
        name_pool: vec![],
        is_builtin: false,
        is_active: true,
        source_team: None,
        source_team_persona_slug: None,
        definition_respond_to: None,
        definition_respond_to_allowlist: vec![],
        definition_parallelism: None,
        relay_mesh: None,
        shared: false,
        catalog_source: None,
        team_catalog_source: None,
    }
}

#[test]
fn test_allowlist_merges_additively_into_instance_list() {
    // The instance's own allowlist entry (added via the members sidebar)
    // must survive a persona-level allowlist edit.
    let mut records = vec![agent(
        "persona-1",
        "Neo",
        RespondTo::Allowlist,
        &["instance-entry"],
    )];

    let changed = propagate_persona_respond_to(
        &mut records,
        "persona-1",
        RespondTo::Allowlist,
        &["definition-entry".to_string()],
    );

    assert_eq!(changed, vec!["pubkey-Neo".to_string()]);
    assert_eq!(records[0].respond_to, RespondTo::Allowlist);
    assert_eq!(
        records[0].respond_to_allowlist,
        vec!["instance-entry".to_string(), "definition-entry".to_string()],
        "definition entries append; instance entries are preserved"
    );
}

#[test]
fn test_mode_change_applies_to_owner_only_instance() {
    // An instance still on the default owner-only gate picks up both the
    // allowlist mode and the definition's pubkeys.
    let mut records = vec![agent("persona-1", "Neo", RespondTo::OwnerOnly, &[])];

    let changed = propagate_persona_respond_to(
        &mut records,
        "persona-1",
        RespondTo::Allowlist,
        &["definition-entry".to_string()],
    );

    assert_eq!(changed, vec!["pubkey-Neo".to_string()]);
    assert_eq!(records[0].respond_to, RespondTo::Allowlist);
    assert_eq!(
        records[0].respond_to_allowlist,
        vec!["definition-entry".to_string()]
    );
}

#[test]
fn test_non_allowlist_mode_preserves_instance_list() {
    // Narrowing to owner-only applies the mode but leaves the instance's
    // stored allowlist untouched, mirroring update_managed_agent's
    // across-mode-toggle preservation.
    let mut records = vec![agent(
        "persona-1",
        "Neo",
        RespondTo::Allowlist,
        &["instance-entry"],
    )];

    let changed =
        propagate_persona_respond_to(&mut records, "persona-1", RespondTo::OwnerOnly, &[]);

    assert_eq!(changed, vec!["pubkey-Neo".to_string()]);
    assert_eq!(records[0].respond_to, RespondTo::OwnerOnly);
    assert_eq!(
        records[0].respond_to_allowlist,
        vec!["instance-entry".to_string()],
        "stored allowlist survives the mode toggle"
    );
}

#[test]
fn test_other_persona_instances_untouched() {
    let mut records = vec![agent("persona-2", "Other", RespondTo::OwnerOnly, &[])];

    let changed = propagate_persona_respond_to(&mut records, "persona-1", RespondTo::Anyone, &[]);

    assert!(changed.is_empty());
    assert_eq!(records[0].respond_to, RespondTo::OwnerOnly);
}

#[test]
fn test_noop_when_instance_already_matches() {
    // Same mode and a list already containing the definition entries
    // (case-insensitively) must not report a change.
    let mut records = vec![agent("persona-1", "Neo", RespondTo::Allowlist, &["ABCDEF"])];
    let before = records[0].clone();

    let changed = propagate_persona_respond_to(
        &mut records,
        "persona-1",
        RespondTo::Allowlist,
        &["abcdef".to_string()],
    );

    assert!(changed.is_empty());
    assert_eq!(records[0], before, "record must be untouched");
}
