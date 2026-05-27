# ZenithOS

ZenithOS is the macOS operator surface for a Zenith Hub.

It is not the Hub runtime. It does not own queue storage, case execution, Review Access policy, Matrix infrastructure, or artifact persistence. It gives an operator a local SwiftUI control plane over those systems: queue state, case state, Hub filesystem previews, reviewer access management, Matrix/Synapse views, model/inference status, 3D tooling, and local vault files.

A repository README should be a searchable orientation map before it becomes a manual. This README is the map.

## Search map

Use this section to jump by concept, file, or subsystem.

| Search for | Start here | What owns the behavior |
|---|---|---|
| app targets, SwiftPM, macOS version | `Package.swift` | Swift Package Manager package definition |
| menu bar daemon, login item, FaceTime capture | `Sources/ZenithOS/` | `ZenithOS` executable target |
| dock app, workspace shell, navigation | `Sources/ZenithOSUI/ZenithOSUIApp.swift`, `Sources/ZenithOSUI/ContentView.swift` | `ZenithOSUI` executable target |
| Hub node URL, admin credential, local mirror root | `Sources/ZenithOSUI/Hub/HubStore.swift`, `Sources/ZenithOSUI/Hub/HubConfigView.swift` | local app settings plus macOS Keychain |
| authenticated Hub admin calls | `Sources/ZenithOSUI/ReviewAccess/ReviewAccessHubClient.swift` | Hub Gateway remains the server authority |
| HubFS, `/data`, process docs, remote artifact reads | `Sources/ZenithOSUI/Hub/HubFSClient.swift`, `Sources/ZenithOSUI/Hub/HubRemoteAccess.swift` | Hub Gateway `/v1/admin/fs/*` routes |
| artifact mirror mounts and fallback previews | `Sources/ZenithOSUI/Hub/HubArtifactMount.swift`, `Sources/ZenithOSUI/Hub/HubArtifactMirror.swift` | authenticated Hub content first, optional local materialization/cache second |
| queue monitor | `Sources/ZenithOSUI/Queue/` | Hub queue service or Gateway admin proxy |
| case monitor, process detail, inspector sidebar | `Sources/ZenithOSUI/Processes/` | Hub cases service or Gateway admin proxy |
| Review Access clients/projects/deployments/access codes | `Sources/ZenithOSUI/ReviewAccess/` | Hub Review Access admin API |
| Matrix login, rooms, DMs | `Sources/ZenithOSUI/Matrix/` | Matrix homeserver; tokens stored in Keychain |
| Synapse inbox view | `Sources/ZenithOSUI/Synapse/` | local/operator Matrix/Synapse surface |
| MIL inference monitor | `Sources/ZenithOSUI/MILInference/` | local HTTP status endpoints and menu bar status scene |
| Playground prompting | `Sources/ZenithOSUI/Playground/` | configured OpenAI-compatible endpoint |
| Markdown reader and Hub file previews | `Sources/ZenithOSUI/Markdown/`, `Sources/ZenithOSUI/MarkdownResources/` | local WebKit renderer with custom link handling |
| Three.js editor and dev tools | `Sources/ZenithOSUI/ThreeJS/` | local WebKit/editor/dev-server tooling |
| local vault contacts and todos | `Sources/ZenithOSUI/Vault/`, `Sources/ZenithOSUI/Todos/` | local vault filesystem |
| FaceTime transcript capture | `Sources/ZenithOS/Features/FaceTimeCapture/` | local menu-bar daemon using macOS capture APIs |
| CI and public safety checks | `.github/workflows/ci.yml`, `Tests/` | GitHub Actions + Python contract tests |
| app bundle assembly | `build-app.sh`, `build.sh`, `scripts/release.sh` | local macOS packaging scripts |
| historical implementation plans | `docs/plans/` | design record, not active runtime authority |

## What exists now

ZenithOS currently ships two Swift executable targets from one package:

1. `ZenithOS` — a menu bar daemon.
   - Registers `ZenithFeature` plugins through `AppDelegate`.
   - Currently exposes FaceTime capture.
   - Writes local transcript/audio artifacts to the configured hub/vault capture paths.

2. `ZenithOSUI` — a dock/operator app.
   - Provides the main workspace shell.
   - Reads local vault files and configured Hub mirror roots.
   - Talks to Hub Gateway admin APIs when the Review Access admin credential has been verified.
   - Provides Review Access rotation/management UI for Hub-owned reviewer codes.
   - Monitors queue/case/process state.
   - Previews HubFS/process docs/artifacts through typed file resolvers.

The Hub remains the source of truth. ZenithOS is the operator cockpit.

## Runtime boundary

ZenithOS has three runtime planes.

### 1. Local macOS plane

Local macOS code owns UI, user settings, Keychain storage, local file browsing, capture permissions, and app bundle assembly.

Relevant files:

```text
Sources/ZenithOS/
Sources/ZenithOSUI/
ZenithOS.entitlements
build-app.sh
build.sh
scripts/release.sh
```

The app uses macOS facilities directly:

- `AppKit` for menu bar status items, custom windows, panels, and workspace actions.
- `SwiftUI` for the dock app surface.
- `Security` / Keychain for credentials.
- `WebKit` for Markdown, Three.js, and local preview surfaces.
- `ScreenCaptureKit`, `AVFoundation`, and Speech APIs for FaceTime capture.

### 2. Hub control plane

Hub APIs own queue, case, artifact, HubFS, and Review Access state. ZenithOS reads or mutates those only through explicit API clients.

Relevant files:

```text
Sources/ZenithOSUI/Hub/HubStore.swift
Sources/ZenithOSUI/Hub/HubFSClient.swift
Sources/ZenithOSUI/Queue/QueueStore.swift
Sources/ZenithOSUI/Processes/ProcessStore.swift
Sources/ZenithOSUI/ReviewAccess/ReviewAccessHubClient.swift
```

Important rule: production queue/case state should normally flow through Gateway admin proxy routes. Direct local service URLs are development shortcuts.

### 3. Local mirror / filesystem plane

ZenithOS can browse and preview local files, but local files are not the canonical Hub runtime. Configured mirror roots are cache/materialization surfaces, not authority.

Relevant files:

```text
Sources/ZenithOSUI/FileStore.swift
Sources/ZenithOSUI/Hub/HubRemoteAccess.swift
Sources/ZenithOSUI/Hub/HubArtifactMount.swift
Sources/ZenithOSUI/Hub/HubArtifactMirror.swift
```

Current product rule: direct authenticated POSIX-style HubFS access is primary for remote runtime paths. Local mirrors are an optional acceleration and development convenience.

## Workspace map

The dock app exposes workspaces through `ZenithWorkspace` in `ContentView.swift`.

| Workspace | Surface | Backing files | Notes |
|---|---|---|---|
| MIL | inference monitoring and status | `MILInference/` | Uses `ZenithStatus` and `ZenithMenuBarScene` for status visibility. |
| Playground | prompt experiments | `Playground/` | Sends prompts to a configured OpenAI-compatible endpoint. |
| Queue | inbound work queue | `Queue/` | Reads local `QUEUE_HTTP_URL` in dev or Gateway admin queue routes in operator mode. |
| Cases | Frank/case execution | `Processes/` | Polls lists, loads detail, opens live SSE only against a local cases service. |
| Matrix | Matrix inbox and conversations | `Matrix/` | Matrix access tokens are namespaced and stored in Keychain. |
| Synapse | Synapse inbox/events | `Synapse/` | Local/operator view over Matrix/Synapse events. |
| Review Access | reviewer-code operations | `ReviewAccess/` | Rotates Hub-owned reviewer access rows; raw generated codes are one-time display/copy only. |
| Hub Connection | node binding and credentials | `Hub/HubConfigView.swift`, `Hub/HubStore.swift` | Stores Hub URL, verifies admin token, configures mirror roots. |
| 3D Editor | Three.js/Form editor | `ThreeJS/ThreeEditorWindowController.swift` | Local editor surface around Forms/Three.js assets. |
| 3D DevTools | web/scene inspection | `ThreeJS/ThreeDevToolsWindowController.swift` | Local dev-server launcher and WebKit inspection bridge. |

The sidebar also includes a local file tree. Selecting a file leaves workspace mode and opens a file detail view.

## Architecture notes by subsystem

### Menu bar daemon: `Sources/ZenithOS/`

`ZenithOS` is a small menu-bar process.

- `main.swift` launches the AppKit app.
- `AppDelegate.swift` owns the status item, menu, lifecycle, and `ZenithFeature` registry.
- `Shared/VaultConfig.swift` defines default local capture roots from the current user's home directory.
- `Shared/AssetStore.swift` indexes recorded assets in SQLite.

Feature registration is explicit. A new daemon feature should conform to `ZenithFeature` and be added to `AppDelegate.features`.

### FaceTime capture: `Sources/ZenithOS/Features/FaceTimeCapture/`

FaceTime capture is local and permission-heavy.

Files:

- `FaceTimeCaptureFeature.swift` — menu items and feature lifecycle.
- `FaceTimeCaptureManager.swift` — capture/session coordinator.
- `ProcessAudioTap.swift` — process/system audio tap boundary.
- `AudioRecorder.swift` — local audio recording.
- `SpeechTranscriber.swift` — speech recognition wrapper.
- `TranscriptWriter.swift` — Markdown transcript writer.
- `HUDWindow.swift` — capture HUD panel.

Permissions required:

- Microphone.
- Screen Recording.
- Speech Recognition.

The output is a local capture artifact. Later extraction into a vault/Hub graph is a downstream process, not part of the capture feature itself.

### UI shell: `Sources/ZenithOSUI/`

`ZenithOSUIApp.swift` creates the main SwiftUI scene, injects shared `HubStore` and inference status objects, and registers command menus.

`ContentView.swift` owns:

- workspace routing;
- sidebar file tree;
- detail view switching;
- tab overview gesture/command handling;
- local file previews.

`FileStore.swift` scans the selected local mirror/root and produces `FileNode` values for the sidebar. It skips local implementation artifacts such as `.git`, `.build`, `.obsidian`, and `node_modules`.

### Hub connection and credentials: `Sources/ZenithOSUI/Hub/`

This subsystem binds the local app to a Hub node.

Files:

- `HubStore.swift` — shared observable state for Hub URL, namespace, queue health, vault path, Matrix reachability, Review Access verification, and mirror root config.
- `HubConfigView.swift` — operator UI for Hub node URL, admin-token verification/update, mirror roots, and local connection state.
- `EnvFile.swift` — local `.env` parser for development/operator convenience.
- `HubRemoteAccess.swift` — local mirror root and namespace rules.
- `HubArtifactMount.swift` — runtime-prefix-to-local-root mapping.
- `HubArtifactMirror.swift` — materialization/preview fallback behavior.
- `HubFSClient.swift` — authenticated HubFS admin client.

Credential rule:

- Raw admin credentials live in macOS Keychain.
- ZenithOS may send bearer authorization to Hub Gateway.
- ZenithOS should not print, hash-print, or persist raw admin tokens in repository files, logs, or debug copy.

### HubFS and artifact previews

HubFS support gives ZenithOS direct authenticated access to POSIX-style remote paths such as `/data/...` and `/app/base/ops/processes/...`.

Resolution order for file-like case slots:

1. Normalize the path and classify whether it belongs to a HubFS namespace.
2. Prefer authenticated HubFS/admin artifact content for remote runtime paths.
3. Use configured local mounts for materialization, cache, or development fallback where available.
4. Render Markdown/file previews with existing Markdown reader components when possible.

The important product boundary: do not make local filesystem access the correctness condition for a remote Hub case. Local mirrors are optional.

### Queue monitor: `Sources/ZenithOSUI/Queue/`

The queue surface shows messages from the Hub workspace queue.

Files:

- `QueueStore.swift` — fetches messages by status.
- `QueueMessage.swift` — queue message and JSON value models.
- `QueueListView.swift` — list UI.
- `MessageDetailView.swift` — message payload/detail rendering.
- `FrankAnalysis.swift` — typed analysis rendering for Frank outputs.

Data sources:

- Development: `QUEUE_HTTP_URL` can point directly at a local queue service.
- Operator/prod: Gateway admin route `v1/admin/queues/workspace/peek` after admin credential verification.

### Cases and process inspection: `Sources/ZenithOSUI/Processes/`

The cases subsystem is the core Hub execution inspector.

Files:

- `ProcessStore.swift` — list/detail polling, local SSE stream management, admin-route fallback.
- `ProcessCase.swift` — API response models for cases, steps, slots, logs, artifacts, contracts, and progress.
- `ProcessListView.swift` — open/recent case list.
- `ProcessDetailView.swift` — process graph/detail surface.
- `ProcessSpecParser.swift` — parsed process spec, variables, I/O, steps, DAG edges.
- `CaseInspectionSelection.swift` — canonical inspector selection state.
- `CaseInspectionModel.swift` — derives step/slot/edge/root inspection context.
- `CaseInspectionSidebar.swift` — modular inspection drawer.
- `CaseInspectionOverlay.swift` — host that attaches the fixed inspection surface to case detail content.

Inspection design:

- Graph and sidebar share one canonical selection model.
- Step/root/slot/edge detail is derived generically from process contracts, parsed specs, case detail, slots, logs, and execution evidence.
- The DAG should stay visually clean; dense metadata belongs in the inspector or hover/detail surfaces.
- Live streams are local-service-only today. Production admin mode falls back to polling until Gateway exposes a case-detail stream route.

### Review Access: `Sources/ZenithOSUI/ReviewAccess/`

Review Access is the operator UI for Hub-owned reviewer authentication rows.

Files:

- `ReviewAccessConfig.swift` — saved local config, project presets, policy normalization, access-code ID derivation.
- `ReviewAccessStore.swift` — local persistence of safe metadata only.
- `ReviewAccessHubClient.swift` — Hub admin API client and Keychain helpers.
- `ReviewAccessView.swift` — rotate/create/replace UI.

Important invariants:

- Hub is canonical. ZenithOS does not own credential policy.
- Raw generated reviewer codes may be displayed/copied once after Hub generates them.
- Saved local config is metadata: client/project/deployment/policy/access-row IDs, not raw reviewer codes.
- The admin token is a Keychain credential for the configured Hub node.
- Gallery and SWRL presets are public metadata; they are not secrets.

### Matrix and Synapse: `Sources/ZenithOSUI/Matrix/`, `Sources/ZenithOSUI/Synapse/`

Matrix support gives the operator a local communication surface.

Files:

- `MatrixClient.swift` — registration, login, logout, joined rooms, DMs, room creation, app-service credential loading.
- `MatrixLoginView.swift` — login/register UI.
- `MatrixInboxView.swift` — room list/inbox UI.
- `MatrixMessage.swift` — message models.
- `SynapseInboxView.swift` — Synapse event/inbox surface.

Credential rule: Matrix access tokens are stored in Keychain using namespaced keys.

### Markdown reader: `Sources/ZenithOSUI/Markdown/`, `Sources/ZenithOSUI/MarkdownResources/`

The Markdown reader wraps a WebKit renderer around bundled Markdown resources.

Files:

- `MarkdownReader.swift` — document source/session/link navigation/WebView holder/UI wrapper.
- `MarkdownResources/viewer.html`, `viewer.css`, `viewer.js`, `marked.umd.js` — bundled renderer.
- `Markdown/Resources/marked.umd.js` — excluded legacy/bundled resource copy.

This renderer is used by local file previews and Hub artifact/process-doc previews.

### Playground and inference status: `Sources/ZenithOSUI/Playground/`, `Sources/ZenithOSUI/MILInference/`

The Playground is for rapid prompt experiments against a configured OpenAI-compatible endpoint.

The MIL/inference status surface monitors status/log endpoints and exposes a menu-bar status scene through `ZenithMenuBarScene`.

Files:

- `PlaygroundInferenceClient.swift`
- `PlaygroundView.swift`
- `FloatingGlassOverlay.swift`
- `FloatingGlassTextBox.swift`
- `MILInferenceView.swift`
- `ZenithStatus.swift`
- `ZenithMenuBarScene.swift`

### Three.js tools: `Sources/ZenithOSUI/ThreeJS/`

Three.js tools are local development/operator surfaces.

Files:

- `ThreeEditorWindowController.swift` — editor window and Forms catalog.
- `ThreeDevToolsWindowController.swift` — WebKit dev tools shell, scene tree, renderer stats, navigation, dev-server launcher.
- `ThreeDetailViews.swift` — editor/detail WebView surfaces.
- `DevServerManager.swift` — local dev-server process state.
- `RepoScanner.swift` — scans repo notes for dev-server metadata.
- `ZenithFileSchemeHandler.swift` — `zenith-file://` custom scheme for local preview assets.

Security boundary: the custom file scheme is bounded to allowed local roots and should not become a general remote file server.

### Vault, todos, and transcripts

Files:

- `Vault/VaultScanner.swift` and `Vault/VaultContact.swift` — local vault contact discovery.
- `Todos/TodoStore.swift` and `Todos/TodoWidget.swift` — note-backed daily todo surface.
- `TranscriptStore.swift` — scans local capture transcripts for the UI.

These are local filesystem integrations. They are convenience surfaces over an operator's own vault; they are not Hub canonical stores.

## Data and credential flow

### Admin token flow

```text
Operator enters token
  -> ReviewAccessHubClient.saveAdminTokenToKeychain(...)
  -> Hub Connection verifies against /v1/admin/review-auth/capabilities
  -> Queue/Cases/HubFS/Review Access admin clients may call Gateway admin routes
```

The token should never be committed, logged, hash-printed, or stored in `UserDefaults`.

### Queue/case flow

```text
ZenithOSUI
  -> QueueStore / CaseStore
  -> local service URL if QUEUE_HTTP_URL or CASES_HTTP_URL is explicitly set
  -> otherwise ReviewAccessHubClient.adminData(...)
  -> Hub Gateway admin proxy
  -> Hub queue/cases services
```

### Artifact preview flow

```text
Case detail slot/artifact/process path
  -> ProcessSpecParser / CaseInspectionModel classify slot and file reference
  -> HubArtifactMountResolver checks local mirror mappings
  -> HubFSClient or admin artifact endpoints fetch remote content if needed
  -> MarkdownReaderView or generic file detail renders preview
```

### Review Access rotation flow

```text
ReviewAccessView builds request metadata
  -> ReviewAccessHubClient sends admin-authenticated request
  -> Hub creates/replaces access-code rows and hashes raw reviewer code
  -> ZenithOS saves safe metadata only
  -> raw generated/provided reviewer code is copied/displayed once
```

## Environment variables and local settings

| Name | Used by | Purpose |
|---|---|---|
| `QUEUE_HTTP_URL` | `QueueStore` | Direct local queue service for development. `HubStore` has its own initializer/default local queue-health base. |
| `CASES_HTTP_URL` | `CaseStore`, case detail stream | Direct local cases service for development and SSE. |
| Hub node URL setting | `HubStore.hubNodeURL` | Gateway base URL for operator/admin mode. |
| `vaultPath` app storage | `HubStore`, `VaultScanner`, Three.js repo scanner | Local vault/contact/repo-note root. |
| `hubEnvPath` app storage | `HubStore.connectSophia()` | Optional local `.env` source for Sophia app-service credentials. |
| `hubPathRoot` app storage | `HubRemoteAccess` | Local mirror root for Hub runtime files. |
| `hubArtifactMountsJSON` app storage | `HubArtifactMount` | Runtime-prefix to local-root mappings. |

Development URLs are local shortcuts. A public/operator deployment should prefer the configured Hub node and authenticated Gateway admin routes.

## Build and verification

Minimum local verification:

```bash
swift build -c debug --product ZenithOSUI
swift build -c debug
```

Python contract tests require pytest. In CI the workflow creates a venv before running them:

```bash
python3 -m venv .venv-ci
.venv-ci/bin/python -m pip install pytest
.venv-ci/bin/python -m pytest Tests -q
```

If pytest is unavailable locally, the current tests can also be inspected as source-contract checks in `Tests/review_access_policy_contract_test.py`.

CI lives in `.github/workflows/ci.yml` and runs:

- SwiftPM build for `ZenithOS`.
- SwiftPM build for `ZenithOSUI`.
- Python Review Access contract tests.

## Local app packaging

Packaging scripts are local convenience scripts, not release infrastructure.

| Script | Use |
|---|---|
| `build-app.sh` | Builds both release products, assembles nested `ZenithOS.app` + `ZenithOSUI.app`, ad-hoc signs both. |
| `build.sh` | Rebuilds and copies binaries into an existing `ZenithOS.app` bundle, then re-signs. |
| `scripts/release.sh` | Builds a standalone local `release/ZenithOSUI.app`. |
| `scripts/generate-app-icon.py` | Generates `Resources/ZenithOSIcon.icns` from the SVG source when needed. |

Generated bundles, build output, caches, logs, DBs, `.hermes/`, and release artifacts are ignored by `.gitignore` and should stay untracked.

## Public-repo hygiene

This repository is public. Treat it as source and documentation only.

Do not commit:

- `.env` files;
- raw admin tokens, reviewer codes, access codes, API keys, or provider keys;
- Keychain exports;
- Matrix access tokens or app-service tokens;
- local databases, logs, sessions, `.hermes/`, `.build/`, app bundles, release bundles, or pycache;
- private screenshots or local temp paths.

GitHub secret scanning and push protection should remain enabled for the public repository.

## Historical docs

`docs/plans/` contains implementation plans and design records. These are useful for architectural archaeology, but they are not runtime authority.

Read them as context for why a subsystem exists. Use source code, tests, and Hub API contracts to determine current behavior.

Current plan files:

- `docs/plans/2026-05-17-hub-connection-review-access-refactor.md`
- `docs/plans/2026-05-17-hub-propagated-review-admin-token.md`
- `docs/plans/2026-05-17-review-access-ux-mode-redesign.md`

## Contribution orientation

Before changing behavior, identify the owner plane:

- Local UI or operator state? Change ZenithOS.
- Canonical queue/case/artifact state? Change Hub.
- Reusable UI library component? Change ZenithUI, not this repo.
- Wire format or federation protocol? Change the transport/protocol repo, not this repo.

Before committing:

1. Keep the diff bounded to one concern.
2. Run SwiftPM build for the touched target.
3. Run contract tests if Review Access, queue/case, HubFS, or public metadata changed.
4. Keep public-repo hygiene clean.
5. Update `CHANGELOG.md` under `## [Unreleased]` when the commit records a meaningful change.

## Current maturity

This is active operator software. Expect fast movement around:

- HubFS and remote artifact preview behavior;
- case/process inspectability;
- Review Access operator workflows;
- Matrix/Synapse community surfaces;
- local 3D/procedural tooling;
- eventual scoped auth/capability replacement for the temporary admin-token bridge.

The stable boundary is simpler: ZenithOS is a local operator cockpit. Hub is the runtime source of truth.
