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

public enum CameraFlashMode: Int {
    case off, on, auto
}

public enum CameraOutputMode: Int {
    case photo
    case videoWithMic
    case videoOnly
}

public protocol CameraManagerDelegate: class {
    func cameraManager(_ cameraManager: CameraManager, didChangeSessionPreset preset: AVCaptureSession.Preset)
}

/// Class for handling iDevices custom camera usage
open class CameraManager: NSObject, UIGestureRecognizerDelegate {
    
    @available(iOS 11.0, *)
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
            if shouldRespondToOrientationChanges {
                _startFollowingDeviceOrientation()
            } else {
                _stopFollowingDeviceOrientation()
            }
        }
    }
    
    open var updateConnectionsOrientation = false
    
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
        let hasFlashDevices = AVCaptureDevice.videoDevices.filter { $0.hasFlash }
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
            if cameraIsSetup && cameraPosition != oldValue {
                _updateInputs()
                _updateIlluminationMode(flashMode)
                _setupMaxZoomScale()
                _zoom(0)
                _orientationChanged()
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
    open var currentSessionPreset: AVCaptureSession.Preset {
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
                    _setupOutputMode(cameraOutputMode, oldCameraOutputMode: oldValue)
                }
                _setupMaxZoomScale()
                _zoom(0)
            }
        }
    }
    
    var onChangeISO: ((Float) -> Void)?
    
    /// Property to check video recording duration when in progress.
    open var recordedDuration : CMTime { return movieFileOutput?.recordedDuration ?? CMTime.zero }
    
    /// Property to check video recording file size when in progress.
    open var recordedFileSize : Int64 { return movieFileOutput?.recordedFileSize ?? 0 }
    
    /// Property to set focus mode when tap to focus is used (_focusStart).
    open var focusMode : AVCaptureDevice.FocusMode = .continuousAutoFocus
    
    /// Property to set exposure mode when tap to focus is used (_focusStart).
    open var exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure
    
    /// Property to set video stabilisation mode during a video record session
    open var videoStabilisationMode : AVCaptureVideoStabilizationMode = .auto
    
    open var isRecording: Bool { return movieFileOutput?.isRecording ?? false }
    
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
    
//    fileprivate lazy var stillImageOutput: AVCaptureStillImageOutput? = {
//        let output = AVCaptureStillImageOutput()
//        return output
//    }()
    
    fileprivate lazy var photoOutput: AVCapturePhotoOutput? = AVCapturePhotoOutput()
    
    fileprivate lazy var movieFileOutput: AVCaptureMovieFileOutput? = {
        let output = AVCaptureMovieFileOutput()
        output.movieFragmentInterval = .invalid
        return output
    }()
    
    fileprivate var previewLayer: AVCaptureVideoPreviewLayer?
    fileprivate var photoLibrary = PHPhotoLibrary.shared()
    
    fileprivate var cameraIsSetup = false
    fileprivate var cameraIsObservingDeviceOrientation = false
    
    fileprivate var zoomScale       = CGFloat(1.0)
    fileprivate var beginZoomScale  = CGFloat(1.0)
    fileprivate var maxZoomScale    = CGFloat(1.0)
        
    fileprivate func _tempFilePath() -> URL {
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
        _stopFollowingDeviceOrientation()
        stopAndRemoveCaptureSession()
    }
    
    /**
     Inits a capture session and adds a preview layer to the given view. Preview layer bounds will automaticaly be set to match given view. Default session is initialized with still image output.
     
     :param: view The view you want to add the preview layer to
     :param: cameraOutputMode The mode you want capturesession to run image / video / video and microphone
     :param: completion Optional completion block
     
     :returns: Current state of the camera: Ready / AccessDenied / NoDeviceFound / NotDetermined.
     */
    
//    @discardableResult
//    open func addPreviewView(_ view: CameraPreviewView, completion: (() -> Void)?) -> CameraState {
//        if _canLoadCamera() {
//            _setupCameraIfNeeded()
//            _addPreviewView(view)
//            sessionQueue.async {
//                DispatchQueue.main.async {
//                    completion?()
//                }
//            }
//        }
//        return _checkIfCameraIsAvailable()
//    }
    
    open func setSessionPreset(_ newPreset: AVCaptureSession.Preset, animation: Bool, completion: (() -> Void)?) {
        guard newPreset != currentSessionPreset else {
            completion?()
            return
        }
        
        if animation {
            cameraPreviewView?.performBlurAnimation(completion: nil)
        }
        performInSessionQueueIfNedded {
            self.currentSessionPreset = newPreset
            DispatchQueue.main.async {
                if animation {
                    self.cameraPreviewView?.removeTransitionView()
                }
                completion?()
            }
        }
    }
    
    open func setCameraPosition(_ position: AVCaptureDevice.Position, animation: Bool, completion: (() -> Void)?) {
        guard position != self.cameraPosition else {
            completion?()
            return
        }
        if animation {
            cameraPreviewView?.performFlipTransitionAnimation(direction: position == .back ? .fromLeft : .fromRight,
                                                              removeBlurOnComlpetion: false, completion: nil)
        }
        performInSessionQueueIfNedded {
            self.cameraPosition = position
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
    
    /**
     Stops running capture session but all setup devices, inputs and outputs stay for further reuse.
     */
    open func stopCaptureSession() {
        if captureSession.isRunning {
            performInSessionQueueIfNedded {
                self.captureSession.stopRunning()
                self._stopFollowingDeviceOrientation()
            }
        }
    }
    
    /**
     Resumes capture session.
     */
    open func startCaptureSession(completion: (() -> Void)? = nil) {
        self._setupCameraIfNeeded()
        if !self.captureSession.isRunning {
            performInSessionQueueIfNedded {
                self.captureSession.startRunning()
                self._startFollowingDeviceOrientation()
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
//        self.stillImageOutput = nil
        self.movieFileOutput = nil
        self.photoOutput = nil
    }
    
    /**
     Captures still image from currently running capture session.
     
     :param: imageCompletion Completion block containing the captured UIImage
     */
    @available(iOS 11.0, *)
    open func capturePhoto(with settings: AVCapturePhotoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg.rawValue]),
                           completion: @escaping CapturePhotoCompletion) {
        
        guard cameraIsSetup else {
            _show(NSLocalizedString("No capture session setup", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
            return
        }
        
        guard cameraOutputMode == .photo else {
            _show(NSLocalizedString("Capture session output mode video", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
            return
        }
        
        _updateIlluminationMode(flashMode)
        
        
        performInSessionQueueIfNedded {
            if let connection = self.photoOutput?.connection(with: .video),
                connection.isEnabled {
                if self.cameraPosition == .front && connection.isVideoMirroringSupported && self.shouldFlipFrontCameraImage {
                    connection.isVideoMirrored = true
                }
                
                if connection.isVideoOrientationSupported,
                    let orientation = self.previewLayer?.connection?.videoOrientation {
                    connection.videoOrientation = orientation
                }
                
                self.capturePhotoCompletion = completion
                self.photoOutput?.capturePhoto(with: settings, delegate: self)
            } else {
                completion(nil, NSError())
            }
        }
    }
    
    //    fileprivate func _capturePicture(_ imageData: Data, _ imageCompletion: @escaping (UIImage?, NSError?) -> Void) {
    //        guard let img = UIImage(data: imageData) else {
    //            imageCompletion(nil, NSError())
//            return
//        }
//
//        let image = fixOrientation(withImage: img)
//
//        if writeFilesToPhoneLibrary {
//
//            let filePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tempImg\(Int(Date().timeIntervalSince1970)).jpg")
//            let newImageData = _imageDataWithEXIF(forImage: image, imageData) as Data
//
//            do {
//
//                try newImageData.write(to: filePath)
//
//                // make sure that doesn't fail the first time
//                if PHPhotoLibrary.authorizationStatus() != .authorized {
//                    PHPhotoLibrary.requestAuthorization { (status) in
//                        if status == PHAuthorizationStatus.authorized {
//                            self._saveImageToLibrary(atFileURL: filePath, imageCompletion)
//                        }
//                    }
//                } else {
//                    self._saveImageToLibrary(atFileURL: filePath, imageCompletion)
//                }
//
//            } catch {
//                imageCompletion(nil, NSError())
//                return
//            }
//        }
//
//        imageCompletion(image, nil)
//    }
    
    fileprivate func _setVideoWithGPS(forLocation location: CLLocation) {
        let metadata = AVMutableMetadataItem()
        metadata.keySpace = AVMetadataKeySpace.quickTimeMetadata
        metadata.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString
        metadata.identifier = AVMetadataIdentifier.quickTimeMetadataLocationISO6709
        metadata.value = String(format: "%+09.5f%+010.5f%+.0fCRSWGS_84", location.coordinate.latitude, location.coordinate.longitude, location.altitude) as NSString
        movieFileOutput?.metadata = [metadata]
    }
    
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
    
    /**
     Captures still image from currently running capture session.
     
     :param: imageCompletion Completion block containing the captured imageData
     */
//    open func capturePictureDataWithCompletion(_ imageCompletion: @escaping (Data?, NSError?) -> Void) {
//        guard cameraIsSetup else {
//            _show(NSLocalizedString("No capture session setup", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
//            return
//        }
//
//        guard cameraOutputMode == .photo else {
//            _show(NSLocalizedString("Capture session output mode video", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
//            return
//        }
//
//        _updateIlluminationMode(flashMode)
//
//        performInSessionQueueIfNedded {
//            if let connection = self.stillImageOutput?.connection(with: .video),
//                connection.isEnabled {
//                if self.cameraPosition == .front && connection.isVideoMirroringSupported &&
//                    self.shouldFlipFrontCameraImage {
//                    connection.isVideoMirrored = true
//                }
//
//                if connection.isVideoOrientationSupported,
//                    let or = self.previewLayer?.connection?.videoOrientation {
//                    connection.videoOrientation = or
//                }
//
//                self.stillImageOutput?.captureStillImageAsynchronously(from: connection, completionHandler: { [weak self] sample, error in
//
//                    if let error = error {
//                        self?._show(NSLocalizedString("Error", comment:""), message: error.localizedDescription)
//                        imageCompletion(nil, error as NSError?)
//                        return
//                    }
//
//                    guard let sample = sample else { imageCompletion(nil, NSError()); return }
//                    let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(sample)
//                    imageCompletion(imageData, nil)
//
//                })
//            } else {
//                imageCompletion(nil, NSError())
//            }
//        }
//    }
    
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
            
            videoOutput.startRecording(to: self._tempFilePath(), recordingDelegate: self)
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
        let devices = AVCaptureDevice.videoDevices
        for device in devices where device.position == cameraPosition {
            return device.hasFlash
        }
        return false
    }
    
    fileprivate func _saveVideoToLibrary(_ fileURL: URL) {
        
        let location = self.locationManager?.latestLocation
        let date = Date()
        
        photoLibrary.save(videoAtURL: fileURL, albumName: self.videoAlbumName, date: date, location: location, completion: { _ in
            self._executeVideoCompletionWithURL(fileURL, error: nil)
        })
        
    }
    
    // MARK: -
    
    fileprivate func _zoom(_ scale: CGFloat) {
        guard let device = currentVideoCaptureDevice else { return }
        
        do {
            zoomScale = max(1.0, min(beginZoomScale * scale, maxZoomScale))
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
            } catch {}
        }
        
    }
    
    let exposureDurationPower: Float = 4.0 //the exposure slider gain
    let exposureMininumDuration: Float64 = 1.0/2000.0
    
    func _changeExposureDuration(value: Float) {
        guard self.cameraIsSetup, let device = currentVideoCaptureDevice else { return }
        
        do {
            try device.configure {
                let p = Float64(pow(value, exposureDurationPower)) // Apply power function to expand slider's low-end range
                let minDurationSeconds = Float64(max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), exposureMininumDuration))
                let maxDurationSeconds = Float64(CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
                let newDurationSeconds = Float64(p * (maxDurationSeconds - minDurationSeconds)) + minDurationSeconds // Scale from 0-1 slider range to actual duration
                
                if device.exposureMode == .custom {
                    let newExposureTime = CMTimeMakeWithSeconds(Float64(newDurationSeconds), preferredTimescale: 1000*1000*1000)
                    device.setExposureModeCustom(duration: newExposureTime, iso: AVCaptureDevice.currentISO, completionHandler: nil)
                }
            }
        } catch {
            print(error)
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
        var currentConnection: AVCaptureConnection?
        
        switch cameraOutputMode {
        case .photo:
//            currentConnection = stillImageOutput?.connection(with: .video)
            currentConnection = photoOutput?.connection(with: .video)
        case .videoOnly, .videoWithMic:
            currentConnection = movieFileOutput?.connection(with: .video)
            if let location = self.locationManager?.latestLocation {
                _setVideoWithGPS(forLocation: location)
            }
        }
        
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
    
    fileprivate func _currentCaptureVideoOrientation() -> AVCaptureVideoOrientation {
        
        if deviceOrientation == .faceDown
            || deviceOrientation == .faceUp
            || deviceOrientation == .unknown {
            return _currentPreviewVideoOrientation()
        }
        
        return _videoOrientation(forDeviceOrientation: deviceOrientation)
    }
    
    
    fileprivate func _currentPreviewDeviceOrientation() -> UIDeviceOrientation {
        if shouldKeepViewAtOrientationChanges {
            return .portrait
        }
        
        return UIDevice.current.orientation
    }
    
    
    fileprivate func _currentPreviewVideoOrientation() -> AVCaptureVideoOrientation {
        let orientation = _currentPreviewDeviceOrientation()
        return _videoOrientation(forDeviceOrientation: orientation)
    }
    
    open func resetOrientation() {
        //Main purpose is to reset the preview layer orientation.  Problems occur if you are recording landscape, present a modal VC,
        //then turn portriat to dismiss.  The preview view is then stuck in a prior orientation and not redrawn.  Calling this function
        //will then update the orientation of the preview layer.
        _orientationChanged()
    }
    
    fileprivate func _videoOrientation(forDeviceOrientation deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .faceUp:
            /*
             Attempt to keep the existing orientation.  If the device was landscape, then face up
             getting the orientation from the stats bar would fail every other time forcing it
             to default to portrait which would introduce flicker into the preview layer.  This
             would not happen if it was in portrait then face up
             */
            if let validPreviewLayer = previewLayer, let connection = validPreviewLayer.connection  {
                return connection.videoOrientation //Keep the existing orientation
            }
            //Could not get existing orientation, try to get it from stats bar
            return _videoOrientationFromStatusBarOrientation()
        case .faceDown:
            /*
             Attempt to keep the existing orientation.  If the device was landscape, then face down
             getting the orientation from the stats bar would fail every other time forcing it
             to default to portrait which would introduce flicker into the preview layer.  This
             would not happen if it was in portrait then face down
             */
            if let validPreviewLayer = previewLayer, let connection = validPreviewLayer.connection  {
                return connection.videoOrientation //Keep the existing orientation
            }
            //Could not get existing orientation, try to get it from stats bar
            return _videoOrientationFromStatusBarOrientation()
        default:
            return .portrait
        }
    }
    
    fileprivate func _videoOrientationFromStatusBarOrientation() -> AVCaptureVideoOrientation {
        
        var orientation: UIInterfaceOrientation?
        
        DispatchQueue.main.sync {
            orientation = UIApplication.shared.statusBarOrientation
        }
        
        /*
         Note - the following would fall into the guard every other call (it is called repeatedly) if the device was
         landscape then face up/down.  Did not seem to fail if in portrait first.
         */
        guard let statusBarOrientation = orientation else {
            return .portrait
        }
        
        switch statusBarOrientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
    
    fileprivate func fixOrientation(withImage image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
        var isMirrored = false
        let orientation = image.imageOrientation
        if orientation == .rightMirrored
            || orientation == .leftMirrored
            || orientation == .upMirrored
            || orientation == .downMirrored {
            
            isMirrored = true
        }
        
        let newOrientation = _imageOrientation(forDeviceOrientation: deviceOrientation, isMirrored: isMirrored)
        
        if image.imageOrientation != newOrientation {
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: newOrientation)
        }
        
        return image
    }
    
    fileprivate func _canLoadCamera() -> Bool {
        let currentCameraState = _checkIfCameraIsAvailable()
        return currentCameraState == .ready || (currentCameraState == .notDetermined && showAccessPermissionPopupAutomatically)
    }
    
    fileprivate func _setupCameraIfNeeded() {
        guard cameraIsSetup == false else { return }
        performInSessionQueueIfNedded {
            self.captureSession.configure {
                self.currentSessionPreset = self.preferredPresets.first ?? .high
                self._updateInputs()
                self._setupOutputMode(self.cameraOutputMode, oldCameraOutputMode: nil)
            }
            
            self._updateIlluminationMode(self.flashMode)
            self.captureSession.startRunning()
//            self._startFollowingDeviceOrientation()
//            self._orientationChanged()
            
            self.cameraIsSetup = true
        }
        
    }
    
//    fileprivate func _setupCameraIfNeeded(_ completion: @escaping () -> Void) {
//        sessionQueue.async(execute: {
//            self._setupCameraIfNeeded()
//            DispatchQueue.main.async {
//                completion()
//            }
//        })
//    }
    
    fileprivate func _startFollowingDeviceOrientation() {
        if shouldRespondToOrientationChanges && !cameraIsObservingDeviceOrientation {
            coreMotionManager = CMMotionManager()
            coreMotionManager.accelerometerUpdateInterval = 0.005
            
            if coreMotionManager.isAccelerometerAvailable {
                coreMotionManager.startAccelerometerUpdates(to: OperationQueue(), withHandler:
                    {data, error in
                        
                        guard let acceleration: CMAcceleration = data?.acceleration  else {
                            return
                        }
                        
                        let scaling: CGFloat = CGFloat(1) / CGFloat(( abs(acceleration.x) + abs(acceleration.y)))
                        
                        let x: CGFloat = CGFloat(acceleration.x) * scaling
                        let y: CGFloat = CGFloat(acceleration.y) * scaling
                        
                        if acceleration.z < Double(-0.75) {
                            self.deviceOrientation = .faceUp
                        } else if acceleration.z > Double(0.75) {
                            self.deviceOrientation = .faceDown
                        } else if x < CGFloat(-0.5) {
                            self.deviceOrientation = .landscapeLeft
                        } else if x > CGFloat(0.5) {
                            self.deviceOrientation = .landscapeRight
                        } else if y > CGFloat(0.5) {
                            self.deviceOrientation = .portraitUpsideDown
                        } else {
                            self.deviceOrientation = .portrait
                        }
                        
                        self._orientationChanged()
                })
                
                cameraIsObservingDeviceOrientation = true
            } else {
                cameraIsObservingDeviceOrientation = false
            }
        }
    }
    
    fileprivate func _stopFollowingDeviceOrientation() {
        if cameraIsObservingDeviceOrientation {
            coreMotionManager.stopAccelerometerUpdates()
            cameraIsObservingDeviceOrientation = false
        }
    }
    
//    fileprivate func _addPreviewView(_ view: CameraPreviewView) {
//        cameraPreviewView = view
//        cameraPreviewView?.delegate = self
//        cameraPreviewView?.videoPreviewLayer = previewLayer
//    }
    
    fileprivate func _setupMaxZoomScale() {
        var maxZoom = CGFloat(1.0)
        beginZoomScale = CGFloat(1.0)
        
        if let device = currentVideoCaptureDevice {
            maxZoom = device.activeFormat.videoMaxZoomFactor
        }
        
        maxZoomScale = maxZoom
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
    
    fileprivate func _setupOutputMode(_ newCameraOutputMode: CameraOutputMode, oldCameraOutputMode: CameraOutputMode?) {
        captureSession.beginConfiguration()
        
        if let cameraOutputToRemove = oldCameraOutputMode {
            // remove current setting
            switch cameraOutputToRemove {
            case .photo:
//                if let validStillImageOutput = stillImageOutput {
//                    captureSession.removeOutput(validStillImageOutput)
//                }
                photoOutput.map {
                    captureSession.removeOutput($0)
                }
            case .videoOnly, .videoWithMic:
                if let validMovieOutput = movieFileOutput {
                    captureSession.removeOutput(validMovieOutput)
                }
                if cameraOutputToRemove == .videoWithMic {
                    _removeMicInput()
                }
            }
        }
        
        // configure new devices
        switch newCameraOutputMode {
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
            
            if newCameraOutputMode == .videoWithMic,
                let validMic = _deviceInputFromDevice(currentAudioCaptureDevice) {
                captureSession.addInput(validMic)
            }
        }
        captureSession.commitConfiguration()
        _orientationChanged()
    }
    
    fileprivate func _updateInputsInQueue() {
        performInSessionQueueIfNedded { self._updateInputs() }
    }
    
    fileprivate func _updateInputs() {
        performInSessionQueueIfNedded {
            self.captureSession.configure {
                
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.cameraPosition),
                    let deviceInput = self._deviceInputFromDevice(device) {
                    
                    if !device.supportsSessionPreset(self.currentSessionPreset),
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
            }
        }
        
    }
    
    fileprivate func _updateIlluminationMode(_ mode: CameraFlashMode) {
        if (cameraOutputMode != .photo) {
            _updateTorch(mode)
        } else {
            _updateFlash(mode)
        }
    }
    
    fileprivate func _updateTorch(_ torchMode: CameraFlashMode) {
        captureSession.configure {
            for captureDevice in AVCaptureDevice.videoDevices  {
                guard let avTorchMode = AVCaptureDevice.TorchMode(rawValue: flashMode.rawValue) else { continue }
                if captureDevice.isTorchModeSupported(avTorchMode) && cameraPosition == .back {
                    do {
                        try captureDevice.configure {
                            captureDevice.torchMode = avTorchMode
                        }
                    } catch {}
                }
            }
        }
    }
    
    fileprivate func _updateFlash(_ flashMode: CameraFlashMode) {
        captureSession.configure {
            for captureDevice in AVCaptureDevice.videoDevices  {
                guard let avFlashMode = AVCaptureDevice.FlashMode(rawValue: flashMode.rawValue) else { continue }
                if captureDevice.isFlashModeSupported(avFlashMode) && cameraPosition == .back  {
                    do {
                        try captureDevice.configure {
                            captureDevice.flashMode = avFlashMode
                        }
                    } catch {}
                }
            }
        }
    }
    
    fileprivate func _performShutterAnimation(_ completion: (() -> Void)?) {
        if let previewView = self.cameraPreviewView {
            previewView.performShutterAnimation(completion)
        } else {
            completion?()
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
    
    fileprivate func _removeMicInput() {
        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
                deviceInput.device == currentAudioCaptureDevice {
                captureSession.removeInput(deviceInput)
                break
            }
        }
    }
    
    fileprivate func _show(_ title: String, message: String) {
        if showErrorsToUsers {
            DispatchQueue.main.async(execute: { () -> Void in
                self.showErrorBlock(title, message)
            })
        }
    }
    
    fileprivate func _deviceInputFromDevice(_ device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let validDevice = device else { return nil }
        do {
            return try AVCaptureDeviceInput(device: validDevice)
        } catch {
            _show(NSLocalizedString("Device setup error occured", comment: ""), message: "\(error)")
            return nil
        }
    }
    
    public func performInSessionQueueIfNedded(_ execute: @escaping () -> Void) {
        if OperationQueue.current != operationQueue {
            operationQueue.addOperation(execute)
        } else {
            execute()
        }
    }
    
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    
    @available(iOS 11.0, *)
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            showErrorBlock("Error", error.localizedDescription)
            capturePhotoCompletion?(photo, error)
            return
        }
        
        capturePhotoCompletion?(photo, error)
    }
    
}

// MARK: - AVCaptureFileOutputRecordingDelegate
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
            _show(NSLocalizedString("Unable to save video to the device", comment:""), message: error.localizedDescription)
        }
    }
    
}

// MARK: - CameraPreviewLayerDelegate
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

// MARK: - CameraLocationManager()

extension CameraManager {
    
    fileprivate class CameraLocationManager: NSObject, CLLocationManagerDelegate {
        var locationManager = CLLocationManager()
        var latestLocation: CLLocation?
        
        override init() {
            super.init()
            locationManager.delegate = self
            locationManager.requestWhenInUseAuthorization()
            locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.headingFilter = 5.0
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }
        
        func startUpdatingLocation() {
            locationManager.startUpdatingLocation()
        }
        
        func stopUpdatingLocation() {
            locationManager.stopUpdatingLocation()
        }
        
        // MARK: - CLLocationManagerDelegate
        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            // Pick the location with best (= smallest value) horizontal accuracy
            latestLocation = locations.sorted { $0.horizontalAccuracy < $1.horizontalAccuracy }.first
        }
        
        func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                locationManager.startUpdatingLocation()
            } else {
                locationManager.stopUpdatingLocation()
            }
        }
    }
    
}

fileprivate extension AVCaptureSession {
    
    func configure(with closure: () -> Void) {
        beginConfiguration()
        closure()
        commitConfiguration()
    }
    
}

fileprivate extension AVCaptureDevice {
    
    func configure(with closure: () -> Void) throws {
        try lockForConfiguration()
        closure()
        unlockForConfiguration()
    }
    
}

fileprivate extension AVCaptureDevice {
    
    fileprivate static var videoDevices: [AVCaptureDevice] {
        return AVCaptureDevice.devices(for: AVMediaType.video)
    }
    
}
