# ADR-0016: Decouple AGY sidecar health from concrete model versions

- Status: Accepted
- Date: 2026-08-20
- Related: [ADR-0013](0013-agy-sidecar-health-monitoring.md)
- Supersedes: ADR-0013 only where health parsing pinned exact model IDs

## Context

The AGY wrapper migrated its primary reviewer from Gemini 3.6 Flash High to
Gemini 3.7 Flash High. The wrapper Doctor remained `READY`, but Codex Monitor
reported `BROKEN` because its receipt whitelist treated the old exact model ID
as part of the safety protocol.

A model version is deployment evidence, not a stable health invariant. At the
same time, accepting arbitrary model names would hide accidental route changes.
The monitor therefore needs a contract that survives version upgrades without
weakening repository isolation, Diff delivery, tool-audit or finding checks.

## Decision

AGY Doctor and review receipts use additive contract metadata:

```json
{
  "contract_version": 1,
  "model_roles": {
    "primary": {
      "family": "gemini-flash-high",
      "model": "gemini-3.7-flash-high"
    },
    "secondary": {
      "family": "claude-sonnet",
      "model": "claude-sonnet-4-6"
    }
  }
}
```

The semantic role and family are stable routing assertions. The concrete model
ID is retained as evidence and must be a bounded safe identifier, but its
version component does not independently determine health. The Doctor's
`models` map, review route model, and `attempted_models` must agree exactly with
the declared role model IDs.

Codex Monitor keeps narrow backward compatibility for legacy receipts by
recognizing the version-independent `gemini-<version>-flash-high` and
`claude-sonnet-<version>` families. It does not accept arbitrary legacy model
names.

Status handling is:

- supported contract and families plus all existing protocol assertions:
  `READY` or `COMPLETE`;
- a structurally safe but unknown contract version: Doctor
  `COMPATIBILITY_WARNING`, E2E `PARTIAL`, error `CONTRACT_UNSUPPORTED`;
- a structurally safe but unknown role family: Doctor
  `COMPATIBILITY_WARNING`, E2E `PARTIAL`, error
  `MODEL_ROLE_UNSUPPORTED`;
- malformed identifiers, role/route mismatch, repository exposure, unsafe Diff
  delivery, missing Diff reads, extra tools, corrupt or oversized receipts, or a
  missed canary finding: `BROKEN`.

The compact HUD renders compatibility warnings in amber as “兼容待确认” and the
settings page displays the actual discovered model IDs. AGY runtime quota,
Doctor health and E2E health remain independent.

## Consequences

Routine AGY model upgrades no longer create false red incidents, while an
unrecognized routing family cannot silently become fully healthy. Exact model
IDs remain visible for diagnosis and audit without becoming a brittle policy
constant.

The wrapper and monitor must be deployed together when introducing a new
contract version. Older receipts remain narrowly readable, but any future
contract or family requires an explicit monitor update before it can return a
fully healthy state.

This change does not alter AGY permissions, retry behavior, model selection,
repository disclosure, canary frequency or Token accounting. Validation may
run Doctor without a model call; a real E2E model canary still requires separate
explicit authorization.
