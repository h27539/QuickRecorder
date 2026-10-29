#!/usr/bin/env python3
"""Deterministic production stop/start-completion and termination tests.
Hardware/UI are fakes: these tests exercise our ordering, not OS callback delivery.
"""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
work = root / 'build/lifecycle-regression'
work.mkdir(parents=True, exist_ok=True)

def function(path, signature):
    source = (root / path).read_text()
    start = source.index('    ' + signature)
    # Functions selected here have no braces inside strings that affect balance.
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'

swift = r'''
import Foundation
extension String { var local: String { self } }
enum StreamType { case screen, systemaudio, idevice }
let ud = Defaults()
struct Defaults { func bool(forKey: String) -> Bool { false } }
class Window { var title = ""; func close() {}; func orderOut(_ sender: Any?) {} }
let controlPanel = Window(), camWindow = Window(), deviceWindow = Window()
let mousePointer = Window(), screenMagnifier = Window()
var hideMousePointer = false, hideScreenMagnifier = false
func updateStatusBar() {}
class PopoverState { static let shared = PopoverState(); var isShowing = false; var isPaused = false }
class SleepPreventer { static let shared = SleepPreventer(); func allowSleep() {} }
class NSApplication {
    enum TerminateReply { case terminateNow, terminateLater }
    var windows = [Window]()
    var replyCount = 0
    func reply(toApplicationShouldTerminate: Bool) { replyCount += 1 }
}
let NSApp = NSApplication()
class CaptureSession { func stopRunning() {} }
class Stream {
    var stops = 0
    var completion: ((Error?) -> Void)?
    func stopCapture(_ handler: @escaping (Error?) -> Void) { stops += 1; completion = handler }
}
class AVCaptureConnection {}
class AVCaptureFileOutput {
    var isRecording = false
    var stops = 0
    func stopRecording() { stops += 1 }
}
typealias AVCaptureMovieFileOutput = AVCaptureFileOutput
let AVErrorRecordingSuccessfullyFinishedKey = "finished"
class SCContext {
    static let mediaLock = NSRecursiveLock()
    static var streamType: StreamType?
    static var recordingSessionID: UUID?
    static var captureStartPending = false
    static var isStopping = false
    static var recordingError: String?
    static var stream: Stream?
    static var filePath: String? = "/test/movie.mov"
    static var diskSpaceTimer: Timer?
    static var stopMicrophone: (() -> Void)?
    static var autoStop = 0
    static var recordCam = "", recordDevice = ""
    static var isMagnifierEnabled = false
    static var audioFile: Any?, audioFile2: Any?, vW: Any?, vwInput: Any?, awInput: Any?, micInput: Any?
    static var startTime: Date?, firstFrame: Any?, lastPTS: Any?, window: Any?, screen: Any?, application: Any?
    static var isPaused = false, isResume = false, shouldMixAudio = false, shouldExportMP3 = false
    static var systemAudioFramesWritten = 0
    static var previewSession: CaptureSession?, captureSession: CaptureSession?
    static var finished = 0, failures = 0, successes = 0
    static func isCameraRunning() -> Bool { false }
    static func reportSaveFailure(_ reason: String, path: String) { failures += 1 }
    static func showNotification(title: String, body: String, id: String) { successes += 1 }
    // Media writer finalization is separately covered by the real AVFoundation suite.
    private static func finishRecordingWriter() {
        finished += 1
        if recordingError != nil { failures += 1 }
        completeRecordingStop()
    }
'''
for signature in ['static func stopRecording(', 'static func finishCaptureStart(', 'private static func stopCaptureAndFinish(', 'static func failRecording(', 'static func completeRecordingStop(']:
    swift += function('QuickRecorder/SCContext.swift', signature)
swift += '\n}\nclass AVOutputClass {\n    static let shared = AVOutputClass()\n    var recordingOutput: AVCaptureMovieFileOutput?\n'
for signature in ['public func stopRecording(', 'func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo', 'func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo']:
    swift += function('QuickRecorder/AVContext.swift', signature)
swift += '\n}\nclass AppDelegate {\n    static let shared = AppDelegate()\n    private static var waitingToTerminate = false\n    var presenterType = "OFF"\n    func stopGlobalMouseMonitor() {}\n'
for signature in ['func applicationShouldTerminate(', 'func recordingDidFinishForTermination(']:
    swift += function('QuickRecorder/QuickRecorderApp.swift', signature)
swift += r'''
}
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
func reset(_ type: StreamType? = nil) {
    SCContext.streamType = type
    SCContext.recordingSessionID = type == nil ? nil : UUID()
    SCContext.isStopping = false
    SCContext.captureStartPending = false
    SCContext.recordingError = nil
    SCContext.stream = nil
    SCContext.finished = 0
    SCContext.failures = 0
    SCContext.successes = 0
    NSApp.replyCount = 0
    AVOutputClass.shared.recordingOutput = nil
}
let failure = NSError(domain: "Injected startup failure", code: 1)
reset()
require(AppDelegate.shared.applicationShouldTerminate(NSApp) == .terminateNow, "Setup failed before request should exit immediately")
require(NSApp.replyCount == 0, "Immediate exit should not defer a reply")
print("PASS: no recording request / setup failure exits immediately")

reset(.idevice)
let device = AVCaptureFileOutput() // isRecording is deliberately false.
AVOutputClass.shared.recordingOutput = device
require(AppDelegate.shared.applicationShouldTerminate(NSApp) == .terminateLater, "Pending device request must finish before quit")
require(device.stops == 1 && SCContext.isStopping, "Pending device request did not receive stop")
AVOutputClass.shared.stopRecording()
require(device.stops == 1, "Repeated stop duplicated device stop")
AVOutputClass.shared.fileOutput(device, didStartRecordingTo: URL(fileURLWithPath: "/test.mov"), from: [])
drain()
require(device.stops == 2, "Late device start ignored stop intent")
AVOutputClass.shared.fileOutput(device, didFinishRecordingTo: URL(fileURLWithPath: "/test.mov"), from: [], error: failure)
drain()
require(SCContext.streamType == nil && SCContext.failures == 1 && SCContext.successes == 0, "Device startup failure reported success or retained state")
require(NSApp.replyCount == 1, "Device failure did not resolve terminateLater once")
AVOutputClass.shared.fileOutput(device, didFinishRecordingTo: URL(fileURLWithPath: "/test.mov"), from: [], error: failure)
drain()
require(NSApp.replyCount == 1 && SCContext.failures == 1, "Duplicate device completion was not ignored")
print("PASS: device early quit, late start, startup failure and repeated stop/completion")

reset(.idevice)
require(AppDelegate.shared.applicationShouldTerminate(NSApp) == .terminateLater, "Orphan state did not clean up")
require(NSApp.replyCount == 0, "Quit reply arrived before terminateLater returned")
drain()
require(NSApp.replyCount == 1 && SCContext.streamType == nil, "No-request device state blocked quit")
print("PASS: orphan device state resolves quit asynchronously without a callback")

reset(.idevice)
let broken = AVCaptureFileOutput()
AVOutputClass.shared.recordingOutput = broken
_ = AppDelegate.shared.applicationShouldTerminate(NSApp)
AVOutputClass.shared.fileOutput(broken, didFinishRecordingTo: URL(fileURLWithPath: "/broken.mov"), from: [], error: failure)
drain()
require(NSApp.replyCount == 1 && SCContext.successes == 0, "Abnormal device finish blocked quit")
print("PASS: device abnormal finish while isRecording=false resolves quit")
reset(.idevice)
let replacement = AVCaptureFileOutput()
AVOutputClass.shared.recordingOutput = replacement
AVOutputClass.shared.fileOutput(broken, didFinishRecordingTo: URL(fileURLWithPath: "/old.mov"), from: [], error: failure)
drain()
require(AVOutputClass.shared.recordingOutput === replacement && SCContext.streamType == .idevice && SCContext.failures == 0, "Old device completion cleared a new request")
print("PASS: late device completion cannot clear a replacement request")


reset(.screen)
let starting = Stream(), id = SCContext.recordingSessionID!
SCContext.stream = starting
SCContext.captureStartPending = true
_ = AppDelegate.shared.applicationShouldTerminate(NSApp)
SCContext.stopRecording()
require(starting.stops == 0 && SCContext.finished == 0 && NSApp.replyCount == 0, "Finalized before startCapture settled")
require(!SCContext.finishCaptureStart(sessionID: id), "Cancelled start became active")
require(starting.stops == 1 && SCContext.finished == 0, "Start completion failed to schedule exactly one capture stop")
SCContext.stopRecording()
require(starting.stops == 1, "Repeated stop duplicated stream stop")
starting.completion?(nil)
drain()
require(SCContext.finished == 1 && NSApp.replyCount == 1 && SCContext.streamType == nil, "Early stop did not finish once after stopCapture")
print("PASS: startCapture suspended -> quit/repeated stop -> start returns -> stop -> finish")

reset(.screen)
let failedStart = Stream(), failedID = SCContext.recordingSessionID!
SCContext.stream = failedStart
SCContext.captureStartPending = true
_ = AppDelegate.shared.applicationShouldTerminate(NSApp)
_ = SCContext.finishCaptureStart(sessionID: failedID, error: failure)
drain()
require(failedStart.stops == 0 && SCContext.finished == 1 && NSApp.replyCount == 1 && SCContext.failures == 1, "Failed pending start blocked quit or attempted to stop an unstarted stream")
print("PASS: pending startup throws during quit; writer/error cleanup resolves exit")


reset(.screen)
let plainFailure = Stream(), plainFailureID = SCContext.recordingSessionID!
SCContext.stream = plainFailure
SCContext.captureStartPending = true
_ = SCContext.finishCaptureStart(sessionID: plainFailureID, error: failure)
drain()
require(SCContext.finished == 1 && SCContext.failures == 1 && SCContext.streamType == nil, "Ordinary startup failure retained recording state")
require(AppDelegate.shared.applicationShouldTerminate(NSApp) == .terminateNow, "Cannot quit after startup failure")
print("PASS: ordinary startup failure releases state and permits immediate quit")

reset(.screen)
let normal = Stream(), normalID = SCContext.recordingSessionID!
SCContext.stream = normal
SCContext.captureStartPending = true
require(SCContext.finishCaptureStart(sessionID: normalID), "Normal start was rejected")
SCContext.stopRecording()
SCContext.stopRecording()
require(normal.stops == 1, "Normal repeated stop not idempotent")
normal.completion?(nil)
drain()
require(SCContext.finished == 1 && SCContext.streamType == nil, "Normal stop not finalized")
print("PASS: normal start and duplicate stop finish once")

reset(.screen)
let old = Stream(), oldID = SCContext.recordingSessionID!
SCContext.stream = old
SCContext.stopRecording()
let staleCompletion = old.completion!
reset(.screen)
let newID = SCContext.recordingSessionID!
require(!SCContext.finishCaptureStart(sessionID: oldID, error: failure), "Stale startup accepted")
staleCompletion(failure)
drain()
require(SCContext.recordingSessionID == newID && SCContext.finished == 0 && SCContext.recordingError == nil, "Old stop callback contaminated new session")
SCContext.failRecording("queued old error")
reset(.screen)
let nextID = SCContext.recordingSessionID!
drain()
require(SCContext.recordingSessionID == nextID && !SCContext.isStopping && SCContext.finished == 0, "Queued old failure stopped new session")
print("PASS: stale startup, stop completion and queued failure cannot mutate a new session")
'''
(work / 'main.swift').write_text(swift)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'module-cache'), str(work / 'main.swift'), '-o', str(work / 'verify-lifecycle')], check=True)
subprocess.run([str(work / 'verify-lifecycle')], check=True)
