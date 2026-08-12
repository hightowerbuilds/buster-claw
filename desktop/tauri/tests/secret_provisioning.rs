// The Clinch Phase 0 guard, and a sibling to `acl_lockstep.rs`.
//
// A secret is only useful to the BEAM if it is provisioned in TWO places in
// lockstep: an `ensure_secret(...)` call that puts it in the Keychain, and an
// `.env(...)` line on the release spawn that hands it to Phoenix. Miss the
// second half and the Elixir side silently falls back to generating its own
// value and persisting it to a CLEARTEXT file in the data dir — which is exactly
// what happened to `agent_token`, the token authorizing untrusted-provenance
// agent runs. It was provisioned nowhere and injected nowhere, so nothing failed;
// it just quietly wrote itself to disk on every packaged install.
//
// Like the ACL test, this reads source text rather than linking the crate: the
// point is to check two places in one file against each other, not runtime
// behavior, and it must run without a Keychain.

use std::collections::BTreeSet;

const MAIN_RS: &str = include_str!("../src/main.rs");

/// Every account name passed to `ensure_secret(&data_dir, "<name>", ...)`.
///
/// Call sites only — the `fn ensure_secret(` definition is skipped, or the first
/// quoted string in its *body* (an error message) would be read as an account.
fn provisioned_accounts() -> BTreeSet<String> {
    MAIN_RS
        .match_indices("ensure_secret(")
        .filter(|(i, _)| !MAIN_RS[..*i].ends_with("fn "))
        .filter_map(|(i, _)| {
            let rest = &MAIN_RS[i..];
            // The account is the first quoted string in the call.
            let start = rest.find('"')? + 1;
            let end = start + rest[start..].find('"')?;
            Some(rest[start..end].to_string())
        })
        .collect()
}

/// Every environment variable name passed to `.env("<name>", ...)`.
fn injected_env_vars() -> BTreeSet<String> {
    MAIN_RS
        .match_indices(".env(\"")
        .filter_map(|(i, _)| {
            let rest = &MAIN_RS[i + ".env(\"".len()..];
            let end = rest.find('"')?;
            Some(rest[..end].to_string())
        })
        .collect()
}

/// The account → env-var mapping is not a pure transformation (`mcp_token`
/// becomes `BUSTER_CLAW_MCP_API_TOKEN`, inserting an `API` that isn't in the
/// account name), so it is spelled out. Adding a secret means adding a line
/// here, which is the point: the test should have to be edited deliberately.
const EXPECTED: &[(&str, &str)] = &[
    ("secret_key_base", "SECRET_KEY_BASE"),
    ("api_token", "BUSTER_CLAW_API_TOKEN"),
    ("mcp_token", "BUSTER_CLAW_MCP_API_TOKEN"),
    ("agent_token", "BUSTER_CLAW_AGENT_API_TOKEN"),
    // Clinch finding #7. The PTY used to inherit BUSTER_CLAW_API_TOKEN — the full
    // token — so an agent with a prompt could reach /api/clinch and manage
    // credentials. This one is trusted-equivalent for commands and refused by
    // RequireTrusted, and terminal.rs injects it into the shell UNDER THE NAME
    // BUSTER_CLAW_API_TOKEN, so the in-app CLI needs no change.
    ("terminal_token", "BUSTER_CLAW_TERMINAL_API_TOKEN"),
];

#[test]
fn every_provisioned_secret_is_injected_into_the_release() {
    let injected = injected_env_vars();

    for (account, var) in EXPECTED {
        assert!(
            injected.contains(*var),
            "`{account}` is provisioned but `{var}` is never passed to the release spawn. \
             The BEAM will fall back to generating its own value and writing it to disk \
             in cleartext. Add `.env(\"{var}\", &self.{account})` to spawn_release."
        );
    }
}

#[test]
fn every_expected_secret_is_actually_provisioned() {
    let provisioned = provisioned_accounts();

    for (account, _) in EXPECTED {
        assert!(
            provisioned.contains(*account),
            "`{account}` is expected in the Keychain but no ensure_secret call provisions it"
        );
    }
}

#[test]
fn no_secret_is_provisioned_without_being_declared_here() {
    let provisioned = provisioned_accounts();
    let declared: BTreeSet<String> = EXPECTED.iter().map(|(a, _)| a.to_string()).collect();

    let undeclared: Vec<_> = provisioned.difference(&declared).collect();

    assert!(
        undeclared.is_empty(),
        "new Keychain secret(s) {undeclared:?} are provisioned but not declared in this test's \
         EXPECTED table, so nothing checks that they reach the release. Add them."
    );
}

// Tripwires: if main.rs is reshaped so these parsers silently match nothing, the
// assertions above would all pass vacuously.
#[test]
fn the_parsers_still_find_something() {
    assert!(
        provisioned_accounts().len() >= EXPECTED.len(),
        "ensure_secret parser found {} accounts; main.rs may have been reshaped",
        provisioned_accounts().len()
    );
    assert!(
        injected_env_vars().len() >= EXPECTED.len(),
        "the .env(...) parser found {} vars; main.rs may have been reshaped",
        injected_env_vars().len()
    );
}
