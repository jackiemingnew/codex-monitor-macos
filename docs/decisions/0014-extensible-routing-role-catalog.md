# ADR 0014: Use an additive role catalog with explicit lifecycle

- Status: Accepted
- Date: 2026-08-12
- Supersedes: ADR 0007 fixed ten-role catalog and current-role identity-health sections

## Context

Routing telemetry originally encoded ten registered roles in several independent
switches. The global router later replaced that matrix with six roles. Two new
roles (`terra-explorer` and `luna-max-implementer`) were therefore collapsed
into the opaque unknown bucket, while retired roles still occupied permanent
zero rows. The `commit-pusher` contract also remained at Luna Low after the
global role changed to Luna High.

Reading arbitrary role names dynamically from `config.toml` would avoid a code
update, but it would make historical snapshots depend on a mutable external
configuration format and could persist user-defined, potentially sensitive role
names. Inferring roles from model and Effort would merge distinct work contracts
and violate the existing evidence boundary.

## Decision

Use one additive in-process role catalog as the single source for aggregation,
identity validation, ordering, labels, and color family. Each entry contains a
stable role ID, display label, expected model, expected Effort, lifecycle, and
visual accent.

When a stable role ID keeps its name but changes model or Effort, the same entry
may carry a bounded historical identity with an exclusive creation-time cutoff.
Rows created before that cutoff may match the historical contract; the same old
identity on or after the cutoff remains a current mismatch. Missing creation
time fails closed. This keeps 30-day history valid without allowing a retired
contract to mask a new routing regression.

The catalog has two explicit lifecycles:

- `active`: the current six globally registered roles. Every active entry gets a
  deterministic zero bucket so snapshots remain comparable. Identity mismatch
  affects the current health result.
- `retired`: roles that may still appear in the seven- or thirty-day window or
  in persisted payloads. A retired role is emitted only when it has nonzero
  usage, is labelled as history, and does not fail the current identity contract.

Any source role absent from both sets remains one opaque unknown bucket. Its raw
role string is neither persisted nor displayed. Model and Effort continue to
validate a registered active contract; they never infer the role.

Adding or retiring a role is an additive edit to this one catalog. Existing raw
role identifiers and payload shapes remain unchanged, so old snapshots continue
to decode. The derived database schema, timer, source query, and privacy boundary
do not change.

## Consequences

- Current global roles no longer become unknown merely because presentation and
  aggregation switches drift independently.
- Historical work remains visible without being presented as a current routing
  recommendation or current identity failure.
- A future role still fails closed until intentionally registered in the
  catalog; this is the privacy-preserving trade-off for not persisting arbitrary
  configuration names.
- Same-name contract migrations require one explicit dated historical identity;
  they do not require a schema migration or a second presentation switch.
- The UI denominator is the number of active roles, while retired role classes
  are disclosed separately only when present.
