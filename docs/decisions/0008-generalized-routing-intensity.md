# ADR 0008: Generalize routing intensity across models and Effort

- Status: Accepted
- Date: 2026-08-05
- Supersedes: ADR 0007 routing-token denominator, daily-guidance, chart, and report sections
- Superseded in part by: ADR 0009 dual daily baselines and Ultra comparison presentation

## Decision

The primary route metric is **multi-agent routing intensity**: strict attributed
child Token divided by the Token of roots that actually have a strict attributed
dispatch plus those children. Root model and Effort do not restrict eligibility.
Attribution is fail-closed: every parent link must be present and unique, the
chain must be acyclic and orphan-free, and its root must be in the current
window. A child that is multi-parent, orphaned, cyclic, or attached to an
out-of-window root remains unattributed and is never counted twice.

The auxiliary overall child burden remains all edge-child Token divided by all
window task Token. Root dispatch coverage is shown independently as routed roots
divided by all window roots; roots without a strictly attributed descendant do
not enter the primary denominator.

Daily payloads add aggregate-only `RoutingTokenPartition` data: window and
routed-root counts/Tokens, strict attributed and unattributed child counts/Tokens,
composite parent-root buckets, generic observed root/child deltas, evidence
completeness, and same-day merge count. No raw ID, title, path, unknown model, or
unknown Effort is persisted. Model families use a finite vocabulary (`gpt-5.6`
Sol/Luna/Terra, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`,
`gpt-5.3-codex-spark`, `codex-auto-review`, and `other`). Effort uses only
`none`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`, and `unknown`.
The model-family + Effort pair remains composite in storage even when the UI
groups it into a short Ultra/Max/High/Medium/other summary. Source presentation
keeps two meanings separate: routed-root count answers which tiers initiated
dispatch, while attributed child Token share answers which tiers produced the
downstream Token burden. The compact card leads with root counts so a small-Token
dispatch is not rounded into an apparent zero-dispatch tier; Token shares remain
available in the expanded details and report.

`RoutingUltraTokenPartition` and its old fields remain a separate Codable
compatibility surface. ADR 0009 restores its exact-Ultra comparison presentation
and future daily collection without mixing generalized deltas into Ultra fields.
Missing fields decode as legacy/unavailable, not zero.

The existing `routing_baselines.strict_class` stores only the generalized
`root`/`child`/`other` classification. Existing one-read SQLite topology and
hash baselines are reused. Duplicate IDs, class drift, stale participants,
rollbacks, missing baseline/class evidence, and incomplete same-day history make
the generalized daily observation incomplete. A newly created post-observation
thread may establish a safe zero baseline. No new scan, table, network, JSONL
read, timer, or per-role query is introduced.

Guidance is a Token-weighted local operational band over at least three complete
daily observed points: below 20% low, 20–35% balanced, above 35–50% elevated, and
above 50% excessive. It is not an official or community health standard;
cumulative shares are reference-only and never drive guidance.

## Evidence and privacy boundary

The report and compact 520pt UI show generalized routing intensity, overall child
burden, root dispatch coverage, and parent-source distribution. Trend tooltips,
keyboard navigation, and VoiceOver use the same generalized daily denominator.
Reports retain the existing privacy, read-only, performance, and `UNVERIFIED`
outcome boundaries. State SQLite does not prove task success, token-per-success,
or true end-to-end speedup; those values remain `UNVERIFIED`.
