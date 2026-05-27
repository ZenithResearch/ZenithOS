# Review Access UX Mode Redesign Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make the ZenithOS Review Access page unambiguous by separating “replace existing access record” from “create new access record,” preventing stale/misaligned metadata from driving credential rotation.

**Architecture:** Keep this as an app-local SwiftUI refinement inside `ReviewAccessView.swift` and its directly related review-access models. The page should become mode-driven: the selected operation controls which fields are shown, which metadata source is authoritative, which mismatches block submission, and how the final action is labeled.

**Tech Stack:** SwiftUI, AppKit clipboard integration, existing `ReviewAccessConfig`, `ReviewAccessStore`, and `ReviewAccessHubClient` types in ZenithOS.

**Screenshot / prompt reference:** `<local screenshot path redacted>`

---

## UX diagnosis

The current page has the right data but the wrong mental model.

The screenshot shows the selected overwrite target as:

- Access row: `dan-prota-swrl-ui-review`
- Client: `Dan Prota (dan-prota)`
- Project: `swrl-ui`
- Scope metadata: `swrl-ui-production-alias`
- Origin: `https://swrl-ui.vercel.app`
- Subject: `https://swrl-ui.vercel.app*`

But the editable Reviewer fields below show:

- Rolodex person: `dan`
- Client name: `dan`
- Client slug: `dan`

That creates the dangerous ambiguity the overwrite selector was meant to remove. The operator cannot tell whether “Generate code” will replace `dan-prota-swrl-ui-review` or derive a new `dan-swrl-ui-review` target from stale form values.

The UX must make these invariants true:

1. The operator always knows whether they are creating or replacing.
2. Replacing an existing record makes that existing record the authoritative target.
3. Creating a new record makes the form values authoritative.
4. A selected overwrite target and editable form may not silently diverge.
5. The final button label must name the operation and target.
6. Debug/log visibility must remain safe: no raw admin token, raw access code, hashes, session tokens, or DB credentials.

---

## Non-goals

- Do not add a new backend endpoint.
- Do not fetch canonical records from Hub in this pass; use the existing local safe metadata store.
- Do not persist raw access codes.
- Do not redesign all Hub/ZenithOS form styling.
- Do not move this into ZenithUI yet. This is a product-surface refinement; promote reusable pieces later only if the pattern stabilizes.

---

## Proposed page structure

### 1. Operation section

Replace “Overwrite target” as the top conceptual object with an explicit mode selector:

```text
Operation
(•) Replace existing access record
( ) Create new access record
```

When `Replace existing access record` is selected:

- Show existing-record picker.
- Require a selected saved config before enabling rotation.
- Rename “Clear target” to “Create new record instead.”
- Selected record is authoritative for `accessCodeID`.

When `Create new access record` is selected:

- Hide selected overwrite summary.
- Clear `selectedConfigID`.
- Use form values to derive the access row.
- Show “New access row preview.”

### 2. Selected target card

For replace mode, show a read-only selected target card:

```text
Replacing existing access record
Dan Prota — dan-prota-swrl-ui-review

Access row: dan-prota-swrl-ui-review
Client: Dan Prota (dan-prota)
Project: swrl-ui
Scope metadata: swrl-ui-production-alias
Origin: https://swrl-ui.vercel.app
Subject: https://swrl-ui.vercel.app*
```

This card should be visibly binding, not decorative.

### 3. Metadata form

In replace mode:

- Selecting a config auto-loads all config metadata into the form immediately.
- Show a small “Loaded from selected access record” note.
- If fields diverge from selected config, show an amber mismatch warning and disable rotate actions until the operator chooses one of:
  - “Reload selected metadata”
  - “Create new record from current form instead”

In create mode:

- Show normal Rolodex/client/project/deployment fields.
- The form may derive a new access row from client slug + project.
- The preview should make that derivation visible.

### 4. Final target summary near actions

Keep the final target summary near the Generate / Use entered code controls, but make it mode-specific.

Replace mode:

```text
Final target
Mode: Replace existing access record
Access row: dan-prota-swrl-ui-review
Client: Dan Prota
Project: swrl-ui
Deployment: swrl-ui-production-alias
```

Create mode:

```text
Final target
Mode: Create new access record
New access row: dan-swrl-ui-review
Client: dan
Project: swrl-ui
Deployment: swrl-ui-production-alias
```

### 5. Action labels

Replace generic buttons with mode-aware labels:

- Replace mode generate: `Replace code for Dan Prota`
- Replace mode provided: `Replace with entered code`
- Create mode generate: `Generate new access code`
- Create mode provided: `Create with entered code`

---

## Implementation tasks

### Task 1: Add explicit operation mode state

**Objective:** Introduce a tiny UI state model that separates create and replace workflows.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Add a private enum near `ReviewAccessView`:

```swift
private enum ReviewAccessOperationMode: String, CaseIterable, Identifiable {
    case replaceExisting
    case createNew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .replaceExisting: return "Replace existing access record"
        case .createNew: return "Create new access record"
        }
    }
}
```

2. Add state:

```swift
@State private var operationMode: ReviewAccessOperationMode = .replaceExisting
```

3. If there are no saved configs, default to `.createNew` on appear or in view logic.

4. Add `effectiveOperationMode` computed property:

```swift
private var effectiveOperationMode: ReviewAccessOperationMode {
    reviewStore.configs.isEmpty ? .createNew : operationMode
}
```

**Verification:**

Run:

```bash
swift build -c debug --product ZenithOSUI
```

Expected: build succeeds.

---

### Task 2: Replace overwrite section with operation section

**Objective:** Make the top of the page answer “what am I doing?” before asking for metadata.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Rename `overwriteTargetSection` to `operationSection`.
2. Add a Picker for `operationMode` using `.segmented` or radio-style buttons if segmented looks too compressed.
3. In replace mode:
   - Show existing-record picker.
   - Show selected target card.
   - Rename “Clear target” to `Create new record instead` and have it set:

```swift
operationMode = .createNew
selectedConfigID = nil
```

4. In create mode:
   - Show helper text:

```text
No existing access row will be overwritten. The access row will be derived from the form below.
```

5. If saved configs are empty:
   - Hide replace mode or disable it with helper text.

**Verification:**

Run:

```bash
swift build -c debug --product ZenithOSUI
```

Expected: build succeeds.

Manual visual check:

- Saved configs present: operation section shows both modes.
- No saved configs: create mode is clearly active.

---

### Task 3: Make selected config auto-sync authoritative metadata

**Objective:** Selecting an existing row should immediately load matching client/project/deployment metadata into the form, avoiding stale defaults.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Keep `applySelectedConfigDefaults()` but make it also force replace mode:

```swift
private func applySelectedConfigDefaults() {
    guard let selectedConfig else { return }
    operationMode = .replaceExisting
    applyConfigToForm(selectedConfig)
}
```

2. Review `applyConfigToForm(_:)` ordering so `selectedContactID` changes do not overwrite `clientName` / `clientSlug` after applying selected config. If needed, make contact-default application mode-aware:

```swift
private func applySelectedContactDefaults() {
    guard effectiveOperationMode == .createNew else { return }
    guard let contact = selectedContact else { return }
    clientName = contact.displayName
    clientSlug = ReviewAccessCodeFactory.slug(from: contact.displayName)
}
```

This is likely the root of the screenshot mismatch: selected config applied `Dan Prota`, then Rolodex contact selection re-applied `dan`.

3. In replace mode, either:
   - disable the Rolodex picker/client fields, or
   - keep them editable but detect mismatches and block submit.

Recommended first pass: disable fields that define the selected target identity in replace mode, because access-code rotation should not silently edit reviewer identity.

**Verification:**

Manual:

- Select `Dan Prota — dan-prota-swrl-ui-review`.
- Reviewer section should show `Dan Prota` / `dan-prota`, not `dan` / `dan`.

Build:

```bash
swift build -c debug --product ZenithOSUI
```

---

### Task 4: Add metadata mismatch detection

**Objective:** Prevent a selected overwrite target from diverging silently from the visible form.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Add computed property:

```swift
private var selectedConfigMismatches: [String] {
    guard effectiveOperationMode == .replaceExisting, let selectedConfig else { return [] }
    var mismatches: [String] = []

    if clientName.trimmingCharacters(in: .whitespacesAndNewlines) != selectedConfig.clientName {
        mismatches.append("Client name differs: selected target uses \(selectedConfig.clientName)")
    }
    if ReviewAccessCodeFactory.slug(from: clientSlug) != selectedConfig.clientSlug {
        mismatches.append("Client slug differs: selected target uses \(selectedConfig.clientSlug)")
    }
    if projectID.trimmingCharacters(in: .whitespacesAndNewlines) != selectedConfig.projectID {
        mismatches.append("Project ID differs: selected target uses \(selectedConfig.projectID)")
    }
    if deploymentID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != selectedConfig.deploymentID {
        mismatches.append("Deployment differs: selected target uses \(selectedConfig.deploymentID ?? "project-scoped")")
    }
    if allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != selectedConfig.allowedOrigin {
        mismatches.append("Allowed origin differs: selected target uses \(selectedConfig.allowedOrigin ?? "—")")
    }
    if subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != selectedConfig.subjectPattern {
        mismatches.append("Subject pattern differs: selected target uses \(selectedConfig.subjectPattern ?? "—")")
    }

    return mismatches
}
```

2. Add:

```swift
private var hasBlockingMetadataMismatch: Bool {
    !selectedConfigMismatches.isEmpty
}
```

3. Show an amber warning card in replace mode when mismatches exist:

```text
Metadata mismatch detected
The selected overwrite target and visible form do not match.
[Reload selected metadata] [Create new record from current form instead]
```

4. Disable generate/use-entered buttons when `hasBlockingMetadataMismatch` is true.

**Verification:**

Manual:

- Select an existing target.
- Edit client slug to a different value.
- Buttons should disable and warning should appear.
- Click Reload selected metadata.
- Warning should disappear and buttons should enable.

Build:

```bash
swift build -c debug --product ZenithOSUI
```

---

### Task 5: Make target derivation mode-aware

**Objective:** Ensure the payload’s `accessCodeID` behavior exactly matches the visible operation mode.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Update `targetAccessCodeID`:

```swift
private var targetAccessCodeID: String {
    if effectiveOperationMode == .replaceExisting, let selectedConfig {
        return selectedConfig.accessCodeID
    }
    return ReviewAccessCodeFactory.swrlAccessCodeID(clientSlug: ReviewAccessCodeFactory.slug(from: clientSlug))
}
```

2. Add can-submit guard:

```swift
private var canRotate: Bool {
    canSave &&
    !isSubmitting &&
    !hasBlockingMetadataMismatch &&
    (effectiveOperationMode == .createNew || selectedConfig != nil)
}
```

3. Replace button `.disabled(!canSave || isSubmitting)` with `.disabled(!canRotate)`.

4. Keep `ReviewAccessRotateRequest.deploymentScopedAccess` unchanged for now unless another requirement changes it.

**Verification:**

Manual:

- Replace mode without selected config: disabled.
- Replace mode with selected config and no mismatch: enabled.
- Create mode with valid form: enabled.
- Create mode should preview a derived row.

Build:

```bash
swift build -c debug --product ZenithOSUI
```

---

### Task 6: Make final action labels mode-specific

**Objective:** The operator should know exactly what pressing the button will do.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Add computed labels:

```swift
private var generateButtonTitle: String {
    switch effectiveOperationMode {
    case .replaceExisting:
        return "Replace code for \(clientName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "selected reviewer")"
    case .createNew:
        return "Generate new access code"
    }
}

private var providedCodeButtonTitle: String {
    switch effectiveOperationMode {
    case .replaceExisting:
        return "Replace with entered code"
    case .createNew:
        return "Create with entered code"
    }
}
```

2. Use these in `codeSection`.

3. Keep `SecureField("Or enter code manually", text: $manualCode)`.

**Verification:**

Manual:

- Replace mode selected: button says `Replace code for Dan Prota`.
- Create mode selected: button says `Generate new access code`.

Build:

```bash
swift build -c debug --product ZenithOSUI
```

---

### Task 7: Update rotation summary copy

**Objective:** Make the summary read like a confirmation, not a technical dump.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Replace `Target summary: selected existing row` with:

```text
Final target: replacing existing access record
```

2. Replace `Target summary: new or derived row` with:

```text
Final target: creating new access record
```

3. Include `Access row` first and make it visually prominent.
4. Keep the technical metadata below in monospaced text.

**Verification:**

Manual visual check that the final summary answers:

- What mode am I in?
- What row will be affected?
- Which client/project/deployment does this apply to?

Build:

```bash
swift build -c debug --product ZenithOSUI
```

---

### Task 8: Preserve safe debug log behavior

**Objective:** Ensure the new mode state appears in debug logs without exposing secrets.

**Files:**
- Modify: `Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift`

**Steps:**

1. Add `operation_mode` to `debugLogHeader`:

```swift
"operation_mode=\(effectiveOperationMode.rawValue)"
```

2. Keep token output limited to:

- present boolean
- length
- SHA256 prefix

3. Keep raw access code output as present/absent redacted.

**Verification:**

Manual:

- Trigger a failed request with an invalid token.
- Debug log includes `operation_mode` and selected row metadata.
- Debug log does not include raw admin token or raw entered/generated code.

Build:

```bash
swift build -c debug --product ZenithOSUI
```

---

## Acceptance criteria

The redesigned page is acceptable when:

1. The page has an explicit create-vs-replace operation mode.
2. Selecting an existing target loads all matching safe metadata into the visible fields.
3. The screenshot failure case cannot recur: selected target `Dan Prota / dan-prota` cannot coexist silently with form values `dan / dan` while rotate buttons remain enabled.
4. Clearing the target clearly means “create new record instead.”
5. The final action button says whether it will replace or create.
6. The final summary names the exact `access_code_id` before the operator submits.
7. `swift build -c debug --product ZenithOSUI` succeeds.
8. No raw access codes, admin tokens, access-code hashes, session tokens, or DB credentials are logged or persisted.

---

## Recommended implementation order

Implement in this order:

1. Operation mode state.
2. Operation section UI.
3. Metadata auto-sync guard for selected configs.
4. Mismatch detection and submit blocking.
5. Mode-aware target derivation.
6. Mode-aware action labels.
7. Rotation summary copy.
8. Debug log operation-mode addition.

Stop after task 4 for a visual/manual checkpoint if possible. That is the point where the UX ambiguity should be resolved even before final copy polish.
