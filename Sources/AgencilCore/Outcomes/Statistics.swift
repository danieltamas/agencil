import Foundation

public enum Wilson {
    private static let z = 1.96

    /// The Wilson score interval of `successes` in `total`, clamped to [0, 1]; nil for an empty sample.
    public static func interval(successes: Int, total: Int) -> (lower: Double, upper: Double)? {
        guard total > 0 else { return nil }
        let n = Double(total), p = Double(successes) / n
        let centre = p + z * z / (2 * n)
        let spread = z * (p * (1 - p) / n + z * z / (4 * n * n)).squareRoot()
        let scale = 1 + z * z / n
        return (max(0, (centre - spread) / scale), min(1, (centre + spread) / scale))
    }
}

/// A rate with its sample: `n=0` is shown when there is nothing to divide, never 0%.
public struct Share: Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, of denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public var value: Double? { denominator > 0 ? Double(numerator) / Double(denominator) : nil }
    public var interval: (lower: Double, upper: Double)? { Wilson.interval(successes: numerator, total: denominator) }
    public var display: String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "n=0" }
}
