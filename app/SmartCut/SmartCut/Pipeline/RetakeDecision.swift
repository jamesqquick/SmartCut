import Foundation

/// Decisions the user can make when reviewing a proposed retake cut.
/// Wire encoding mirrors the `action` string on `decide` RPC calls.
enum RetakeDecision: String, Codable, Sendable {
    case remove
    case keep
    case approveRest
    case cancel
}

/// One cut's final decision in the batch transcript-review flow.
/// `removeStartIndex`/`removeEndIndex` are inclusive transcript token indices.
/// Mirrors `ReviewCutDecision` in `pipeline/decisions.ts`.
struct ReviewCutDecision: Codable, Hashable, Sendable {
    let opId: String
    let enabled: Bool
    let removeStartIndex: Int
    let removeEndIndex: Int
}
