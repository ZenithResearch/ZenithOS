# ISS-P16-003: Human vs service identity separation

> Issue = PR boundary. Tasks below = commit boundaries inside that PR.

## PR boundary

- **PR scope:** ISS-P16-003: Human vs service identity separation
- **Suggested branch:** `issue/iss-p16-003-human-vs-service-identity-separation`
- **Suggested PR title:** `ISS-P16-003: Human vs service identity separation`
- **Primary repo:** `ZenithResearch/ZenithOS`
- **Supporting repo/API dependency:** `ZenithResearch/hub`
- **Source vault note:** `private source note: iss-p16-003`
- **GitHub issue:** https://github.com/ZenithResearch/ZenithOS/issues/3
- **Repo-local spec path:** `docs/issues/matrix-synapse-v0/iss-p16-003-human-vs-service-identity-separation.md`

## Full spec

### Objective

Keep Matrix user login, Sophia/service accounts, and appservice state visually and technically separate.

### Repo rationale

ZenithOS owns operator UI; Hub is upstream for redacted readiness/routing APIs.

### Dependencies / blocked by

- ISS-P16-002 status schema

### Target files and surfaces

- MatrixLoginView.swift, MatrixInboxView.swift, SynapseInboxView.swift, MatrixClient.swift, HubConfigView.swift

### Locked decisions and invariants

- Mission Control / ZenithOS shows Hub auth/provisioning readiness beside Matrix status now.
- Human Matrix login, service identities, appservice credentials, and Hub admin/provisioning authority remain separate.
- Readiness/status comes from Gateway admin endpoint.
- Routing visibility waits on P18 routing/provenance shape.

### Acceptance criteria

- Human Matrix tokens cannot be reused as appservice credentials; UI labels distinguish human vs Hub/Sophia service identities.
- Evidence is recorded in the implementation repo or linked capture before this issue is marked complete.
- The project note is updated with the completion evidence and any downstream blockers.

### Verification commands

- swift test; swift build; manual UI boundary smoke.

### Forbidden claims / non-goals

- Do not claim production deployment unless live deploy evidence exists.
- Do not claim Matrix identity is Hub authority.
- Do not print or persist raw appservice/admin/reviewer secrets.
- Do not claim wallet, secS-magik, Zenith Review SDK wallet-auth, or Dregg-backed authorization in this v0 Matrix/Synapse issue set.

## Task list — commit boundaries

Each checked task should land as a separate commit on the PR branch. Do not combine tasks unless the diff is mechanically inseparable; if combined, explain why in the PR body.

### Task 1: Scope and baseline evidence

**Commit boundary:** one commit in the `ISS-P16-003` PR.

**Objective:** Read the source vault note and inspect the target repo surfaces for `ISS-P16-003`. Confirm the exact files/modules to touch, record current behavior, and update this spec if discovery changes the file list.

**Files / surfaces:**
- MatrixLoginView.swift, MatrixInboxView.swift, SynapseInboxView.swift, MatrixClient.swift, HubConfigView.swift

**Steps:**
1. Inspect the named files/surfaces and keep the diff limited to this issue.
2. Make only the change required for this task.
3. Run the narrowest relevant verification command before committing.
4. Commit with:

```bash
git add <changed-files>
git commit -m "docs: scope iss-p16-003"
```

**Done when:** this task's change is independently reviewable and the next task can build on it without rewriting it.
### Task 2: Contract / failing test or guard

**Commit boundary:** one commit in the `ISS-P16-003` PR.

**Objective:** Add the smallest failing test, static check, fixture, or documentation guard that proves the issue is not already complete and captures the desired behavior before implementation.

**Files / surfaces:**
- MatrixLoginView.swift, MatrixInboxView.swift, SynapseInboxView.swift, MatrixClient.swift, HubConfigView.swift

**Steps:**
1. Inspect the named files/surfaces and keep the diff limited to this issue.
2. Make only the change required for this task.
3. Run the narrowest relevant verification command before committing.
4. Commit with:

```bash
git add <changed-files>
git commit -m "test: cover iss-p16-003 contract"
```

**Done when:** this task's change is independently reviewable and the next task can build on it without rewriting it.
### Task 3: Implement the primary behavior

**Commit boundary:** one commit in the `ISS-P16-003` PR.

**Objective:** Make the minimal production change for the objective. Keep the diff limited to this issue's PR boundary and do not pull in adjacent phase work.

**Files / surfaces:**
- MatrixLoginView.swift, MatrixInboxView.swift, SynapseInboxView.swift, MatrixClient.swift, HubConfigView.swift

**Steps:**
1. Inspect the named files/surfaces and keep the diff limited to this issue.
2. Make only the change required for this task.
3. Run the narrowest relevant verification command before committing.
4. Commit with:

```bash
git add <changed-files>
git commit -m "feat: implement iss-p16-003"
```

**Done when:** this task's change is independently reviewable and the next task can build on it without rewriting it.
### Task 4: Negative cases and edge behavior

**Commit boundary:** one commit in the `ISS-P16-003` PR.

**Objective:** Add fail-closed, non-leakage, duplicate/idempotency, unavailable-dependency, or no-op cases relevant to this issue. If the issue is documentation-only, add explicit forbidden examples instead.

**Files / surfaces:**
- MatrixLoginView.swift, MatrixInboxView.swift, SynapseInboxView.swift, MatrixClient.swift, HubConfigView.swift

**Steps:**
1. Inspect the named files/surfaces and keep the diff limited to this issue.
2. Make only the change required for this task.
3. Run the narrowest relevant verification command before committing.
4. Commit with:

```bash
git add <changed-files>
git commit -m "test: harden iss-p16-003 edge cases"
```

**Done when:** this task's change is independently reviewable and the next task can build on it without rewriting it.
### Task 5: Docs, operator notes, and evidence hooks

**Commit boundary:** one commit in the `ISS-P16-003` PR.

**Objective:** Update repo-local docs/runbooks/config comments so an operator or future agent can verify the behavior without reading the vault. Add evidence placeholders or command examples, but do not commit secrets or live tokens.

**Files / surfaces:**
- MatrixLoginView.swift, MatrixInboxView.swift, SynapseInboxView.swift, MatrixClient.swift, HubConfigView.swift

**Steps:**
1. Inspect the named files/surfaces and keep the diff limited to this issue.
2. Make only the change required for this task.
3. Run the narrowest relevant verification command before committing.
4. Commit with:

```bash
git add <changed-files>
git commit -m "docs: record iss-p16-003 operator evidence"
```

**Done when:** this task's change is independently reviewable and the next task can build on it without rewriting it.
### Task 6: PR readiness verification

**Commit boundary:** one commit in the `ISS-P16-003` PR.

**Objective:** Run the verification commands below, run `git diff --check`, inspect the PR diff for scope creep/secrets, and update the PR body with evidence and explicit non-claims.

**Files / surfaces:**
- MatrixLoginView.swift, MatrixInboxView.swift, SynapseInboxView.swift, MatrixClient.swift, HubConfigView.swift

**Steps:**
1. Inspect the named files/surfaces and keep the diff limited to this issue.
2. Make only the change required for this task.
3. Run the narrowest relevant verification command before committing.
4. Commit with:

```bash
git add <changed-files>
git commit -m "chore: verify iss-p16-003 pr readiness"
```

**Done when:** this task's change is independently reviewable and the next task can build on it without rewriting it.

## PR body checklist

Before opening or marking the PR ready, include:

- [ ] Link to this repo-local spec.
- [ ] Link to source vault note `private source note: iss-p16-003`.
- [ ] Summary of the implementation.
- [ ] Task/commit list with commit SHAs.
- [ ] Verification commands and results.
- [ ] Explicit forbidden claims that remain false.
- [ ] Supporting repo/API dependency status, if any.

## Related

- [[prp-pr-016|PRP-PR-016: ZenithOS production Synapse operator updates]]
- [[../capture/2026-06-04-matrix-wallet-extension-initiative|Matrix production and vanilla auth initiative]]
- [[projects]]
- [[Zenith]]

Areas:
- [[Zenith]]
- [[projects]]
