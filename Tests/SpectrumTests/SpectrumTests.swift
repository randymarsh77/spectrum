import XCTest

@testable import Spectrum

class SpectrumTests: XCTestCase {
	func testOverlappingChunkAccumulator() {
		let input = [[1, 2, 3, 4, 5, 6]]
		let chunkAccumulator = OverlappingChunkAccumulator<Int>(chunkSize: 3, advanceBy: 1)

		let result = input
			.compactMap { x in chunkAccumulator.accumulate(x) }
			.flatMap { $0 }
		XCTAssertEqual(result, [[1, 2, 3], [2, 3, 4], [3, 4, 5], [4, 5, 6]])
	}
}
