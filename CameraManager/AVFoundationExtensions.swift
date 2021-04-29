//
//  AVFoundationExtensions.swift
//  CameraManager
//
//  Created by Max Lesichniy on 03.02.2021.
//

import AVFoundation

@available(iOS 4.0, macCatalyst 14.0, *)
public extension AVCaptureSession {
    
    func configure(with closure: () -> Void) {
        beginConfiguration()
        closure()
        commitConfiguration()
    }
    
}

@available(iOS 4.0, macCatalyst 14.0, *)
public extension AVCaptureDevice {
    
    func configure(with closure: () -> Void) throws {
        try lockForConfiguration()
        closure()
        unlockForConfiguration()
    }
    
}

@available(iOS 4.0, macCatalyst 14.0, *)
public extension AVCaptureVideoOrientation {
    
    init(_ interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        default:
            self = .portrait
        }
    }
    
}
