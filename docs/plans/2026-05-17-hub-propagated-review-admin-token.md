# Hub-Propagated Review Admin Token Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Let ZenithOS set or rotate the Review Access admin credential on the active Hub node, then save the same credential locally, instead of only writing macOS Keychain.

**Architecture:** Hub remains canonical. ZenithOS owns local credential entry and UX, but token setup/rotation is an authenticated Hub operation. The Hub gateway accepts first-time bootstrap only when no Review Access admin token exists; otherwise token update requires the current valid admin token. The running gateway reads the effective admin token dynamically from Hub config secrets so a reset can take effect without an ECS env-var redeploy in self-hosted/operator-managed nodes.

**Tech Stack:** FastAPI / pytest in Hub; SwiftUI / SwiftPM in ZenithOS.

---

## Work surfaces

1. Hub dynamic credential source: prefer `REVIEW_ACCESS_ADMIN_TOKEN` from the Hub config-secrets file when present; fall back to startup env.
2. Hub token setup/rotate endpoint: safe PUT endpoint that writes the token to Hub config secrets, returns only configured/capability metadata, and never returns the raw token.
3. ZenithOS client/store: call the Hub endpoint, then save the same token to Keychain only after Hub accepts it.
4. Hub Connection UI: distinguish “Save Local Credential” from “Set/Rotate on Hub”.
5. Verification and docs.

---

### Task 1: Add Hub-side admin-token update endpoint

**Objective:** Allow an operator to set the Review Access admin token on the active Hub node.

**Files:**
- Modify: `../hub/services/gateway_http/app.py`
- Test: `../hub/tests/test_gateway_http_sessions.py`

**Rules:**
- `PUT /v1/admin/review-auth/admin-token`
- Body: `{ "value": "new-token" }`
- If no token is currently configured anywhere, allow bootstrap without Authorization.
- If a token is already configured, require current valid bearer token.
- Write `REVIEW_ACCESS_ADMIN_TOKEN` into `HUB_CONFIG_SECRETS_PATH`.
- Return `configured`, `capabilities`, `secrets_printed=false`; never return raw token or hash.

### Task 2: Make Hub auth check dynamic

**Objective:** Ensure a token set through the Hub endpoint is immediately accepted by the same running gateway.

**Files:**
- Modify: `../hub/services/gateway_http/app.py`

**Rules:**
- `_require_review_access_admin()` must use the effective token from config secrets if present.
- Fall back to `settings.review_access_admin_token` for env/infra-managed deployments.
- This keeps AWS/ECS env-token compatibility but lets self-hosted/operator-managed nodes rotate without redeploy.

### Task 3: Add ZenithOS client/store methods

**Objective:** Let ZenithOS propagate a new admin token to the active Hub node.

**Files:**
- Modify: `./Sources/ZenithOSUI/ReviewAccess/ReviewAccessHubClient.swift`
- Modify: `./Sources/ZenithOSUI/Hub/HubStore.swift`

**Rules:**
- Add `updateAdminTokenOnHub(newToken:currentToken:)`.
- Use Authorization header only when a current local token exists.
- After Hub accepts the update, save the new token to Keychain.
- Verify connection immediately.

### Task 4: Update Hub Connection UI

**Objective:** Make the “first phone setup” path obvious.

**Files:**
- Modify: `./Sources/ZenithOSUI/Hub/HubConfigView.swift`

**Rules:**
- Keep “Save Local Credential” for importing an already-existing Hub credential.
- Add “Set/Rotate on Hub” button that sends the draft credential to the active Hub and saves locally only on success.
- Copy should explain:
  - first setup works when Hub has no admin credential yet
  - rotation works when the current local credential is valid
  - if neither is true, bootstrap/owner recovery is required outside this endpoint

### Task 5: Verify

**Commands:**
```bash
cd ../hub
.venv/bin/pytest tests/test_gateway_http_sessions.py -q

cd .
swift build -c debug --product ZenithOSUI
git checkout -- .build ZenithOS.app
```

**Acceptance criteria:**
- A fresh Hub with no token accepts first setup and then requires that token.
- A configured Hub rejects unauthenticated token replacement.
- A configured Hub accepts replacement with the current valid token and immediately accepts the new token.
- ZenithOS can set/rotate on Hub and then verify the active Hub node.
