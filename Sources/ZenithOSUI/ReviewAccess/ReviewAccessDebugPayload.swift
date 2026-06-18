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

    static func smokeSummary(from debugLog: String) -> String {
        let fields = Dictionary(
            uniqueKeysWithValues: debugLog
                .split(separator: "\n")
                .compactMap { line -> (String, String)? in
                    guard let separator = line.firstIndex(of: "=") else { return nil }
                    let key = String(line[..<separator])
                    let value = String(line[line.index(after: separator)...])
                    return (key, value)
                }
        )
        let responseStatus = fields["response_status"] ?? fields["preflight_status"] ?? "not-run"
        let endpoint = fields["endpoint"] ?? "unknown"
        let responseKind = endpoint.contains("/preflight") ? "preflight" : "rotate"
        let policyCount = Int(fields["policy_count"] ?? "0") ?? 0
        let policyLines = (0..<policyCount).map { index in
            let deploymentID = fields["policy[\(index)].deployment_id"] ?? "unknown"
            let allowedOrigin = fields["policy[\(index)].allowed_origin"] ?? "unknown"
            let subjectPattern = fields["policy[\(index)].subject_pattern"] ?? "unknown"
            let originStatus = allowedOrigin.isEmpty || allowedOrigin == "unknown" ? "missing-origin" : "origin-present"
            let subjectStatus = subjectPattern.isEmpty || subjectPattern == "unknown" ? "missing-subject" : "subject-present"
            return "policy[\(index)]=\(deploymentID) origin=\(allowedOrigin) subject=\(subjectPattern) status=\(originStatus),\(subjectStatus)"
        }

        return ([
            "review_access_smoke_summary_v1",
            "hub_url=\(fields["hub_url"] ?? "unknown")",
            "endpoint=\(endpoint)",
            "project_id=\(fields["project_id"] ?? "unknown")",
            "access_code_id=\(fields["access_code_id"] ?? "unknown")",
            "policy_count=\(policyCount)",
            "\(responseKind)_response_status=\(responseStatus)"
        ] + policyLines).joined(separator: "\n")
    }
}
