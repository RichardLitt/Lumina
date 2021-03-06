//
//  Camera.swift
//  CameraFramework
//
//  Created by David Okun on 8/31/17.
//  Copyright © 2017 David Okun. All rights reserved.
//

import UIKit
import AVFoundation

protocol LuminaCameraDelegate {
    func stillImageCaptured(camera: LuminaCamera, image: UIImage)
    func videoFrameCaptured(camera: LuminaCamera, frame: UIImage)
    func finishedFocus(camera: LuminaCamera)
    func detected(camera: LuminaCamera, metadata: [Any])
}

class LuminaCamera: NSObject {
    var delegate: LuminaCameraDelegate! = nil
    var controller: LuminaViewController?
    
    var torchState = false {
        didSet {
            guard let input = self.videoInput else {
                torchState = false
                return
            }
            do {
                try input.device.lockForConfiguration()
                if torchState == false {
                    if input.device.isTorchModeSupported(.off) {
                        input.device.torchMode = .off
                        input.device.unlockForConfiguration()
                    }
                } else {
                    if input.device.isTorchModeSupported(.on) {
                        input.device.torchMode = .on
                        input.device.unlockForConfiguration()
                    }
                }
            } catch {
                torchState = false
                input.device.unlockForConfiguration()
            }
        }
    }
    
    var streamFrames = false {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                update()
            }
        }
    }
    
    var trackMetadata = false {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                update()
            }
        }
    }
    
    var position: CameraPosition = .unspecified {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                update()
            }
        }
    }
    
    required init(with controller: LuminaViewController) {
        self.controller = controller
    }
    
    fileprivate var session = AVCaptureSession()
    fileprivate var discoverySession: AVCaptureDevice.DiscoverySession? {
        return AVCaptureDevice.DiscoverySession(deviceTypes: [AVCaptureDevice.DeviceType.builtInWideAngleCamera], mediaType: AVMediaType.video, position: AVCaptureDevice.Position.unspecified)
    }
    fileprivate var videoInput: AVCaptureDeviceInput?
    fileprivate var videoBufferQueue = DispatchQueue(label: "com.Lumina.videoBufferQueue")
    fileprivate var metadataBufferQueue = DispatchQueue(label: "com.lumina.metadataBufferQueue")
    fileprivate var videoOutput: AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: videoBufferQueue)
        return output
    }
    fileprivate var photoOutput = AVCapturePhotoOutput()
    
    private var _metadataOutput: AVCaptureMetadataOutput?
    fileprivate var metadataOutput: AVCaptureMetadataOutput {
        if let existingOutput = _metadataOutput {
            return existingOutput
        }
        let output = AVCaptureMetadataOutput()
        output.setMetadataObjectsDelegate(self, queue: metadataBufferQueue)
        _metadataOutput = output
        return output
    }
    
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let controller = self.controller else {
            return nil
        }
        let previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
        previewLayer.frame = controller.view.bounds
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        
        return previewLayer
    }
    
    func captureStillImage() {
        let settings = AVCapturePhotoSettings()
        settings.isAutoStillImageStabilizationEnabled = true
        settings.flashMode = self.torchState ? .on : .off
        self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func updateOutputVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        self.videoBufferQueue.async {
            for output in self.session.outputs {
                guard let connection = output.connection(with: AVMediaType.video) else {
                    continue
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
        }
    }
    
    func update() {
        recycleDeviceIO()
        self.torchState = false
        guard let input = getNewInputDevice() else {
            return
        }
        guard self.session.canAddInput(input) else {
            return
        }
        guard self.session.canAddOutput(self.videoOutput) else {
            return
        }
        guard self.session.canAddOutput(self.photoOutput) else {
            return
        }
        guard self.session.canAddOutput(self.metadataOutput) else {
            return
        }
        self.videoInput = input
        self.session.addInput(input)
        if self.streamFrames {
            self.session.addOutput(self.videoOutput)
        }
        self.session.addOutput(self.photoOutput)
        if self.trackMetadata {
            self.session.addOutput(self.metadataOutput)
            self.metadataOutput.metadataObjectTypes = self.metadataOutput.availableMetadataObjectTypes
        }
        self.session.commitConfiguration()
        self.session.startRunning()
    }
    
    func pause() {
        self.session.stopRunning()
    }
}

// MARK: Focus Handling

extension LuminaCamera {
    func handleFocus(at focusPoint: CGPoint) {
        guard let input = self.videoInput else {
            return
        }
        do {
            if input.device.isFocusModeSupported(.autoFocus) && input.device.isFocusPointOfInterestSupported {
                try input.device.lockForConfiguration()
                input.device.focusMode = .autoFocus
                input.device.focusPointOfInterest = CGPoint(x: focusPoint.x, y: focusPoint.y)
                if input.device.isExposureModeSupported(.autoExpose) && input.device.isExposurePointOfInterestSupported {
                    input.device.exposureMode = .autoExpose
                    input.device.exposurePointOfInterest = CGPoint(x: focusPoint.x, y: focusPoint.y)
                }
                input.device.unlockForConfiguration()
            } else {
                self.delegate.finishedFocus(camera: self)
            }
        } catch {
            self.delegate.finishedFocus(camera: self)
        }
    }
    
    func resetCameraToContinuousExposureAndFocus() {
        do {
            guard let input = self.videoInput else {
                print("Trying to focus, but cannot detect device input!")
                return
            }
            if input.device.isFocusModeSupported(.continuousAutoFocus) {
                try input.device.lockForConfiguration()
                input.device.focusMode = .continuousAutoFocus
                if input.device.isExposureModeSupported(.continuousAutoExposure) {
                    input.device.exposureMode = .continuousAutoExposure
                }
                input.device.unlockForConfiguration()
            }
        } catch {
            print("could not reset to continuous auto focus and exposure!!")
        }
    }
}

// MARK: CaptureDevice Handling

private extension LuminaCamera {
    func getNewInputDevice() -> AVCaptureDeviceInput? {
        do {
            guard let device = getDevice(with: self.position == .front ? AVCaptureDevice.Position.front : AVCaptureDevice.Position.back) else {
                print("could not find valid AVCaptureDevice")
                return nil
            }
            let input = try AVCaptureDeviceInput(device: device)
            return input
        } catch {
            return nil
        }
    }
    
    func recycleDeviceIO() {
        for oldInput in self.session.inputs {
            self.session.removeInput(oldInput)
        }
        for oldOutput in self.session.outputs {
            self.session.removeOutput(oldOutput)
        }
    }
    
    func getDevice(with position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        guard let discoverySession = self.discoverySession else {
            return nil
        }
        for device in discoverySession.devices {
            if device.position == position {
                return device
            }
        }
        return nil
    }
}

// MARK: Still Photo Capture

extension LuminaCamera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
        guard let buffer = photoSampleBuffer else {
            return
        }
        guard let image = buffer.normalizedStillImage(forCameraPosition: self.position) else {
            return
        }
        self.delegate.stillImageCaptured(camera: self, image: image)
    }
}

// MARK: Video Frame Streaming

extension LuminaCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = sampleBuffer.normalizedVideoFrame() else {
            return
        }
        DispatchQueue.main.async {
            self.delegate.videoFrameCaptured(camera: self, frame: image)
        }
    }
}

// MARK: Image Normalization Methods

extension CMSampleBuffer {
    func normalizedStillImage(forCameraPosition position: CameraPosition) -> UIImage? {
        guard let imageData = AVCapturePhotoOutput.jpegPhotoDataRepresentation(forJPEGSampleBuffer: self, previewPhotoSampleBuffer: nil) else {
            return nil
        }
        guard let dataProvider = CGDataProvider(data: imageData as CFData) else {
            return nil
        }
        guard let cgImageRef = CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: CGColorRenderingIntent.defaultIntent) else {
            return nil
        }
        return UIImage(cgImage: cgImageRef, scale: 1.0, orientation: getImageOrientation(forCamera: position))
    }
    
    func normalizedVideoFrame() -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(self) else {
            return nil
        }
        let coreImage: CIImage = CIImage(cvPixelBuffer: imageBuffer)
        let context: CIContext = CIContext()
        guard let sample: CGImage = context.createCGImage(coreImage, from: coreImage.extent) else {
            return nil
        }
        return UIImage(cgImage: sample)
    }
    
    private func getImageOrientation(forCamera: CameraPosition) -> UIImageOrientation {
        switch UIApplication.shared.statusBarOrientation {
        case .landscapeLeft:
            return forCamera == .back ? .down : .upMirrored
        case .landscapeRight:
            return forCamera == .back ? .up : .downMirrored
        case .portraitUpsideDown:
            return forCamera == .back ? .left : .rightMirrored
        case .portrait:
            return forCamera == .back ? .right : .leftMirrored
        case .unknown:
            return forCamera == .back ? .right : .leftMirrored
        }
    }
}

extension LuminaCamera: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard case self.trackMetadata = true else {
            return
        }
        DispatchQueue.main.async {
            self.delegate.detected(camera: self, metadata: metadataObjects)
        }
    }
}

