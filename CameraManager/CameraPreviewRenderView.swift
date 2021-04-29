//
//  CameraPreviewRenderView.swift
//  Alamofire
//
//  Created by Max Lesichniy on 11.06.2020.
//

import UIKit
import AVFoundation

@available(iOS 4.0, macCatalyst 14.0, *)
public class CameraPreviewRenderView: UIView {
    
    weak var session: AVCaptureSession?
    
    func attachTo(_ session: AVCaptureSession) {
        fatalError("needs override this method")
    }
    
}

//class CameraPreviewDefaultRenderView: CameraPreviewRenderView {
//
//    public private(set) var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
//        willSet {
//            videoPreviewLayer?.removeFromSuperlayer()
//        }
//        didSet {
//            guard let validLayer = videoPreviewLayer else {
//                return
//            }
//
//            layer.addSublayer(validLayer)
//        }
//    }
//
//    override func attachTo(_ captureSession: AVCaptureSession) {
//        if captureSession != self.session {
//            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
//            previewLayer.videoGravity = .resizeAspectFill
//            self.videoPreviewLayer = previewLayer
//            self.session = captureSession
//        }
//    }
//
//}
