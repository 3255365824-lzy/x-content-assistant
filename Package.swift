// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XContentAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XContentAssistant", targets: ["XContentAssistant"]),
        .executable(name: "XContentAssistantCoreTestRunner", targets: ["XContentAssistantCoreTestRunner"]),
        .executable(name: "XReplyBridge", targets: ["XReplyBridge"])
    ],
    targets: [
        .executableTarget(name: "XReplyBridge", dependencies: ["XContentAssistantCore"], path: "Sources/XReplyBridge"),
        .target(
            name: "XContentAssistantCore",
            path: "Sources/XContentAssistantCore"
        ),
        .executableTarget(
            name: "XContentAssistant",
            dependencies: ["XContentAssistantCore"],
            path: "Sources/XContentAssistant", exclude: ["ModelTestHarness.swift"]
        ),
        .executableTarget(
            name: "XContentAssistantCoreTestRunner",
            dependencies: ["XContentAssistantCore"],
            path: "Tests/TestRunner"
        )
    ]
)
