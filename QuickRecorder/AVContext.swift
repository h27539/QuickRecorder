//
//  AVContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/27.
//
import AppKit
import Foundation
import AVFoundation
import UserNotifications

extension AppDelegate {
    func recordingCamera(with device: AVCaptureDevice) {
        SCContext.captureSession = AVCaptureSession()
        
        guard let input = try? AVCaptureDeviceInput(device: device),
              SCContext.captureSession.canAddInput(input) else {
            print("Failed to set up camera")
            SCContext.requestCameraPermission()
            return
        }
        SCContext.captureSession.addInput(input)
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: .global())
        
        if SCContext.captureSession.canAddOutput(videoOutput) {
            SCContext.captureSession.addOutput(videoOutput)
        }
        
        SCContext.captureSession.startRunning()
        DispatchQueue.main.async { self.startCameraOverlayer() }
    }
    
    func closeCamera() {
        if SCContext.isCameraRunning() {
            //SCContext.previewType = nil
            if camWindow.isVisible { camWindow.close() }
            SCContext.captureSession.stopRunning()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        /* 保留后续以作他用
        if !SCContext.isPaused && ud.string(forKey: "recordCam") != "" {
            if sampleBuffer.isValid { SCContext.isCameraReady = true }
            if sampleBuffer.imageBuffer != nil { SCContext.frameCache = sampleBuffer }
        }*/
    }
}

class AVOutputClass: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = AVOutputClass()
    var output: AVCaptureMovieFileOutput!
    var dataOutput: AVCaptureVideoDataOutput!
    // The requested file output is independent of isRecording and preview output.
    private var recordingOutput: AVCaptureMovieFileOutput?
    //var captureSession: AVCaptureSession!
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        //print(sampleBuffer.nsImage?.size)
    }
    
    public func startRecording(with device: AVCaptureDevice, mute: Bool = false, preset: AVCaptureSession.Preset = .high, didOutput: Bool = true) {
        if didOutput && !Thread.isMainThread {
            DispatchQueue.main.async { self.startRecording(with: device, mute: mute, preset: preset, didOutput: didOutput) }
            return
        }
        if didOutput, SCContext.streamType != nil { return }
        if didOutput, !SCContext.checkRecordingSpace(at: URL(fileURLWithPath: ud.string(forKey: "saveDirectory") ?? NSHomeDirectory())) { return }
        output = AVCaptureMovieFileOutput()
        dataOutput = AVCaptureVideoDataOutput()
        dataOutput.setSampleBufferDelegate(self, queue: .global())
        SCContext.captureSession = AVCaptureSession()
        SCContext.previewSession = AVCaptureSession()
        SCContext.captureSession.sessionPreset = preset
        SCContext.previewSession.sessionPreset = preset
        
        guard let input = try? AVCaptureDeviceInput(device: device),
              let preview = try? AVCaptureDeviceInput(device: device),
              SCContext.captureSession.canAddInput(input),
              SCContext.previewSession.canAddInput(preview),
              SCContext.captureSession.canAddOutput(output),
              SCContext.previewSession.canAddOutput(dataOutput) else {
            print("Failed to set up camera or device")
            SCContext.requestCameraPermission()
            return
        }
        
        SCContext.captureSession.addInput(input)
        SCContext.captureSession.addOutput(output)
        SCContext.previewSession.addInput(preview)
        SCContext.previewSession.addOutput(dataOutput)
        
        if mute {
            if let audioConnection = output.connection(with: .audio) {
                SCContext.captureSession.removeConnection(audioConnection)
                /*DispatchQueue.main.async {
                    let alert = createAlert(title: "No Audio Connection",
                                                               message: "Unable to get audio stream on this device, only screen content will be recorded!",
                                                               button1: "OK")
                    alert.runModal()
                }*/
            }
        }
        
        if didOutput {
            let encoderIsH265 = ud.string(forKey: "encoder") == Encoder.h265.rawValue
            let videoSettings: [String: Any] = [ AVVideoCodecKey: encoderIsH265 ? AVVideoCodecType.hevc : AVVideoCodecType.h264 ]
            guard let connection = output.connection(with: .video) else { return }
            output.setOutputSettings(videoSettings, for: connection)
            let fileEnding = ud.string(forKey: "videoFormat") ?? ""
            SCContext.filePath = "\(SCContext.getFilePath()).\(fileEnding)"
            SCContext.captureSession.startRunning()
            recordingOutput = output
            SCContext.mediaLock.lock()
            SCContext.recordingSessionID = UUID()
            SCContext.streamType = StreamType.idevice
            SCContext.mediaLock.unlock()
            output.startRecording(to: SCContext.filePath.url, recordingDelegate: self)
            SCContext.startTime = Date.now
            SCContext.startDiskSpaceMonitor()
        }
        
        SCContext.previewSession.startRunning()
        DispatchQueue.main.async {
            closeAllWindow(except: "Area Overlayer".local)
            updateStatusBar()
            AppDelegate.shared.startDeviceOverlayer(size: NSSize(width: 300, height: 500))
        }
    }

    public func stopRecording() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopRecording() }
            return
        }
        guard SCContext.streamType == .idevice, !SCContext.isStopping else { return }
        SCContext.mediaLock.lock()
        SCContext.isStopping = true
        SCContext.mediaLock.unlock()
        SCContext.diskSpaceTimer?.invalidate()
        SCContext.diskSpaceTimer = nil
        if let recordingOutput = recordingOutput {
            // A request may still be starting, or already finishing with an error.
            // isRecording only describes new sample collection, not completion.
            recordingOutput.stopRecording()
        } else {
            SCContext.reportSaveFailure("No device recording request is pending.", path: SCContext.filePath ?? "")
            SCContext.completeRecordingStop()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            guard output === self.recordingOutput, SCContext.streamType == .idevice else { return }
            if SCContext.isStopping { output.stopRecording() }
        }
    }
    
    func closePreview() {
        if SCContext.isCameraRunning() {
            //SCContext.previewType = nil
            if deviceWindow.isVisible { deviceWindow.close() }
            if let preview = SCContext.previewSession { preview.stopRunning() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            guard output === self.recordingOutput, SCContext.streamType == .idevice else { return }
            self.recordingOutput = nil
            SCContext.diskSpaceTimer?.invalidate()
            SCContext.diskSpaceTimer = nil
            let nsError = error as NSError?
            let usable = error == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            if let reason = SCContext.recordingError ?? (usable ? nil : error?.localizedDescription) {
                SCContext.reportSaveFailure(reason, path: outputFileURL.path)
            } else {
                SCContext.showNotification(title: "Recording Completed".local,
                    body: String(format: "File saved to: %@".local, outputFileURL.path),
                    id: "quickrecorder.completed.\(UUID().uuidString)")
            }
            SCContext.completeRecordingStop()
        }
    }
}
