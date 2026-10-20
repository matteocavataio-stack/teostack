import Foundation

/// Velocità a media mobile su una finestra temporale scorrevole.
public struct RateWindow {
    private var samples: [(time: TimeInterval, value: Int64)] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    public mutating func add(time: TimeInterval, value: Int64) {
        samples.append((time, value))
        while samples.count > 2, let first = samples.first, time - first.time > window {
            samples.removeFirst()
        }
    }

    /// byte/s sulla finestra; 0 se i dati non bastano.
    public var rate: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return Double(last.value - first.value) / (last.time - first.time)
    }

    public mutating func reset() { samples.removeAll() }
}
