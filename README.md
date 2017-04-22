# Spectrum
Audio samples in. Frequency domain out.

[![license](https://img.shields.io/github/license/mashape/apistatus.svg)]()
[![GitHub release](https://img.shields.io/github/release/randymarsh77/spectrum.svg)]()
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![Build Status](https://api.travis-ci.org/randymarsh77/spectrum.svg?branch=master)](https://travis-ci.org/randymarsh77/spectrum)
[![codebeat badge](https://codebeat.co/badges/6e4b6f25-7372-4ae1-b975-ab814be4ff0b)](https://codebeat.co/projects/github-com-randymarsh77-spectrum-master)

# Usage

Spectrum defines an extension method, `spectralize` that performs a stream transform from `IReadableStream<StereoChannel16BitPCMAudioData>` to `ReadableStream<[FrequencyDomainValue]>`. `StereoChannel16BitPCMAudioData` is a simple typealias for `Data`, but the bytes are assumed to be in the typed format.

# Example

The following example uses [Crystal](https://github.com/randymarsh77/crystal) to generate the input audio stream. Spectrum transforms that audio stream into a series of frequency domain snapshots. We define a view that renders some vertical bars and exposes an input stream for each frame that should be rendered (a frequency domain snapshot). 

Given the view:

```
import AudioToolbox
import Crystal
import Spectrum
import Streams

let v = View(frame: view.bounds)

let propertyData = try! ASBDFactory.CreateDefaultDescription(format: kAudioFormatLinearPCM)
let (q, audio) = try! AQFactory.CreateDefaultInputQueue(propertyData: propertyData)
audio
  .spectralize(to: Spectrum.Default)
  .pipe(to: v.input)

AudioQueueStart(q, nil)
```

The view that will draw the frequency graph:

```
import AppKit
import Spectrum
import Streams

public class View : NSView
{
	public var input: WriteableStream<[FrequencyDomainValue]>

	var stream: Stream<[FrequencyDomainValue]>
	var points: [FrequencyDomainValue] = []

	override init(frame frameRect: NSRect) {
		stream = Stream<[FrequencyDomainValue]>()
		input = WriteableStream(stream)

		super.init(frame: frameRect)

		_ = stream.subscribe {
			self.points = $0
			self.setNeedsDisplay(self.bounds)
		}
	}

	override public func draw(_ dirtyRect: NSRect) {
		if (points.count == 0) {
			return
		}

		let width = floor(self.bounds.width / CGFloat(points.count))

		for (i, point) in points.enumerated() {
			let rect = NSRect(x: CGFloat(i) * (width + 1), y: 0.0, width: width, height: CGFloat(point.magnitude) * self.bounds.height)
			let path = NSBezierPath(rect: rect)

			NSColor.orange.set()
			path.fill()

			NSColor.black.set()
			path.stroke()
		}
	}

	required public init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}
```
