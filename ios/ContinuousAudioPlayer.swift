import AVFoundation
import ExpoModulesCore

/// Continuous audio player using AVAudioSourceNode for gapless streaming playback
class ContinuousAudioPlayer {
    private var audioEngine: AVAudioEngine!
    private var sourceNode: AVAudioSourceNode!
    private var audioFormat: AVAudioFormat!

    // Ring buffer for storing incoming audio data
    private var audioBuffer: RingBuffer<Float>
    private var isPlaying: Bool = false
    private let audioQueue = DispatchQueue(label: "com.expoaudiostream.continuousplayer", qos: .userInteractive)

    init(sampleRate: Double = 16000.0) {
        // Create audio format
        self.audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

        // Create ring buffer (30 seconds capacity)
        self.audioBuffer = RingBuffer<Float>(capacity: Int(sampleRate * 30))

        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()

        // Create source node that provides audio data on demand
        let format = self.audioFormat!
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                // Try to read from ring buffer
                if let sample = self.audioBuffer.read() {
                    // Write to output buffer
                    for buffer in ablPointer {
                        let buf = buffer.mData?.assumingMemoryBound(to: Float.self)
                        buf?[frame] = sample
                    }
                } else {
                    // No data available, output silence
                    for buffer in ablPointer {
                        let buf = buffer.mData?.assumingMemoryBound(to: Float.self)
                        buf?[frame] = 0.0
                    }
                }
            }

            return noErr
        }

        // Connect source node to output
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)

        do {
            try audioEngine.start()
            Logger.debug("[ContinuousAudioPlayer] Audio engine started")
        } catch {
            Logger.debug("[ContinuousAudioPlayer] Failed to start audio engine: \(error)")
        }
    }

    /// Add audio chunk to the ring buffer
    func addAudioChunk(pcmData: Data) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            // Convert PCM16 to Float32
            let sampleCount = pcmData.count / 2
            var floatSamples: [Float] = []
            floatSamples.reserveCapacity(sampleCount)

            pcmData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                let int16Pointer = bytes.baseAddress?.assumingMemoryBound(to: Int16.self)
                for i in 0..<sampleCount {
                    if let sample = int16Pointer?[i] {
                        floatSamples.append(Float(Int16(littleEndian: sample)) / 32768.0)
                    }
                }
            }

            // Write to ring buffer
            let written = self.audioBuffer.write(floatSamples)

            Logger.debug("[ContinuousAudioPlayer] Added \(floatSamples.count) samples, written: \(written), buffer level: \(self.audioBuffer.availableToRead)/\(self.audioBuffer.capacity)")

            // Start playback if not already playing
            if !self.isPlaying && self.audioBuffer.availableToRead > Int(self.audioFormat.sampleRate * 0.5) {
                self.startPlayback()
            }
        }
    }

    private func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true

        sourceNode.volume = 1.0
        Logger.debug("[ContinuousAudioPlayer] Started playback")
    }

    func stop() {
        isPlaying = false
        audioBuffer.reset()
        Logger.debug("[ContinuousAudioPlayer] Stopped playback")
    }

    func destroy() {
        audioEngine.stop()
        Logger.debug("[ContinuousAudioPlayer] Destroyed")
    }
}

/// Simple ring buffer implementation
class RingBuffer<T> {
    private var buffer: [T?]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var count: Int = 0
    let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    var availableToRead: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var availableToWrite: Int {
        lock.lock()
        defer { lock.unlock() }
        return capacity - count
    }

    func write(_ elements: [T]) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var written = 0
        for element in elements {
            guard count < capacity else { break }

            buffer[writeIndex] = element
            writeIndex = (writeIndex + 1) % capacity
            count += 1
            written += 1
        }
        return written
    }

    func read() -> T? {
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else { return nil }

        let element = buffer[readIndex]
        buffer[readIndex] = nil
        readIndex = (readIndex + 1) % capacity
        count -= 1

        return element
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        readIndex = 0
        writeIndex = 0
        count = 0
    }
}
