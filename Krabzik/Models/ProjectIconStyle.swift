import Foundation

struct ProjectIconStyle: Codable, Equatable {
    var hex = "687080"
    var glass = true

    var isValid: Bool {
        hex.count == 6 && hex.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }
}
