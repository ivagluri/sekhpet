// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SekhPet",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SekhPet",
            linkerSettings: [
                .linkedFramework("SceneKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
