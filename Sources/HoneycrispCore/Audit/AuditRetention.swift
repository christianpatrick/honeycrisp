import Foundation

/// The activity list sizes Settings offers. A config saved before the
/// presets existed may hold any value, so the choices always include the
/// current one.
public enum AuditRetention {
    public static let presets = [500, 1000, 2000, 5000, 10000, 20000]

    /// The presets plus `current` when it is not one of them, ascending.
    public static func choices(including current: Int) -> [Int] {
        Array(Set(presets + [current])).sorted()
    }
}
