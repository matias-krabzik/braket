// swift-tools-version:5.9
import PackageDescription

// SwiftTerm v1.9.0, 8840e3596739adfe9599c0e7fff89f4fa88bedcf.
// Use its built-in forkpty backend; omit CLI and optional swift-subprocess targets.
let package = Package(name: "SwiftTerm", platforms: [.macOS(.v14)],
                      products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
                      targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["iOS"])])
