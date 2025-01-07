import Accelerate
import Crystal
import Foundation
import Surge

public struct Shaping: Sendable {
	// include lowest and highest frequency in spectrum
	public let criticalPoints: [Int]

	// an array of criticalPoints.count - 1 values that sum to 1 indicating the percentage granularity of each subrange
	public let weights: [Float]

	public init(criticalPoints: [Int], weights: [Float]) {
		assert(criticalPoints.count == weights.count + 1)
		assert(weights.reduce(0) { (acc, v) in acc + v } - 1.0 < 0.000001)
		self.criticalPoints = criticalPoints
		self.weights = weights
	}

	public static let Default: Shaping = Shaping(
		criticalPoints: [0, 100, 300, 1000, 3000, 10000, 20000, 22100],
		weights: [0.04, 0.05, 0.25, 0.5, 0.1, 0.05, 0.01])
}

public struct WindowingModeFlag: OptionSet, Sendable {
	public let rawValue: Int32

	public static let None = WindowingModeFlag([])
	public static let HalfWindow = WindowingModeFlag(rawValue: Int32(vDSP_HALF_WINDOW))

	public init(rawValue: Int32) {
		self.rawValue = rawValue
	}
}

public struct HanningWindowingModeFlag: OptionSet, Sendable {
	public let rawValue: Int32

	public static let None = HanningWindowingModeFlag([])
	public static let HalfWindow = HanningWindowingModeFlag(rawValue: Int32(vDSP_HALF_WINDOW))
	public static let Norm = HanningWindowingModeFlag(rawValue: Int32(vDSP_HANN_NORM))
	public static let Denorm = HanningWindowingModeFlag(rawValue: Int32(vDSP_HANN_DENORM))

	public init(rawValue: Int32) {
		self.rawValue = rawValue
	}
}

public enum WindowingMode: Sendable {
	case None
	case Hanning(HanningWindowingModeFlag)
	case Blackman(WindowingModeFlag)
	case Hamming(WindowingModeFlag)
}

public struct Windowing: Sendable {
	public let mode: WindowingMode
	public let size: Int
	public let overlapAdvancement: Int

	public init(mode: WindowingMode, size: Int, overlapAdvancement: Int) {
		self.mode = mode
		self.size = size
		self.overlapAdvancement = overlapAdvancement
	}

	public static let Default: Windowing = Windowing(
		mode: .Hanning([.HalfWindow]), size: 4096, overlapAdvancement: 1764)
}

public enum ScalingStrategy: Sendable {
	case None
	case StaticMax(Float)
	case Adaptive(Float)
}

public struct OutputOptions: Sendable {
	public let valueCount: Int
	public let decay: Float
	public let scaling: ScalingStrategy

	public init(valueCount: Int, decay: Float, scaling: ScalingStrategy) {
		self.valueCount = valueCount
		self.decay = decay
		self.scaling = scaling
	}

	public static let Default: OutputOptions = OutputOptions(
		valueCount: 128, decay: 0.90, scaling: .None)
}

public typealias FrequencyRange = (Float, Float)
public typealias FrequencyDomain = [FrequencyRange]

public struct FrequencyDomainValue: Sendable {
	public let magnitude: Float
	public let range: FrequencyRange
}

@available(iOS 13.0, *)
@available(macOS 10.15, *)
extension AsyncStream where Self.Element == AudioData {
	public func spectralize(to: Spectrum) throws -> AsyncStream<[FrequencyDomainValue]> {
		return AsyncStream<[FrequencyDomainValue]> { continuation in
			Task {
				let chunkAccumulator = OverlappingChunkAccumulator<Float>(
					chunkSize: to.windowing.size, advanceBy: to.windowing.overlapAdvancement)
				let state = SpectralState(size: to.windowing.size)
				let partiallyMapped =
					self
					.map(ConvertToMonoChannelAudioChunks)
					.compactMap { x in chunkAccumulator.accumulate(x) }
				for await floatChunks in partiallyMapped {
					for samples in floatChunks {
						// TODO: Avoid array copy
						var mutableSamples = samples
						let windowed = ApplyWindow(to.windowing.mode, &mutableSamples)
						let rawFrequencies = fft(windowed)
						let shaped = Shape(rawFrequencies, to.shapingData, to.frequencyDomain)
						let result = ApplyScaleAndDecay(
							frequencyValues: shaped, &state.previousMagnitudes, to.outputOptions)

						continuation.yield(result)
					}
				}
				continuation.finish()
			}
		}
	}
}

public struct Spectrum: Sendable {
	public static let Default: Spectrum = Spectrum(
		Shaping.Default, Windowing.Default, OutputOptions.Default)

	public init(_ shaping: Shaping, _ windowing: Windowing, _ outputOptions: OutputOptions) {
		(shapingData, frequencyDomain) = CreateShapingData(
			shaping, outputOptions.valueCount, windowing.size)
		self.windowing = windowing
		self.outputOptions = outputOptions
	}

	public let shapingData: ShapingData
	public let frequencyDomain: FrequencyDomain
	public let windowing: Windowing
	public let outputOptions: OutputOptions
}

@available(macOS 10.15.0, *)
internal final class SpectralState: @unchecked Sendable {
	public var previousMagnitudes: [Float]
	public init(size: Int) {
		self.previousMagnitudes = [Float](repeating: 0.0, count: size)
	}
}

internal final class OverlappingChunkAccumulator<T>: @unchecked Sendable {
	internal init(chunkSize: Int, advanceBy: Int) {
		_chunkSize = chunkSize
		_advanceBy = advanceBy
	}

	func accumulate(_ data: [T]) -> [[T]]? {
		var result: [[T]]?

		let toFill = min(data.count, _chunkSize - _accumulator.count)
		let leftovers = toFill < data.count ? data[toFill...data.count - 1] : []
		_accumulator.append(contentsOf: data[0...toFill - 1])
		if _accumulator.count == _chunkSize {
			result = [_accumulator]
			_accumulator = Array(_accumulator[_advanceBy..._chunkSize - 1])
		}

		if leftovers.count != 0 {
			if let additional = accumulate(Array(leftovers)) {
				for chunk in additional {
					result!.append(chunk)
				}
			}
		}

		return result
	}

	let _chunkSize: Int
	let _advanceBy: Int
	var _accumulator: [T] = []
}

public typealias ShapingData = [Int]

internal func CreateShapingData(_ shaping: Shaping, _ bins: Int, _ points: Int) -> (
	ShapingData, FrequencyDomain
) {
	let maxFrequency = shaping.criticalPoints.last!
	let pointFrequencyValue = Double(maxFrequency) / Double(points)
	var shapingData: [Int] = []
	var domain: FrequencyDomain = []
	var currentBin = 0
	var currentPoint = 0
	var currentBaseFrequency = shaping.criticalPoints[0]
	var lastFrequency = currentBaseFrequency
	for (i, weight) in shaping.weights.enumerated() {
		let nextBaseFrequency = shaping.criticalPoints[i + 1]
		let numBins = Int(max(1, round(Float(bins + 1) * weight)))
		let numPoints = ceil(Double(nextBaseFrequency - currentBaseFrequency) / pointFrequencyValue)
		let pointDist = Int(ceil(numPoints / Double(numBins)))
		let freqDist = (nextBaseFrequency - currentBaseFrequency) / numBins
		for j in 1...numBins {
			domain.append((Float(lastFrequency), Float(currentBaseFrequency + (j * freqDist))))
			shapingData.append(currentPoint + pointDist)
			currentPoint += pointDist
			lastFrequency = currentBaseFrequency + (j * freqDist)
		}
		currentBaseFrequency = nextBaseFrequency
		currentBin += numBins
	}
	assert(domain.count == bins)
	return (shapingData, domain)
}

internal func Shape(
	_ frequencyValues: [Float], _ shapingData: ShapingData, _ domain: FrequencyDomain
) -> [FrequencyDomainValue] {
	var reduced: [FrequencyDomainValue] = []
	var current: Float = 0.0
	var boundaryIterator = shapingData.makeIterator()
	var nextBoundary = boundaryIterator.next()!
	for (i, point) in frequencyValues.enumerated() {
		if i == nextBoundary {
			reduced.append(
				FrequencyDomainValue(
					magnitude: current, range: domain[shapingData.firstIndex(of: nextBoundary)!]))
			current = 0
			nextBoundary = boundaryIterator.next() ?? 100000
		}
		current = i == 0 || i == 1 ? 0 : max(current, point)
	}
	return reduced
}

internal func ConvertToMonoChannelAudioChunks(_ audioData: AudioData) -> [Float] {
	let data = audioData.data
	// TODO: Stop assuming this is StereoChannel16BitPCMAudioData
	let count = data.count
	let floats = data.withUnsafeBytes { (bits: UnsafeRawBufferPointer) -> [Float] in
		var arr: [Float] = [Float]()
		for i in 0...count - 1 where i % 2 == 0 {
			let n = Int16(bits[i])
			let np = (n >> 8) | (n << 8)  // reverse endian
			arr.append(Float(np))
		}
		return arr
	}
	return floats
}

internal func ApplyWindow(_ mode: WindowingMode, _ samples: inout [Float]) -> [Float] {
	switch mode {
	case .Hanning(let flag):
		vDSP_hann_window(&samples, UInt(samples.count), flag.rawValue)
	case .Blackman(let flag):
		vDSP_blkman_window(&samples, UInt(samples.count), flag.rawValue)
	case .Hamming(let flag):
		vDSP_hamm_window(&samples, UInt(samples.count), flag.rawValue)
	case .None:
		break
	}
	return samples
}

internal func ApplyScaleAndDecay(
	frequencyValues: [FrequencyDomainValue], _ previousMagnitudes: inout [Float],
	_ options: OutputOptions
) -> [FrequencyDomainValue] {
	return frequencyValues.enumerated().map { (i, value) in
		let scaled = Scale(value: value.magnitude, using: options.scaling)
		previousMagnitudes[i] = max(scaled, previousMagnitudes[i] * options.decay)
		return FrequencyDomainValue(magnitude: previousMagnitudes[i], range: value.range)
	}
}

internal func Scale(value: Float, using: ScalingStrategy) -> Float {
	switch using {
	case .None:
		return value
	case .StaticMax(let max):
		return log(1 + min(1, value / max)) / log(2)
	case .Adaptive(let lifetime):
		return log(1 + min(1, value / lifetime)) / log(2)
	}
}
