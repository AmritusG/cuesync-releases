import Foundation

// `public` (id/name/category/all/name(for:)/evaluate(_:t:)) so the CueSync (swift-cross-ui)
// executable target can drive the envelope canvas and the cue table's Interpolation picker
// via a plain `import CueSyncCore` (spec CUESYNC-7 §0.6/§G — the same cross-module-boundary
// reason CuePoint/Track/etc. were widened). `Equatable`/`CustomStringConvertible` let
// swift-cross-ui's `Picker(of:selection:)` (which displays each option via `"\(option)"`,
// see UI/State/AppState.swift's `SortField`) drive the curve dropdown directly. `Sendable`
// (all-value-type members, trivially safe) is required for the Swift 6 compiler to accept
// `public static let all` as a concurrency-safe global.
public struct CurveType: Identifiable, Equatable, CustomStringConvertible, Sendable {
    public let id: Int
    public let name: String
    public let category: String

    public var description: String { name }

    public static let all: [CurveType] = [
        CurveType(id: 1,  name: "Linear",             category: "Basic"),
        CurveType(id: 2,  name: "Quadratic In",       category: "Quadratic"),
        CurveType(id: 3,  name: "Quadratic Out",      category: "Quadratic"),
        CurveType(id: 4,  name: "Quadratic In/Out",   category: "Quadratic"),
        CurveType(id: 5,  name: "Sine In",            category: "Sine"),
        CurveType(id: 6,  name: "Sine Out",           category: "Sine"),
        CurveType(id: 7,  name: "Sine In/Out",        category: "Sine"),
        CurveType(id: 8,  name: "Circular In",        category: "Circular"),
        CurveType(id: 9,  name: "Circular Out",       category: "Circular"),
        CurveType(id: 10, name: "Circular In/Out",    category: "Circular"),
        CurveType(id: 11, name: "Exponential In",     category: "Exponential"),
        CurveType(id: 12, name: "Exponential Out",    category: "Exponential"),
        CurveType(id: 13, name: "Exponential In/Out", category: "Exponential"),
        CurveType(id: 14, name: "Elastic In",         category: "Elastic"),
        CurveType(id: 15, name: "Elastic Out",        category: "Elastic"),
        CurveType(id: 16, name: "Elastic In/Out",     category: "Elastic"),
        CurveType(id: 17, name: "Back In",            category: "Back"),
        CurveType(id: 18, name: "Back Out",           category: "Back"),
        CurveType(id: 19, name: "Back In/Out",        category: "Back"),
        CurveType(id: 20, name: "Bounce In",          category: "Bounce"),
        CurveType(id: 21, name: "Bounce Out",         category: "Bounce"),
        CurveType(id: 22, name: "Bounce In/Out",      category: "Bounce"),
        CurveType(id: 23, name: "Hold",               category: "Basic"),
    ]

    static let categoryOrder = ["Basic", "Quadratic", "Sine", "Circular", "Exponential", "Elastic", "Back", "Bounce"]

    static var grouped: [(category: String, curves: [CurveType])] {
        categoryOrder.compactMap { cat in
            let curves = all.filter { $0.category == cat }
            return curves.isEmpty ? nil : (category: cat, curves: curves)
        }
    }

    public static func name(for id: Int) -> String {
        all.first(where: { $0.id == id })?.name ?? "Linear"
    }

    /// Evaluate the easing function at parameter t (0-1)
    public static func evaluate(_ curveId: Int, t: Double) -> Double {
        // Clamp to 0...1; a non-finite t (NaN/Inf) collapses to 0 so the result is always finite.
        let t = t.isFinite ? min(max(t, 0), 1) : 0
        switch curveId {
        case 1: return t // Linear
        case 2: return t * t // Quadratic In
        case 3: return t * (2 - t) // Quadratic Out
        case 4: return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t // Quadratic In/Out
        case 5: return 1 - cos(t * .pi / 2) // Sine In
        case 6: return sin(t * .pi / 2) // Sine Out
        case 7: return 0.5 * (1 - cos(.pi * t)) // Sine In/Out
        case 8: return 1 - sqrt(1 - t * t) // Circular In
        case 9: let t1 = t - 1; return sqrt(1 - t1 * t1) // Circular Out
        case 10:
            if t < 0.5 { return 0.5 * (1 - sqrt(1 - 4 * t * t)) }
            let t1 = 2 * t - 2; return 0.5 * (sqrt(1 - t1 * t1) + 1)
        case 11: return t == 0 ? 0 : pow(2, 10 * (t - 1)) // Exponential In
        case 12: return t == 1 ? 1 : 1 - pow(2, -10 * t) // Exponential Out
        case 13:
            if t == 0 || t == 1 { return t }
            if t < 0.5 { return 0.5 * pow(2, 20 * t - 10) }
            return 1 - 0.5 * pow(2, -20 * t + 10)
        case 14: // Elastic In
            if t == 0 || t == 1 { return t }
            return -pow(2, 10 * t - 10) * sin((t * 10 - 10.75) * (2 * .pi) / 3)
        case 15: // Elastic Out
            if t == 0 || t == 1 { return t }
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi) / 3) + 1
        case 16: // Elastic In/Out
            if t == 0 || t == 1 { return t }
            if t < 0.5 {
                return -0.5 * pow(2, 20 * t - 10) * sin((20 * t - 11.125) * (2 * .pi) / 4.5)
            }
            return pow(2, -20 * t + 10) * sin((20 * t - 11.125) * (2 * .pi) / 4.5) * 0.5 + 1
        case 17: return t * t * (2.70158 * t - 1.70158) // Back In
        case 18: let t1 = t - 1; return t1 * t1 * (2.70158 * t1 + 1.70158) + 1 // Back Out
        case 19: // Back In/Out
            let c = 1.70158 * 1.525
            if t < 0.5 { return 0.5 * (4 * t * t * ((c + 1) * 2 * t - c)) }
            let t1 = 2 * t - 2; return 0.5 * (t1 * t1 * ((c + 1) * t1 + c) + 2)
        case 20: return 1 - Self.evaluate(21, t: 1 - t) // Bounce In
        case 21: // Bounce Out
            if t < 1 / 2.75 { return 7.5625 * t * t }
            if t < 2 / 2.75 { let t1 = t - 1.5 / 2.75; return 7.5625 * t1 * t1 + 0.75 }
            if t < 2.5 / 2.75 { let t1 = t - 2.25 / 2.75; return 7.5625 * t1 * t1 + 0.9375 }
            let t1 = t - 2.625 / 2.75; return 7.5625 * t1 * t1 + 0.984375
        case 22: // Bounce In/Out
            if t < 0.5 { return 0.5 * Self.evaluate(20, t: 2 * t) }
            return 0.5 * Self.evaluate(21, t: 2 * t - 1) + 0.5
        case 23: return 0 // Hold (step function - value stays at start until next point)
        default: return t
        }
    }
}
