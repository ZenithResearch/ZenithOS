# Review Access rotate smoke

This runbook verifies the ZenithOS Review Access rotate/debug contract against the active Hub node without leaking admin tokens, one-time reviewer keys, code hashes, or session tokens.

Use it when validating ZenithOS issue #11 / the Review Access smoke contract, or when proving whether a failure belongs to the ZenithOS client payload, Hub Gateway freshness, or Hub policy validation.

## Preconditions

- ZenithOS is built from the commit under test.
- Hub Connection points at the intended Hub node.
- Hub Connection has verified the Review Access admin credential.
- The operator has an approved reviewer target and an approved safe channel for any one-time raw reviewer key.
- Do not paste raw admin tokens, generated reviewer codes, pasted manual reviewer codes, access-code hashes, or browser session tokens into GitHub, chat, screenshots, or this repo.

## 1. Build source commit SHA check

Record the exact source commit before opening the app:

```bash
git rev-parse HEAD
git status --short --branch
swift test --filter ReviewAccessDebugPayloadTests
```

Expected:

- working tree is clean or only contains intentional local operator notes;
- debug payload tests pass;
- the commit SHA is copied into the evidence note/PR comment.

## 2. Hub health and endpoint freshness check

From Hub Connection in ZenithOS:

1. Confirm the active Hub URL is the intended deployed node.
2. Click the Review Access admin verification action.
3. Continue only if ZenithOS reports that the admin credential is verified.

Optional shell check, with secrets kept out of logs:

```bash
curl -fsS https://hub.zenith-research.ca/health
```

If `/v1/admin/review-auth/access-codes/preflight` returns HTTP 404, the deployed Gateway is older than the Hub preflight PR. In that case, the ZenithOS UI should show preflight as unavailable and rotate should remain governed by local validation.

## 3. Prepare canonical SWRL payload

In ZenithOS → Review Access:

1. Select the reviewer target.
2. Select the SWRL Web project preset.
3. Confirm allowed environment rows:

```text
policy[0].deployment_id=swrl-web-production
policy[0].allowed_origin=https://www.collectswirls.com
policy[0].subject_pattern=https://www.collectswirls.com/*
policy[1].deployment_id=swrl-web-local
policy[1].allowed_origin=http://localhost:*
policy[1].subject_pattern=http://localhost:*/*
```

Forbidden stale form:

```text
https://www.collectswirls.com*
```

That stale form must not appear in the debug block, smoke summary, issue comments, or evidence notes except as an explicit forbidden example.

## 4. Run preflight before raw reviewer key handling

Click **Run preflight** before generating or pasting a reviewer key.

Expected if the deployed Hub includes the preflight endpoint:

- Hub preflight shows `Server OK`.
- Policy rows show `server-ok` badges.
- Debug drawer endpoint is `/v1/admin/review-auth/access-codes/preflight`.
- Debug block includes `raw_access_code_in_payload=absent`.
- Debug block includes `admin_token_value=redacted`.
- Smoke summary includes `preflight_response_status=success`.

Expected if the deployed Hub is older:

- Hub preflight shows unavailable / HTTP 404.
- Smoke summary can be copied for evidence.
- Rotate is not blocked solely by endpoint unavailability.

Expected if Hub rejects the current payload:

- Hub preflight shows `Server rejected`.
- Policy rows show `server-rejected`.
- Rotate is disabled until the payload changes or is reset to canonical.

## 5. Rotate and capture safe evidence

Only after preflight is accepted or intentionally unavailable:

1. Use Generate or Paste manual code according to the operator plan.
2. If a raw reviewer key appears, send it only through the approved safe channel.
3. Open the debug drawer.
4. Click **Copy smoke summary** and paste only that summary into issue/PR evidence.
5. Use **Copy debug block** only when detailed public metadata is needed.

Expected rotate success debug fields:

```text
endpoint=/v1/admin/review-auth/access-codes/rotate
response_status=success
raw_access_code_in_payload=absent          # generate mode
raw_access_code_in_payload=present-redacted # manual-code mode
admin_token_value=redacted
policy_count=2
```

Expected smoke summary fields:

```text
review_access_smoke_summary_v1
hub_url=<active Hub URL>
endpoint=/v1/admin/review-auth/access-codes/rotate
project_id=swrl
access_code_id=<reviewer access row id>
policy_count=2
rotate_response_status=success
policy[0]=swrl-web-production origin=https://www.collectswirls.com subject=https://www.collectswirls.com/* status=origin-present,subject-present
policy[1]=swrl-web-local origin=http://localhost:* subject=http://localhost:*/* status=origin-present,subject-present
```

## 6. Inspect safe Hub policy rows

Once the Hub safe policy-list endpoint is deployed, inspect public policy rows only. The response is allowed to include client/project/deployment IDs, allowed origins, subject patterns, active flags, and stale-policy flags.

The response must not include:

- raw access codes;
- access-code hashes;
- raw admin tokens;
- browser session tokens.

Evidence should confirm that live Hub rows match the canonical SWRL rows above.

## 7. Failure attribution

Use this attribution table before filing follow-up work:

| Signal | Likely owner | Next action |
|---|---|---|
| ZenithOS debug block contains `https://www.collectswirls.com*` | ZenithOS | Reset canonical policies and file a client regression. |
| Preflight endpoint returns 404 | Hub deploy/runtime | Deploy/restart Gateway with the Hub preflight PR. |
| Preflight rejects canonical rows | Hub policy validator or seeded deployment rows | Compare smoke summary to safe Hub policy rows. |
| Rotate succeeds but browser login fails | Review SDK / deployment allowlist / browser session | Capture smoke summary, Hub public rows, and browser origin; do not paste secrets. |
| Debug/smoke summary contains raw token/code/hash | ZenithOS security bug | Stop, delete leaked artifact if possible, rotate affected secret, and file a blocker. |

## Evidence template

```text
ZenithOS commit: <sha>
Hub URL: <url>
Hub health: <ok/fail>
Preflight: <success/unavailable/rejected + status>
Rotate: <success/failure + status>
Smoke summary:
<copy smoke summary output>
Safe Hub policy rows checked: <yes/no + endpoint/run reference>
Secrets excluded: yes
```
