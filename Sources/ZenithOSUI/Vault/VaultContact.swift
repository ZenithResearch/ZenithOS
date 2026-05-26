import Foundation

struct VaultContact: Identifiable, Hashable {
    let id: String          // "{vault_id}/{name}" — stable unique key
    let displayName: String
    let matrixIds: [String]

    var hasMatrix: Bool { !matrixIds.isEmpty }
}
