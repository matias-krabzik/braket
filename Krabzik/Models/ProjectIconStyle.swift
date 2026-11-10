import Foundation

struct ProjectIconStyle: Codable, Equatable {
    var hex = "687080"
    var glass = true
    var letters = ""

    init(hex: String = "687080", glass: Bool = true, letters: String = "") {
        self.hex = hex
        self.glass = glass
        self.letters = letters
    }

    private enum CodingKeys: String, CodingKey { case hex, glass, letters }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hex = try values.decode(String.self, forKey: .hex)
        glass = try values.decode(Bool.self, forKey: .glass)
        letters = try values.decodeIfPresent(String.self, forKey: .letters) ?? ""
    }

    func label(for name: String) -> String {
        let custom = letters.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return initials.isEmpty ? "<>" : initials
    }

    var isValid: Bool {
        letters.count <= 4 && letters.isValidProjectText()
            && hex.count == 6 && hex.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }
}
