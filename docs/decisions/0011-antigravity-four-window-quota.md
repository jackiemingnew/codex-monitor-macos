# ADR-0011: Normalize Antigravity's four quota windows

- Status: Superseded by ADR-0012
- Date: 2026-08-06
- Supersedes: [ADR-0010](0010-antigravity-quota-via-codexbar-cli.md)

## Context

CodexBar's public Antigravity adapter now exposes a normalized
`UsageSnapshot.extraRateWindows` collection. Each `NamedRateWindow` has an
`id`, `title`, optional `usageKnown`, and a nested window carrying
`usedPercent`, `windowMinutes`, `resetsAt`, and reset metadata. The
representative `primary` and `secondary` fields are fallback session/model
quotas; they do not identify a weekly period. Showing only those two values
made the AGY strip unable to distinguish the four user-facing limits.

The monitor remains deliberately local and read-only. It must invoke the
installed CodexBarCLI with request mode `--source cli`, avoid OAuth/automatic
source selection and credential or web access, and avoid new polling or
network paths. CodexBar can identify the local strategy that satisfied that
request as `app`, `cli`, or `ide`; those are result metadata, not additional
monitor-side source selection.

## Decision

Normalize the fixed pools and periods into four slots, in this order:

1. Gemini 5h (`primary`, `.fiveHour`)
2. Gemini 7d (`primary`, `.sevenDay`)
3. Claude + GPT 5h (`secondary`, `.fiveHour`)
4. Claude + GPT 7d (`secondary`, `.sevenDay`)

The normalized `AntigravityQuotaWindow` persists only pool, period, remaining
percent (optional), and reset timestamp. Source ids, titles, descriptions,
identity fields, and raw helper output are not retained. Unknown percentages
are rendered as `--` and are never converted to zero or one hundred.

Parser precedence is explicit extra-window classification by pool and period.
`windowMinutes` 300/10080 is preferred; title/id aliases such as `5h`,
`5-hour`, `session`, `weekly`, and `7d` provide compatibility when duration
metadata is absent. Unknown windows are ignored. `usageKnown=false` and
synthetic placeholders keep their reset timestamp but expose a nil percentage.
If no extra weekly window exists, the weekly slot remains nil. Legacy
primary/secondary payloads and caches decode as five-hour slots only.

The 520-point detail panel renders one compact row per pool with explicit `5h`
and `7d` cells. The help and VoiceOver text use the same fixed four-window
order, include `暂无` for unknown values, and include any available reset time.
Fresh/stale/unavailable status text remains unchanged.

## Compatibility and operational boundaries

- The client command remains `usage --provider antigravity --source cli
  --format json --json-only` against the installed CodexBarCLI helper.
- Parsed and cached result sources are limited to CodexBar's local `app`,
  `cli`, and `ide` strategies. OAuth, `auto`, and unknown sources are rejected.
- Old `primary`/`secondary` cache keys are accepted and default to `.fiveHour`;
  new weekly keys are optional. Cache load/save validates each pool/period
  pair and keeps the existing 0600 file and 0700 directory permissions.
- No timer, browser, OAuth, account lookup, internal API, or new network path
  is introduced. Existing stale-cache grace and single in-flight refresh
  behavior are unchanged.

## Consequences

The AGY strip now distinguishes all four official windows without inventing
weekly data when the installed helper is on an older source contract. Weekly
absence is visible and honest (`7d --`), while reset metadata can still help a
user understand an unknown window. The normalized cache remains small and
privacy-safe, and the old two-slot cache remains readable during rollout.
