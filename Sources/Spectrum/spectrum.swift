import Accelerate
import Foundation
import Streams
import Surge

public struct Shaping
{
	// include lowest and highest frequency in spectrum
	public var criticalPoints: [Int]

	// an array of criticalPoints.count - 1 values that sum to 1 indicating the percentage granularity of each subrange
	public var weights: [Float]

	public init(criticalPoints: [Int], weights: [Float]) {
		assert(criticalPoints.count == weights.count + 1)
		assert(weights.reduce(0) { (acc, v) in acc + v } - 1.0 < 0.000001)
		self.criticalPoints = criticalPoints
		self.weights = weights
	}

	public static var Default: Shaping = Shaping(criticalPoints: [ 0, 100, 300, 1000, 3000, 10000, 20000, 22100 ], weights: [ 0.04, 0.05, 0.25, 0.5, 0.1, 0.05, 0.01 ])
}

public struct WindowingModeFlag: OptionSet {
    public let rawValue: Int32

    public static let None = WindowingModeFlag(rawValue: 0)
	public static let HalfWindow = WindowingModeFlag(rawValue: Int32(vDSP_HALF_WINDOW))

	public init(rawValue: Int32)
	{
		self.rawValue = rawValue
	}
}

public struct HanningWindowingModeFlag: OptionSet {
    public let rawValue: Int32

    public static let None = HanningWindowingModeFlag(rawValue: 0)
	public static let HalfWindow = HanningWindowingModeFlag(rawValue: Int32(vDSP_HALF_WINDOW))
	public static let Norm = HanningWindowingModeFlag(rawValue: Int32(vDSP_HANN_NORM))
	public static let Denorm = HanningWindowingModeFlag(rawValue: Int32(vDSP_HANN_DENORM))

	public init(rawValue: Int32)
	{
		self.rawValue = rawValue
	}
}

public enum WindowingMode
{
	case None
	case Hanning(HanningWindowingModeFlag)
	case Blackman(WindowingModeFlag)
	case Hamming(WindowingModeFlag)
}

public struct Windowing
{
	public var mode: WindowingMode
	public var size: Int
	public var overlapAdvancement: Int

	public init(mode: WindowingMode, size: Int, overlapAdvancement: Int) {
		self.mode = mode
		self.size = size
		self.overlapAdvancement = overlapAdvancement
	}

	public static var Default: Windowing = Windowing(mode: .Hanning([.HalfWindow]), size: 4096, overlapAdvancement: 1764)
}

public enum ScalingStrategy
{
	case None
	case StaticMax(Float)
	case Adaptive(Float)
}

public struct OutputOptions
{
	public var valueCount: Int
	public var decay: Float
	public var scaling: ScalingStrategy

	public init(valueCount: Int, decay: Float, scaling: ScalingStrategy) {
		self.valueCount = valueCount
		self.decay = decay
		self.scaling = scaling
	}

	public static var Default: OutputOptions = OutputOptions(valueCount: 128, decay: 0.90, scaling: .None)
}

public typealias FrequencyRange = (Float, Float)
public typealias FrequencyDomain = [FrequencyRange]

public struct FrequencyDomainValue
{
	public var magnitude: Float
	public var range: FrequencyRange
}

public typealias StereoChannel16BitPCMAudioData = Data

public extension IReadableStream where Self.ChunkType == StereoChannel16BitPCMAudioData
{
	func spectralize(to: Spectrum) throws -> ReadableStream<[FrequencyDomainValue]> {
		let shape: OneToOneMapping<[Float], [FrequencyDomainValue]> = { data in
			return Shape(data, to.shapingData, to.frequencyDomain)
		}

		return try self
			.map(ConvertToMonoChannelAudioChunks)
			.flatten()
			.overlappingChunks(of: to.windowing.size, advancingBy: to.windowing.overlapAdvancement)
			.map { samples in ApplyWindow(to.windowing.mode, &samples) }
			.map(fft)
			.map(shape)
			.map { (v: [FrequencyDomainValue]) in ApplyScaleAndDecay(frequencyValues: v, &to.previousMagnitudes, to.outputOptions) }
	}
}

public class Spectrum
{
	public static var Default: Spectrum = Spectrum(Shaping.Default, Windowing.Default, OutputOptions.Default)

	public init(_ shaping: Shaping, _ windowing: Windowing, _ outputOptions: OutputOptions) {
		(shapingData, frequencyDomain) = CreateShapingData(shaping, outputOptions.valueCount, windowing.size)
		self.windowing = windowing
		self.outputOptions = outputOptions
		previousMagnitudes = [Float](repeating: 0.0, count: windowing.size)
	}

	public let shapingData: ShapingData
	public let frequencyDomain: FrequencyDomain
	public let windowing: Windowing
	public let outputOptions: OutputOptions

	internal var previousMagnitudes: [Float]
}

public typealias ShapingData = [Int]

internal func CreateShapingData(_ shaping: Shaping, _ bins: Int, _ points: Int) -> (ShapingData, FrequencyDomain) {
	let maxFrequency = shaping.criticalPoints.last!
	let pointFrequencyValue = Double(maxFrequency) / Double(points)
	var shapingData: [Int] = []
	var domain: FrequencyDomain = []
	var currentBin = 0
	var currentPoint = 0
	var currentBaseFrequency = shaping.criticalPoints[0]
	var lastFrequency = currentBaseFrequency
	for (i, weight) in shaping.weights.enumerated() {
		let nextBaseFrequency = shaping.criticalPoints[i+1]
		let numBins = Int(max(1, round(Float(bins+1) * weight)))
		let numPoints = ceil(Double(nextBaseFrequency - currentBaseFrequency) / pointFrequencyValue)
		let pointDist = Int(ceil(numPoints / Double(numBins)))
		let freqDist = (nextBaseFrequency - currentBaseFrequency) / numBins
		for j in 1...numBins {
			domain.append((Float(lastFrequency), Float(currentBaseFrequency + (j * freqDist))))
			shapingData.append(currentPoint + pointDist)
			currentPoint = currentPoint + pointDist
			lastFrequency = currentBaseFrequency + (j * freqDist)
		}
		currentBaseFrequency = nextBaseFrequency
		currentBin = currentBin + numBins
	}
	assert(domain.count == bins)
	return (shapingData, domain)
}

internal func Shape(_ frequencyValues: [Float], _ shapingData: ShapingData, _ domain: FrequencyDomain) -> [FrequencyDomainValue] {
	var reduced: [FrequencyDomainValue] = []
	var current: Float = 0.0
	var boundaryIterator = shapingData.makeIterator()
	var nextBoundary = boundaryIterator.next()!
	for (i, point) in frequencyValues.enumerated() {
		if (i == nextBoundary) {
			reduced.append(FrequencyDomainValue(magnitude: current, range: domain[shapingData.firstIndex(of: nextBoundary)!]))
			current = 0
			nextBoundary = boundaryIterator.next() ?? 100000
		}
		current = i == 0 || i == 1 ? 0 : max(current, point)
	}
	return reduced
}

internal func ConvertToMonoChannelAudioChunks(_ data: StereoChannel16BitPCMAudioData) -> [Float] {
	let count = data.count / 2
	let floats = data.withUnsafeBytes { (bits: UnsafeRawBufferPointer) -> [Float] in
		var arr: [Float] = [Float]()
		for i in 0...count - 1 {
			if (i % 2 == 0) {
				arr.append(abs(Float(bits[i])))
			}
		}
		return arr
	}
	return floats
}

internal func ApplyWindow(_ mode: WindowingMode, _ samples: inout [Float]) {
	switch mode {
	case .Hanning(let flag):
		vDSP_hann_window(&samples, UInt(samples.count), flag.rawValue)
	case .Blackman(let flag):
		vDSP_blkman_window(&samples, UInt(samples.count), flag.rawValue)
	case .Hamming(let flag):
		vDSP_hamm_window(&samples, UInt(samples.count), flag.rawValue)
	case .None:
		return
	}
}

internal func ApplyScaleAndDecay(frequencyValues: [FrequencyDomainValue], _ previousMagnitudes: inout [Float], _ options: OutputOptions) -> [FrequencyDomainValue] {
	return frequencyValues.enumerated().map { (i, value) in
		let scaled = Scale(value: value.magnitude, using: options.scaling)
		previousMagnitudes[i] = max(scaled, previousMagnitudes[i] * options.decay)
		return FrequencyDomainValue(magnitude: previousMagnitudes[i], range: value.range)
	}
}

internal func Scale(value: Float, using: ScalingStrategy)-> Float {
	switch using {
	case .None:
		return value
	case .StaticMax(let max):
		return log(1 + min(1, value / max)) / log(2)
	case .Adaptive(let lifetime):
		return log(1 + min(1, value / lifetime)) / log(2)
	}
}
