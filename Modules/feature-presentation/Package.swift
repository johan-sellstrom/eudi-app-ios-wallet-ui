// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "feature-presentation",
  platforms: [.iOS(.v17)],
  products: [
    .library(
      name: "feature-presentation",
      targets: ["feature-presentation"])
  ],
  dependencies: [
    .package(name: "feature-common", path: "./feature-common"),
    .package(name: "feature-test", path: "./feature-test"),
    .package(
      url: "https://github.com/iProov/ios-spm.git",
      .upToNextMajor(from: "13.1.1")
    )
  ],
  targets: [
    .target(
      name: "feature-presentation",
      dependencies: [
        "feature-common",
        .product(name: "iProov", package: "ios-spm")
      ],
      path: "./Sources"
    ),
    .testTarget(
      name: "feature-presentation-tests",
      dependencies: [
        "feature-presentation",
        "feature-common",
        "feature-test"
      ],
      path: "./Tests"
    )
  ]
)
