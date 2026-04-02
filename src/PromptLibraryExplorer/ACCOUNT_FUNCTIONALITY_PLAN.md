# User Account Functionality Plan

## Goal
Add native user account functionality to PromptLibrary Explorer so the app can authenticate against `artofficial.world`, show account status inside the macOS app, and later call Art Official generation endpoints using the authenticated session.

The first visible milestone is an **Account page** that shows:
- signed-in / signed-out state
- current subscription tier
- credits remaining / credits used
- account email or display name
- entry points to sign in, sign out, refresh account state, and open billing/account management on the website

## Current State
- The native Swift app is a local-file explorer with no networking layer, no auth/session model, and no account UI.
- There is no existing API client, token storage, or remote configuration in the Swift package.
- The app already has custom modal surfaces (`SettingsView`, `HelpView`) and a shared `ExplorerViewModel`, so account functionality should follow that presentation model.
- The Swift package currently has no external dependencies, so the first version should prefer Apple frameworks plus `URLSession`.

## Proposed Product Shape

### User-facing behavior
- Add an **Account** surface accessible from the app menu and from a header or settings entry point.
- If signed out:
  - show a short explanation of why sign-in is needed
  - show `Sign In` and `Create Account` actions
- If signed in:
  - show account identity
  - show subscription tier
  - show credits summary
  - show last refresh time
  - show `Manage Subscription`, `Open Website`, `Refresh`, and `Sign Out`
- Account state should persist between launches.
- Generation features should be gated behind a valid authenticated session and visible account state.

### Authentication approach
- Use **browser-based web authentication** rather than embedding credentials in-app.
- Preferred native flow:
  1. start login from the app
  2. open `artofficial.world` auth in `ASWebAuthenticationSession`
  3. receive callback into the app using a custom URL scheme or universal link
  4. exchange callback data for an app session/token pair
  5. store session credentials securely in Keychain
- Do not store auth tokens in `UserDefaults` or app settings storage.

## Native App Architecture

### New models
- `AccountSession`
  - access token
  - refresh token if supported
  - expiry
  - user id
- `AccountProfile`
  - email
  - display name
  - subscription tier
  - billing status
  - credits remaining
  - credits used in current period
  - credits reset date if available
- `AccountState`
  - signed out / loading / signed in / error
  - current profile
  - session freshness

### New services
- `AccountService`
  - owns auth flow, profile loading, session refresh, sign-out, and generation request auth headers
- `KeychainService`
  - secure read/write/delete for session credentials
- `ArtOfficialAPI`
  - thin `URLSession` client for account and generation endpoints

### View model changes
- Prefer a dedicated `AccountViewModel` owned by the app root rather than growing `ExplorerViewModel` further.
- `ExplorerViewModel` can read a lightweight account summary if generation affordances need it, but account/auth state should live outside explorer-only concerns.

### UI additions
- Add `AccountView` as a dedicated sheet/window matching the styling of `SettingsView` and `HelpView`.
- Add an `Account` menu item in the app menu.
- Add an account button in the header bar or toolbar once auth exists.
- Reserve space in the account view for future generation settings/history without coupling that work into v1.

## Website / Backend Contract Required

The native app can only ship cleanly if `artofficial.world` exposes an app-safe auth and account API. The backend should provide:

### Auth endpoints
- login start endpoint or website route suitable for `ASWebAuthenticationSession`
- callback exchange endpoint for native sessions
- refresh endpoint if tokens expire
- revoke/logout endpoint

### Account endpoints
- `GET /account/me`
- `GET /account/subscription`
- `GET /account/credits`
- optional single aggregated endpoint that returns all account summary data in one payload

### Generation endpoints
- authenticated endpoint(s) for generation requests initiated from the native app
- usage/credit deduction behavior defined server-side
- stable error responses for:
  - insufficient credits
  - expired session
  - subscription restriction
  - validation failure

### Native app support requirements
- custom URL scheme or universal-link callback for the macOS app
- CORS is not relevant for native `URLSession`, but token issuance must explicitly support native clients
- rate limiting and abuse controls should be server-side

## Security / Session Handling
- Store tokens in Keychain only.
- Refresh sessions silently where possible.
- On startup:
  1. read cached credentials from Keychain
  2. validate or refresh
  3. fetch account summary
- On auth failure:
  - clear invalid credentials
  - keep the app usable for local browsing
  - show a signed-out account state instead of blocking the explorer
- Never trust locally cached credits or tier as authoritative; always treat server data as source of truth.

## Account Page Content

### Primary cards
- identity card
  - email / display name
  - account status
- subscription card
  - current tier
  - renewal or expiration date if available
  - manage billing link
- credits card
  - credits remaining
  - credits used this cycle
  - reset / renewal date if available

### Actions
- sign in
- create account
- refresh account data
- manage subscription
- open website
- sign out

### Error / empty states
- signed out
- network unavailable
- session expired
- backend unavailable
- partial account data available

## Generation Integration Follow-up
- After account v1 lands, add a generation client workflow that reuses `AccountService` auth state.
- Generation UI should:
  - require sign-in
  - show whether the current tier permits generation
  - preflight credit availability where useful
  - rely on server-side enforcement for final billing and entitlement checks
- Successful generation responses should be designed to fit the app’s existing `.plib` / image-centric workflow where possible.

## Implementation Phases

### Phase 1: Session and account foundation
- add account models
- add Keychain-backed credential storage
- add API client scaffolding
- add browser auth flow
- add startup session restore

### Phase 2: Account page
- add menu entry and account sheet/window
- add signed-out and signed-in states
- add credits and subscription presentation
- add refresh / sign out / website actions

### Phase 3: Generation readiness
- expose authenticated request helpers
- add entitlement checks
- define generation request/response types
- add generation entry points later without reworking auth

## Testing Plan

### Unit-level
- token persistence and removal
- session refresh behavior
- account payload decoding
- signed-out fallback on invalid credentials

### Integration-level
- browser login round-trip
- app relaunch with restored session
- expired-token refresh path
- sign out clears Keychain and UI state
- credits/subscription refresh updates account page correctly

### UX validation
- account page opens from menu reliably
- local explorer remains usable when signed out
- network/auth failures are surfaced without breaking the app
- billing/credits labels remain readable and accurate in dark theme

## Open Dependencies / Assumptions
- `artofficial.world` must expose a native-compatible auth flow and account endpoints.
- Subscription tier and credit usage data exist server-side and are queryable per user.
- The native app will remain fully functional for local browsing when no user is signed in.
- `ASWebAuthenticationSession` is the preferred auth mechanism unless the website stack requires a different callback model.
- This plan does **not** include payment processing inside the app; billing management should open on the website.
