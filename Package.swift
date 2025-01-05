// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "Spectrum",
	products: [
		.library(
			name: "Spectrum",
			targets: ["Spectrum"]
		)
	],
	dependencies: [
		.package(url: "https://github.com/randymarsh77/crystal", branch: "master"),
		.package(url: "https://github.com/Jounce/surge", branch: "master"),
	],
	targets: [
		.target(
			name: "Spectrum",
			dependencies: [
				.product(name: "Crystal", package: "Crystal"),
				.product(name: "Surge", package: "Surge"),
			]
		),
		.testTarget(name: "SpectrumTests", dependencies: ["Spectrum"]),
	]
)
