import Foundation

/// Decisions the user can make when reviewing a proposed retake cut.
/// Wire encoding mirrors the `action` string on `decide` RPC calls.
enum RetakeDecision: String, Codable, Sendable {
    case remove
    case keep
    case approveRest
    case cancel
}
