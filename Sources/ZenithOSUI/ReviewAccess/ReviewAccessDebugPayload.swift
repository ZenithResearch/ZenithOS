import Foundation

struct ReviewAccessDebugPayloadBuilder {
    static let formatVersion = "review_access_rotate_debug_v1"

    struct Context {
        var requestID: String
        var hubURL: URL
        var endpoint: String
        var keychainService: String
        var keychainAccount: String
        var adminTokenPresent: Bool
        var operationMode: String
        var mode: ReviewAccessRotateRequest.Mode
        var selectedExistingRow: Bool
        var payload: ReviewAccessRotateRequest
    }

    static func debugLog(context: Context) -> String {
        let policyLines = context.payload.policies.enumerated().flatMap { index, policy in
            [
                "policy[\(index)].deployment_id=\(policy.deploymentID)",
                "policy[\(index)].deployment_slug=\(policy.deploymentSlug)",
                "policy[\(index)].allowed_origin=\(policy.allowedOrigin)",
                "policy[\(index)].subject_pattern=\(policy.subjectPattern)"
            ]
        }

        return ([
            formatVersion,
            "request_id=\(context.requestID)",
            "hub_url=\(context.hubURL.absoluteString)",
            "endpoint=\(context.endpoint)",
            "keychain_service=\(context.keychainService)",
            "keychain_account=\(context.keychainAccount)",
            "admin_token_present=\(context.adminTokenPresent)",
            "admin_token_value=redacted",
            "operation_mode=\(context.operationMode)",
            "mode=\(context.mode.rawValue)",
            "raw_access_code_in_payload=\(context.payload.accessCode == nil ? "absent" : "present-redacted")",
            "selected_existing_row=\(context.selectedExistingRow)",
            "client_id=\(context.payload.clientID)",
            "client_slug=\(context.payload.clientSlug)",
            "client_name=\(context.payload.clientName)",
            "project_id=\(context.payload.projectID)",
            "project_slug=\(context.payload.projectSlug)",
            "project_name=\(context.payload.projectName)",
            "compat_deployment_id=\(context.payload.deploymentID ?? "nil")",
            "compat_deployment_slug=\(context.payload.deploymentSlug ?? "nil")",
            "compat_allowed_origin=\(context.payload.allowedOrigin ?? "nil")",
            "compat_subject_pattern=\(context.payload.subjectPattern ?? "nil")",
            "deployment_scoped_access=\(context.payload.deploymentScopedAccess)",
            "policy_count=\(context.payload.policies.count)",
            "access_code_id=\(context.payload.accessCodeID)",
            "access_label=\(context.payload.accessLabel)"
        ] + policyLines).joined(separator: "\n")
    }
}
