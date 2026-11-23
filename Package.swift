// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CliHeads",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CliHeads", targets: ["CliHeads"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")],
    targets: [
        .executableTarget(name: "CliHeads", dependencies: ["SwiftTerm"], path: "Sources/CliHeads")
    ]
)
