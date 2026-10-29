//
//  SCContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AVFAudio
import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications
import SwiftLAME
import SwiftUI
import AECAudioStream

class SCContext {
    // Serializes sample callbacks from SCStream, AVAudioEngine, AEC and AVCapture
    // against the stop boundary. Never hold this lock while stopping a producer.
    static let mediaLock = NSRecursiveLock()
    static let captureQueue = DispatchQueue(label: "QuickRecorder.capture")
    static var isStopping = false
    static var recordingError: String?
    static var stopMicrophone: (() -> Void)?
    static var shouldMixAudio = false
    static var shouldExportMP3 = false
    static var diskSpaceTimer: Timer?

    static func remainingCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map { Int64($0) }
    }

    static func checkRecordingSpace(at directory: URL) -> Bool {
        guard let bytes = remainingCapacity(at: directory), bytes < 512 * 1024 * 1024 else { return true }
        showNotification(title: "Failed to save file".local,
                         body: "Insufficient disk space: \(directory.path) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))",
                         id: "quickrecorder.error.\(UUID().uuidString)")
        return false
    }

    static func startDiskSpaceMonitor() {
        diskSpaceTimer?.invalidate()
        guard let path = filePath else { return }
        let directory = path.url.deletingLastPathComponent()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            if let bytes = remainingCapacity(at: directory), bytes < 256 * 1024 * 1024 {
                failRecording("Recording stopped because disk space is low. Files retained at: \(path)")
            }
        }
        diskSpaceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static func failRecording(_ message: String) {
        mediaLock.lock()
        guard !isStopping, recordingError == nil else { mediaLock.unlock(); return }
        recordingError = message
        mediaLock.unlock()
        DispatchQueue.main.async {
            if streamType == .idevice { AVOutputClass.shared.stopRecording() } else { stopRecording() }
        }
    }

    static func append(_ buffer: @autoclosure () -> CMSampleBuffer?, to input: AVAssetWriterInput?) {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        guard !isStopping, let writer = vW, let input = input, writer.inputs.contains(where: { $0 === input }) else { return }
        if writer.status == .failed {
            failRecording(writer.error?.localizedDescription ?? "Media writer failed.")
            return
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData, let buffer = buffer() else { return }
        if !input.append(buffer), writer.status == .failed {
            failRecording(writer.error?.localizedDescription ?? "Media writer failed.")
        }
    }

    static var trimingList = [URL]()
    static var firstFrame: CMSampleBuffer?
    static var autoStop = 0
    static var recordCam = ""
    static var recordDevice = ""
    static var captureSession: AVCaptureSession!
    static var previewSession: AVCaptureSession!
    static var frameCache: CMSampleBuffer?
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    static var isSkipFrame = false
    static var lastPTS: CMTime?
    static var timeOffset = CMTimeMake(value: 0, timescale: 0)
    static var screenArea: NSRect?
    static let audioEngine = AVAudioEngine()
    static let AECEngine = AECAudioStream(sampleRate: 48000)
    static var backgroundColor: CGColor = CGColor.black
    static var filePath: String!
    static var filePath1: String!
    static var filePath2: String!
    static var audioFile: AVAudioFile?
    static var audioFile2: AVAudioFile?
    static var vW: AVAssetWriter!
    static var vwInput, awInput, micInput: AVAssetWriterInput!
    static var startTime: Date?
    static var timePassed: TimeInterval = 0
    static var stream: SCStream!
    static var screen: SCDisplay?
    static var window: [SCWindow]?
    static var application: [SCRunningApplication]?
    static var streamType: StreamType?
    static var availableContent: SCShareableContent?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]
    
    static func updateAvailableContentSync() -> SCShareableContent? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent? = nil

        updateAvailableContent { content in
            result = content
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }
    
    private static func updateAvailableContent(completion: @escaping (SCShareableContent?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [self] content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.updateAvailableContent() {_ in}
                    }
                default:
                    print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                completion(nil) // 在错误情况下返回 nil
                return
            }

            availableContent = content
            if let displays = content?.displays, !displays.isEmpty {
                completion(content) // 返回成功获取的 content
            } else {
                print("There needs to be at least one display connected!".local)
                completion(nil) // 如果没有显示器连接，则返回 nil
            }
        }
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined: requestPermissions()
                default: print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                return
            }
            availableContent = content
            assert(availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected!".local)
            completion()
        }
    }
    
    static func getSelf() -> SCRunningApplication? {
        return SCContext.availableContent!.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }
    
    static func getSelfWindows() -> [SCWindow]? {
        return SCContext.availableContent!.windows.filter( {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != "Mouse Pointer".local
            && title != "Screen Magnifier".local
            && title != "Camera Overlayer".local
            && title != "iDevice Overlayer".local
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).map({ $0.owningApplication }) {
            if !apps.contains(app!) { apps.append(app!) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return apps
    }
    
    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        var windows = [SCWindow]()
        windows = availableContent!.windows.filter {
            guard let app =  $0.owningApplication,
                  let title = $0.title else {//, !title.isEmpty else {
                return false
            }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
        }
        if isOnScreen { windows = windows.filter({$0.isOnScreen == true}) }
        if hideSelf && ud.bool(forKey: "hideSelf") { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return windows
    }
    
    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon!.size = NSSize(width: 69, height: 69)
        return icon
    }
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func getSCDisplayWithMouse() -> SCDisplay? {
        if let displays = availableContent?.displays {
            for display in displays {
                if let currentDisplayID = getScreenWithMouse()?.displayID {
                    if display.displayID == currentDisplayID {
                        return display
                    }
                }
            }
        }
        return nil
    }
    
    static func getFilePath(capture: Bool = false) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        return ud.string(forKey: "saveDirectory")! + (capture ? "/Capturing at ".local : "/Recording at ".local) + dateFormatter.string(from: Date())
    }
    
    static func updateAudioSettings(format: String = ud.string(forKey: "audioFormat") ?? "", rate: Int = 48000) -> [String : Any] {
        var audioSettings: [String : Any] = [AVSampleRateKey : rate, AVNumberOfChannelsKey : 2] // reset audioSettings
        var bitRate = ud.integer(forKey: "audioQuality") * 1000
        if rate < 44100 { bitRate = min(64000, bitRate / 2) }
        switch format {
        case AudioFormat.mp3.rawValue: fallthrough
        case AudioFormat.aac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        case AudioFormat.alac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case AudioFormat.flac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatFLAC
        case AudioFormat.opus.rawValue:
            audioSettings[AVFormatIDKey] = ud.string(forKey: "videoFormat") != VideoFormat.mp4.rawValue ? kAudioFormatOpus : kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] =  bitRate
        default:
            assertionFailure("unknown audio format while setting audio settings: ".local + (ud.string(forKey: "audioFormat") ?? "[no defaults]".local))
        }
        return audioSettings
    }
    
    static func getBackgroundColor() -> CGColor {
        guard let color = ud.string(forKey: "background") else { return CGColor.black  }
        if color == BackgroundType.wallpaper.rawValue { return CGColor.black }
        switch color {
            case "clear": backgroundColor = CGColor.clear
            case "black": backgroundColor = CGColor.black
            case "white": backgroundColor = CGColor.white
            case "gray": backgroundColor = NSColor.systemGray.cgColor
            case "yellow": backgroundColor = NSColor.systemYellow.cgColor
            case "orange": backgroundColor = NSColor.systemOrange.cgColor
            case "green": backgroundColor = NSColor.systemGreen.cgColor
            case "blue": backgroundColor = NSColor.systemBlue.cgColor
            case "red": backgroundColor = NSColor.systemRed.cgColor
            default: backgroundColor = ud.cgColor(forKey: "userColor") ?? CGColor.black
        }
        return backgroundColor
    }
    
    static func performMicCheck() async {
        guard ud.bool(forKey: "recordMic") == true else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        ud.setValue(false, forKey: "recordMic")
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs permission to record your microphone.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    
    private static func requestPermissions() {
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs screen recording permissions, even if you only intend on recording audio.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            NSApp.terminate(self)
        }
    }
    
    static func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized, .restricted, .notDetermined:
            break
        case .denied:
            DispatchQueue.main.async {
                let alert = createAlert(title: "Permission Required",
                                                           message: "QuickRecorder needs this permission to record your camera or mobile device.",
                                                           button1: "Open Settings",
                                                           button2: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        @unknown default:
            break
        }
    }
    
    static func getWallpaper(_ display: SCDisplay) -> NSImage? {
        guard let screen = display.nsScreen else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        do {
            var wallpaper: NSImage?
            try wallpaper = NSImage(data: Data(contentsOf: url))
            if let w = wallpaper { return w }
        } catch {
            print("load wallpaper error: \(error)")
        }
        return nil
    }
    
    static func getRecordingSize() -> String {
        do {
            let fileAttr = try fd.attributesOfItem(atPath: filePath)
            let byteFormat = ByteCountFormatter()
            byteFormat.allowedUnits = [.useMB]
            byteFormat.countStyle = .file
            return byteFormat.string(fromByteCount: fileAttr[FileAttributeKey.size] as! Int64)
        } catch {
            print(String(format: "failed to fetch file for size indicator: %@".local, error.localizedDescription))
        }
        return "Unknown".local
    }
    
    static func getRecordingLength() -> String {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        if isPaused || isStopping { return formatter.string(from: timePassed) ?? "Unknown".local }
        timePassed = Date.now.timeIntervalSince(startTime ?? Date.now)
        return formatter.string(from: timePassed) ?? "Unknown".local
    }
    
    static func isCameraRunning() -> Bool {
        var preview = false
        var capture = false
        if let session = previewSession { preview = session.isRunning }
        if let session = captureSession { capture = session.isRunning }
        return (preview || capture)
    }
    
    static func pauseRecording() {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        guard !isStopping else { return }
        isPaused.toggle()
        PopoverState.shared.isPaused = isPaused
        if !isPaused {
            isResume = true
            startTime = Date.now.addingTimeInterval(-1) - SCContext.timePassed
        }
    }
    
    static func stopRecording() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { stopRecording() }
            return
        }
        mediaLock.lock()
        guard streamType != nil, streamType != .idevice, !isStopping else { mediaLock.unlock(); return }
        isStopping = true
        mediaLock.unlock()
        diskSpaceTimer?.invalidate()
        diskSpaceTimer = nil
        if ud.bool(forKey: "preventSleep") { SleepPreventer.shared.allowSleep() }
        autoStop = 0
        recordCam = ""
        recordDevice = ""
        isMagnifierEnabled = false
        mousePointer.orderOut(nil)
        screenMagnifier.orderOut(nil)
        AppDelegate.shared.stopGlobalMouseMonitor()
        NSApp.windows.first(where: { $0.title == "Area Overlayer".local })?.close()
        PopoverState.shared.isShowing = false

        // Close producers outside mediaLock: stopRunning/removeTap can wait for a
        // callback which itself needs the lock. Late callbacks now discard samples.
        stopMicrophone?()
        stopMicrophone = nil
        if let recordingStream = stream {
            recordingStream.stopCapture { error in
                DispatchQueue.main.async {
                    if let error = error, recordingError == nil { recordingError = error.localizedDescription }
                    finishRecordingWriter()
                }
            }
        } else {
            finishRecordingWriter()
        }
    }

    private static func finishRecordingWriter() {
        // All append/write callbacks passed through mediaLock before isStopping
        // was set. Nothing may append once inputs have been marked finished.
        let writer = vW
        let finished: () -> Void = {
            DispatchQueue.main.async {
                audioFile = nil
                audioFile2 = nil
                if writer == nil && startTime == nil && recordingError == nil {
                    reportSaveFailure("No media samples were written.", path: filePath ?? "")
                    completeRecordingStop()
                    return
                }
                if let writer = writer, writer.status != .completed {
                    let reason = recordingError ?? writer.error?.localizedDescription ?? "No media samples were written."
                    reportSaveFailure(reason, path: filePath ?? writer.outputURL.path)
                    completeRecordingStop()
                    return
                }
                if let reason = recordingError {
                    reportSaveFailure(reason, path: filePath ?? "")
                    completeRecordingStop()
                    return
                }
                processFinishedRecording()
            }
        }
        guard let writer = writer else { finished(); return }
        guard writer.status == .writing else {
            if writer.status == .unknown { writer.cancelWriting() }
            finished()
            return
        }
        guard startTime != nil else {
            writer.cancelWriting()
            finished()
            return
        }
        for input in writer.inputs { input.markAsFinished() }
        writer.finishWriting(completionHandler: finished)
    }

    static func reportSaveFailure(_ reason: String, path: String) {
        showNotification(title: "Failed to save file".local,
                         body: "\(reason)\nFiles retained at: \(path)",
                         id: "quickrecorder.error.\(UUID().uuidString)")
    }

    private static func processFinishedRecording() {
        guard let path = filePath else { completeRecordingStop(); return }
        let url = path.url
        if streamType == .systemaudio {
            if shouldExportMP3 && url.pathExtension != "qma" {
                let source = (filePath1 ?? path).url
                let output = url.deletingPathExtension().appendingPathExtension("mp3")
                Task {
                    do {
                        try await m4a2mp3(inputUrl: source, outputUrl: output)
                        try? fd.removeItem(at: source)
                        DispatchQueue.main.async {
                            presentFinishedRecording(output, image: NSImage(named: "audioIcon"))
                            completeRecordingStop()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            reportSaveFailure(error.localizedDescription, path: source.path)
                            completeRecordingStop()
                        }
                    }
                }
                return
            }
            if shouldMixAudio {
                do {
                    let document = try qmaPackageHandle.load(from: url)
                    let manager = AudioPlayerManager()
                    manager.loadAudioFiles(format: document.info.format, package: url, encoder: document.info.encoder, saveMP3: document.info.exportMP3)
                    manager.sysVol = document.info.sysVol
                    manager.micVol = document.info.micVol
                    let format = document.info.exportMP3 ? "mp3" : document.info.format
                    manager.saveFile(url.deletingPathExtension().appendingPathExtension(format), saveAsMP3: document.info.exportMP3) { result in
                        DispatchQueue.main.async {
                            if case .failure(let error) = result { reportSaveFailure(error.localizedDescription, path: path) }
                            completeRecordingStop()
                        }
                    }
                } catch {
                    reportSaveFailure(error.localizedDescription, path: path)
                    completeRecordingStop()
                }
                return
            }
            presentFinishedRecording(url, image: NSImage(named: url.pathExtension == "qma" ? "qmaIcon" : "audioIcon"))
        } else if shouldMixAudio {
            mixAudioTracks(videoURL: url) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let output): presentFinishedRecording(output)
                    case .failure(let error):
                        // The finalized source already has independent audio tracks.
                        // Keep it under its original name; never overwrite a user's file.
                        reportSaveFailure(error.localizedDescription, path: url.path)
                    }
                    completeRecordingStop()
                }
            }
            return
        } else {
            presentFinishedRecording(url)
        }
        completeRecordingStop()
    }

    private static func presentFinishedRecording(_ url: URL, image: NSImage? = nil) {
        if !ud.bool(forKey: "showPreview") {
            showNotification(title: "Recording Completed".local,
                             body: String(format: "File saved to: %@".local, url.path),
                             id: "quickrecorder.completed.\(UUID().uuidString)")
        }
        if streamType != .systemaudio && ud.bool(forKey: "trimAfterRecord") {
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
        } else {
            showPreview(path: url.path, image: image)
        }
    }

    static func completeRecordingStop() {
        controlPanel.close()
        if isCameraRunning() {
            camWindow.close()
            deviceWindow.close()
            previewSession?.stopRunning()
            captureSession?.stopRunning()
        }
        mediaLock.lock()
        audioFile = nil
        audioFile2 = nil
        vW = nil
        vwInput = nil
        awInput = nil
        micInput = nil
        stream = nil
        streamType = nil
        startTime = nil
        firstFrame = nil
        lastPTS = nil
        window = nil
        screen = nil
        application = nil
        isPaused = false
        isResume = false
        isStopping = false
        recordingError = nil
        shouldMixAudio = false
        shouldExportMP3 = false
        mediaLock.unlock()
        PopoverState.shared.isPaused = false
        hideMousePointer = false
        hideScreenMagnifier = false
        AppDelegate.shared.presenterType = "OFF"
        updateStatusBar()
        AppDelegate.shared.recordingDidFinishForTermination()
    }

    static func showPreview(path: String, image: NSImage? = nil) {
        if !ud.bool(forKey: "showPreview") { return }
        var previewImage: NSImage?
        let previewURL = fd.temporaryDirectory.appendingPathComponent("qr-preview.jpg")
        if image == nil { firstFrame?.nsImage?.saveToFile(previewURL, type: .jpeg) }
        
        if let i = image { previewImage = i } else { previewImage = NSImage(contentsOf: previewURL) }
        if let previewImage = previewImage, let screen = getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFront(self)
        }
    }
    
    static func m4a2mp3(inputUrl: URL, outputUrl: URL) async throws {
        let progress = Progress()
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(Int32(ud.integer(forKey: "audioQuality"))),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress // optional
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }
    
    static func trimVideo() {
        if ud.bool(forKey: "trimAfterRecord") {
            let fileURL = filePath.url
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: fileURL), title: fileURL.lastPathComponent, only: false)
        }
    }
    
    static func getCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getMicrophone() -> [AVCaptureDevice] {
        var discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        }
        return discoverySession.devices.filter({ !$0.localizedName.contains("CADefaultDeviceAggregate") })
    }
    
    static func getiDevice() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .muxed, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getCurrentMic() -> AVCaptureDevice? {
        let deviceName = ud.string(forKey: "micDevice")
        return getMicrophone().first(where: { $0.localizedName == deviceName })
    }
    
    /*static func getChannelCount() -> Int? {
        if let device = getCurrentMic() {
            if let channels = device.formats.first?.formatDescription.audioChannelLayout?.numberOfChannels {
                return channels
            }
            
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let channelCount = audioStreamBasicDescription.mChannelsPerFrame
                return max(2, Int(channelCount))
            }
        }
        return getDefaultChannelCount()
    }
    
    static func getDefaultChannelCount() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取通道数
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // 查询流配置信息
        var streamConfig: UnsafeMutableAudioBufferListPointer?
        propertySize = 0
        
        // 先获取属性大小
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr else {
            print("Failed to get size for stream configuration")
            return nil
        }
        
        // 分配内存以存储音频流配置
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferList.deallocate() }
        
        let configStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        guard configStatus == noErr else {
            print("Failed to get stream configuration")
            return nil
        }
        
        streamConfig = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // 计算通道总数
        var totalChannels = 0
        for buffer in streamConfig! {
            totalChannels += Int(buffer.mNumberChannels)
        }
        return max(2, totalChannels)
    }*/
    
    static func getSampleRate() -> Int? {
        if let device = getCurrentMic() {
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let sampleRate = audioStreamBasicDescription.mSampleRate
                return Int(sampleRate)
            }
        }
        return getDefaultSampleRate()
    }
    
    static func getDefaultSampleRate() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取采样率
        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout.size(ofValue: sampleRate))
        
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let sampleRateStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &sampleRate
        )
        
        guard sampleRateStatus == noErr else {
            print("Failed to get sample rate for the default input device")
            return nil
        }
        
        return Int(sampleRate)
    }
    
    static func adjustTime(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetFormatDescription(sample) != nil else { return nil }
        
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(CMSampleBufferGetNumSamples(sample)))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingInfo.count, arrayToFill: &timingInfo, entriesNeededOut: nil)
        
        for i in 0..<timingInfo.count {
            timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, offset)
            timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, offset)
        }
        
        var outSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: timingInfo.count, sampleTimingArray: &timingInfo, sampleBufferOut: &outSampleBuffer)
        
        return outSampleBuffer
    }
    
    static func showNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification failed to send：\(error.localizedDescription)") }
        }
    }
    
    static func mixAudioTracks(videoURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        showNotification(title: "Still Processing".local, body: "Mixing audio track...".local, id: "quickrecorder.processing.\(UUID().uuidString)")
        
        let asset = AVAsset(url: videoURL)
        let audioOutputURL = videoURL.deletingPathExtension()
        let outputURL = audioOutputURL.deletingPathExtension()
        let audioOnlyComposition = AVMutableComposition()

        guard !fd.fileExists(atPath: audioOutputURL.path), !fd.fileExists(atPath: outputURL.path) else {
            completion(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)))
            return
        }
        let size = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let free = remainingCapacity(at: videoURL.deletingLastPathComponent()), free < Int64(size) * 2 + 256 * 1024 * 1024 {
            completion(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
            return
        }
        
        let fileEnding = videoURL.pathExtension
        var fileType: AVFileType?
        switch fileEnding {
        case VideoFormat.mov.rawValue: fileType = AVFileType.mov
        case VideoFormat.mp4.rawValue: fileType = AVFileType.mp4
        default: assertionFailure("loaded unknown video format".local)
        }
        
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
            return
        }
        
        for audioTrack in audioTracks {
            if let compositionAudioTrack = audioOnlyComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    let range = CMTimeRangeGetIntersection(audioTrack.timeRange, otherRange: CMTimeRange(start: .zero, duration: asset.duration))
                    try compositionAudioTrack.insertTimeRange(range, of: audioTrack, at: range.start)
                } catch {
                    completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                    return
                }
            }
        }
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioOnlyComposition.tracks(withMediaType: .audio).map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.trackID = $0.trackID
            return parameters
        }
        
        guard let audioExportSession = AVAssetExportSession(asset: audioOnlyComposition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "AudioExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio export session."])))
            return
        }
        audioExportSession.outputURL = audioOutputURL
        audioExportSession.outputFileType = fileType ?? .mp4
        audioExportSession.audioMix = audioMix
        
        audioExportSession.exportAsynchronously {
            switch audioExportSession.status {
            case .completed:
                let audioAsset = AVAsset(url: audioOutputURL)
                let composition = AVMutableComposition()
                
                guard let videoTrack = asset.tracks(withMediaType: .video).first,
                      let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    completion(.failure(NSError(domain: "VideoTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get video track."])))
                    return
                }
                
                do {
                    try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "VideoTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert video track: \(error.localizedDescription)"])))
                    return
                }
                
                let audioTracks = audioAsset.tracks(withMediaType: .audio)
                guard audioTracks.count >= 1 else {
                    completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
                    return
                }
                
                for audioTrack in audioTracks {
                    if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        do {
                            let range = CMTimeRangeGetIntersection(audioTrack.timeRange, otherRange: CMTimeRange(start: .zero, duration: asset.duration))
                            try compositionAudioTrack.insertTimeRange(range, of: audioTrack, at: range.start)
                        } catch {
                            completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                            return
                        }
                    }
                }
                
                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    completion(.failure(NSError(domain: "ExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session."])))
                    return
                }
                
                exportSession.outputURL = outputURL
                exportSession.outputFileType = fileType ?? .mp4
                // The mixed track already contains the audio mix. Preserve video
                // orientation in the final passthrough container.
                compositionVideoTrack.preferredTransform = videoTrack.preferredTransform
                
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        let  fileManager = fd
                        try? fileManager.removeItem(at: videoURL)
                        try? fileManager.removeItem(atPath: audioOutputURL.path)
                        completion(.success(outputURL))
                    case .failed:
                        completion(.failure(exportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
                    case .cancelled:
                        completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
                    default:
                        completion(.failure(NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected export status."])))
                    }
                }
            case .failed:
                completion(.failure(audioExportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
            case .cancelled:
                completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
            default:
                completion(.failure(NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected audio export status."])))
            }
        }
    }
}
