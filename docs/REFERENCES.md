# Reference Analysis: GaugeZ & LimitBar

Technical analysis of [GaugeZ](https://github.com/vzandli/GaugeZ) and [limitbar](https://github.com/dancik/limitbar) for architecting **AdaptaPE AI Tracker** (native macOS menu bar app, SwiftUI `MenuBarExtra`, Swift 6, macOS 14+).

---

## 1. Menu Bar & Tray Architecture

### LimitBar
- **Language / Stack:** Swift 6 (`Package.swift`, `swiftLanguageMode(.v5)`, macOS 14+), AppKit (`NSStatusBar`, `NSPanel`, `NSHostingView`) + SwiftUI + Combine.
- **Menu Bar Item:** Creates `NSStatusItem(withLength: NSStatusItem.variableLength)` (`AppDelegate.swift:26`). Houses a SwiftUI `TrayView` inside `PassThroughHostingView<TrayView>` (`AppDelegate.swift:28-32, 160-162`), where `hitTest(_:) -> nil` passes clicks through to the status bar button.
- **Window Type & Appearance:** Custom borderless `NSPanel` (`AppDelegate.swift:57-66`):
  - `styleMask: [.nonactivatingPanel, .borderless]`
  - `level = .popUpMenu`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`
  - `hidesOnDeactivate = false`, backdrop `NSVisualEffectView` with `.popover` material, 16pt corner radius.
- **Hide-on-Blur & Interaction:**
  - Hover: `NSTrackingArea` on status button (`zone: "item"`) and panel (`zone: "panel"`). 150 ms hover delay opens panel; 250 ms exit delay hides panel (`AppDelegate.swift:137-156`).
  - Click to Pin: Clicking button toggles `pinned` state. Outside click dismissed via `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` (`AppDelegate.swift:118-133`).
  - `.nonactivatingPanel` prevents stealing focus from active editors/terminal.
- **Activation Policy:** `app.setActivationPolicy(.accessory)` (`main.swift:64`).
- **Launch at Login:** Uses `SMAppService.mainApp.register()` / `.unregister()` (`Views.swift:80, 108-113`).

### GaugeZ
- **Language / Stack:** Swift 6, AppKit + SwiftUI + Combine. Dual presentation: Status Item + Screen Edge/Notch Rail overlay.
- **Menu Bar Item:** Uses `NSStatusBar.system.statusItem(withLength: ...)` with an `NSMenu` (`makeMenu()`, `AppDelegate.swift:260-339`). Rebuilds lines dynamically on `NSMenuDelegate` callbacks (`AppDelegate.swift:342-423`). The tray button dynamically renders a CoreGraphics bitmap image showing provider mini-meters (`MenuBarReadings.swift:10-84`).
- **Window Type (Edge/Notch Rail):** Custom borderless `NSPanel` (`EdgePanelController.swift:72-77, 1166-1169`):
  - `styleMask: [.borderless, .nonactivatingPanel]`
  - `level = .statusBar`, `isOpaque = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
  - `canBecomeKey = false`, `canBecomeMain = false`.
- **Hide-on-Blur & Interaction:** Manages pointer hit-testing via global/local mouse monitors (`NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged])`). Panel sets `ignoresMouseEvents = true` by default and routes clicks only over drawn content (`EdgePanelController.swift:135-160`).
- **Activation Policy:** Dynamic: `.accessory` by default, or `.regular` if Dock icon is enabled (`AppDelegate.swift:29, 142-150`).
- **Launch at Login:** `SMAppService.mainApp.register()` / `.unregister()`, actively tracking `SMAppService.mainApp.status == .requiresApproval` (`UsageStore.swift:344-368, 417`).

---

## 2. Provider Data Collection Matrix

| Provider | Data Source | Auth Method | Fields Read | Refresh Interval | File:Line Pointer |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **ChatGPT / Codex (Web)** | `GET https://chatgpt.com/backend-api/wham/usage` | Bearer token + `ChatGPT-Account-Id` from `~/.codex/auth.json` (`tokens.access_token`, `tokens.account_id`) | `rate_limit.primary_window`, `secondary_window` (`used_percent`, `limit_window_seconds`, `reset_at`, `reset_after_seconds`); extras: `additional_rate_limits`, `code_review_rate_limit` | Active: 60s<br>Idle: 300s | `GaugeZ:CodexUsageProvider.swift:62-113, 216-254, 275-350` |
| **ChatGPT / Codex (Credits & Tokens)** | `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`<br>`GET https://chatgpt.com/backend-api/wham/profiles/me` | Bearer token + `ChatGPT-Account-Id` from `~/.codex/auth.json` | `rate-limit-reset-credits`: `available_count`, `credits[].expires_at`<br>`profiles/me`: `stats.daily_usage_buckets[].tokens` | Coincides with web refresh | `GaugeZ:CodexUsageProvider.swift:123-154, 280-292` |
| **ChatGPT / Codex (CLI Logs)** | Local JSONL: `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | None (reads local disk tail, up to 256 KB) | Line containing `"rate_limits"` -> `payload.rate_limits.primary`, `secondary` (`used_percent`, `resets_at`, `window_minutes`) | Checked every 30s; parsed if `mtime` changed | `limitbar:Fetchers.swift:165-188` |
| **ChatGPT / Codex (App-Server)** | Local CLI RPC: Subprocess `codex app-server` | Handled internally by `codex` CLI | JSON-RPC method `account/rateLimits/read` -> `rateLimits.primary`, `secondary` (`usedPercent`, `resetsAt`, `windowDurationMins`); `rateLimitResetCredits.credits[].expiresAt` | Active: 60s<br>Idle: 30m | `limitbar:Fetchers.swift:190-225`<br>`GaugeZ:CodexUsageProvider.swift:42-60` |
| **Claude / Claude Code (Web)** | `GET https://api.anthropic.com/api/oauth/usage`<br>`GET https://api.anthropic.com/api/oauth/profile` | Bearer token from Keychain (`Claude Code-credentials` or `Claude Safe Storage` decrypted) | `limits[]` (`kind`: `"session"`, `"weekly_all"`, `"weekly_opus"`; `percent` / `utilization`, `resets_at`); map keys: `five_hour`, `seven_day`, `extra_usage`. Profile: `account.email_address`, `organization.rate_limit_tier` | Min floor 300s (rate limit guard) | `GaugeZ:ClaudeUsageProvider.swift:17-45, 120-210, 470-580` |
| **Claude (Desktop Cache)** | Local files: `~/Library/Application Support/Claude/config.json` + `plan-usage-history.json` | AES-128-CBC decrypt of `oauth:tokenCacheV2` via PBKDF2 key from Keychain `Claude Safe Storage` | `tokenCache` (`token`, `expiresAt`, `subscriptionType`); fallback log reads historical bucket usage | Read on launch/fallback; preferred age <15m | `GaugeZ:ClaudeUsageProvider.swift:40-48, 275-430` |
| **Claude Code (Statusline)** | Local cache: `~/Library/Caches/limitbar/claude-status.json` | None (written by Claude Code statusline hook via `limitbar --statusline`) | `rate_limits.five_hour`, `seven_day` (`used_percentage` / `percent`, `resets_at`) | 30s (free disk read) | `limitbar:main.swift:35-59`<br>`limitbar:Fetchers.swift:47-59` |
| **Claude Code (CLI /usage)** | CLI subprocess: `claude -p /usage --output-format json --max-turns 1` | CLI auth session | Regex parse stdout: `"Current session:\s*(\d+)%\s*used · resets (.*?)\s*\((.*?)\)"`, `"Current week (all models)"` | Max once per 20 min | `limitbar:Fetchers.swift:65-128` |
| **Gemini / Antigravity (LSP)** | `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` | Port & CSRF token from running process `language_server_macos_arm64` via `lsof -nP -iTCP -sTCP:LISTEN` + `--csrf_token` | `Connect-Protocol-Version: 1`, `X-Codeium-Csrf-Token: <token>`. Quota buckets per model group (`remaining_fraction`, `reset_time`) | Active: 60s<br>Idle: 300s | `GaugeZ:AntigravityUsageProvider.swift:18-200` |
| **Gemini / Antigravity (Cloud API)** | `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` | Bearer token from Keychain (`service: "gemini"`, `account: "antigravity"`) or `~/.gemini/oauth_creds.json` | Body: `{"project": "<projectId>"}`. Returns quota summary per model group | Active: 60s<br>Idle: 300s | `GaugeZ:AntigravityUsageProvider.swift:65-115`<br>`GaugeZ:AntigravityCredentials.swift:1-118` |
| **Gemini / Antigravity (CLI Quota)** | CLI subprocess: `agy -p /quota --output-format json` (in `sandbox-exec`) | Managed by `agy` CLI | `command.data.groups[].buckets[]` (`remaining_fraction`, `window` ["5h"], `reset_time`) | 5m if active, 30m idle | `limitbar:Fetchers.swift:134-160` |
| **Cursor** | `GET https://cursor.com/api/usage-summary`<br>Legacy: `GET https://cursor.com/api/usage?user=<userID>` | Cookie: `WorkosCursorSessionToken=<userID>%3A%3A<accessToken>` from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `billingCycleEnd`, `membershipType`, `individualUsage.plan.totalPercentUsed` (or `used`/`limit`), `individualUsage.onDemand`, `individualUsage.overall`, `teamUsage.onDemand` | Active: 60s<br>Idle: 300s | `GaugeZ:CursorUsageProvider.swift:12-104, 108-150, 230-290` |
| **GitHub Copilot** | `GET https://api.github.com/copilot_internal/user` | Bearer token from `~/.config/gh/hosts.yml` (`github.com.oauth_token`) or `GH_TOKEN` or `gh auth token` | `quota_snapshots.premium_interactions`, `chat`, `completions` (`entitlement`, `remaining`, `used`, `unlimited`, `reset_date`); `quota_reset_date_utc` | Active: 60s<br>Idle: 300s | `GaugeZ:GitHubCopilotProvider.swift:6-45, 59-170, 172-240` |
| **Grok (xAI)** | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`<br>OR CLI ACP: `grok agent stdio` (`_x.ai/billing`) | Web: Bearer token from `~/.grok/auth.json`<br>CLI: ACP JSON-RPC inside `sandbox-exec` | `creditUsagePercent` (0–100), `currentPeriod.end` / `billingPeriodEnd`, `subscription_tier` | Web: 300s floor<br>CLI: 5m busy / 30m idle | `GaugeZ:GrokUsageProvider.swift:14-55, 109-150`<br>`limitbar:Fetchers.swift:229-250` |
| **Ollama (Cloud)** | `GET https://ollama.com/api/usage` | Bearer token from `OLLAMA_API_KEY` or user settings | `limits.monthly.usage` (fraction 0-1), `limits.weekly.usage`, `limits.session.usage` (no reset timestamp provided) | Active: 60s<br>Idle: 300s | `GaugeZ:OllamaUsageProvider.swift:10-70, 75-130` |
| **Local Models (Ollama / LM Studio)** | Local HTTP endpoints:<br>Ollama: `GET http://127.0.0.1:11434/api/tags` & `api/ps`<br>LM Studio: `GET http://127.0.0.1:1234/v1/models` | None (Local loopback unauthenticated) | Running models, VRAM usage, active session status (no external rate limits) | Active: 30s<br>Idle: 60s | Native local integration pattern |

---

## 3. Cookie & Token Extraction Mechanisms & Security Caveats

### How Tokens and Cookies Are Extracted
Neither GaugeZ nor LimitBar extracts browser cookie databases (Chrome/Safari SQLite) or loads hidden WebViews:
1. **Direct macOS Keychain Access (`SecItemCopyMatching`):**
   - **Claude Code:** Service `Claude Code-credentials` (reads JSON `claudeAiOauth` -> `accessToken`, `expiresAt`, `subscriptionType`).
   - **Claude Desktop:** Service `Claude Safe Storage` (or `Electron Safe Storage`). Decrypts `config.json` via AES-128-CBC using a key derived via PBKDF2 (HMAC-SHA1, 1003 rounds, salt `"saltysalt"`, IV = 16 spaces).
   - **Antigravity:** Service `"gemini"`, account `"antigravity"` (prefixed `go-keyring-base64:`, payload has `access_token`, RFC3339 `expiry`).
   - **Cursor CLI:** Service `"cursor-access-token"`, account `"cursor-user"`.
2. **Local SQLite State Databases:**
   - **Cursor Editor:** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`. Reads table `ItemTable` for `cursorAuth/accessToken` and `cursorAuth/stripeMembershipAuthId`. Synthesizes Cookie: `WorkosCursorSessionToken=<userID>%3A%3A<accessToken>`.
   - **Devin / Windsurf:** `~/Library/Application Support/Devin/User/globalStorage/state.vscdb`.
   - Opened using WAL-friendly read-only SQLite flags (`sqlite3_open_v2` with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`).
3. **Plaintext CLI Auth Files:**
   - Codex: `~/.codex/auth.json` (`tokens.access_token`, `tokens.account_id`, `tokens.id_token`).
   - Grok: `~/.grok/auth.json` (keyed by auth scope).
   - GitHub: `~/.config/gh/hosts.yml` (YAML parser extracts `oauth_token` under `github.com`).
   - Antigravity: `~/.gemini/oauth_creds.json`.
4. **Sandboxed CLI Execution (LimitBar approach):**
   - LimitBar never reads other apps' Keychain or auth files. Instead, it executes the vendor's own binary (`agy`, `codex app-server`, `grok agent stdio`) inside a locked macOS kernel sandbox (`/usr/bin/sandbox-exec -f cli.sb`) which permits only the tool's own directory and state directory.
   - For Claude Code, LimitBar relies on an opt-in statusline helper (`limitbar --statusline`) writing `~/Library/Caches/limitbar/claude-status.json`.

### Security & Operational Caveats
- **App Sandbox Restriction:** macOS App Sandbox strictly blocks access to arbitrary home files (`~/.codex/`, `~/.config/gh/`, `~/Library/Application Support/Cursor/`) and third-party Keychain entries. AdaptaPE AI Tracker **must be distributed without App Sandbox** (direct download / Developer ID notarization) to access these sources.
- **Keychain Access Prompts:** Reading foreign Keychain services without explicit user authorization can prompt system permission dialogs. Always query Keychain with fail-fast flags (e.g. `kSecUseAuthenticationUIFail`) or only on explicit user consent.
- **Fragility of Internal APIs:** Endpoints (`chatgpt.com/backend-api/wham/usage`, `cursor.com/api/usage-summary`) are private and subject to breaking changes, Cloudflare protection, or 403 blocks on non-browser user agents.
- **Token Lifetimes & Refresh:** Borrowed tokens expire. Neither app implements custom OAuth refresh flows; they rely on the host CLI/app to rotate tokens, or background-spawn `claude -p` to trigger CLI self-refresh.

---

## 4. Patterns Worth Copying vs. Avoid for AdaptaPE AI Tracker

### Patterns Worth Copying
1. **Layered Data Acquisition:**
   - *Tier 1 (Free & Fast):* Read local session logs (`~/.codex/sessions/*.jsonl`, Claude statusline hook, `plan-usage-history.json`). Zero network overhead and zero rate-limiting risk.
   - *Tier 2 (Direct HTTP):* Query the provider usage endpoint (`api.anthropic.com`, `chatgpt.com/backend-api/wham/usage`, `cursor.com`) using ephemeral `URLSession` (short 15s timeout, no cache, no cookies).
   - *Tier 3 (Local RPC / Subprocess):* Fallback to CLI app-server (`codex app-server`, `agy -p /quota`).
2. **Adaptive Activity-Based Polling:**
   - Watch directory modification timestamps (`mtime`) on session folders (`~/.codex/sessions`, `~/.gemini/antigravity-cli/conversations`). Only poll actively (60s) when the tool is being used; otherwise idle at 20–30 min.
   - Hook into `NSWorkspace.willSleepNotification` (halt timers) and `didWakeNotification` (refresh immediately).
   - Schedule polls immediately after a known `resetsAt` timestamp.
3. **Robust Login Item Registration:**
   - Use `SMAppService.mainApp.register()` and `.unregister()`. Check `status == .requiresApproval` and guide users to `SMAppService.openSystemSettingsLoginItems()`.
4. **Non-Activating Window Behavior:**
   - If extending beyond standard SwiftUI `MenuBarExtra`, use `NSPanel` with `.nonactivatingPanel` so clicking the menu bar never steals keyboard focus from code editors or terminals.

### Anti-Patterns to Avoid
1. **Frequent Heavy Subprocess Execution:**
   - Avoid executing `claude -p /usage` on an automatic timer. Spawning Node.js runtimes every 1–5 minutes causes noticeable CPU spikes and battery drain.
2. **Unsandboxed CLI Execution:**
   - Never execute user CLI tools in user workspace paths without stripping hooks and MCP configs (`--restricted --strict-mcp-config`). LimitBar demonstrated that running `claude` in an arbitrary directory can accidentally trigger user-configured MCP servers or bash hooks.
3. **Storing Tokens Locally:**
   - Do not save extracted OAuth tokens or cookies to AdaptaPE AI Tracker's own disk cache. Keep tokens ephemeral in memory and save only computed percentages, window descriptions, and reset dates to disk.
4. **Monolithic Overlay Windows:**
   - GaugeZ implements a complex 1200-line screen-edge / notch tracking panel with manual coordinate conversion across multi-display setups. For AdaptaPE AI Tracker, prefer SwiftUI 6 `MenuBarExtra(..., isInserted: ...)` with `.window` style, falling back to a clean `NSPanel` popover only if custom positioning is required.
