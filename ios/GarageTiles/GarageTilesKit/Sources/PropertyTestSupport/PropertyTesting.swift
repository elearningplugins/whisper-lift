import Foundation
import Testing

/** A small seeded generator so a failing property can be replayed with GTK_PROPERTY_SEED. */
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// A fresh seed per run keeps exploring; set GTK_PROPERTY_SEED to replay a reported failure, then pin the case as a deterministic test.
public func propertySeed() -> UInt64 {
    if let raw = ProcessInfo.processInfo.environment["GTK_PROPERTY_SEED"], let seed = UInt64(raw) { return seed }
    return UInt64.random(in: .min ... .max)
}

/** Checks a property over generated values and reports the first failing value with its replay seed; there is no shrinking. */
public func forAll<Value>(
    iterations: Int = 200,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ generate: (inout SplitMix64) -> Value,
    _ property: (Value) throws -> Bool
) rethrows {
    let seed = propertySeed()
    var rng = SplitMix64(seed: seed)
    for iteration in 0..<iterations {
        let value = generate(&rng)
        if try !property(value) {
            Issue.record("Property failed on iteration \(iteration) for \(value). Replay with GTK_PROPERTY_SEED=\(seed).", sourceLocation: sourceLocation)
            return
        }
    }
}

/** The async form of forAll, for properties that exercise async code. */
public func forAllAsync<Value>(
    iterations: Int = 200,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ generate: (inout SplitMix64) -> Value,
    _ property: (Value) async throws -> Bool
) async rethrows {
    let seed = propertySeed()
    var rng = SplitMix64(seed: seed)
    for iteration in 0..<iterations {
        let value = generate(&rng)
        if try await !property(value) {
            Issue.record("Property failed on iteration \(iteration) for \(value). Replay with GTK_PROPERTY_SEED=\(seed).", sourceLocation: sourceLocation)
            return
        }
    }
}
