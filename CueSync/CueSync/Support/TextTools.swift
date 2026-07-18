import Foundation

/// Pure-Swift text hardening for two trust-boundary jobs: turning arbitrary,
/// possibly-untrusted text into a safe filename component (`slugify`), and minting
/// an unguessable identifier (`generateToken`). No `AppKit`/`SwiftUI`/`Security`
/// dependency, so this stays in the shared `CueSyncCore` target and compiles
/// identically on macOS, Windows, and Linux (spec CUESYNC-7 §2/§5).
public enum TextTools {
    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// Windows device names reserved regardless of case or extension. Checked against
    /// the fully-reduced slug (punctuation already collapsed to `-`), so a name like
    /// `"CON.txt"` — whose `.` becomes a separator before this check ever runs — is
    /// already `"con-txt"` and never collides with the bare reserved token `"con"`.
    private static let reservedDeviceNames: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul"]
        for n in 1...9 {
            names.insert("com\(n)")
            names.insert("lpt\(n)")
        }
        return names
    }()

    /// Turns arbitrary text — a track title from a parsed file, a user-typed preset
    /// name, anything crossing the untrusted-input boundary described in spec §4 —
    /// into a single, traversal-free, cross-platform-safe path *component*. Never
    /// returns a path (no `/`, no `\`), never `.` or `..`, and never a bare Windows
    /// reserved device name. Deterministic and idempotent:
    /// `slugify(slugify(x)) == slugify(x)`.
    ///
    /// - Parameters:
    ///   - input: Arbitrary text, potentially from an untrusted source.
    ///   - maxLength: Maximum length of the returned slug. The result is truncated on
    ///     a separator boundary so it never ends in `-`.
    ///   - fallback: Returned verbatim when `input` reduces to nothing (empty,
    ///     whitespace-only, or entirely stripped). Must itself be a valid, non-empty
    ///     slug — the default `"untitled"` is.
    public static func slugify(_ input: String, maxLength: Int = 80, fallback: String = "untitled") -> String {
        // .lowercased() (no Locale) is Unicode default case folding — deterministic
        // across platforms and immune to the Turkish-I divergence a Locale-aware
        // lowercase would introduce (spec §2.2, §5).
        let rawSlug = slugComponents(of: input.lowercased()).joined(separator: "-")
        guard !rawSlug.isEmpty else { return fallback }

        let escaped = reservedDeviceNames.contains(rawSlug) ? "_" + rawSlug : rawSlug
        let truncated = truncatedOnSeparatorBoundary(escaped, maxLength: maxLength)
        guard !truncated.isEmpty else { return fallback }
        return truncated
    }

    /// Splits `input` into runs of ASCII `[a-z0-9]`, dropping every other character
    /// (whitespace, `/`, `\`, `.`, NUL, control characters, non-ASCII letters/digits —
    /// stripped rather than transliterated, since ICU transliteration is not
    /// byte-identical across platforms, spec §5). Each returned component is a
    /// nonempty run; joining them with `-` is exactly "collapse separator runs to a
    /// single `-`, trim leading/trailing `-`".
    private static func slugComponents(of input: String) -> [String] {
        var components: [String] = []
        var current = ""
        for scalar in input.unicodeScalars {
            let isLowerAZ = scalar.value >= 0x61 && scalar.value <= 0x7A // a-z
            let isDigit09 = scalar.value >= 0x30 && scalar.value <= 0x39 // 0-9
            if isLowerAZ || isDigit09 {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                components.append(current)
                current = ""
            }
        }
        if !current.isEmpty { components.append(current) }
        return components
    }

    /// Truncates `slug` to at most `maxLength` characters, cutting at the last `-`
    /// within that window so a word is never split with a dangling separator left
    /// behind. Falls back to a hard cut only when no separator exists in the window.
    private static func truncatedOnSeparatorBoundary(_ slug: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard slug.count > maxLength else { return slug }
        let window = String(slug.prefix(maxLength))
        guard let lastDash = window.lastIndex(of: "-") else { return window }
        return String(window[..<lastDash])
    }

    /// Generates a `length`-character identifier over `[0-9a-f]`, sourced from
    /// `SystemRandomNumberGenerator` — the standard library's CSPRNG (`arc4random` on
    /// Darwin, `getrandom`/`/dev/urandom` on Linux, `BCryptGenRandom` on Windows, spec
    /// §4). Whole bytes are hex-encoded (never `Int.random(in:) % n`), so there is no
    /// modulo bias. Replaces timestamp- or counter-derived identifiers, which are
    /// predictable and can collide.
    ///
    /// - Parameter length: Number of hex characters to return. `0` or negative
    ///   returns `""`. Odd lengths draw one extra byte and emit only its first nibble.
    public static func generateToken(length: Int = 32) -> String {
        guard length > 0 else { return "" }
        var rng = SystemRandomNumberGenerator()
        let byteCount = (length + 1) / 2
        var token = ""
        token.reserveCapacity(length)
        for _ in 0..<byteCount {
            let byte = UInt8.random(in: .min ... .max, using: &rng)
            token.append(hexDigits[Int(byte >> 4)])
            token.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(token.prefix(length))
    }
}
