import Foundation
import SwiftUI

// MARK: - Models

struct FrankAnalysis: Codable {
    let session: SessionCheck
    let participants: [FrankParticipant]
    let background: String
    let objective: String
    let informationGaps: [InformationGap]

    enum CodingKeys: String, CodingKey {
        case session, participants, background, objective
        case informationGaps = "information_gaps"
    }
}

struct SessionCheck: Codable {
    let found: Bool
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case found
        case sessionId = "session_id"
    }
}

struct FrankParticipant: Codable, Identifiable {
    var id: String { identifier }
    let identifier: String
    let known: Bool
    let rolodexId: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case identifier, known
        case rolodexId = "rolodex_id"
        case displayName = "display_name"
    }
}

struct InformationGap: Codable, Identifiable {
    var id: String { gap }
    let gap: String
    let knowledgeFound: String?

    enum CodingKeys: String, CodingKey {
        case gap
        case knowledgeFound = "knowledge_found"
    }
}

// MARK: - Parse from queue message metadata

extension QueueMessage {
    var frankAnalysis: FrankAnalysis? {
        guard case .object(let obj)? = metadata["frank_analysis"],
              let data = try? JSONEncoder().encode(obj)
        else { return nil }
        return try? JSONDecoder().decode(FrankAnalysis.self, from: data)
    }
}

// MARK: - Frank Analysis Section

struct FrankAnalysisSectionView: View {
    let analysis: FrankAnalysis?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Frank Analysis")

            if let analysis {
                FrankAnalysisContentView(analysis: analysis)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("Pending analysis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Analysis Content

struct FrankAnalysisContentView: View {
    let analysis: FrankAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            FieldGrid {
                FieldRow(
                    label: "Session",
                    value: analysis.session.found
                        ? (analysis.session.sessionId ?? "found")
                        : "none"
                )
            }

            if !analysis.participants.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Participants")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(analysis.participants) { p in
                        HStack(spacing: 6) {
                            Text(p.displayName.map { "\($0) (\(p.identifier))" } ?? p.identifier)
                                .font(.body)
                                .textSelection(.enabled)
                            if !p.known {
                                Text("unknown")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            if let rid = p.rolodexId {
                                Text(rid)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
            }

            if !analysis.background.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(analysis.background)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !analysis.objective.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Objective")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(analysis.objective)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            if !analysis.informationGaps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Information Gaps")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(analysis.informationGaps) { gap in
                        HStack(alignment: .top, spacing: 8) {
                            Image(
                                systemName: gap.knowledgeFound != nil
                                    ? "checkmark.circle.fill"
                                    : "circle.dotted"
                            )
                            .foregroundStyle(gap.knowledgeFound != nil ? .green : .secondary)
                            .font(.caption)
                            .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gap.gap)
                                    .font(.body)
                                    .textSelection(.enabled)
                                if let found = gap.knowledgeFound {
                                    Text(found)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
