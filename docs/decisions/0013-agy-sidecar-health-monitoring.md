# ADR-0013: Monitor AGY sidecar health independently from AGY quota

- Status: Accepted
- Date: 2026-08-07
- Related: [ADR-0012](0012-native-local-only-agy-quota-provider.md)

## Context

The native AGY quota lane proves only that a local AGY runtime can expose quota
data. It does not prove that the repository-review sidecar still creates a
read-only tracked snapshot, delivers the Diff as a workspace file, avoids extra
tools, detects a known defect, or returns a valid bounded Token receipt.

Treating those signals as one status would hide independent failures. Running a
real model review on every UI refresh would also add avoidable latency, quota
use and network work.

## Decision

Monitor three independent signals:

1. **AGY Runtime** remains the existing quota provider and keeps its own
   availability and cache semantics.
2. **Sidecar Doctor** invokes only
   `/usr/bin/python3 ~/.codex/skills/agy-model-sidecar/scripts/agy_review.py doctor`.
   It is single-flight, cancellable and bounded by a timeout. Results, including
   failures, are cached for six hours; a controller-owned low-frequency task
   schedules the next check without depending on rendering or ordinary Token
   refresh, while manual checks bypass that freshness window.
3. **E2E acceptance** is disabled unless the build explicitly authorizes live
   canaries. Manual acceptance performs one wrapper invocation with no retry.
   Automatic acceptance is opt-in and cannot run more frequently than once per
   24 hours.

The E2E canary owns a dedicated Git repository under the app's Application
Support directory. Its only commit contains a correct pure-Python `clamp`; its
worktree contains one deliberate bound-order regression and exactly one benign
untracked file. Symlinks, unknown files and unexpected Git state fail closed as
`FIXTURE_INVALID`; the app never deletes unknown content.

The sidecar process runner uses a fixed Python executable and argv array. It
separates stdout from stderr, parses JSON only from stdout, caps the receipt at
96 KiB and accepts only a strict field whitelist. It never stores the full
receipt, Diff, prompt, repository content, finding text or stderr. The cache and
diagnostic log retain only normalized state, timestamps, protocol summaries,
tool counts, explicitly reported Token fields and sanitized error codes with
the existing 0600/0700 permissions.

`COMPLETE` requires every repository-snapshot and tool-audit assertion plus a
structured finding that identifies the deliberate `clamp.py` defect.
`PARTIAL`, `BROKEN`, `UNAVAILABLE` and `NEVER_RUN` retain distinct meanings.
Finding severity is not health: detecting the deliberate defect is the success
condition. Missing model Token fields remain `UNAVAILABLE`; receipt bytes never
stand in for Tokens, and Codex Token usage remains unavailable unless a future
runtime explicitly supplies it.

## Alternatives considered

- Reuse quota availability as sidecar health: rejected because it does not
  exercise the review protocol or model route.
- Run a model canary during ordinary quota or Token refresh: rejected because
  render-driven or frequent checks would consume quota and couple independent
  refresh lanes.
- Persist raw receipts for diagnostics: rejected because they can contain
  untrusted model output or repository-derived text.
- Repair or recreate an unexpected fixture automatically: rejected because the
  directory may contain user data that the app does not own.

## Consequences

The existing AGY strip can show quota and a compact sidecar indicator without
one hiding the other. Detailed Doctor, E2E, source, tool-audit and Token summaries
live in the existing Codex settings page.

Unit and integration tests use simulated wrapper receipts and temporary local
scripts. They validate the protocol but do not prove live AGY availability. A
build with live canaries disabled must therefore keep E2E at `NEVER_RUN`; only a
separately authorized real acceptance can establish live `COMPLETE`.
