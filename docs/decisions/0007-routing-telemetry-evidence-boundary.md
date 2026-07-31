# ADR 0007: Keep routing telemetry independent, aggregate-only, and evidence-bound

- Status: Accepted
- Date: 2026-07-30

## Decision

Routing telemetry is a third Analytics mode, independent of both the official
WebKit Analytics page and Local Token/JSONL cost scanning. Its automatic lane is
a small daily local-21:00 read of the highest numbered `state_*.sqlite`; manual deep assessment uses
the same SQLite-only evidence with either seven or thirty local natural days.

Each daily point is an as-of snapshot of the preceding seven local natural days,
not an event bucket for that calendar day. The 7/30 selector shows a history of
those snapshots and must not sum edges or child counts across points.

The source database opens through SQLite C API in read-only mode and one read
transaction. A missing `threads`/`thread_spawn_edges` table or required column
is `UNAVAILABLE`; integrity anomalies lower a published result to `PARTIAL`.
There is no JSONL, subprocess, network, WebKit, or
model fallback. The UI only loads a published aggregate snapshot, and its top
refresh starts the cheap lane only.

Derived data is stored only at
`~/Library/Application Support/CodexNotch/routing-telemetry.sqlite`, never in
the existing `usage-deltas.sqlite`. It retains at most 90 days of daily and
assessment aggregates. Per-thread token baselines use SHA-256 keys and bounded
`last_seen` retention; title, cwd, rollout path, prompts, messages, reasoning,
and raw thread IDs are neither retained nor displayed.

Child-role detail is an aggregate extension of the same daily payload, not a
new query or table. Every current-window row that is actually the child side of
a spawn edge is assigned once by an exact `agent_role`/`role` match to the ten
global registered roles, in their declared order. The fixed zero buckets make
snapshots comparable. A nonzero opaque unknown bucket absorbs missing or
unregistered roles; it retains no raw source role. Model and reasoning effort
never infer a role. For a registered role they only validate the observed
identity against that role's fixed model/Effort contract; the UI marks missing
metadata or a mismatch as partial. Bucket counts, cumulative tokens, and
baseline-derived adjacent deltas reconcile to the existing child totals.
When both schema generations exist, a null or empty `agent_role` falls back
row-wise to the legacy `role` column; model and effort aliases use the same
non-empty fallback rule.

The daily payload also carries an optional aggregate-only Ultra Token
partition. The existing overall child share remains every recent edge-child's
cumulative Token divided by every recent row's cumulative Token. The stricter
Ultra-routing share is attributed Ultra-child Tokens divided by exact
`gpt-5.6-sol` + `ultra` root Tokens plus those attributed child Tokens; exact
`max` roots are retained only as aggregate context and are excluded from that
denominator. A child is attributed once only if its complete upward path through
the full edge table is unique, acyclic, non-orphaned, and ends at an in-window
exact Ultra root. Missing nodes, multiple parents, cycles, roots outside the
window, or insufficient root metadata leave the affected child unattributed;
its Token remains in the overall ratio and aggregate coverage counts rather
than being forced into the Ultra numerator. Duplicate thread IDs make the whole
strict partition unavailable and the published route quality `PARTIAL`.
Legacy payloads and zero strict denominators also display unavailable rather
than a fabricated zero. No raw identifiers are stored in this partition.

The partition additionally carries an optional strict **daily observed** Token
aggregate. It is not obtained by subtracting two published cumulative
snapshots. During one light scan, each hashed baseline increase is classified
only as aggregate `root`, `child`, or `other` from the current strict topology,
then the local-day row accumulates its safe root and child increases across
light scans. `routing_baselines` is extended in place with that non-sensitive
class; it continues to retain only the hash, Token baseline, and last-seen
time. No new per-thread table, raw ID, title, path, or unknown role is added.

Strict daily evidence fails closed for duplicate IDs, missing or legacy
baseline/class evidence on a strict participant, rollback, class drift between
`root`/`child`/`other`, or a participant unseen for more than 48 hours. The
problem row contributes no strict guidance increment. A genuinely new thread
created after the previous observation may start from zero. If an old daily
payload lacks these fields, or an earlier same-day scan was incomplete, the
whole day's strict aggregate remains incomplete; a new local day starts a new
evidence aggregate. Max and other roots remain outside the strict numerator and
denominator.

The product may summarize at least three complete strict daily points using a
Token-weighted local operational guardrail: below 20%, 20% through 35%, above
35% through 50%, and above 50%. These are this product's initial guidance
bands, not an official OpenAI standard or a community-wide consensus. They
apply only to strict daily observed increments; cumulative Token shares must
never be used for this guidance or as a health judgment.

Automatic work defers under Low Power Mode or serious/critical thermal pressure.
It uses a one-shot tolerant timer and catches up after a missed scheduled point
only when there is no later successful snapshot. Manual light refresh remains
allowed. Deep and light work are serialized; cancelled work cannot publish a
new result.

## Evidence boundary

State SQLite supports structural relationships, metadata coverage, token
burden, adjacent observations, and a median per-thread created-to-updated
proxy. It does not
prove task outcomes or actual execution start/end. Therefore verified success
rate, token per verified success, and true E2E speedup are persisted and shown
as `UNVERIFIED`.

The role breakdown is likewise not a success rate, efficiency measure, or
quality ranking. It is an as-of burden attribution. SQLite exposes current row
metadata, not role-change history, so a thread whose role changed cannot be
split across historical roles; the published snapshot conservatively uses only
its current exact metadata. Legacy daily BLOB payloads decode without a role
breakdown and the UI explicitly labels that absence rather than treating it as
an empty new snapshot.

The native manual report deterministically derives structure, identity, and
efficiency states from the same aggregate `RoutingAssessment`. Structure follows
metric quality while exposing depth, orphan, and cycle counts. Identity is
partial for missing metadata, a nonzero unknown bucket, registered-role identity
mismatches, or legacy `roleBuckets=nil`; efficiency remains `UNVERIFIED`. A
30-day report burden is an as-of recency-window cumulative value, not a 30-day
consumption claim. A user may manually render the aggregate report to one
atomically replaced local 0600 HTML cache file and open its file URL. This path
uses no WebKit, localhost, network, or model and never includes raw IDs, titles,
prompts, or paths.

Both Token shares are as-of burden ratios, not consumption or outcome metrics.
The report and chart state both denominators, disclose strict attribution counts
and Tokens, and state that Max roots are excluded. They never force an
unattributable child into Ultra routing.

## Consequences

The route feature remains privacy-bounded and does not add an interactive
background cost. First observations do not fabricate deltas; token rollbacks
clamp the delta and lower quality. A stale or partial route result cannot alter
official Analytics or Local Token state.
