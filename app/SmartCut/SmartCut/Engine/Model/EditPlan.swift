import Foundation

// MARK: - Engine-internal plan types
// These are the mutable in-progress representations inside the pipeline.
// "EnginePlan" avoids a naming conflict with the wire "EditPlan" in PipelineEvent.swift.

struct RemoveSilenceOp: Sendable {
    let start: Double
    let end: Double
}

// MARK: - EnginePlan

struct EnginePlan: Sendable {
    let source: String
    let duration: Double
    var operations: [Op]

    enum Op: Sendable {
        case silence(RemoveSilenceOp)
        case retake(RemoveRetakeOp)   // RemoveRetakeOp from PipelineEvent.swift

        var start: Double {
            switch self { case .silence(let o): return o.start; case .retake(let o): return o.start }
        }
        var end: Double {
            switch self { case .silence(let o): return o.end;   case .retake(let o): return o.end }
        }
    }

    var retakeOps: [RemoveRetakeOp] {
        operations.compactMap { if case .retake(let op) = $0 { return op }; return nil }
    }
    var silenceOps: [RemoveSilenceOp] {
        operations.compactMap { if case .silence(let op) = $0 { return op }; return nil }
    }

    /// Convert to the wire EditPlan used in PipelineEvent.done.
    func toDonePlan() -> EditPlan {
        let wireOps: [EditOperation] = operations.map { op in
            switch op {
            case .silence(let s): return .removeSilence(start: s.start, end: s.end)
            case .retake(let r):  return .removeRetake(r)
            }
        }
        return EditPlan(source: source, duration: duration, operations: wireOps)
    }
}

func buildEnginePlan(source: String, duration: Double, operations: [EnginePlan.Op]) -> EnginePlan {
    let sorted = operations.sorted { $0.start < $1.start }
    return EnginePlan(source: source, duration: duration, operations: sorted)
}

// MARK: - Plan → keep segments

/// Collapse all remove operations into keep segments, applying padding and
/// clipping retake regions back out (so padding never bleeds into removed speech).
func planToKeepSegments(_ plan: EnginePlan, leadInMs: Double, tailOutMs: Double) -> [Segment] {
    let cuts: [Segment] = plan.operations.map { Segment(start: $0.start, end: $0.end) }
    let mergedCuts = cuts.mergingOverlaps()
    let raw    = mergedCuts.invertToKeep(duration: plan.duration)
    let padded = raw
        .applyPadding(leadInMs: leadInMs, tailOutMs: tailOutMs, duration: plan.duration)
        .mergingOverlaps()

    // Clip retake regions back — padding must not re-add removed speech.
    let retakeRegions: [Segment] = plan.retakeOps.map { Segment(start: $0.start, end: $0.end) }
    return padded.subtracting(retakeRegions)
}
