import Foundation

/// The owner of the brain ("Yo"/"Me" in every transcript) lives in `people/README.md`, which the
/// schema tells Claude to read; filling it in up front saves Claude from guessing it per meeting.
public extension VaultStore {
    static let ownerFile = "people/README.md"
    private static let ownerLine = #/^- \*\*(?:Nombre|Name):\*\*[ \t]*(.*)$/#.anchorsMatchLineEndings()
    private static let unknownOwner = ["_aún no identificado_", "_not identified yet_", ""]

    /// The owner's name, or nil while it is still unknown.
    func ownerName() -> String? {
        guard let text = try? read(Self.ownerFile),
              let match = text.firstMatch(of: Self.ownerLine) else { return nil }
        let name = Self.displayName(String(match.1))
        return Self.unknownOwner.contains(name) ? nil : name
    }

    /// "Jaime — ver [[jaime]]" / "[[jaime|Jaime]]" → "Jaime" (Claude may link the owner's page).
    private static func displayName(_ value: String) -> String {
        var name = value.components(separatedBy: " — ").first ?? value
        name = name.replacing(#/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/#) { String($0.1) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Writes the owner's name (empty resets it to "not identified yet").
    func setOwnerName(_ name: String) throws {
        let url = url(for: Self.ownerFile)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let value = clean.isEmpty ? Self.unknownOwner[0] : clean
        if let match = text.firstMatch(of: Self.ownerLine) {
            guard Self.displayName(String(match.1)) != value else { return }
            text.replaceSubrange(match.range, with: "- **Nombre:** \(value)")
        } else {
            text += "\n- **Nombre:** \(value)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        Log.info("owner name set")
    }
}
