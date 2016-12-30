import PackageDescription

let package = Package(
    name: "Spectrum",
    dependencies: [
		.Package(url: "https://github.com/randymarsh77/streams", majorVersion: 0),
		.Package(url: "https://github.com/randymarsh77/surge", majorVersion: 1),
	]
)
