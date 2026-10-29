#!/usr/bin/env python3
"""Exercise production writer-finalization and mix functions using real AVFoundation.
No capture permissions required. Generates only disposable fixtures under build/.
UI, ScreenCaptureKit stopCapture, hardware microphones and low-space volumes are
not covered. Requires Xcode command-line tools on macOS.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / 'QuickRecorder/SCContext.swift').read_text()
work = root / 'build/media-regression'
work.mkdir(parents=True, exist_ok=True)

# Slice complete functions at the next class-level member. This runs the current
# implementation, rather than a separately maintained copy of its algorithm.
def member(name):
    start = source.index('    ' + name)
    ends = [p for marker in ('\n    static func ', '\n    private static func ')
            if (p := source.find(marker, start + 5)) >= 0]
    return source[start:min(ends)] if ends else source[start:source.rfind('\n}')]

swift = r'''
import Foundation
import AVFoundation
import CoreVideo

let fd = FileManager.default
extension String { var local: String { self } }
enum VideoFormat: String { case mov, mp4 }
class SCContext {
    static var vW: AVAssetWriter!
    static var audioFile: AVAudioFile?
    static var audioFile2: AVAudioFile?
    static var filePath: String?
    static var recordingError: String?
    static var startTime: Date?
    static var done = false
    static var successful = false
    static var failures = [String]()
    static func showNotification(title: String, body: String, id: String) {}
    static func reportSaveFailure(_ reason: String, path: String) { failures.append(reason) }
    static func completeRecordingStop() { done = true }
    static func processFinishedRecording() { successful = true; done = true }
    static func finishForTest() { finishRecordingWriter() }
'''
swift += member('static func remainingCapacity(')
swift += member('private static func finishRecordingWriter(')
swift += member('static func mixAudioTracks(')
swift += r'''
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "Regression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func waitUntil(_ ready: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(30)
    while !ready(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try require(ready(), "Timed out")
}
let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func fixture(_ name: String) -> URL { work.appendingPathComponent(name) }
func writeTone(_ url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
    buffer.frameLength = 48000
    for channel in 0..<2 {
        for i in 0..<48000 { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.1) }
    }
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
    try file!.write(from: buffer)
    file = nil
}
func writeVideo(_ url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
    writer.add(input)
    try require(writer.startWriting(), "Video writer start failed")
    writer.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        try waitUntil { input.isReadyForMoreMediaData }
        var pixel: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
        CVPixelBufferLockBaseAddress(pixel!, [])
        memset(CVPixelBufferGetBaseAddress(pixel!), 0, CVPixelBufferGetDataSize(pixel!))
        CVPixelBufferUnlockBaseAddress(pixel!, [])
        try require(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(i), timescale: 30)), "Video append failed")
    }
    input.markAsFinished()
    var finished = false
    writer.finishWriting { finished = true }
    try waitUntil { finished }
    try require(writer.status == .completed, "Video fixture finalization failed: \(String(describing: writer.error))")
}
func multiplex(_ url: URL, audioCount: Int, video: Bool = true) throws {
    let composition = AVMutableComposition()
    for (file, type) in (video ? [(fixture("video.mp4"), AVMediaType.video)] : []) + Array(repeating: (fixture("tone.m4a"), AVMediaType.audio), count: audioCount) {
        let asset = AVURLAsset(url: file)
        let track = asset.tracks(withMediaType: type)[0]
        let output = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try output.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48000)), of: track, at: .zero)
    }
    let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
    export.outputURL = url
    export.outputFileType = url.pathExtension == "mov" ? .mov : .mp4
    var done = false
    export.exportAsynchronously { done = true }
    try waitUntil { done }
    try require(export.status == .completed, "Fixture mux failed: \(String(describing: export.error))")
}
func mix(_ url: URL) throws -> Result<URL, Error> {
    var result: Result<URL, Error>?
    SCContext.mixAudioTracks(videoURL: url) { result = $0 }
    try waitUntil { result != nil }
    return result!
}
func checkDecodable(_ url: URL, video: Int, audio: Int) throws {
    let asset = AVURLAsset(url: url)
    try require(asset.isPlayable, "Output is not playable")
    try require(asset.tracks(withMediaType: .video).count == video, "Unexpected video track count")
    try require(asset.tracks(withMediaType: .audio).count == audio, "Unexpected audio track count")
    try require(asset.duration.seconds > 0.9, "Output truncated")
    let reader = try AVAssetReader(asset: asset)
    var outputs = [AVAssetReaderTrackOutput]()
    for track in asset.tracks {
        let settings: [String: Any] = track.mediaType == .audio ? [AVFormatIDKey: kAudioFormatLinearPCM] : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        outputs.append(output)
    }
    try require(reader.startReading(), "Cannot read output")
    for output in outputs {
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        try require(count > 0, "Track cannot be decoded")
    }
    try require(reader.status == .completed, "Decode failed: \(String(describing: reader.error))")
}
// Test the actual production asynchronous writer barrier with AAC microphone data.
func checkWriterBarrier() throws {
    let source = AVURLAsset(url: fixture("tone.m4a"))
    let reader = try AVAssetReader(asset: source)
    let output = AVAssetReaderTrackOutput(track: source.tracks(withMediaType: .audio)[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    reader.add(output)
    let writer = try AVAssetWriter(outputURL: fixture("mic-finalized.m4a"), fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
    writer.add(input)
    try require(writer.startWriting(), "Mic writer failed to start")
    writer.startSession(atSourceTime: .zero)
    try require(reader.startReading(), "Cannot read tone")
    while let sample = output.copyNextSampleBuffer() {
        try waitUntil { input.isReadyForMoreMediaData }
        try require(input.append(sample), "Mic append failed")
    }
    SCContext.vW = writer
    SCContext.startTime = Date()
    SCContext.filePath = writer.outputURL.path
    SCContext.finishForTest()
    try require(!SCContext.done, "Completion ran inline before finalization")
    try waitUntil { SCContext.done }
    try require(SCContext.successful && SCContext.failures.isEmpty && writer.status == .completed, "Finalization did not succeed")
    try checkDecodable(writer.outputURL, video: 0, audio: 1)
    print("PASS: asynchronous writer barrier; microphone M4A finalized and decoded")
    SCContext.done = false
    SCContext.successful = false
    SCContext.vW = try AVAssetWriter(outputURL: fixture("empty.m4a"), fileType: .m4a)
    SCContext.startTime = nil
    SCContext.finishForTest()
    try waitUntil { SCContext.done }
    try require(!SCContext.successful && SCContext.failures.count == 1, "Empty writer incorrectly succeeded")
    print("PASS: empty writer reports failure exactly once")
    SCContext.vW = nil
    SCContext.done = false
    SCContext.finishForTest()
    try waitUntil { SCContext.done }
    try require(!SCContext.successful && SCContext.failures.count == 2, "Empty system audio incorrectly succeeded")
    print("PASS: empty system audio without a writer reports failure")
}
do {
    try writeTone(fixture("tone.m4a"))
    try writeVideo(fixture("video.mp4"))
    try checkWriterBarrier()
    let unrelated = fixture("next-recording.mp4")
    try Data("keep".utf8).write(to: unrelated)
    SCContext.filePath = unrelated.path
    for ext in ["mp4", "mov"] {
        let source = fixture("mix.\(ext).\(ext).\(ext)")
        try multiplex(source, audioCount: 2)
        let result = try mix(source)
        let output = try result.get()
        try checkDecodable(output, video: 1, audio: 1)
        try require(!fd.fileExists(atPath: source.path), "Successful mix source not cleaned up")
        try require(try Data(contentsOf: unrelated) == Data("keep".utf8), "Unrelated file changed")
        print("PASS: \(ext) mix produces decodable video + one audio track; unrelated file retained")
    }
    let missing = fixture("single.mp4.mp4.mp4")
    try multiplex(missing, audioCount: 1)
    if case .success = try mix(missing) { throw NSError(domain: "Unexpected success", code: 1) }
    try checkDecodable(missing, video: 1, audio: 1)
    print("PASS: insufficient tracks fail and retain playable source")
    let audioOnly = fixture("no-video.mp4.mp4.mp4")
    try multiplex(audioOnly, audioCount: 2, video: false)
    if case .success = try mix(audioOnly) { throw NSError(domain: "Unexpected success", code: 1) }
    try checkDecodable(audioOnly, video: 0, audio: 2)
    print("PASS: failure after audio export retains both original audio tracks")

    let collision = fixture("collision.mp4.mp4.mp4")
    try multiplex(collision, audioCount: 2)
    let destination = fixture("collision.mp4")
    try Data("existing".utf8).write(to: destination)
    if case .success = try mix(collision) { throw NSError(domain: "Unexpected overwrite", code: 1) }
    try require(try Data(contentsOf: destination) == Data("existing".utf8), "Existing destination overwritten")
    try checkDecodable(collision, video: 1, audio: 2)
    print("PASS: output collision fails without deleting source or existing destination")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
'''
qma_source = (root / 'QuickRecorder/ViewModel/QmaPlayer.swift').read_text()
def qma_member(signature):
    start = qma_source.index('    ' + signature)
    ends = [p for marker in ('\n    func ', '\n    private func ')
            if (p := qma_source.find(marker, start + 5)) >= 0]
    return qma_source[start:min(ends)]

qma_class = r'''
class AudioPlayerManager {
    var exporting = false
    var audioLength: TimeInterval = 0
    var sysVol: Float = 1
    var micVol: Float = 1
    private var engine = AVAudioEngine()
    private var playerNode1 = AVAudioPlayerNode()
    private var playerNode2 = AVAudioPlayerNode()
    private var mixerNode = AVAudioMixerNode()
    private var audioFile1: AVAudioFile?
    private var audioFile2: AVAudioFile?
    private var fileFormat = "m4a"
    private var fileEncoder = "aac"
    private var exportMP3 = false
    private var packageURL: URL?
    init() { setupAudioEngine() }
'''
for signature in ['private func setupAudioEngine(', 'func loadAudioFiles(', 'func saveFile(', 'private func updateSysVol(', 'private func updateMicVol(']:
    qma_class += qma_member(signature)
qma_class += "\n}\n"
swift = swift.replace('func require(', qma_class + '\nfunc require(', 1)
swift = swift.replace('    static var vW:', r'''
    static func updateAudioSettings(format: String) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]
    }
    // MP3 uses the app's SwiftLAME dependency and is outside this harness.
    static func m4a2mp3(inputUrl: URL, outputUrl: URL) async throws {
        throw NSError(domain: "MP3 conversion not exercised by this harness", code: 1)
    }
    static var vW:''', 1)
swift = swift.replace('    try checkWriterBarrier()', r'''
    try checkWriterBarrier()
    let qma = fixture("test.qma")
    try fd.createDirectory(at: qma, withIntermediateDirectories: true)
    try fd.copyItem(at: fixture("tone.m4a"), to: qma.appendingPathComponent("sys.m4a"))
    try fd.copyItem(at: fixture("tone.m4a"), to: qma.appendingPathComponent("mic.m4a"))
    let manager = AudioPlayerManager()
    manager.loadAudioFiles(format: "m4a", package: qma, encoder: "aac", saveMP3: false)
    var qmaResult: Result<URL, Error>?
    manager.saveFile(fixture("qma-export.m4a")) { qmaResult = $0 }
    try waitUntil { qmaResult != nil }
    let qmaOutput = try qmaResult!.get()
    try checkDecodable(qmaOutput, video: 0, audio: 1)
    print("PASS: production QMA offline mixer closes and decodes audio before completion")
    qmaResult = nil
    manager.saveFile(qmaOutput) { qmaResult = $0 }
    try waitUntil { qmaResult != nil }
    if case .success = qmaResult! { throw NSError(domain: "Unexpected QMA overwrite", code: 1) }
    try checkDecodable(qmaOutput, video: 0, audio: 1)
    let missingManager = AudioPlayerManager()
    var missingResult: Result<URL, Error>?
    missingManager.saveFile(fixture("missing-qma.m4a")) { missingResult = $0 }
    try waitUntil { missingResult != nil }
    if case .success = missingResult! { throw NSError(domain: "Unexpected QMA success", code: 1) }
    print("PASS: QMA missing inputs and destination collision report failure")

''', 1)
(work / 'main.swift').write_text(swift)
# Each run gets fresh fixtures; never delete user-supplied paths.
import tempfile
with tempfile.TemporaryDirectory(prefix='fixtures-', dir=work) as fixtures:
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'module-cache'),
                    str(work / 'main.swift'), '-o', str(work / 'verify-media')], check=True)
    subprocess.run([str(work / 'verify-media'), fixtures], check=True)
