# ISS-P16-001: Production homeserver option

> Issue = PR boundary. The three tasks below are the exact commit boundaries.

- GitHub issue: https://github.com/ZenithResearch/ZenithOS/issues/1
- Branch: `issue/1-production-matrix-endpoint`
- Primary repo: `ZenithResearch/ZenithOS`
- Private planning source consulted: `notes/iss-p16-001.md`

## Objective

Make `https://synapse.zenith-research.ca` the default Matrix homeserver in ZenithOS while retaining the explicit `http://localhost:8008` Local Development option and removing user-visible assumptions that Matrix always runs on localhost.

## Locked behavior

- Production default: `https://synapse.zenith-research.ca`.
- Local Development: `http://localhost:8008`.
- One normalization contract removes trailing slashes.
- Empty or malformed inputs fall back to Production.
- Credential-bearing, query-bearing, fragment-bearing, and path-bearing inputs fall back to Production.
- HTTPS is required except for loopback HTTP development endpoints.
- Both the human and Sophia clients initialize from the same normalized active endpoint.
- Matrix clients and their tokens are immutable during a running app session. Selecting or resetting an endpoint persists the next endpoint and explicitly requires an app restart; ZenithOS does not pretend to hot-switch either client.
- Login, client reachability, room/DM requests, and registration/invite links derive from the active endpoint.
- Existing Matrix human and Sophia Keychain key names and token handling remain unchanged.

## Operator behavior

1. Open **Hub Connection → Matrix**.
2. Read the connection row for the active endpoint and its **Production** or **Local Development** label.
3. Select **Use Production** or **Use Local Development**. **Reset** selects Production.
4. If the selected endpoint differs from the active endpoint, restart ZenithOS when prompted.
5. Reopen Hub Connection and confirm the selected endpoint is active for both human and Sophia clients.
6. The login sheet shows the same endpoint and environment label. Invite links are generated from that same endpoint.

No credentials are needed to test endpoint selection or client-version reachability. Login and registration success require separate authorized manual evidence and are not claimed by this issue.

## Commit boundaries

1. `test(matrix): define production homeserver contract`
   - Add focused RED-first normalization, fallback, security, and labeling tests.
   - Add the smallest production configuration contract needed to make them GREEN.
2. `feat(matrix): use Zenith production homeserver by default`
   - Initialize human and Sophia clients from the shared persisted endpoint.
   - Add Production/Local Development selection, reset, restart-safe copy, and active endpoint display.
   - Derive status, login, Matrix requests, and invite links from the active endpoint.
3. `docs(matrix): document production endpoint selection`
   - Reconcile this spec with the live issue.
   - Update README/operator guidance and the changelog.
   - Record portable verification and non-claims.

## Verification and evidence

Run from the repository root on the final PR head:

```sh
swift test
swift build --target ZenithOSUI
./build-app.sh
git diff --check
curl -fsS https://synapse.zenith-research.ca/_matrix/client/versions
```

Expected evidence:

- All Swift tests pass, including the Matrix homeserver configuration suite.
- The `ZenithOSUI` target builds.
- `build-app.sh` assembles and signs the local app bundle; `.build/` and `ZenithOS.app/` remain untracked.
- `git diff --check` is clean.
- The credential-free client versions endpoint returns HTTP 200 with Matrix versions JSON.
- Final diff and tracked-file scans contain no credentials or generated application/build artifacts.

The parent operator performs the final launch smoke before merge: verify Production is active, select Local Development, observe the restart requirement, restart if desired, then reset to Production. This implementation PR does not claim that launch smoke has occurred unless separately recorded in the PR evidence.

## Acceptance criteria

- [x] Fresh/default runtime targets the production Matrix endpoint.
- [x] Operator can select Local Development and reset to Production without source edits.
- [x] Connection and login surfaces identify the endpoint and environment.
- [x] Registration/invite links derive from the active normalized endpoint.
- [x] Focused tests cover defaults, normalization, malformed input, credentials, query/fragment, and insecure remote HTTP fallback.
- [x] Token Keychain names and handling are unchanged.
- [ ] Final automated, package, endpoint, and parent-operator launch evidence is attached to the PR before merge.

## Non-goals and forbidden claims

- This PR does not deploy, configure, or harden Synapse.
- It does not prove credentialed login or registration succeeds.
- Matrix identity does not grant Hub/operator authority.
- It does not add or expose service/appservice/admin/access credentials.
- It does not implement federation policy, registration policy, Hub authority, routing visibility, wallets, Dregg, secS-magik, or Review SDK authentication.
