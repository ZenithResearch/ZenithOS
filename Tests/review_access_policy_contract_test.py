from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = (ROOT / "Sources/ZenithOSUI/ReviewAccess/ReviewAccessConfig.swift").read_text()
CLIENT = (ROOT / "Sources/ZenithOSUI/ReviewAccess/ReviewAccessHubClient.swift").read_text()
VIEW = (ROOT / "Sources/ZenithOSUI/ReviewAccess/ReviewAccessView.swift").read_text()
SOURCE_TEXT = "\n".join(
    path.read_text()
    for path in (ROOT / "Sources/ZenithOSUI/ReviewAccess").glob("*.swift")
)


def test_swrl_sources_do_not_reintroduce_legacy_policy_literals():
    assert "https://www.collectswirls.com*" not in SOURCE_TEXT
    assert "localhost:3000" not in SOURCE_TEXT
    assert 'deploymentID: "swrl-local"' not in SOURCE_TEXT


def test_gallery_preset_and_policy_model_exist():
    assert "struct ReviewAccessPolicy" in CONFIG
    assert "enum ReviewAccessProjectPreset" in CONFIG
    assert "case swrlWeb" in CONFIG
    assert "case gallery" in CONFIG
    assert 'case .swrlWeb: return "swrl"' in CONFIG
    assert "swrl-web-production" in CONFIG
    assert "https://www.collectswirls.com" in CONFIG
    assert 'subjectPattern: "https://www.collectswirls.com/*"' in CONFIG
    assert 'subjectPattern: "https://swrl-ui.vercel.app/*"' in CONFIG
    assert "https://gal-ler-y.com" in CONFIG
    assert "https://www.gal-ler-y.com" in CONFIG
    assert "http://localhost:*" in CONFIG
    assert "http://localhost:*/*" in CONFIG
    assert "swrl-web-local" in CONFIG
    assert "gallery-production-apex" in CONFIG
    assert "gallery-production-www" in CONFIG
    assert "gallery-local" in CONFIG


def test_safe_config_migrates_legacy_single_policy_fields():
    assert "case policies" in CONFIG
    assert "case deploymentID" in CONFIG
    assert "Legacy policy" in CONFIG
    assert "legacyPolicy" in CONFIG


def test_gallery_saved_metadata_normalizes_legacy_deployment_ids():
    assert "normalizedPolicies" in CONFIG
    assert "discard stale local Gallery policy metadata" in CONFIG
    assert "Older local app metadata used a legacy local deployment id" in CONFIG
    assert "ReviewAccessProjectPreset.swrlWeb.defaultPolicies" in CONFIG
    assert 'deploymentID: "gallery-local"' in CONFIG
    assert 'subjectPattern: "http://localhost:*/*"' in CONFIG
    assert 'deploymentID: "gallery-production-apex"' in CONFIG
    assert 'deploymentID: "gallery-production-www"' in CONFIG
    assert 'subjectPattern: "https://gal-ler-y.com/*"' in CONFIG
    assert 'subjectPattern: "https://www.gal-ler-y.com/*"' in CONFIG
    assert "normalizedRotationPolicies" in VIEW
    assert "ReviewAccessProjectPreset.gallery.defaultPolicies" in VIEW
    assert "legacyGalleryPolicyIDs" in VIEW
    assert "let rotationPolicies = normalizedRotationPolicies(policies, projectID: projectIdentifier)" in VIEW
    assert "Gallery review access must rotate exactly the canonical gallery-production-apex, gallery-production-www, and gallery-local policies" in VIEW
    assert "effectiveRotationPolicies" in VIEW
    assert "rotationBlockers" in VIEW
    assert "Paste existing reviewer key" in VIEW
    assert "Clear local saved rows" in VIEW
    assert "Create new Hub row" in VIEW
    assert "Mode: create a new Hub review-access row" in VIEW
    assert "Allowed environments sent to Hub" in VIEW
    assert "edit the allowed environments" in VIEW
    assert "HubCard { policiesSection }" in VIEW
    assert "Metadata differences" in VIEW
    assert "Differences here are informational" in VIEW
    assert "Access label returned to apps" in VIEW
    assert "Dan Admin" in VIEW


def test_rotate_request_sends_policies_and_decodes_policy_count():
    assert "struct ReviewAccessPolicyPayload" in CLIENT
    assert "var policies: [ReviewAccessPolicyPayload]" in CLIENT
    assert "case policies" in CLIENT
    assert "var policyCount: Int" in CLIENT
    assert "policyCount = \"policy_count\"" in CLIENT
    assert "decodeIfPresent(Int.self, forKey: .policyCount) ?? 0" in CLIENT
    assert "decodeIfPresent(Bool.self, forKey: .rawCodePresent) ?? (rawCode != nil)" in CLIENT


def test_view_sends_first_policy_as_legacy_compatibility_metadata():
    assert "let compatibilityPolicy = policyPayloads.first" in VIEW
    assert "deploymentID: compatibilityPolicy?.deploymentID" in VIEW
    assert "deploymentSlug: compatibilityPolicy?.deploymentSlug" in VIEW
    assert "allowedOrigin: compatibilityPolicy?.allowedOrigin" in VIEW
    assert "subjectPattern: compatibilityPolicy?.subjectPattern" in VIEW
    assert "compat_deployment_id=" in VIEW


def test_view_sends_explicit_access_label_separate_from_client_name():
    assert "@State private var accessLabel" in VIEW
    assert "private var effectiveAccessLabel" in VIEW
    assert "accessLabel = config.accessLabel" in VIEW
    assert "accessLabel: effectiveAccessLabel" in VIEW
    assert "Access label differs" in VIEW


def test_view_uses_allowed_environments_instead_of_single_scope_only():
    assert "Allowed environments" in VIEW
    assert "Add Gallery defaults" in VIEW
    assert "Add Localhost" in VIEW
    assert "http://localhost:*" in VIEW
    assert "Local any port" in VIEW
    assert "policy_count" in VIEW
    assert "policy[" in VIEW
    assert "reviewAccessPayload" in VIEW
    assert "policies:" in VIEW
