//
//  OrientationObserver.swift
//  CameraManager
//
//  Created by Max Lesichniy on 03.02.2021.
//

import Foundation
import UIKit
import CoreMotion
import AVFoundation

@available(iOS 4.0, macCatalyst 14.0, *)
class OrientationObserver {
    
    fileprivate lazy var coreMotionManager: CMMotionManager = {
        let manager = CMMotionManager()
        manager.accelerometerUpdateInterval = 0.005
        return manager
    }()
    
    fileprivate var orientationChangedHandler: ((OrientationObserver) -> Void)?
    fileprivate(set) var observingDeviceOrientation: Bool = false    
    var deviceOrientation: UIDeviceOrientation = .portrait
    var shouldKeepViewAtOrientationChanges: Bool = true
    
    
    init() {
        
    }
    
    deinit {
        stopFollowingDeviceOrientation()
    }
    
    func startFollowingDeviceOrientation(orientationChanged: @escaping (OrientationObserver) -> Void) {
        guard !observingDeviceOrientation else {
            return
        }
        
        if coreMotionManager.isAccelerometerAvailable {
            coreMotionManager.startAccelerometerUpdates(to: OperationQueue(), withHandler: { data, error in
                
                guard let acceleration: CMAcceleration = data?.acceleration else {
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
                
                self.orientationChanged()
            })
            
            orientationChangedHandler = orientationChanged
            observingDeviceOrientation = true
        } else {
            observingDeviceOrientation = false
        }
    }
    
    func stopFollowingDeviceOrientation() {
        if observingDeviceOrientation {
            coreMotionManager.stopAccelerometerUpdates()
            observingDeviceOrientation = false
        }
    }
    
    func currentCaptureVideoOrientation() -> AVCaptureVideoOrientation {
        
        if deviceOrientation == .faceDown
            || deviceOrientation == .faceUp
            || deviceOrientation == .unknown {
            return currentPreviewVideoOrientation()
        }
        
        return videoOrientation(for: deviceOrientation)
    }
    
    fileprivate func currentPreviewVideoOrientation() -> AVCaptureVideoOrientation {
        let orientation = currentPreviewDeviceOrientation()
        return videoOrientation(for: orientation)
    }
    
    fileprivate func currentPreviewDeviceOrientation() -> UIDeviceOrientation {
        if shouldKeepViewAtOrientationChanges {
            return .portrait
        }
        
        return UIDevice.current.orientation
    }
    
    func videoOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
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
            //            if let validPreviewLayer = previewLayer, let connection = validPreviewLayer.connection  {
            //                return connection.videoOrientation //Keep the existing orientation
            //            }
            //Could not get existing orientation, try to get it from stats bar
            return videoOrientationFromStatusBarOrientation()
        case .faceDown:
            /*
             Attempt to keep the existing orientation.  If the device was landscape, then face down
             getting the orientation from the stats bar would fail every other time forcing it
             to default to portrait which would introduce flicker into the preview layer.  This
             would not happen if it was in portrait then face down
             */
            //            if let validPreviewLayer = previewLayer, let connection = validPreviewLayer.connection  {
            //                return connection.videoOrientation //Keep the existing orientation
            //            }
            //Could not get existing orientation, try to get it from stats bar
            return videoOrientationFromStatusBarOrientation()
        default:
            return .portrait
        }
    }
    
    fileprivate func videoOrientation(from interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch interfaceOrientation {
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
    
    fileprivate func videoOrientationFromStatusBarOrientation() -> AVCaptureVideoOrientation {
        let orientation = DispatchQueue.main.sync {
            UIApplication.shared.statusBarOrientation
        }
        return videoOrientation(from: orientation)
    }
    
    fileprivate func orientationChanged() {
        
    }
    
}
