# ADR 0004: Read personal Pro Analytics from an app-owned persistent web session

- Status: Accepted
- Date: 2026-07-18
- Refined by: [ADR 0006](0006-low-energy-refresh-and-storage-hot-paths.md)

## Context

Codex Monitor needs the personal 7-day Turns total, Skills usage count, Plugin
call count, daily Surface/model Turns, and daily Skill calls shown by Codex Analytics. The
authenticated Enterprise Analytics API reference is not available to the
current personal Pro account. After successful MFA, the OpenAI Admin Portal
returned `需要访问权限`, and the public product guidance limits Codex Enterprise
Analytics API access to enabled Enterprise workspaces with a matching
organization key.

The personal Pro page at
`https://chatgpt.com/codex/cloud/settings/analytics` does expose the requested
metrics. KPI values are visible text. Model, Surface, and Skill values are
available as daily rows in the user-visible Recharts Tooltips. There is no
documented API or download contract for this personal view.

## Decision

Use a visible, app-owned `WKWebView` as an explicitly interactive provider for
personal Pro Analytics:

1. Load only the documented user-facing Analytics URL and normal authentication
   hosts. Do not discover, call, or persist undocumented page endpoints.
2. Use the app-owned default `WKWebsiteDataStore` so a completed login can be
   reused after restart. Never read or copy Chrome/Safari cookies. Provide a
   visible action that clears this app's WebKit website data.
3. Extract only a whitelist of visible metrics. Select the seven-day range,
   read the three KPI values, then sample visible daily Tooltips for `By model`,
   `By surface`, and `Skills used`.
4. Report `COMPLETE` only if all charts yield the same seven dates, model and
   Surface sums equal Turns, and Skill sums equal Skills used. Retain validated
   partial daily points without synthesizing missing zeroes.
5. Cache the last successful snapshot in memory for 30 minutes. Refresh on
   detail presentation after expiry or on explicit refresh. Do not add a timer
   or hidden background browser work.
6. Keep web quality and login state entirely separate from local task, quota,
   Token, and RUN/IDLE state.
7. Treat ChatGPT login as an SPA flow: perform bounded readiness checks after
   each navigation, and make manual reload navigate to the exact Analytics URL
   instead of refreshing an arbitrary ChatGPT page. Keep a deterministic chart
   layout size before the retained browser window is first attached so a
   detail-triggered refresh can reuse a persisted login after app restart.
8. Sample chart positions inside the SVG clip bounds at up to twice the
   expected daily density, deduplicate visible Tooltip dates, and stop after
   seven unique days. A missing date remains missing rather than becoming zero.
9. Render the normalized daily data with native Swift Charts in a separate,
   vertically scrollable Analytics detail page. Keep a 48-point KPI entry on
   the Codex page and retain the existing visible WebKit window for login and
   source verification; do not create a second embedded WebKit.

## Security and privacy boundary

- Codex Monitor never reads Chrome/Safari cookies, passwords, auth tokens, raw
  HTML, prompts, responses, or account identifiers.
- The provider returns only counts, names, date labels, and the browser time
  zone. The app does not write the web snapshot to disk, logs, or diagnostics.
- Main-frame navigation is HTTPS-only and limited to ChatGPT/OpenAI plus common
  authentication providers. A blocked navigation fails closed.
- The visible login window explains that the session persists inside this
  app's WebKit store while parsed Analytics values remain memory-only. Its
  destructive “Clear Sign-in” action requires confirmation and does not affect
  Chrome or Safari.

## Consequences

- Personal Pro users can see official cross-surface aggregates without an
  Enterprise key.
- Page DOM or chart-library changes can break extraction. This is reported as
  `PARTIAL`, `STALE`, or `UNAVAILABLE`; it is not silently repaired with local
  estimates.
- The official page may expose fewer than seven interactive daily points. The
  native chart keeps the verified points and reports truthful `PARTIAL` coverage
  until the page itself exposes the missing date.
- Users normally authenticate once and can explicitly clear the retained app
  session at any time.
- This provider is less stable than a documented API. If OpenAI later exposes a
  supported personal Analytics API or export, it should replace the DOM adapter
  behind the existing provider protocol without changing the normalized UI
  model.

## Rejected alternatives

- **Enterprise Analytics API:** unavailable to the current personal Pro account.
- **Ordinary Platform API key:** does not grant Enterprise Analytics access and
  cannot be substituted for a matching workspace organization key.
- **Chrome cookie or profile reuse:** crosses browser credential boundaries and
  is not acceptable.
- **Ephemeral WebKit session:** minimizes persistence but forces a full login
  after every app restart; rejected after user validation of the workflow.
- **Undocumented network endpoint replay:** would couple the app to an internal
  contract and require extracting browser authentication.
- **Direct webpage embedding:** duplicates or reparents authenticated WebKit
  content inside a 520-point HUD, increasing compositor cost and coupling the
  layout to undocumented page DOM. Native charts keep the visible source while
  preserving the existing single login window.
- **Local-only replacement:** stable but omits Cloud/Mobile and cannot claim the
  same official totals; it remains a separate local metric source.
