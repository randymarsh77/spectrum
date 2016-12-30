import Accelerate
import Foundation
import Streams
import Surge

public struct Shaping
{
	// include lowest and highest frequency in spectrum
	public var criticalPoints: [Int]

	// an array of criticalPoints.count - 2 values that sum to 1 indicating the percentage granularity of each subrange
	public var weights: [Float]

	public static var Default: Shaping = Shaping(criticalPoints: [ 0, 100, 300, 1000, 3000, 10000, 20000, 22100 ], weights: [ 0.04, 0.05, 0.25, 0.5, 0.1, 0.05, 0.01 ])
}

public struct Windowing
{
	public var size: Int
	public var overlapAdvancement: Int

	public static var Default: Windowing = Windowing(size: 4096, overlapAdvancement: 1764)
}

public struct OutputOptions
{
	public var valueCount: Int
	public var decay: Float

	public static var Default: OutputOptions = OutputOptions(valueCount: 32, decay: 0.99)
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
	public func spectralize(to: Spectrum) -> ReadableStream<[FrequencyDomainValue]> {
		let shape: OneToOneMapping<[Float], [FrequencyDomainValue]> = { data in
			return Shape(data, to.shapingData, to.frequencyDomain)
		}

		return self
			.map(ConvertToMonoChannelAudioChunks)
			.flatten()
			.overlappingChunks(of: to.windowing.size, advancingBy: to.windowing.overlapAdvancement)
			.map(ApplyHanningWindow)
			.map(fft)
			.map(shape)
			.map { ScaleAndTail(frequencyValues: $0, &to.previousMagnitudes, to.outputOptions.decay) }
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

	internal let shapingData: ShapingData
	internal let frequencyDomain: FrequencyDomain
	internal let windowing: Windowing
	internal let outputOptions: OutputOptions
	internal var previousMagnitudes: [Float]
}

internal typealias ShapingData = [Int]

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
		let numBins = i == shaping.criticalPoints.count - 1 ?
			bins - currentBin :
			Int(floor(Float(bins) * weight))
		let numPoints = floor(Double(nextBaseFrequency - currentBaseFrequency) / pointFrequencyValue)
		let pointDist = Int(floor(numPoints / Double(numBins)))
		let freqDist = (nextBaseFrequency - currentBaseFrequency) / numBins
		for j in 0...numBins-1 {
			domain.append((Float(lastFrequency), Float(currentBaseFrequency + (j * freqDist))))
			shapingData.append(currentPoint + pointDist)
			currentPoint = currentPoint + pointDist
			lastFrequency = currentBaseFrequency + (j * freqDist)
		}
		currentBaseFrequency = nextBaseFrequency
		currentBin = currentBin + numBins
	}
	return (shapingData, domain)
}

internal func Shape(_ frequencyValues: [Float], _ shapingData: ShapingData, _ domain: FrequencyDomain) -> [FrequencyDomainValue] {
	var reduced: [FrequencyDomainValue] = []
	var current: Float = 0.0
	var boundaryIterator = shapingData.makeIterator()
	var nextBoundary = boundaryIterator.next()!
	for (i, point) in frequencyValues.enumerated() {
		if (i == nextBoundary) {
			reduced.append(FrequencyDomainValue(magnitude: current, range: domain[i]))
			current = 0
			nextBoundary = boundaryIterator.next() ?? 100000
		}
		current = i == 0 || i == 1 ? 0 : max(current, point)
	}
	return reduced
}

internal func ConvertToMonoChannelAudioChunks(_ data: StereoChannel16BitPCMAudioData) -> [Float] {
	let count = data.count / 2
	let floats = data.withUnsafeBytes { (bits: UnsafePointer<Int16>) -> [Float] in
		let buffer = UnsafeBufferPointer(start: bits, count: count);
		var arr: [Float] = [Float]()
		for i in 0...count - 1 {
			if (i % 2 == 0) {
				arr.append(abs(Float(buffer[i])))
			}
		}
		return arr
	}
	return floats
}

internal func ApplyHanningWindow(_ samples: inout [Float]) {
	vDSP_hann_window(&samples, UInt(samples.count), Int32(vDSP_HALF_WINDOW))
}

internal func ScaleAndTail(frequencyValues: [FrequencyDomainValue], _ previousMagnitudes: inout [Float], _ decayFactor: Float) -> [FrequencyDomainValue] {
	return frequencyValues.enumerated().map { (i, value) in
		let scaled = log(1 + min(1, value.magnitude / 1000)) / log(2)
		previousMagnitudes[i] = max(scaled, previousMagnitudes[i] * decayFactor)
		return FrequencyDomainValue(magnitude: previousMagnitudes[i], range: value.range)
	}
}