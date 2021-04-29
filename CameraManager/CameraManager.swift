//
//  CameraManager.swift
//  camera
//
//  Created by Natalia Terlecka on 10/10/14.
//  Copyright (c) 2014 Imaginary Cloud. All rights reserved.
//

import UIKit
import AVFoundation
import Photos
import ImageIO
import MobileCoreServices
import CoreLocation
import CoreMotion
import CoreImage

public enum CameraState {
    case ready, accessDenied, noDeviceFound, notDetermined
}

@available(iOS 4.0, macCatalyst 14.0, *)
public enum CameraFlashMode: Int, CaseIterable {
    case off, on, auto
    
    var flashMode: AVCaptureDevice.FlashMode {
        return AVCaptureDevice.FlashMode(rawValue: rawValue) ?? .off
    }
}

public enum CameraOutputMode: Int {
    case photo
    case videoWithMic
    case videoOnly
}

@available(iOS 4.0, macCatalyst 14.0, *)
public protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ cameraManager: CameraManager, didChangeSessionPreset preset: AVCaptureSession.Preset)
}

/// Class for handling iDevices custom camera usage
@available(iOS 4.0, macCatalyst 14.0, *)
open class CameraManager: NSObject, UIGestureRecognizerDelegate {
    
    public enum VideoOrientationBehavior {
        case fixed(AVCaptureVideoOrientation)
        case followDeviceOrientation
    }
    
    @available(iOS 11.0, macCatalyst 14.0, *)
    public typealias CapturePhotoCompletion = (AVCapturePhoto?, Error?) -> Void
    
    // MARK: - Public properties
    
    open var preferredPresets: [AVCaptureSession.Preset] = [.hd1920x1080, .hd1280x720, .vga640x480]
    
    open weak var delegate: CameraManagerDelegate?
    
    // Property for custom image album name.
    open var imageAlbumName: String?
    
    // Property for custom image album name.
    open var videoAlbumName: String?
    
    /// Property for capture session to customize camera settings.
    open var captureSession = AVCaptureSession()
    
    /** 
     Property to determine if the manager should show the error for the user. If you want to show the errors yourself set this to false. If you want to add custom error UI set showErrorBlock property.
     - note: Default value is **false**
     */
    open var showErrorsToUsers = false
    
    /// Property to determine if the manager should show the camera permission popup immediatly when it's needed or you want to show it manually. Default value is true. Be carful cause using the camera requires permission, if you set this value to false and don't ask manually you won't be able to use the camera.
    open var showAccessPermissionPopupAutomatically = true
    
    /// A block creating UI to present error message to the user. This can be customised to be presented on the Window root view controller, or to pass in the viewController which will present the UIAlertController, for example.
    open var showErrorBlock:(_ erTitle: String, _ erMessage: String) -> Void = { (erTitle: String, erMessage: String) -> Void in
        
        var alertController = UIAlertController(title: erTitle, message: erMessage, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: UIAlertAction.Style.default, handler: { (alertAction) -> Void in  }))
        
        if let topController = UIApplication.shared.keyWindow?.rootViewController {
            topController.present(alertController, animated: true, completion:nil)
        }
    }
    
    /**
     Property to determine if manager should write the resources to the phone library.
     - note: Default value is **true**
     */
    open var writeFilesToPhoneLibrary = true
    
    /**
     Property to determine if manager should follow device orientation.
     - note: Default value is **true**
     */
    open var shouldRespondToOrientationChanges = true {
        didSet {
//            if shouldRespondToOrientationChanges {
//                _startFollowingDeviceOrientation()
//            } else {
//                _stopFollowingDeviceOrientation()
//            }
        }
    }
    
//    open var updateConnectionsOrientation = false
    
    /**
     Property to determine if manager should horizontally flip image took by front camera.
     - note: Default value is **false**
     */
    open var shouldFlipFrontCameraImage = false
    
    /**
     Property to determine if manager should keep view with the same bounds when the orientation changes.
     - note: Default value is **false**
     */
    open var shouldKeepViewAtOrientationChanges = false
    
    /// Property to determine if the camera is ready to use.
    open var cameraIsReady: Bool {
        get {
            return cameraIsSetup
        }
    }
    
    /// Property to determine if current device has flash.
    open var hasFlash: Bool = {
        let hasFlashDevices = AVCaptureDevice.devices(for: .video).filter { $0.hasFlash }
        return !hasFlashDevices.isEmpty
    }()
    
    /**
     Property to enable or disable shutter animation when taking a picture.
     - note: Default value is **true**
     */
    open var animateShutter: Bool = true
    
    /**
     Property to enable or disable location services. Location services in camera is used for EXIF data.
     - note: Default value is **false**
     */
    open var shouldUseLocationServices: Bool = false {
        didSet {
            if shouldUseLocationServices {
                self.locationManager = CameraLocationManager()
            }
        }
    }
    
    /// Property to change camera device between front and back.
    open var cameraPosition: AVCaptureDevice.Position = .back {
        didSet {
            if cameraPosition != oldValue {
                _updateInputs()
            }
        }
    }
    
    /// Property to change camera flash mode.
    open var flashMode = CameraFlashMode.off {
        didSet {
            if cameraIsSetup && flashMode != oldValue {
                _updateIlluminationMode(flashMode)
            }
        }
    }
    
    /// Property to change camera output quality.
    open var sessionPreset: AVCaptureSession.Preset {
        set {
            if newValue != captureSession.sessionPreset {
                self._updateSessionPreset(newValue, notify: false)
            }
        }
        get {
            return captureSession.sessionPreset
        }
    }
    
    /// Property to change camera output.
    open var cameraOutputMode = CameraOutputMode.photo {
        didSet {
            if cameraIsSetup {
                if cameraOutputMode != oldValue {
                    _setupOutputMode(cameraOutputMode, oldMode: oldValue)
                }
                _resetZoomScale()
                _zoom(0)
            }
        }
    }
    
    var onChangeISO: ((Float) -> Void)?
    
    /// Property to check video recording duration when in progress.
    open var recordedDuration: CMTime { return movieFileOutput?.recordedDuration ?? CMTime.zero }
    
    /// Property to check video recording file size when in progress.
    open var recordedFileSize: Int64 { return movieFileOutput?.recordedFileSize ?? 0 }
    
    /// Property to set focus mode when tap to focus is used (_focusStart).
    open var focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus
    
    /// Property to set exposure mode when tap to focus is used (_focusStart).
    open var exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure
    
    /// Property to set video stabilisation mode during a video record session
    open var videoStabilisationMode : AVCaptureVideoStabilizationMode = .auto
    
    open var isRecording: Bool { return movieFileOutput?.isRecording ?? false }
    
    // MARK: -
    
    var orientationObserver = OrientationObserver()
    
    open var videoOrientationBehavior: VideoOrientationBehavior = .followDeviceOrientation
    
    // MARK: - Private properties
    
    fileprivate var locationManager: CameraLocationManager?
    
    open weak var cameraPreviewView: CameraPreviewView? {
        didSet {
            cameraPreviewView?.delegate = self
            cameraPreviewView?.videoPreviewLayer = previewLayer
        }
    }
    
    public var didCompletionRecording: ((_ videoURL: URL?, _ error: Error?) -> Void)?
    fileprivate var didStartRerording: (() -> Void)?
    
    fileprivate var capturePhotoCompletion: CapturePhotoCompletion?
    
    fileprivate var sessionQueue: DispatchQueue = DispatchQueue(label: "CameraManagerQueue", attributes: [])
    fileprivate var operationQueue = OperationQueue()
    
    fileprivate var currentVideoCaptureDevice: AVCaptureDevice?
    fileprivate var videoDeviceInput: AVCaptureDeviceInput?
    
    fileprivate lazy var currentAudioCaptureDevice: AVCaptureDevice? = {
        return AVCaptureDevice.default(for: AVMediaType.audio)
    }()
    
    public fileprivate(set) lazy var photoOutput: AVCapturePhotoOutput? = AVCapturePhotoOutput()
    
    public fileprivate(set) lazy var movieFileOutput: AVCaptureMovieFileOutput? = {
        let output = AVCaptureMovieFileOutput()
        output.movieFragmentInterval = .invalid
        return output
    }()
    
    fileprivate var previewLayer: AVCaptureVideoPreviewLayer?
    fileprivate var photoLibrary = PHPhotoLibrary.shared()
    
    fileprivate var cameraIsSetup = false
    fileprivate var cameraIsObservingDeviceOrientation = false
    
    fileprivate var zoomScale: CGFloat = 1.0
    fileprivate var beginZoomScale: CGFloat = 1.0
        
    fileprivate var tempFileUrl: URL {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tempMovie\(Date().timeIntervalSince1970)").appendingPathExtension("mp4")
        return tempURL
    }
    
    fileprivate var coreMotionManager: CMMotionManager!
    
    /// Real device orientation from accelerometer
    fileprivate var deviceOrientation: UIDeviceOrientation = .portrait
    
    // MARK: - CameraManager
    
    public override init() {
        super.init()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = sessionQueue
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.videoGravity = .resizeAspectFill
    }
    
    deinit {
        stopAndRemoveCaptureSession()
    }
    
    // MARK: - Public
    
    public func performInSessionQueueIfNedded(_ execute: @escaping () -> Void) {
        if OperationQueue.current != operationQueue {
            operationQueue.addOperation(execute)
        } else {
            execute()
        }
    }
    
    open func setSessionPreset(_ newPreset: AVCaptureSession.Preset, animation: Bool, completion: (() -> Void)?) {
        guard newPreset != sessionPreset else {
            completion?()
            return
        }
        
        if animation {
            cameraPreviewView?.performBlurAnimation(completion: nil)
        }
        performInSessionQueueIfNedded {
            self.sessionPreset = newPreset
            DispatchQueue.main.async {
                if animation {
                    self.cameraPreviewView?.removeTransitionView()
                }
                completion?()
            }
        }
    }
    
    open func setCameraPosition(_ position: AVCaptureDevice.Position, animation: Bool = true,
                                additionally: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        guard position != self.cameraPosition else {
            completion?()
            return
        }
        
        if animation {
            cameraPreviewView?.performFlipTransitionAnimation(direction: position == .back ? .fromLeft : .fromRight,
                                                              removeBlurOnComlpetion: false, completion: nil)
        }
        
        performInSessionQueueIfNedded {
            self.captureSession.configure {
                self.cameraPosition = position
                additionally?()
            }
            
            DispatchQueue.main.async {
                if animation {
                    self.cameraPreviewView?.removeTransitionView()
                }
                completion?()
            }
        }
    }
    
    /**
     Zoom in to the requested scale.
     */
    open func zoom(_ scale: CGFloat) {
        _zoom(scale)
    }
    
    /**
     Asks the user for camera permissions. Only works if the permissions are not yet determined. Note that it'll also automaticaly ask about the microphone permissions if you selected VideoWithMic output.
     
     :param: completion Completion block with the result of permission request
     */
    open func askUserForCameraPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: { allowedAccess in
            if self.cameraOutputMode == .videoWithMic {
                AVCaptureDevice.requestAccess(for: .audio, completionHandler: { allowedAccess in
                    DispatchQueue.main.async {
                        completion(allowedAccess)
                    }
                })
            } else {
                DispatchQueue.main.async{
                    completion(allowedAccess)
                }
            }
        })
    }
    
    open func prepare() {
        _setupCameraIfNeeded()
    }
    
    /**
     Stops running capture session but all setup devices, inputs and outputs stay for further reuse.
     */
    open func stopCaptureSession() {
        if captureSession.isRunning {
            performInSessionQueueIfNedded {
                self.captureSession.stopRunning()
            }
        }
    }
    
    /**
     Resumes capture session.
     */
    open func startCaptureSession(completion: (() -> Void)? = nil) {
        prepare()
        performInSessionQueueIfNedded {
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                DispatchQueue.main.async {
                    completion?()
                }
            }
        }
    }
    
    /**
     Stops running capture session and removes all setup devices, inputs and outputs.
     */
    open func stopAndRemoveCaptureSession() {
        self.stopCaptureSession()
        self.cameraIsSetup = false
        self.previewLayer = nil
        self.currentAudioCaptureDevice = nil
        self.movieFileOutput = nil
        self.photoOutput = nil
    }
    
    /**
     Captures still image from currently running capture session.
     
     :param: imageCompletion Completion block containing the captured UIImage
     */
    @available(iOS 11.0, macCatalyst 14.0, *)
    open func capturePhoto(with settings: AVCapturePhotoSettings? = nil,
                           completion: @escaping CapturePhotoCompletion) {
        
        guard cameraIsSetup else {
            _show(NSLocalizedString("No capture session setup", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
            return
        }
        
        guard cameraOutputMode == .photo,
              let photoOutput = self.photoOutput else {
            _show(NSLocalizedString("Capture session output mode video", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
            return
        }
        
        let resolvedSettings = settings ?? {
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg.rawValue])
            if #available(macCatalyst 14.0, *) {
                if photoOutput.supportedFlashModes.contains(flashMode.flashMode) {
                    settings.flashMode = flashMode.flashMode
                }
            }
            return settings
        }()
        
        performInSessionQueueIfNedded {
            if let connection = photoOutput.connection(with: .video),
                connection.isEnabled {
                if self.cameraPosition == .front && connection.isVideoMirroringSupported && self.shouldFlipFrontCameraImage {
                    connection.isVideoMirrored = true
                }
                
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = self._videoOrientation(from: self.videoOrientationBehavior)
                }
                
                self.capturePhotoCompletion = completion
                photoOutput.capturePhoto(with: resolvedSettings, delegate: self)
            } else {
                completion(nil, NSError())
            }
        }
    }
    
    /**
     Starts recording a video with or without voice as in the session preset.
     */
    open func startRecordingVideo(completion: (() -> Void)? = nil) {
        guard cameraOutputMode != .photo else {
            _show(NSLocalizedString("Capture session output still image", comment:""), message: NSLocalizedString("I can only take pictures", comment:""))
            return
        }
        
        guard let videoOutput = movieFileOutput else { return }
        
        didStartRerording = completion
        
        performInSessionQueueIfNedded {
            
            // setup video mirroring
            for connection in videoOutput.connections {
                for port in connection.inputPorts {
                    
                    if port.mediaType == .video {
                        let videoConnection = connection as AVCaptureConnection
                        if videoConnection.isVideoMirroringSupported {
                            videoConnection.isVideoMirrored = (self.cameraPosition == .front && self.shouldFlipFrontCameraImage)
                        }
                        
                        if videoConnection.isVideoStabilizationSupported {
                            videoConnection.preferredVideoStabilizationMode = self.videoStabilisationMode
                        }
                    }
                }
            }
            
//            let specs = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: AVMetadataIdentifier.quickTimeMetadataLocationISO6709,
//                         kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String] as [String : Any]
//
//            var locationMetadataDesc: CMFormatDescription?
//            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specs] as CFArray, formatDescriptionOut: &locationMetadataDesc)
            
            // Create the metadata input and add it to the session.
//            guard let locationMetadata = locationMetadataDesc else { return }
//
//            let newLocationMetadataInput = AVCaptureMetadataInput(formatDescription: locationMetadata, clock: CMClockGetHostTimeClock())
//            self.captureSession.addInputWithNoConnections(newLocationMetadataInput)
            
            // Connect the location metadata input to the movie file output.
//            let inputPort = newLocationMetadataInput.ports[0]
//            self.captureSession.addConnection(AVCaptureConnection(inputPorts: [inputPort], output: videoOutput))
            
//            self._updateIlluminationMode(self.flashMode)
            
            videoOutput.startRecording(to: self.tempFileUrl, recordingDelegate: self)
        }
        
    }
    
    /**
     Stop recording a video. Save it to the cameraRoll and give back the url.
     */
    open func stopVideoRecording(_ completion: ((_ videoURL: URL?, _ error: Error?) -> Void)?) {
        if let runningMovieOutput = movieFileOutput, runningMovieOutput.isRecording {
            if let newClosure = completion {
                let oldClosure = self.didCompletionRecording
                didCompletionRecording = { videoURL, error in
                    oldClosure?(videoURL, error)
                    newClosure(videoURL, error)
                }
            }
            runningMovieOutput.stopRecording()
        }
    }
    
    /**
     Check if the device rotation is locked
     */
    open func deviceOrientationMatchesInterfaceOrientation() -> Bool {
        return deviceOrientation == UIDevice.current.orientation
    }
    
    /**
     Current camera status.
     
     :returns: Current state of the camera: Ready / AccessDenied / NoDeviceFound / NotDetermined
     */
    open func currentCameraStatus() -> CameraState {
        return _checkIfCameraIsAvailable()
    }
    
    /**
     Change current flash mode to next value from available ones.
     
     :returns: Current flash mode: Off / On / Auto
     */
    open func changeFlashMode() -> CameraFlashMode {
        guard let newFlashMode = CameraFlashMode(rawValue: (flashMode.rawValue+1)%3) else { return flashMode }
        flashMode = newFlashMode
        return flashMode
    }
    
    /**
     Check the camera device has flash
     */
    open func hasFlash(for cameraPosition: AVCaptureDevice.Position) -> Bool {
        for device in AVCaptureDevice.devices(for: .video) where device.position == cameraPosition {
            return device.hasFlash
        }
        return false
    }
    
    // MARK: - Private
    
    fileprivate func _canLoadCamera() -> Bool {
        let currentCameraState = _checkIfCameraIsAvailable()
        return currentCameraState == .ready || (currentCameraState == .notDetermined && showAccessPermissionPopupAutomatically)
    }
    
    fileprivate func _setupCameraIfNeeded() {
        guard cameraIsSetup == false else { return }
        performInSessionQueueIfNedded {
            self.captureSession.configure {
                self._updateInputs()
                self._setupOutputMode(self.cameraOutputMode, oldMode: nil)
            }
            self._updateIlluminationMode(self.flashMode)
            self.cameraIsSetup = true
        }
    }
    
    fileprivate func _setupOutputMode(_ newMode: CameraOutputMode, oldMode: CameraOutputMode?) {
        captureSession.beginConfiguration()
        
        if let cameraOutputToRemove = oldMode {
            // remove current setting
            switch cameraOutputToRemove {
            case .photo:
                photoOutput.map {
                    captureSession.removeOutput($0)
                }
            case .videoOnly, .videoWithMic:
                movieFileOutput.map {
                    captureSession.removeOutput($0)
                }
                
                if cameraOutputToRemove == .videoWithMic {
                    for input in captureSession.inputs {
                        if let deviceInput = input as? AVCaptureDeviceInput,
                            deviceInput.device == currentAudioCaptureDevice {
                            captureSession.removeInput(deviceInput)
                            break
                        }
                    }
                }
            }
        }
        
        // configure new devices
        switch newMode {
        case .photo:
            if let photoOutput = photoOutput,
                captureSession.canAddOutput(photoOutput) {
                captureSession.addOutput(photoOutput)
            }
        case .videoOnly, .videoWithMic:
            if let movieFileOutput = movieFileOutput,
                captureSession.canAddOutput(movieFileOutput) {
                captureSession.addOutput(movieFileOutput)
            }
            
            if newMode == .videoWithMic,
                let validMic = _makeDeviceInputFromDevice(currentAudioCaptureDevice) {
                captureSession.addInput(validMic)
            }
        }
        captureSession.commitConfiguration()
        _orientationChanged()
    }
    
    fileprivate func _getPreferredVideoCaptureDevice() -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = []
        if #available(iOS 13, *) {
            types.append(.builtInTripleCamera)
            types.append(.builtInDualWideCamera)
        }
        if #available(iOS 10.2, *) {
            types.append(.builtInDualCamera)
        }
        if #available(iOS 11.1, *) {
            types.append(.builtInTrueDepthCamera)
        }
        types.append(.builtInWideAngleCamera)
        
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: self.cameraPosition)
        return discoverySession.devices.first
    }
    
    fileprivate func _updateInputs() {
        performInSessionQueueIfNedded {
            self.captureSession.configure {
                
                if let device = self._getPreferredVideoCaptureDevice(),
                    let deviceInput = self._makeDeviceInputFromDevice(device) {
                    
                    if !device.supportsSessionPreset(self.sessionPreset),
                        let supportedPresset = self.preferredPresets.first(where: { device.supportsSessionPreset($0) }) {
                        self._updateSessionPreset(supportedPresset, notify: true)
                    }
                    
                    self.videoDeviceInput.map { self.captureSession.removeInput($0) }
                    
                    if self.captureSession.canAddInput(deviceInput) {
                        self.captureSession.addInput(deviceInput)
                        self.currentVideoCaptureDevice = device
                        self.videoDeviceInput = deviceInput
                    } else {
                        self.videoDeviceInput.map { self.captureSession.addInput($0) }
                    }
                }
                
                self._resetZoomScale()
                self._updateIlluminationMode(self.flashMode)
            }
        }
        
    }
    
    fileprivate func _updateSessionPreset(_ newPreset: AVCaptureSession.Preset, notify: Bool) {
        if captureSession.canSetSessionPreset(newPreset) {
            performInSessionQueueIfNedded {
                self.captureSession.configure {
                    self.captureSession.sessionPreset = newPreset
                }
                if notify {
                    DispatchQueue.main.async {
                        self.delegate?.cameraManager(self, didChangeSessionPreset: newPreset)
                    }
                }
            }
        } else {
            _show(NSLocalizedString("Preset not supported", comment: ""),
                  message: NSLocalizedString("Camera preset not supported. Please try another one.", comment: ""))
        }
    }
    
    
    fileprivate func _checkIfCameraIsAvailable() -> CameraState {
        let deviceHasCamera = UIImagePickerController.isCameraDeviceAvailable(.rear) || UIImagePickerController.isCameraDeviceAvailable(.front)
        if deviceHasCamera {
            let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            let userAgreedToUseIt = authorizationStatus == .authorized
            if userAgreedToUseIt {
                return .ready
            } else if authorizationStatus == .notDetermined {
                return .notDetermined
            } else {
                _show(NSLocalizedString("Camera access denied", comment: ""), message: NSLocalizedString("You need to go to settings app and grant acces to the camera device to use it.", comment: ""))
                return .accessDenied
            }
        } else {
            _show(NSLocalizedString("Camera unavailable", comment: ""), message: NSLocalizedString("The device does not have a camera.", comment: ""))
            return .noDeviceFound
        }
    }
    
    fileprivate func _updateIlluminationMode(_ mode: CameraFlashMode) {
        if cameraOutputMode != .photo {
            _updateTorch(mode)
        }
    }
    
    fileprivate func _updateTorch(_ torchMode: CameraFlashMode) {
        guard let avTorchMode = AVCaptureDevice.TorchMode(rawValue: flashMode.rawValue) else { return }
        guard let captureDevice = currentVideoCaptureDevice, captureDevice.isTorchModeSupported(avTorchMode) else { return }
        captureSession.configure {
            do {
                try captureDevice.configure {
                    captureDevice.torchMode = avTorchMode
                }
            } catch {
                _show(error)
            }
        }
    }
    
    fileprivate func _resetZoomScale() {
        var minZoom: CGFloat = 1.0
        var defaultZoom: CGFloat = 1.0
        
        if let device = currentVideoCaptureDevice {
            minZoom = device.minAvailableVideoZoomFactor
            defaultZoom = minZoom
            if #available(iOS 13.0, *) {
                if device.isVirtualDevice, let switchOverVideoZoom = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue {
                    defaultZoom = CGFloat(switchOverVideoZoom)
                }
            } else {
                defaultZoom = device.dualCameraSwitchOverVideoZoomFactor
            }
        }
        
        beginZoomScale = minZoom
        
        _zoom(defaultZoom)
    }
    
    fileprivate func _handleError(_ error: Error, title: String? = nil, _ func: String = #function) {
        if let title = title {
            _show(title, message: error.localizedDescription)
        } else {
            _show(error)
        }
        
    }
    
    fileprivate func _show(_ error: Error) {
        _show(NSLocalizedString("Error", comment: ""), message: error.localizedDescription)
    }
    
    fileprivate func _show(_ title: String, message: String) {
        if showErrorsToUsers {
            DispatchQueue.main.async(execute: { () -> Void in
                self.showErrorBlock(title, message)
            })
        }
    }
    
    fileprivate func _performShutterAnimation(_ completion: (() -> Void)?) {
        if let previewView = self.cameraPreviewView {
            previewView.performShutterAnimation(completion)
        } else {
            completion?()
        }
    }
    
    func _videoOrientation(from behavior: VideoOrientationBehavior) -> AVCaptureVideoOrientation {
        switch behavior {
        case .fixed(let orientation):
            return orientation
        case .followDeviceOrientation:
            return orientationObserver.videoOrientation(for: UIDevice.current.orientation)
        }
    }
    
    // MARK: -
    
//    fileprivate func _imageDataWithEXIF(forImage image: UIImage, _ imageData: Data) -> CFMutableData {
//        // get EXIF info
//        let cgImage = image.cgImage
//        let newImageData: CFMutableData = CFDataCreateMutable(nil, 0)
//        let type = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, "image/jpg" as CFString, kUTTypeImage)
//        let destination: CGImageDestination = CGImageDestinationCreateWithData(newImageData, (type?.takeRetainedValue())!, 1, nil)!
//
//        let imageSourceRef = CGImageSourceCreateWithData(imageData as CFData, nil)
//        let currentProperties = CGImageSourceCopyPropertiesAtIndex(imageSourceRef!, 0, nil)
//        let mutableDict = NSMutableDictionary(dictionary: currentProperties!)
//
//        if let location = self.locationManager?.latestLocation {
//            mutableDict.setValue(_gpsMetadata(withLocation: location), forKey: kCGImagePropertyGPSDictionary as String)
//        }
//
//        CGImageDestinationAddImage(destination, cgImage!, mutableDict as CFDictionary)
//        CGImageDestinationFinalize(destination)
//
//        return newImageData
//    }
    
    fileprivate func _setVideoWithGPS(forLocation location: CLLocation) {
        let metadata = AVMutableMetadataItem()
        metadata.keySpace = AVMetadataKeySpace.quickTimeMetadata
        metadata.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString
        metadata.identifier = AVMetadataIdentifier.quickTimeMetadataLocationISO6709
        metadata.value = String(format: "%+09.5f%+010.5f%+.0fCRSWGS_84", location.coordinate.latitude, location.coordinate.longitude, location.altitude) as NSString
        movieFileOutput?.metadata = [metadata]
    }
    
    fileprivate func _gpsMetadata(withLocation location: CLLocation) -> [String: Any] {
        let f = DateFormatter()
        f.timeZone = TimeZone(abbreviation: "UTC")
        
        f.dateFormat = "yyyy:MM:dd"
        let isoDate = f.string(from: location.timestamp)
        
        f.dateFormat = "HH:mm:ss.SSSSSS"
        let isoTime = f.string(from: location.timestamp)
        
        var gpsMetadata = [String: Any]()
        let altitudeRef = Int(location.altitude < 0.0 ? 1 : 0)
        let latitudeRef = location.coordinate.latitude < 0.0 ? "S" : "N"
        let longitudeRef = location.coordinate.longitude < 0.0 ? "W" : "E"
        
        // GPS metadata
        gpsMetadata[(kCGImagePropertyGPSLatitude as String)] = abs(location.coordinate.latitude)
        gpsMetadata[(kCGImagePropertyGPSLongitude as String)] = abs(location.coordinate.longitude)
        gpsMetadata[(kCGImagePropertyGPSLatitudeRef as String)] = latitudeRef
        gpsMetadata[(kCGImagePropertyGPSLongitudeRef as String)] = longitudeRef
        gpsMetadata[(kCGImagePropertyGPSAltitude as String)] = Int(abs(location.altitude))
        gpsMetadata[(kCGImagePropertyGPSAltitudeRef as String)] = altitudeRef
        gpsMetadata[(kCGImagePropertyGPSTimeStamp as String)] = isoTime
        gpsMetadata[(kCGImagePropertyGPSDateStamp as String)] = isoDate
        
        return gpsMetadata
    }
    
    fileprivate func _saveImageToLibrary(atFileURL filePath: URL, _ imageCompletion: @escaping (UIImage?, NSError?) -> Void) {
        
        let location = self.locationManager?.latestLocation
        let date = Date()
        
        photoLibrary.save(imageAtURL: filePath, albumName: self.imageAlbumName, date: date, location: location)
    }
    
    fileprivate func _imageOrientation(forDeviceOrientation deviceOrientation: UIDeviceOrientation, isMirrored: Bool) -> UIImage.Orientation {
        
        switch deviceOrientation {
        case .landscapeLeft:
            return isMirrored ? .upMirrored : .up
        case .landscapeRight:
            return isMirrored ? .downMirrored : .down
        default:
            break
        }
        
        return isMirrored ? .leftMirrored : .right
    }
    
    
    fileprivate func _saveVideoToLibrary(_ fileURL: URL) {
        
        let location = self.locationManager?.latestLocation
        let date = Date()
        
        photoLibrary.save(videoAtURL: fileURL, albumName: self.videoAlbumName, date: date, location: location, completion: { _ in
            self._executeVideoCompletionWithURL(fileURL, error: nil)
        })
        
    }
    
    // MARK: - Device Controls
    
    fileprivate func _zoom(_ scale: CGFloat) {
        guard let device = currentVideoCaptureDevice else { return }
        let maxZoomFactor = device.maxAvailableVideoZoomFactor
        
        do {
            zoomScale = max(1.0, min(beginZoomScale * scale, maxZoomFactor))
            try device.configure {
                device.videoZoomFactor = zoomScale
            }
        } catch {
            print("Error locking configuration")
        }
    }
    
    
    // Available modes:
    // .Locked .AutoExpose .ContinuousAutoExposure .Custom
    func _changeExposureMode(mode: AVCaptureDevice.ExposureMode) {
        guard let device = currentVideoCaptureDevice else { return }
        
        if device.exposureMode == mode { return }
        
        if device.isExposureModeSupported(mode) {
            do {
                try device.configure {
                    device.exposureMode = mode
                }
            } catch {
                _show(error)
            }
        }
    }
    
    let exposureDurationPower: Float = 4.0 //the exposure slider gain
    let exposureMininumDuration: Float64 = 1.0/2000.0
    
    func _changeExposureDuration(value: Float) {
        guard let device = currentVideoCaptureDevice else { return }
        
        do {
            try device.configure {
                let p = Float64(pow(value, exposureDurationPower)) // Apply power function to expand slider's low-end range
                let minDurationSeconds = Float64(max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), exposureMininumDuration))
                let maxDurationSeconds = Float64(CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
                let newDurationSeconds = (p * (maxDurationSeconds - minDurationSeconds)) + minDurationSeconds // Scale from 0-1 slider range to actual duration
                
                if device.exposureMode == .custom {
                    let newExposureTime = CMTimeMakeWithSeconds(newDurationSeconds, preferredTimescale: 1000*1000*1000)
                    device.setExposureModeCustom(duration: newExposureTime, iso: AVCaptureDevice.currentISO, completionHandler: nil)
                }
            }
        } catch {
            _handleError(error)
        }
    }
    
    func expose(withISO: Float) {
        guard let device = currentVideoCaptureDevice else { return }
        
        _changeExposureMode(mode: .custom)
        
        do {
            try device.configure {
                if device.exposureMode == .custom {
                    let validISO = min(max(device.activeFormat.minISO, withISO), device.activeFormat.maxISO)
                    device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: validISO, completionHandler: nil)
                }
            }
        } catch {
            _handleError(error)
        }
    }
    
    // MARK: - CameraManager
    
    fileprivate func _executeVideoCompletionWithURL(_ url: URL?, error: Error?) {
        if let validCompletion = didCompletionRecording {
            DispatchQueue.main.async {
                validCompletion(url, error)
            }
            didCompletionRecording = nil
        }
    }
    
    @objc fileprivate func _orientationChanged() {
//        var currentConnection: AVCaptureConnection?
        
//        switch cameraOutputMode {
//        case .photo:
////            currentConnection = stillImageOutput?.connection(with: .video)
//            currentConnection = photoOutput?.connection(with: .video)
//        case .videoOnly, .videoWithMic:
//            currentConnection = movieFileOutput?.connection(with: .video)
//            if let location = self.locationManager?.latestLocation {
//                _setVideoWithGPS(forLocation: location)
//            }
//        }
        
//        if let validPreviewLayer = previewLayer {
//            if !shouldKeepViewAtOrientationChanges {
//                if let validPreviewLayerConnection = validPreviewLayer.connection,
//                    validPreviewLayerConnection.isVideoOrientationSupported {
//                    validPreviewLayerConnection.videoOrientation = _currentPreviewVideoOrientation()
//                }
//            }
//            if updateConnectionsOrientation {
//                if let validOutputLayerConnection = currentConnection,
//                    validOutputLayerConnection.isVideoOrientationSupported {
//
//                    validOutputLayerConnection.videoOrientation = _currentCaptureVideoOrientation()
//                }
//            }
//        }
    }
    
    
    
    open func resetOrientation() {
        //Main purpose is to reset the preview layer orientation.  Problems occur if you are recording landscape, present a modal VC,
        //then turn portriat to dismiss.  The preview view is then stuck in a prior orientation and not redrawn.  Calling this function
        //will then update the orientation of the preview layer.
//        _orientationChanged()
    }
    
//    fileprivate func _updateFlash(_ flashMode: CameraFlashMode) {
//        guard let avFlashMode = AVCaptureDevice.FlashMode(rawValue: flashMode.rawValue) else { return }
//        guard let captureDevice = currentVideoCaptureDevice, captureDevice.isFlashModeSupported(avFlashMode) else { return }
//        captureSession.configure {
//            do {
//                try captureDevice.configure {
//                    captureDevice.flashMode = avFlashMode
//                }
//            } catch {
//                _show(error)
//            }
//        }
//    }

    
    fileprivate func _makeDeviceInputFromDevice(_ device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let validDevice = device else { return nil }
        do {
            return try AVCaptureDeviceInput(device: validDevice)
        } catch {
            _handleError(error)
            return nil
        }
    }
    
}

// MARK: - AVCapturePhotoCaptureDelegate
@available(iOS 11.0, macCatalyst 14.0, *)
extension CameraManager: AVCapturePhotoCaptureDelegate {
    
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            _handleError(error)
            capturePhotoCompletion?(photo, error)
            return
        }
        
        capturePhotoCompletion?(photo, error)
    }
    
//    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
//        if let error = error {
//            _handleError(error)
//        }
//    }
    
}

// MARK: - AVCaptureFileOutputRecordingDelegate
@available(iOS 4.0, macCatalyst 14.0, *)
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        captureSession.configure {
            if flashMode != .off {
                _updateIlluminationMode(flashMode)
            }
        }
        
        DispatchQueue.main.async {
            self.didStartRerording?()
            self.didStartRerording = nil
        }
    }
    
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        
        if writeFilesToPhoneLibrary {
            if PHPhotoLibrary.authorizationStatus() == .authorized {
                _saveVideoToLibrary(outputFileURL)
            } else {
                PHPhotoLibrary.requestAuthorization { (autorizationStatus) in
                    if autorizationStatus == .authorized {
                        self._saveVideoToLibrary(outputFileURL)
                    }
                }
            }
        } else {
            _executeVideoCompletionWithURL(outputFileURL, error: error)
        }
        
        if let error = error {
            _handleError(error)
        }
    }
    
}

// MARK: - CameraPreviewLayerDelegate
@available(iOS 4.0, macCatalyst 14.0, *)
extension CameraManager: CameraPreviewViewDelegate {
    
    public func cameraPreviewViewBeganZooming(_ view: CameraPreviewView) {
        beginZoomScale = zoomScale
    }
    
    public func cameraPreviewView(_ view: CameraPreviewView, applyZoom scale: CGFloat) {
        _zoom(scale)
    }
    
    public func cameraPreviewView(_ view: CameraPreviewView, applyFocusAndExposure pointOfInterest: CGPoint) {
        guard let validDevice = currentVideoCaptureDevice else { return }
        
        //        _changeExposureMode(mode: .continuousAutoExposure)
        
        do {
            try validDevice.configure {
                if validDevice.isFocusPointOfInterestSupported {
                    validDevice.focusPointOfInterest = pointOfInterest
                }
                
                if  validDevice.isExposurePointOfInterestSupported {
                    validDevice.exposurePointOfInterest = pointOfInterest
                }
                
                if validDevice.isFocusModeSupported(focusMode) {
                    validDevice.focusMode = focusMode
                }
                
                if validDevice.isExposureModeSupported(exposureMode) {
                    validDevice.exposureMode = exposureMode
                }
            }
        } catch {
            print(error)
        }
        
    }
    
    public func cameraPreviewView(_ view: CameraPreviewView, applyExposureDuration value: Float) {
        _changeExposureMode(mode: .custom)
        _changeExposureDuration(value: value)
    }
    
}
