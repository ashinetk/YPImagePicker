//
//  YPPhotoCaptureHelper.swift
//  YPImagePicker
//
//  Created by Sacha DSO on 08/03/2018.
//  Copyright © 2018 Yummypets. All rights reserved.
//

import UIKit
import AVFoundation

internal final class YPPhotoCaptureHelper: NSObject {
    var currentFlashMode: YPFlashMode {
        return YPFlashMode(torchMode: device?.torchMode)
    }
    var device: AVCaptureDevice? {
        return deviceInput?.device
    }
    var hasFlash: Bool {
        let isFrontCamera = device?.position == .front
        let deviceHasFlash = device?.hasFlash ?? false
        return !isFrontCamera && deviceHasFlash
    }
    
    private let sessionQueue = DispatchQueue(label: "YPPhotoCaptureHelperQueue", qos: .background)
    private let session = AVCaptureSession()
    private var deviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var isCaptureSessionSetup: Bool = false
    private var isPreviewSetup: Bool = false
    private var previewView: UIView!
    private var videoLayer: AVCaptureVideoPreviewLayer!
    private var block: ((Data) -> Void)?
    private var initVideoZoomFactor: CGFloat = 1.0
}

// MARK: - Public

extension YPPhotoCaptureHelper {
    func shoot(completion: @escaping (Data) -> Void) {
        // 检查会话是否正在运行
        guard session.isRunning else {
            ypLog("Camera session is not running, cannot capture photo")
            return
        }
        
        // 检查设备是否可用
        guard let device = device else {
            ypLog("Camera device not available")
            return
        }
        
        // 检查是否有可用的连接
        guard photoOutput.connection(with: .video) != nil else {
            ypLog("No video connection available for photo output")
            return
        }
        
        block = completion
        
        // Set current device orientation
        setCurrentOrienation()
        
        let settings = photoCaptureSettings()
        
        // 使用 sessionQueue 来确保线程安全
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 再次检查会话状态（在正确的队列中）
            guard self.session.isRunning else {
                ypLog("Camera session stopped before capture")
                return
            }
            
            // 执行拍照
            do {
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            } catch {
                ypLog("Error capturing photo: \(error)")
            }
        }
    }
    
    func start(with previewView: UIView, completion: @escaping () -> Void) {
        self.previewView = previewView
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if !self.isCaptureSessionSetup {
                self.setupCaptureSession()
            }
            self.startCamera {
                completion()
            }
        }
    }
    
    func stopCamera() {
        if session.isRunning {
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }
    
    func zoom(began: Bool, scale: CGFloat) {
        guard let device = device else {
            return
        }
        
        if began {
            initVideoZoomFactor = device.videoZoomFactor
            return
        }
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            var minAvailableVideoZoomFactor: CGFloat = 1.0
            if #available(iOS 11.0, *) {
                minAvailableVideoZoomFactor = device.minAvailableVideoZoomFactor
            }
            var maxAvailableVideoZoomFactor: CGFloat = device.activeFormat.videoMaxZoomFactor
            if #available(iOS 11.0, *) {
                maxAvailableVideoZoomFactor = device.maxAvailableVideoZoomFactor
            }
            maxAvailableVideoZoomFactor = min(maxAvailableVideoZoomFactor, YPConfig.maxCameraZoomFactor)
            
            let desiredZoomFactor = initVideoZoomFactor * scale
            device.videoZoomFactor = max(minAvailableVideoZoomFactor,
                                         min(desiredZoomFactor, maxAvailableVideoZoomFactor))
        } catch let error {
            ypLog("Error: \(error)")
        }
    }
    
    func flipCamera(completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            self?.flip()
            DispatchQueue.main.async {
                completion()
            }
        }
    }
    
    func focus(on point: CGPoint) {
        guard let device = device else {
            return
        }
        
        setFocusPointOnDevice(device: device, point: point)
    }
}

extension YPPhotoCaptureHelper: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // 处理拍照错误
        if let error = error {
            ypLog("Photo capture error: \(error)")
            return
        }
        
        guard let data = photo.fileDataRepresentation() else {
            ypLog("Failed to get photo data representation")
            return
        }
        
        // 确保在主线程调用完成回调
        DispatchQueue.main.async { [weak self] in
            self?.block?(data)
            self?.block = nil // 清空回调防止重复调用
        }
    }
}

// MARK: - Private
private extension YPPhotoCaptureHelper {
    
    // MARK: Setup
    
    private func photoCaptureSettings() -> AVCapturePhotoSettings {
        var settings = AVCapturePhotoSettings()
        
        // Catpure Heif when available.
        if #available(iOS 11.0, *) {
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
        }
        
        // Catpure Highest Quality possible.
        settings.isHighResolutionPhotoEnabled = true
        
        // Set flash mode.
        if let deviceInput = deviceInput {
            if deviceInput.device.isFlashAvailable {
                let supportedFlashModes = photoOutput.__supportedFlashModes
                switch currentFlashMode {
                case .auto:
                    if supportedFlashModes.contains(NSNumber(value: AVCaptureDevice.FlashMode.auto.rawValue)) {
                        settings.flashMode = .auto
                    }
                case .off:
                    if supportedFlashModes.contains(NSNumber(value: AVCaptureDevice.FlashMode.off.rawValue)) {
                        settings.flashMode = .off
                    }
                case .on:
                    if supportedFlashModes.contains(NSNumber(value: AVCaptureDevice.FlashMode.on.rawValue)) {
                        settings.flashMode = .on
                    }
                }
            }
        }
        
        return settings
    }
    
    private func setupCaptureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        let cameraPosition: AVCaptureDevice.Position = YPConfig.usesFrontCamera ? .front : .back
        let aDevice = AVCaptureDevice.deviceForPosition(cameraPosition)
        
        guard let device = aDevice else {
            ypLog("No camera device available for position: \(cameraPosition)")
            session.commitConfiguration()
            return
        }
        
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            ypLog("Error creating device input: \(error)")
            session.commitConfiguration()
            return
        }
        
        if let videoInput = deviceInput {
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                ypLog("Cannot add video input to session")
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.isHighResolutionCaptureEnabled = true
                
                // Improve capture time by preparing output with the desired settings.
                do {
                    photoOutput.setPreparedPhotoSettingsArray([photoCaptureSettings()], completionHandler: nil)
                } catch {
                    ypLog("Error preparing photo settings: \(error)")
                }
            } else {
                ypLog("Cannot add photo output to session")
            }
        }
        
        session.commitConfiguration()
        isCaptureSessionSetup = true
    }
    
    private func tryToSetupPreview() {
        if !isPreviewSetup {
            setupPreview()
            isPreviewSetup = true
        }
    }
    
    private func setupPreview() {
        videoLayer = AVCaptureVideoPreviewLayer(session: session)
        DispatchQueue.main.async {
            self.videoLayer.frame = self.previewView.bounds
            self.videoLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
            self.previewView.layer.addSublayer(self.videoLayer)
        }
    }
    
    // MARK: Other
    
    private func startCamera(completion: @escaping (() -> Void)) {
        if !session.isRunning {
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                
                // Re-apply session preset
                self.session.sessionPreset = .photo
                let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
                switch status {
                case .notDetermined, .restricted, .denied:
                    ypLog("Camera access not authorized: \(status)")
                    self.session.stopRunning()
                case .authorized:
                    // 确保会话配置正确
                    guard self.isCaptureSessionSetup else {
                        ypLog("Capture session not properly setup")
                        return
                    }
                    
                    self.session.startRunning()
                    
                    // 验证会话确实在运行
                    if self.session.isRunning {
                        DispatchQueue.main.async {
                            completion()
                        }
                        self.tryToSetupPreview()
                    } else {
                        ypLog("Failed to start camera session")
                    }
                @unknown default:
                    ypLog("unknown default reached. Check code.")
                }
            }
        } else {
            DispatchQueue.main.async {
                completion()
            }
        }
    }
    
    private func flip() {
        session.resetInputs()
        guard let di = deviceInput else { return }
        deviceInput = flippedDeviceInputForInput(di)
        guard let deviceInput = deviceInput else { return }
        if session.canAddInput(deviceInput) {
            session.addInput(deviceInput)
        }
    }
    
    private func setCurrentOrienation() {
        let connection = photoOutput.connection(with: .video)
        let orientation = YPDeviceOrientationHelper.shared.currentDeviceOrientation
        switch orientation {
        case .portrait:
            connection?.videoOrientation = .portrait
        case .portraitUpsideDown:
            connection?.videoOrientation = .portraitUpsideDown
        case .landscapeRight:
            connection?.videoOrientation = .landscapeLeft
        case .landscapeLeft:
            connection?.videoOrientation = .landscapeRight
        default:
            connection?.videoOrientation = .portrait
        }
    }
}
