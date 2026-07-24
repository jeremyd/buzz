//! Token sources for the LLM transport layer.
//!
//! [`TokenSource`] decouples request auth from `Config::api_key`. The only
//! shipped implementation is [`StaticTokenSource`] — a plain env-var API key.
//! The trait is kept async and refresh-aware so a rotating/refreshable source
//! can slot in later without touching the [`Llm`] call sites. (An OAuth PKCE
//! browser-login engine used to live here for Databricks; it was removed with
//! the rest of the external interactive login flows — bring-your-own-token
//! via env vars is the supported path.)

use async_trait::async_trait;

use crate::types::AgentError;

/// Asynchronous source of a bearer token. The [`Llm`] calls this per
/// request, so impls are expected to be cheap on the cache-hit path.
#[async_trait]
pub trait TokenSource: Send + Sync {
    async fn bearer(&self) -> Result<String, AgentError>;

    /// Return a bearer token from cache or refresh, **never** opening a browser.
    ///
    /// The default delegates to [`bearer`](Self::bearer) — correct for token
    /// sources (e.g. static API keys) that can never trigger a browser flow.
    async fn bearer_no_browser(&self) -> Result<String, AgentError> {
        self.bearer().await
    }

    /// Force a fresh bearer after the server rejected the current one (401).
    ///
    /// `rejected` is the exact access token that just got the 401. Unlike
    /// [`bearer`](Self::bearer), which trusts the local expiry clock, this is
    /// driven by the server's verdict: the cached token looked valid to us
    /// (well within its local expiry) but the provider rejected it — clock
    /// skew, server-side revocation, or a node that never saw it. The clock
    /// therefore can't decide whether to refresh; the caller passes the
    /// rejected token so the impl can refresh unless a concurrent caller has
    /// *already* replaced it. Implementations must obtain a new token without
    /// any interactive step, so a headless harness never hangs. The default
    /// returns the existing bearer — correct for sources that can't refresh
    /// (a static key); the caller's retry then fails terminally rather than
    /// looping.
    async fn refresh_now(&self, _rejected: &str) -> Result<String, AgentError> {
        self.bearer().await
    }
}

/// A token that never changes for the life of the process.
pub struct StaticTokenSource(String);

impl StaticTokenSource {
    pub fn new(token: impl Into<String>) -> Self {
        Self(token.into())
    }
}

#[async_trait]
impl TokenSource for StaticTokenSource {
    async fn bearer(&self) -> Result<String, AgentError> {
        Ok(self.0.clone())
    }
}
