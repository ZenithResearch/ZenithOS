# Hub Connection / Review Access Refactor Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task if continuing in a later session.

**Goal:** Make ZenithOS bind to one verified Hub node before any Review Access admin action, so Review Access operates against “the Hub” rather than a misleading local Keychain-only setting.

**Architecture:** Hub Settings becomes Hub Connection. ZenithOS stores the selected Hub URL and a local credential in Keychain, but Review Access is blocked until the credential is verified against that deployed Hub. Hub exposes a small authenticated capability endpoint that proves the token is accepted by the running gateway without mutating reviewer records.

**Tech Stack:** SwiftUI / SwiftPM for ZenithOS; FastAPI / pytest for Hub gateway.

---

## Work surfaces

1. Hub API contract: add a non-mutating Review Access admin capability/verify endpoint.
2. ZenithOS connection client: make ReviewAccessHubClient use a configurable Hub URL and expose token verification.
3. Hub Connection UI: rename the settings surface, show node URL, credential source, verification status, and clarify local-vs-Hub update boundary.
4. Review Access gating: show the verified Hub node and disable rotations until connection verification succeeds.
5. Verification and docs: run Hub targeted tests and ZenithOS build; update skill notes.

---

### Task 1: Add a Hub admin capability endpoint

**Objective:** Add a safe GET endpoint that returns authenticated Review Access admin capability metadata without rotating access codes.

**Files:**
- Modify: `../hub/services/gateway_http/app.py`
- Test: `../hub/tests/test_gateway_http_sessions.py`

**Steps:**
1. Add a Pydantic output model with fields: `ok`, `hub`, `capabilities`, `secrets_printed`.
2. Add `GET /v1/admin/review-auth/capabilities` that calls `_require_review_access_admin(request)`.
3. Return `ok=true`, `hub="gateway-http"`, and `capabilities=["review_access_admin", "review_access_rotate"]`.
4. Add tests for success and invalid token rejection.
5. Run targeted pytest.

### Task 2: Refactor ReviewAccessHubClient around Hub node binding

**Objective:** Stop hardcoding the Hub URL as the only possible target and add non-mutating verification.

**Files:**
- Modify: `./Sources/ZenithOSUI/ReviewAccess/ReviewAccessHubClient.swift`

**Steps:**
1. Keep `defaultHubURL` as the default node URL.
2. Add `ReviewAccessCapabilitiesResponse`.
3. Add `verifyAdminToken(_:)` that calls `/v1/admin/review-auth/capabilities` with bearer auth.
4. Ensure no raw token is logged or persisted outside Keychain.

### Task 3: Make HubStore own the active Hub node URL and verification state

**Objective:** Create a single app-level source of truth for the bound Hub node used by Review Access.

**Files:**
- Modify: `./Sources/ZenithOSUI/Hub/HubStore.swift`

**Steps:**
1. Add `@AppStorage("hubNodeURL")` defaulting to `https://hub.zenith-research.ca`.
2. Add published review-access connection state: verified boolean, message, capability list, last verified date.
3. Add `hubNodeBaseURL` parser.
4. Add `verifyReviewAccessAdminConnection()` that reads Keychain once and verifies against the configured Hub URL.
5. Add `resetReviewAccessVerification()` for URL/token changes.

### Task 4: Rename Hub Settings to Hub Connection and clarify credential semantics

**Objective:** Make the UI say that saving a token only updates the local credential for the selected Hub, while verification proves the deployed Hub accepts it.

**Files:**
- Modify: `./Sources/ZenithOSUI/Hub/HubConfigView.swift`
- Modify: `./Sources/ZenithOSUI/ContentView.swift`

**Steps:**
1. Rename visible navigation from Hub Settings to Hub Connection.
2. Add a Hub node URL field with Save/Reset.
3. Change Review Access Admin copy to: local credential is for the configured Hub; it does not rotate production secrets by itself.
4. Add Verify Connection button wired to `HubStore.verifyReviewAccessAdminConnection()`.
5. Show verified/unverified capability status.

### Task 5: Gate Review Access actions on verified Hub connection

**Objective:** Prevent Review Access rotation when the active Hub node has not accepted the admin credential.

**Files:**
- Modify: `./Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**
1. Add a top Hub Connection card showing `hub.hubNodeURL`, verification status, and capabilities.
2. Disable `canRotate` unless `hub.reviewAccessAdminVerified` is true.
3. Use `ReviewAccessHubClient(baseURL: hub.hubNodeBaseURL)` for rotation.
4. Debug logs must print the active Hub URL, not the hardcoded default.
5. If unverified, tell the operator to verify in Hub Connection before rotating.

### Task 6: Verify and clean generated artifacts

**Objective:** Prove both Hub API contract and ZenithOS compile.

**Commands:**
```bash
cd ../hub
.venv/bin/pytest tests/test_gateway_http_sessions.py -q

cd .
swift build -c debug --product ZenithOSUI
git checkout -- .build ZenithOS.app
```

**Acceptance criteria:**
- Hub capability endpoint accepts only the configured admin token.
- ZenithOS Review Access rotate buttons are disabled until Hub Connection verifies.
- The UI distinguishes local Keychain save from deployed-Hub token rotation.
- Debug logs and UI never print raw tokens or reviewer codes except the intended one-time generated reviewer code response.
