/// Reproducible RNG for property/fuzz tests. xorshift64 — fast, no allocs,
/// deterministic across machines and Swift versions. Seeds are pinned per
/// test case so failures can be reproduced from the seed printed on stderr.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0xdead_beef_cafe_babe : seed
    }

    public mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }

    public mutating func int(in range: Range<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound)
        return range.lowerBound + Int(next() % span)
    }

    public mutating func pick<T>(_ elements: [T]) -> T {
        elements[int(in: 0..<elements.count)]
    }
}
