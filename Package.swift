// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nylon",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Nylon", targets: ["NylonApp"])], // the binary's name, which macOS shows in window titles
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")],
    targets: [
        .executableTarget(name: "NylonApp", dependencies: ["Yams"], resources: [.process("Resources")]),
        .testTarget(name: "NylonAppTests", dependencies: ["NylonApp"]),
    ]
)
