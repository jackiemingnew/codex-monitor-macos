# ADR-0012: Native local-only AGY quota provider

- Status: Accepted
- Date: 2026-08-06
- Supersedes: [ADR-0011](0011-antigravity-four-window-quota.md)

## Context

AGY quota data is available through its authenticated local language-server
session, but the previous adapter required a separately installed helper. That
made Monitor's optional strip depend on another app's executable, configuration
and cache boundary.

## Decision

Monitor resolves only the user's existing `agy` executable and starts one
bounded, directly-executed PTY session per refresh. The PTY is drained without
retaining TUI text. On completion, failure, or timeout, Monitor terminates only
the process group it created.

Ports are discovered solely from that PID and its controlled descendants. Each
request is POST-only HTTPS to `127.0.0.1` on one of those exact ports; redirects
are refused. The self-signed TLS exception is limited to that host and port
set. Responses and the whole operation are bounded. `RetrieveUserQuotaSummary`
is preferred; `GetUserStatus` and `GetCommandModelConfigs` may provide only
honest representative 5h values and never synthesize a 7d value.

AGY may publish its HTTPS listener shortly before the quota backend becomes
ready. HTTP 5xx from an exact owned loopback endpoint is treated only as a
startup signal: Monitor retries that endpoint four times with a bounded 2.2
second progressive backoff under the same 12-second operation deadline.

The persisted cache retains only normalized windows and timestamps with the
existing 0600/0700 permissions. It does not retain accounts, tokens, response
metadata, raw response bytes, terminal output, or detailed errors. Existing
15-minute freshness, 30-minute stale grace, and one in-flight ViewModel refresh
remain in effect.

Cache entries whose provenance is not exactly `local` are rejected instead of
being relabeled. This prevents a legacy helper-produced cache from being shown
as native evidence after migration.

## Rejected alternatives

- No OAuth, cookie, WebKit, remote Cloud Code API, or non-loopback request.
- No dependency on another app, its process, its configuration, or its cache.
- No persistent AGY daemon and no termination of a user-launched AGY process.

## Consequences

The strip is optional and degrades to unavailable when an AGY local session
cannot start or expose a permitted loopback endpoint. The implementation keeps
the existing four-slot display, with absent weekly data shown as unknown.

The session/probe approach is a minimal adaptation of the local PTY and
loopback-probe concepts in CodexBar commit `cafb2094d`, under that project's
MIT license; no binary or source dependency is added.
