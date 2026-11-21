import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

/// Live system-audio analyser for the visualiser bars.
/// Uses a Core Audio process tap (macOS 14.2+). macOS asks once for
/// "System Audio Recording" permission. If the tap can't start, `available`
/// stays false and the UI falls back to a synthetic animation.
final class AudioSpectrum: ObservableObject {
    static let shared = AudioSpectrum()

    static let bandCount = 6
    @Published private(set) var levels = [Float](repeating: 0, count: AudioSpectrum.bandCount)
    @Published private(set) var available = false
    /// true while the tap delivers real (non-zero) audio. macOS hands a tap pure zeros when the
    /// "System Audio Recording" permission is missing, so the UI falls back to the synthetic animation.
    @Published private(set) var receiving = false
    private var lastSignal = Date.distantPast
    private var receivingState = false

    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: 1024)
    private var ring: [Float] = []
    private var smoothed = [Float](repeating: 0, count: AudioSpectrum.bandCount)
    private var sampleRate: Double = 48000
    private var started = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "orra.audio", qos: .userInteractive)
    private var lastPublish = Date.distantPast

    private init() {
        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM))
    }

    func start() {
        guard !started else { return }
        started = true
        if #available(macOS 14.2, *) {
            if !startTap() { teardown(); started = false }
        } else {
            lpLog("audio tap needs macOS 14.2+")
            started = false
        }
    }

    /// Stops listening completely (removes the tap, so macOS's recording indicator goes away).
    func stop() {
        guard started else { return }
        started = false
        if #available(macOS 14.2, *) { teardown() }
        DispatchQueue.main.async {
            self.available = false
            self.receiving = false
            self.levels = [Float](repeating: 0, count: Self.bandCount)
        }
    }

    @available(macOS 14.2, *)
    private func teardown() {
        if let pid = procID, aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggID, pid)
            AudioDeviceDestroyIOProcID(aggID, pid)
        }
        procID = nil
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        queue.async { self.ring.removeAll(); self.receivingState = false; self.lastSignal = .distantPast }
    }

    @available(macOS 14.2, *)
    private func startTap() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Orra"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { lpLog("tap create failed: \(st)"); return false }
        tapID = tap

        // stream format -> sample rate
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &asbdSize, &asbd) == noErr, asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        guard let outUID = Self.defaultOutputUID() else { lpLog("no default output device"); return false }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OrraTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString
            ]]
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr else { lpLog("aggregate create failed: \(st)"); return false }
        aggID = agg

        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, agg, queue) { [weak self] _, inData, _, _, _ in
            self?.handle(inData)
        }
        guard st == noErr, pid != nil else { lpLog("ioproc failed: \(st)"); return false }
        procID = pid
        st = AudioDeviceStart(agg, pid)
        guard st == noErr else { lpLog("device start failed: \(st)"); return false }
        lpLog("audio tap running @ \(sampleRate) Hz")
        DispatchQueue.main.async { self.available = true }
        return true
    }

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    // MARK: analysis (runs on `queue`)
    private func handle(_ inData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let buf = abl.first, let raw = buf.mData else { return }
        let ch = max(Int(buf.mNumberChannels), 1)
        let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / ch
        let fp = raw.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        vDSP_maxmgv(fp, 1, &peak, vDSP_Length(frames * ch))
        let t = Date()
        if peak > 0 { lastSignal = t }
        let live = t.timeIntervalSince(lastSignal) < 2.0
        if live != receivingState {
            receivingState = live
            DispatchQueue.main.async { self.receiving = live }
        }
        for i in 0..<frames { ring.append(fp[i * ch]) }

        while ring.count >= n {
            let frame = Array(ring.prefix(n))
            ring.removeFirst(n)
            let bands = analyze(frame)
            let now = Date()
            if now.timeIntervalSince(lastPublish) > 0.03 {
                lastPublish = now
                DispatchQueue.main.async { self.levels = bands }
            }
        }
        if ring.count > n * 8 { ring.removeAll() }   // never let it grow if we fall behind
    }

    private func analyze(_ samples: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        let edgesHz: [Double] = [40, 100, 240, 560, 1300, 3000, 7000]
        let binHz = sampleRate / Double(n)
        var out = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = max(1, Int(edgesHz[b] / binHz))
            let hi = max(lo + 1, min(n / 2 - 1, Int(edgesHz[b + 1] / binHz)))
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] }
            let amp = (sum / Float(hi - lo)) / Float(n)
            let db = 20 * log10(amp + 1e-9)
            let target = min(max((db + 78 + Float(b) * 2.5) / 42, 0), 1)
            // fast attack, slower release = looks like it follows the beat
            let k: Float = target > smoothed[b] ? 0.65 : 0.2
            smoothed[b] += (target - smoothed[b]) * k
            out[b] = smoothed[b]
        }
        return out
    }
}
