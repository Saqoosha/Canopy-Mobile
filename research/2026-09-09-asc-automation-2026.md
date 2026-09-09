# App Store Connect Automation in 2026: CLIs, MCP Servers, and Agent Skills

## Executive summary

The single most consequential fact for anyone automating App Store Connect (ASC) in 2026 is that **app-record creation is still not available in the official API** — Apple's own documentation tells developers not to use the API for it, the Apps collection exposes no `POST /v1/apps`, and an actual POST returns HTTP 403 with a "does not allow CREATE" error even from an Admin-role key ([App Store Connect API – Apps](https://developer.apple.com/documentation/appstoreconnectapi/apps), [Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236)). Everything that claims to create an app record — fastlane's `produce`, the `asc web apps create` command, agent skills that "set up a new app" — is driving Apple's private web/iris endpoints with a scraped cookie session, inheriting 2FA, session expiry, and undocumented-endpoint breakage. For the parts the API *does* cover, the 2026 leader for terminal and agent use is rorkai's `asc` CLI, backed by an official Claude Code plugin marketplace of ASC skills, with codemagic's `app-store-connect` as the mature CI-oriented alternative; Apple now ships a first-party MCP server, but it bridges Xcode's local toolchain (`xcrun mcpbridge`), not App Store Connect.

## Key findings

Ranked by confidence: items 1–8 survived unanimous adversarial verification against Apple primary sources; items 9+ come from single-angle synthesis and are marked where softer.

**Highest confidence — Apple primary sources, unanimous**

- There is no create endpoint for app records. Apple's Apps documentation instructs developers to create new apps on the App Store Connect website rather than through the API, and the collection documents only GET (list/read), PATCH (modify), and relationship endpoints ([App Store Connect API – Apps](https://developer.apple.com/documentation/appstoreconnectapi/apps)).
- A real POST attempt is rejected with `403 FORBIDDEN_ERROR` stating that the `apps` resource does not permit CREATE, with allowed operations listed as GET_COLLECTION, GET_INSTANCE, UPDATE. This is not a key-scope problem — an Admin-role ASC API key gets the same rejection ([Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236)).
- The only POST-shaped endpoint in the Apps collection concerns scheduled price changes, not app creation; the resource is documented as a management surface for apps that already exist ([App Store Connect API – Apps](https://developer.apple.com/documentation/appstoreconnectapi/apps)).
- A developer has filed Apple feedback FB24429185 asking for API-based app-record creation; it remained open as of 2026 ([Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236)).
- `altool` is deprecated **only for notarization** — Apple's technote points notarization at `notarytool` but explicitly tells developers to keep using `altool` for submitting apps to the App Store ([TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)). Treating `altool` as dead is a common and wrong assumption.
- Both `altool` and `notarytool` accept either an Apple ID app-specific password or an ASC API key (issuer UUID + key ID + `.p8`), conventionally stored at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`; `notarytool` ships with Xcode 13+ and is invoked via `xcrun` ([TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)). That technote was published 2023-04-11 and last revised 2024-02-05, so it carries no 2025–2026 revision.
- XcodeBuildMCP is actively maintained under Sentry, shipping v2.5.0 (May 7), v2.6.0 (June 1), v2.6.2 (June 2) and v2.7.0 (July 23), with v2.7.0 adding Xcode 27 Device Hub simulator support — it tracks current Apple toolchains ([getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP)).
- XcodeBuildMCP's scope is strictly local: build, test, simulator and device work. Its repo documents no App Store Connect API surface, no TestFlight upload, no app-record creation, and no ASC auth mechanism — device work leans on Xcode-configured signing. A documented limitation is that it disables Swift macro validation when invoking `xcodebuild` ([getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP)).
- The `asc` CLI authenticates with standard ASC API keys — team keys need an issuer ID, individual keys omit it — i.e. JWT key auth, not a scraped session, and separately offers an optional Apple ID web-session login for validation checks the public API cannot perform ([rorkai/App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI)).

**High confidence — corroborated across angles**

- Apple *does* ship a first-party MCP server as of Xcode 26.3 (Feb 2026): the bundled `xcrun mcpbridge` turns Xcode into an MCP endpoint over XPC (build, run/stop with debugger, build logs, LLDB, SwiftUI previews, Swift REPL, documentation search), enabled under Settings → Intelligence, and carried into Xcode 27 ([Xcode documentation](https://developer.apple.com/documentation/xcode)). Its scope stops at the local toolchain — **there is no Apple-shipped App Store Connect MCP**.
- WWDC 2025 Session 324 introduced a genuine Build Upload API (`POST /v1/buildUploads`, `POST /v1/buildUploadFiles`, chunked PUT, commit, plus a `BUILD_UPLOAD_STATE_UPDATED` webhook) that removes the `altool`/iTMSTransporter dependency and works from Linux with JWT auth alone ([WWDC25 Session 324](https://developer.apple.com/videos/play/wwdc2025/324/)). This is the most important change to the upload path in years and postdates the ASC docs page that still describes uploads as requiring Xcode or Transporter.
- Every independent line of evidence converges on web-session automation as the only route to app creation: `asc` deliberately split the command into a `web` group (`asc web apps create`) in v1.0 to mark it unofficial ([rorkai/App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI)); fastlane's `produce` reaches private endpoints that do not accept ASC API keys and therefore force interactive Apple ID login ([Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236) — one verifier of three doubted this attribution); and issues on rudrankriyam's CLI verify that Apple's own published OpenAPI snapshot through v4.4 (929 paths) contains `GET /v1/apps` and `PATCH /v1/apps/{id}` but no `POST /v1/apps` ([rudrankriyam/app-store-connect-cli](https://github.com/rudrankriyam/app-store-connect-cli)).

**Moderate confidence — single-angle synthesis**

- rorkai's `asc` is the 2026 category leader for terminal/agent use: ~7.1k stars, v5.1.0 shipped 2026-09-08, installable via Homebrew and winget ([rorkai/App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI)), and it is paired with a real Claude Code plugin marketplace of roughly 23 skills ([rorkai/app-store-connect-cli-skills](https://github.com/rorkai/app-store-connect-cli-skills)).
- fastlane is neither abandoned nor thriving: sponsorship from Google ended in 2021 and the project moved to the Mobile Native Foundation in 2023, leaving a large issue backlog, per a maintainer's own history write-up ([Connor Tumbleson's blog, Dec 2025](https://connortumbleson.com/)); releases nonetheless continue every few weeks, with 2.239.0 on 2026-09-04 and 2.235.0 in May 2026 raising the floor to Ruby 3.0+ ([fastlane releases](https://github.com/fastlane/fastlane/releases)). There is an open upstream discussion about moving Spaceship off `altool` onto the new Build Upload endpoints ([fastlane discussion #29928](https://github.com/fastlane/fastlane/discussions/29928)).
- The 2026 failure modes that most affect an AI agent are not rate limits but silent-success and silent-failure in the upload transport: Xcode 26's `altool` produced a run of reports where uploads fail with 409 validation errors or pick the wrong `apple_id` among similar bundle IDs, and where an HTTP 500 is returned after the upload actually succeeded ([fastlane issues](https://github.com/fastlane/fastlane/issues)). An agent that trusts exit codes will report the wrong outcome.

## Details

### Category 1 — Dedicated ASC CLI tools

The field has reshuffled since the older inventories. Two projects are effectively dead, two are healthy libraries rather than CLIs, and one new entrant dominates on activity and agent-friendliness.

| Tool | What it does | Creates an app record? | Auth | Last release (as researched) | Notable limits |
|---|---|---|---|---|---|
| [rorkai `asc`](https://github.com/rorkai/App-Store-Connect-CLI) | Broad ASC CLI: apps, versions, TestFlight, metadata, review | Only via `asc web apps create`, explicitly segregated into a `web` group as unofficial | ASC API key (`.p8` JWT); optional separate Apple ID web session for checks the API can't do | v5.1.0, 2026-09-08 | Web-session path inherits 2FA/expiry; API path cannot create apps |
| [codemagic `app-store-connect`](https://github.com/codemagic-ci-cd/cli-tools) | CI-oriented ASC + signing + publishing toolkit | No (API-only surface) | ASC API key JWT | v0.69.0, 2026-07-15 | Python/CI-shaped; less ergonomic as an interactive agent tool |
| [`xcrun altool`](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool) | Uploads/validates builds to App Store & TestFlight | No | App-specific password **or** ASC API key | Ships with Xcode | Deprecated for notarization only; error reporting is unreliable under Xcode 26 |
| [`notarytool`](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool) | Notarization only | No | Same two mechanisms | Ships with Xcode 13+ | Does **not** replace altool's upload function |
| [Transporter](https://apps.apple.com/us/app/transporter/id1450874784) | Apple's upload transport (app + `iTMSTransporter`) | No | ASC API key or Apple ID | 1.4.5, 2026-09-08 | Self-updating iTMSTransporter has caused unfixable upload bugs |
| [AvdLee/appstoreconnect-swift-sdk](https://github.com/AvdLee/appstoreconnect-swift-sdk) | Swift library over the ASC API | No | JWT | 4.4.3, 2026-08-22 | Library, not a CLI |
| [aaronsky/asc-swift](https://github.com/aaronsky/asc-swift) | Swift library over the ASC API; base for an ASC MCP server | No | JWT | 1.7.1, 2026-08-08 | Library, not a CLI |
| [tddworks/asc-cli](https://github.com/tddworks/asc-cli), [keremerkan/ascelerate](https://github.com/keremerkan/ascelerate) | Newer Swift CLI entrants | No | JWT | Fresh in 2026 | Small, unproven; details not independently verified |
| [ittybittyapps/appstoreconnect-cli](https://github.com/ittybittyapps/appstoreconnect-cli) | Older ASC CLI | No | JWT | Effectively dead since 2022 | Do not adopt |
| [tuist](https://tuist.dev), [xcodes](https://github.com/XcodesOrg/xcodes) | Project generation / Xcode version management | No | n/a | active | **No ASC surface at all** — scope these out of the comparison |

Two corrections to widespread assumptions belong here. First, `altool` being "deprecated" is a misreading of TN3147 — the deprecation is scoped to notarization, and Apple still documents `altool` for App Store submission ([TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)). Second, tuist and xcodes appear on tool lists for iOS release automation but have no App Store Connect functionality; tuist is complementary (project generation, previews, `tuist share`) and has even had an RFC for a fastlane plugin ([tuist](https://tuist.dev)).

The genuinely new direction in 2026 is Ruby-free ASC tooling — Go-based publishers and single-shell-command pipelines — adopted specifically because they are easier for an AI agent to drive than fastlane's Ruby DSL and interactive prompts.

### Category 2 — MCP servers

The decisive finding is that Apple entered this category. Xcode 26.3 (Feb 2026) ships `xcrun mcpbridge`, exposing roughly twenty tools over XPC to Claude Code, Codex, Cursor and Gemini CLI once MCP is enabled under Settings → Intelligence ([Xcode documentation](https://developer.apple.com/documentation/xcode)). That reframes the third-party build servers: [lapfelix/XcodeMCP](https://github.com/lapfelix/XcodeMCP) has repositioned itself as a `--sidekick-only` complement to Apple's server rather than a replacement.

| Server | Category | ASC surface? | Creates an app record? | Auth | Status |
|---|---|---|---|---|---|
| Apple `xcrun mcpbridge` | Build/toolchain | None | No | Local XPC to Xcode | Ships in Xcode 26.3+, carried into 27 |
| [getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) | Build/simulator/device | None documented | No | None (Xcode signing) | v2.7.0, active; disables Swift macro validation |
| [joshuayoes/ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp) | Simulator control | None | No | n/a | v2.1.0 |
| [lapfelix/XcodeMCP](https://github.com/lapfelix/XcodeMCP) | Xcode automation | None | No | n/a | Repositioned as complement to Apple's server |
| Heimdall / erayendes ASC MCP | App Store Connect | ~982 operations generated from Apple's own OpenAPI spec v4.4.1 | No — no create-app tool exists in the spec | `.p8` → ES256 JWT | Active; hits client tool-count ceilings |
| [zelentsov-dev/asc-mcp](https://github.com/zelentsov-dev/asc-mcp) | App Store Connect (Swift) | Yes | No | `.p8` JWT | v4.1.x |
| [mikusnuz/app-publish-mcp](https://github.com/mikusnuz/app-publish-mcp) | Publishing | Yes | No — states the first release of a new app still needs manual ASC setup | `.p8` JWT | Active |
| [cristianoaredes/mcp-apple-store](https://github.com/cristianoaredes/mcp-apple-store) | App Store Connect | Yes | No | `.p8` JWT | Active |

Two structural observations. Every ASC MCP server uses a real API key with ES256 JWT signing — none of them uses a scraped web session, which is exactly why none of them can create an app. And because several are generated wholesale from Apple's OpenAPI spec, they expose hundreds of tools and run into per-client tool-count limits; expect to need filtering before pointing Claude Code at one.

### Category 3 — Claude Code skills and plugins

This category is real and consolidating into two shapes.

**Skill packs wrapping a CLI.** rorkai ships a genuine Claude Code plugin marketplace — `claude plugin marketplace add rorkai/app-store-connect-cli-skills` — with roughly 23 skills over the `asc` CLI ([rorkai/app-store-connect-cli-skills](https://github.com/rorkai/app-store-connect-cli-skills)); rshankras, greenstevester and glebis publish fastlane- or ASC-shaped skills of narrower scope.

**MCP + skill hybrids.** XcodeBuildMCP now ships agent skills with an `xcodebuildmcp init` auto-installer that detects Claude Code, Cursor and Codex ([getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP)). Blitz is an open-source native macOS app exposing roughly 35 MCP tools that drives App Store Connect's *web session* for the operations the public API cannot perform ([blitzdotdev/blitz-mac](https://github.com/blitzdotdev/blitz-mac)).

The agent ecosystem documents the API gap on itself: rorkai's `asc-app-create-ui` skill exists as browser automation precisely because there is no API path, and the locally installed variant reaches App Store Connect's internal iris API using a web session borrowed from Blitz. The standard agent workaround for app creation is web-session automation, full stop.

### The upload path is where the real 2026 change is

The API question that matters most for agents is no longer "can I create an app" (settled: no) but "how do I upload." Apple's ASC documentation page still describes uploads as requiring Xcode, Transporter, or the Transporter app, with ASC API keys usable for auth alongside them ([App Store Connect API – Apps](https://developer.apple.com/documentation/appstoreconnectapi/apps)). WWDC 2025 Session 324 superseded that with a chunked Build Upload API that needs only JWT auth and runs on Linux ([WWDC25 Session 324](https://developer.apple.com/videos/play/wwdc2025/324/)). A Japanese team documented replacing fastlane's `deliver` with a custom action against those endpoints after hitting an unfixable self-updating iTMSTransporter bug, and fastlane itself has an open discussion about the same migration ([fastlane discussion #29928](https://github.com/fastlane/fastlane/discussions/29928)). For an agent-driven pipeline in 2026, the Build Upload API is the path that avoids the Xcode/Transporter dependency and its unreliable error surface entirely.

### Failure modes an agent must handle

- **Web-session fragility.** Anything creating an app record inherits Spaceship's scraped cookie session: 2FA prompts, roughly 30-day session expiry, IP/geo mismatch rejections on CI, and reactive breakage when Apple changes an undocumented endpoint. `SPACESHIP_SKIP_2FA_UPGRADE` exists solely to paper over one such change ([Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236)).
- **Silent success and silent failure in uploads.** Xcode 26-era `altool` reports HTTP 500 after a successful upload, and picks the wrong `apple_id` when bundle IDs are similar ([fastlane issues](https://github.com/fastlane/fastlane/issues)). Exit codes are not trustworthy evidence for an agent; verify by querying build state through the API afterwards.
- **Rate limiting.** The API documents `X-Rate-Limit` headers and `Retry-After`; roughly 300–350 requests/minute is observed before 429s. Milder than the above, but generated MCP servers with hundreds of tools can burn through it in enumeration loops.
- **Role-scoped 403s.** Developer-role keys cannot create apps or versions; App Manager keys scoped to "Selected Apps" return 403 outside that scope. A separate `403 REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` appears whenever Apple ships a new license agreement — this one blocks everything until a human accepts it in the web UI.

### Recommended stack for an agent-driven workflow

For Claude Code or a similar agent, the shape that follows from the evidence is: `asc` CLI plus its skill marketplace for ASC record management and TestFlight metadata ([rorkai/App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI)); Apple's `xcrun mcpbridge` or XcodeBuildMCP for local build/test/simulator ([Xcode documentation](https://developer.apple.com/documentation/xcode), [getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP)); the WWDC25 Build Upload API for the upload leg if you can write the client, `altool` with an ASC key otherwise ([WWDC25 Session 324](https://developer.apple.com/videos/play/wwdc2025/324/), [TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)); and a one-time human step in the App Store Connect web UI for creating each new app record — or, accepting the fragility, a web-session tool like Blitz or `asc web apps create` ([blitzdotdev/blitz-mac](https://github.com/blitzdotdev/blitz-mac)).

## Conflicts and open questions

- **Apple's docs contradict Apple's own 2025 announcement on uploads.** The ASC Apps documentation states that the API cannot upload builds and that Xcode or Transporter is required ([App Store Connect API – Apps](https://developer.apple.com/documentation/appstoreconnectapi/apps)) — one of three verifiers doubted this claim, and the doubt looks justified: WWDC 2025 Session 324 introduced `POST /v1/buildUploads` and companion endpoints that do exactly that ([WWDC25 Session 324](https://developer.apple.com/videos/play/wwdc2025/324/)). The most likely reading is that the docs page predates or was not updated for the Build Upload API. Treat the doc statement as describing the legacy path, not a current constraint.
- **fastlane `produce`'s exact mechanism is attributed from a forum thread, not from fastlane's source.** The claim that `produce` uses private endpoints that reject ASC API keys drew one dissent of three ([Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236)). The conclusion — that `produce` needs an Apple ID session rather than a `.p8` key — is corroborated by every other angle, but the precise endpoint description should be confirmed against Spaceship's source before relying on it.
- **fastlane's health reads differently depending on which signal you pick.** The maintainer's own account describes lost sponsorship and a heavy backlog ([Connor Tumbleson's blog](https://connortumbleson.com/)), while the release feed shows regular shipping through 2026 ([fastlane releases](https://github.com/fastlane/fastlane/releases)). Both are true; the honest summary is that fastlane is maintained but its upload foundation is becoming legacy, not that it is abandoned.
- **Repo-level details for several third-party MCP servers and newer Swift CLIs were not independently re-verified** — specifically Heimdall/erayendes, zelentsov-dev/asc-mcp, mikusnuz/app-publish-mcp, cristianoaredes/mcp-apple-store, tddworks/asc-cli and keremerkan/ascelerate. Version numbers and tool counts for these come from a single research angle. Confirm before adopting.
- **Whether Apple intends to close the app-creation gap is unknown.** FB24429185 is open with no public response ([Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236)), and no release note through API v4.4.1 adds a create endpoint. There is no signal either way.
- **The stability of the private iris endpoint is unmeasured.** Every app-creation workaround depends on it, and by construction it carries no compatibility guarantee. No source quantifies how often it breaks.
- **Nothing was refuted during verification** — no claim was killed by 2/3 or more verifiers, so there are no corrections to report in that category.

## Sources

- [App Store Connect API – Apps](https://developer.apple.com/documentation/appstoreconnectapi/apps) — Apple's reference for the apps resource; states plainly that new apps must be created on the website and lists only GET/PATCH operations.
- [Apple Developer Forums thread 780236](https://developer.apple.com/forums/thread/780236) — Developer report and Apple-hosted discussion of the 403 "does not allow CREATE" response to `POST /v1/apps`, including radar FB24429185.
- [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool) — Apple technote scoping `altool`'s deprecation to notarization and documenting `.p8` key auth for both tools.
- [WWDC25 Session 324](https://developer.apple.com/videos/play/wwdc2025/324/) — Introduces the chunked Build Upload API that removes the Transporter/altool dependency.
- [Xcode documentation](https://developer.apple.com/documentation/xcode) — Reference surface for Xcode 26.3's built-in MCP bridge (`xcrun mcpbridge`).
- [rorkai/App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI) — The 2026 leading ASC CLI; JWT key auth plus a deliberately segregated `web` command group for unofficial operations.
- [rorkai/app-store-connect-cli-skills](https://github.com/rorkai/app-store-connect-cli-skills) — Claude Code plugin marketplace wrapping that CLI in ~23 agent skills.
- [getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) — Sentry-maintained MCP server and CLI for local iOS/macOS build, test and simulator work; no ASC surface.
- [codemagic-ci-cd/cli-tools](https://github.com/codemagic-ci-cd/cli-tools) — Codemagic's CI-oriented ASC and signing toolkit.
- [AvdLee/appstoreconnect-swift-sdk](https://github.com/AvdLee/appstoreconnect-swift-sdk) — Actively maintained Swift client library for the ASC API.
- [aaronsky/asc-swift](https://github.com/aaronsky/asc-swift) — Swift ASC library that underpins at least one ASC MCP server.
- [rudrankriyam/app-store-connect-cli](https://github.com/rudrankriyam/app-store-connect-cli) — Issues here verify Apple's published OpenAPI snapshot contains no `POST /v1/apps`.
- [blitzdotdev/blitz-mac](https://github.com/blitzdotdev/blitz-mac) — Open-source macOS app exposing ~35 MCP tools driven by an App Store Connect web session.
- [fastlane discussion #29928](https://github.com/fastlane/fastlane/discussions/29928) — Upstream discussion of moving Spaceship off `altool` onto the Build Upload endpoints.
- [fastlane releases](https://github.com/fastlane/fastlane/releases) — Release feed showing continued shipping through 2026 (2.239.0, 2026-09-04).
- [fastlane issues](https://github.com/fastlane/fastlane/issues) — Source of the 2025–2026 Xcode 26 upload failure reports (409 validation, wrong `apple_id`, HTTP 500 after success).
- [Connor Tumbleson's blog](https://connortumbleson.com/) — Maintainer's December 2025 account of fastlane's funding and governance history.
- [lapfelix/XcodeMCP](https://github.com/lapfelix/XcodeMCP), [joshuayoes/ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp) — Third-party Xcode and simulator MCP servers; no ASC functionality.
- [zelentsov-dev/asc-mcp](https://github.com/zelentsov-dev/asc-mcp), [mikusnuz/app-publish-mcp](https://github.com/mikusnuz/app-publish-mcp), [cristianoaredes/mcp-apple-store](https://github.com/cristianoaredes/mcp-apple-store) — ASC MCP servers, all `.p8` JWT authenticated, none able to create an app record.
- [Transporter](https://apps.apple.com/us/app/transporter/id1450874784), [tuist](https://tuist.dev), [XcodesOrg/xcodes](https://github.com/XcodesOrg/xcodes) — Apple's upload transport, and two tools frequently listed in this space that have no ASC surface.