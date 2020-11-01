// swift-tools-version:5.1
import PackageDescription

let package = Package(
	name: "Spectrum",
	products: [
		.library(
			name: "Spectrum",
			targets: ["Spectrum"]
		),
	],
	dependencies: [
		.package(url: "https://github.com/randymarsh77/streams", .branch("master")),
		.package(url: "https://github.com/Jounce/surge", .branch("master")),
	],
	targets: [
		.target(
			name: "Spectrum",
			dependencies: ["Streams", "Surge"]
		),
	]
)
