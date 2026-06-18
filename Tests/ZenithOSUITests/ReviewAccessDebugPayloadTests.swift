import Foundation
import Testing
@testable import ZenithOSUI

@Suite("Review Access debug payload")
struct ReviewAccessDebugPayloadTests {
    @Test("SWRL rotate debug payload is stable and redacted")
    func swrlRotateDebugPayloadIsStableAndRedacted() throws {
        let policies = ReviewAccessProjectPreset.swrlWeb.defaultPolicies.map {
            ReviewAccessPolicyPayload(
                deploymentID: $0.deploymentID,
                deploymentSlug: $0.deploymentSlug,
                allowedOrigin: $0.allowedOrigin,
                subjectPattern: $0.subjectPattern
            )
        }
        let payload = ReviewAccessRotateRequest(
            clientID: "dan",
            clientSlug: "dan",
            clientName: "Dan",
            rolodexEntryPath: nil,
            projectID: ReviewAccessProjectPreset.swrlWeb.projectID,
            projectSlug: ReviewAccessProjectPreset.swrlWeb.projectSlug,
            projectName: ReviewAccessProjectPreset.swrlWeb.projectName,
            deploymentID: policies.first?.deploymentID,
            deploymentSlug: policies.first?.deploymentSlug,
            allowedOrigin: policies.first?.allowedOrigin,
            subjectPattern: policies.first?.subjectPattern,
            policies: policies,
            accessCodeID: "dan-swrl-review",
            accessLabel: "Dan SWRL Review",
            mode: .generate,
            accessCode: nil,
            deploymentScopedAccess: false
        )

        let debugLog = ReviewAccessDebugPayloadBuilder.debugLog(
            context: ReviewAccessDebugPayloadBuilder.Context(
                requestID: "req-test",
                hubURL: URL(string: "https://hub.zenith-research.ca")!,
                endpoint: "/v1/admin/review-auth/access-codes/rotate",
                keychainService: ReviewAccessHubClient.keychainService,
                keychainAccount: ReviewAccessHubClient.keychainAccount,
                adminTokenPresent: true,
                operationMode: "replaceExisting",
                mode: .generate,
                selectedExistingRow: true,
                payload: payload
            )
        )

        #expect(debugLog.contains("review_access_rotate_debug_v1"))
        #expect(debugLog.contains("request_id=req-test"))
        #expect(debugLog.contains("endpoint=/v1/admin/review-auth/access-codes/rotate"))
        #expect(debugLog.contains("admin_token_present=true"))
        #expect(debugLog.contains("admin_token_value=redacted"))
        #expect(debugLog.contains("raw_access_code_in_payload=absent"))
        #expect(debugLog.contains("compat_subject_pattern=https://www.collectswirls.com/*"))
        #expect(debugLog.contains("policy[1].deployment_id=swrl-web-local"))
        #expect(debugLog.contains("policy[1].subject_pattern=http://localhost:*/*"))
        #expect(!debugLog.contains("https://www.collectswirls.com*"))
        #expect(!debugLog.contains("secret-admin-token"))
    }

    @Test("Manual code payload reports redacted raw code presence")
    func manualCodePayloadReportsRedactedPresence() throws {
        let policy = ReviewAccessProjectPreset.swrlWeb.defaultPolicies[0]
        let payload = ReviewAccessRotateRequest(
            clientID: "dan",
            clientSlug: "dan",
            clientName: "Dan",
            rolodexEntryPath: nil,
            projectID: "swrl",
            projectSlug: "swrl",
            projectName: "SWRL",
            deploymentID: policy.deploymentID,
            deploymentSlug: policy.deploymentSlug,
            allowedOrigin: policy.allowedOrigin,
            subjectPattern: policy.subjectPattern,
            policies: [
                ReviewAccessPolicyPayload(
                    deploymentID: policy.deploymentID,
                    deploymentSlug: policy.deploymentSlug,
                    allowedOrigin: policy.allowedOrigin,
                    subjectPattern: policy.subjectPattern
                )
            ],
            accessCodeID: "dan-swrl-review",
            accessLabel: "Dan SWRL Review",
            mode: .provided,
            accessCode: "secret-review-code",
            deploymentScopedAccess: true
        )

        let debugLog = ReviewAccessDebugPayloadBuilder.debugLog(
            context: ReviewAccessDebugPayloadBuilder.Context(
                requestID: "req-manual",
                hubURL: URL(string: "https://hub.zenith-research.ca")!,
                endpoint: "/v1/admin/review-auth/access-codes/rotate",
                keychainService: ReviewAccessHubClient.keychainService,
                keychainAccount: ReviewAccessHubClient.keychainAccount,
                adminTokenPresent: true,
                operationMode: "createNew",
                mode: .provided,
                selectedExistingRow: false,
                payload: payload
            )
        )

        #expect(debugLog.contains("raw_access_code_in_payload=present-redacted"))
        #expect(!debugLog.contains("secret-review-code"))
    }
}
