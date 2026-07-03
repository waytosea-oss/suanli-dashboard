// swift-tools-version: 6.0

import PackageDescription
import Foundation

let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Library/Developer/CommandLineTools"
let testingFrameworks = developerDir + "/Library/Developer/Frameworks"
let testingLibraries = developerDir + "/Library/Developer/usr/lib"
let testingFlags: [SwiftSetting] = FileManager.default.fileExists(atPath: testingFrameworks + "/Testing.framework")
  ? [.unsafeFlags(["-F", testingFrameworks], .when(platforms: [.macOS]))]
  : []
let testingLinkerFlags: [LinkerSetting] = FileManager.default.fileExists(atPath: testingFrameworks + "/Testing.framework")
  ? [.unsafeFlags([
    "-F", testingFrameworks,
    "-Xlinker", "-rpath", "-Xlinker", testingFrameworks,
    "-Xlinker", "-rpath", "-Xlinker", testingLibraries
  ], .when(platforms: [.macOS]))]
  : []

let package = Package(
  name: "CodexBalanceDashboard",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "CodexBalance", targets: ["CodexBalance"])
  ],
  targets: [
    .target(name: "CodexBalanceCore"),
    .executableTarget(
      name: "CodexBalance",
      dependencies: ["CodexBalanceCore"]
    ),
    .executableTarget(
      name: "TestRunner",
      dependencies: ["CodexBalanceCore"],
      swiftSettings: testingFlags,
      linkerSettings: testingLinkerFlags
    ),
    .testTarget(
      name: "CodexBalanceCoreTests",
      dependencies: ["CodexBalanceCore"],
      swiftSettings: testingFlags,
      linkerSettings: testingLinkerFlags
    )
  ]
)
