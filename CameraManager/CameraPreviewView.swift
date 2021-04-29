//
//  CameraPreviewView.swift
//  CameraManager
//
//  Created by Max Lesichniy on 3/7/19.
//  OnCreate company (https://oncreate.pro)
//  Copyright © 2019. All rights reserved.
//

import UIKit
import AVFoundation
import CoreImage

@available(iOS 4.0, macCatalyst 14.0, *)
@objc public protocol CameraPreviewViewDelegate: AnyObject {
    func cameraPreviewViewBeganZooming(_ view: CameraPreviewView)
    func cameraPreviewView(_ view: CameraPreviewView, applyZoom scale: CGFloat)
    func cameraPreviewView(_ view: CameraPreviewView, applyFocusAndExposure pointOfInterest: CGPoint)
    func cameraPreviewView(_ view: CameraPreviewView, applyExposureDuration value: Float)
}

@available(iOS 4.0, macCatalyst 14.0, *)
open class CameraPreviewView: UIView, UIGestureRecognizerDelegate {
    
    fileprivate(set) lazy var zoomGesture = UIPinchGestureRecognizer()
    fileprivate(set) lazy var focusGesture = UITapGestureRecognizer()
    fileprivate(set) lazy var exposureGesture = UIPanGestureRecognizer()

    fileprivate(set) lazy var cameraGridView = CameraGridView()
    /**
     Property to determine if manager should enable pinch to zoom on camera preview.
     - note: Default value is **true**
     */
    @IBInspectable open var shouldEnablePinchToZoom = true {
        didSet {
            zoomGesture.isEnabled = shouldEnablePinchToZoom
        }
    }
    /**
     Property to determine if manager should enable tap to focus on camera preview.
     - note: Default value is **true**
     */
    @IBInspectable open var shouldEnableTapToFocus = true {
        didSet {
            focusGesture.isEnabled = shouldEnableTapToFocus
        }
    }
    
    /**
     Property to determine if manager should enable pan to change exposure/brightness.
     - note: Default value is **true**
     */
    @IBInspectable open var shouldEnableExposure = true {
        didSet {
            exposureGesture.isEnabled = shouldEnableExposure
        }
    }
    
    @IBInspectable weak var delegate: CameraPreviewViewDelegate?
    
    @IBInspectable var showGrid: Bool = false {
        didSet {
            setNeedsLayout()
        }
    }
    
    @IBOutlet public var customRenderView: UIView? {
        willSet {
            customRenderView?.removeFromSuperview()
        }
        didSet {
            customRenderView.map {
                addSubview($0)
                // attach render view to current session
                if let renderView = $0 as? CameraPreviewRenderView,
                    let captureSession = videoPreviewLayer?.session {
                    renderView.attachTo(captureSession)
                }
            }
        }
    }
    
    // TODO: need to implement
    @IBOutlet public var overlayView: UIView?
    
    public var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
        willSet {
            videoPreviewLayer?.removeFromSuperlayer()
        }
        didSet {
            guard let validLayer = videoPreviewLayer else {
                return
            }
            
            layer.addSublayer(validLayer)
        }
    }
    
    fileprivate var transitionAnimating: Bool = false
    fileprivate var cameraTransitionView: UIView?
    fileprivate var lastFocusRectangleLayer: CAShapeLayer?
    fileprivate var lastFocusPoint: CGPoint?
    fileprivate var exposureValue: Float = 0 // EV
    fileprivate var translationY: Float = 0
    fileprivate var startPanPointInPreviewLayer: CGPoint?
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }
    
    private func commonInit() {
        clipsToBounds = true
        
        self.zoomGesture.isEnabled = self.shouldEnablePinchToZoom
        self.zoomGesture.addTarget(self, action: #selector(_zoomGestureRecognizerHandler(_:)))
        self.zoomGesture.delegate = self
        addGestureRecognizer(self.zoomGesture)
        
        self.focusGesture.isEnabled = self.shouldEnableTapToFocus
        self.focusGesture.addTarget(self, action: #selector(_focusGestureRecognizerHandler(_:)))
        self.focusGesture.delegate = self
        addGestureRecognizer(self.focusGesture)
        
        self.exposureGesture.isEnabled = self.shouldEnableExposure
        self.exposureGesture.addTarget(self, action: #selector(_exposureGestureRecognizerHandler(_:)))
        self.exposureGesture.delegate = self
        addGestureRecognizer(self.exposureGesture)
        
        cameraGridView.isOpaque = false
        cameraGridView.layer.zPosition = 20
        addSubview(cameraGridView)
    }
    
    override open func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer?.frame = bounds
        videoPreviewLayer?.isHidden = customRenderView != nil
        
        cameraGridView.frame = bounds
        cameraGridView.isHidden = !showGrid
        
        customRenderView.map {
            $0.frame = bounds
        }

    }
    
    // MARK: - Gesture Handlers
    
    @objc fileprivate func _zoomGestureRecognizerHandler(_ recognizer: UIPinchGestureRecognizer) {
        guard let previewLayer = videoPreviewLayer else { return }
        
        if recognizer.state == .began {
            delegate?.cameraPreviewViewBeganZooming(self)
        }
        
        var allTouchesOnPreviewLayer = true
        let numTouch = recognizer.numberOfTouches
        
        for i in 0 ..< numTouch {
            let location = recognizer.location(ofTouch: i, in: self)
            let convertedTouch = previewLayer.convert(location, from: previewLayer.superlayer)
            if !previewLayer.contains(convertedTouch) {
                allTouchesOnPreviewLayer = false
                break
            }
        }
        
        if allTouchesOnPreviewLayer {
            delegate?.cameraPreviewView(self, applyZoom: recognizer.scale)
        }
    }
    
    @objc fileprivate func _focusGestureRecognizerHandler(_ recognizer: UITapGestureRecognizer) {
        guard let previewLayer = videoPreviewLayer else { return }

        let pointInPreviewLayer = layer.convert(recognizer.location(in: self), to: previewLayer)
        let pointOfInterest = previewLayer.captureDevicePointConverted(fromLayerPoint: pointInPreviewLayer)
        
        translationY = 0
        exposureValue = 0.5
        
        _showFocusRectangleAtPoint(pointInPreviewLayer, inLayer: layer)
        
        self.delegate?.cameraPreviewView(self, applyFocusAndExposure: pointOfInterest)
    }
    
    @objc fileprivate func _exposureGestureRecognizerHandler(_ gestureRecognizer: UIPanGestureRecognizer) {
        guard let previewLayer = videoPreviewLayer else { return }
        
        let translation = gestureRecognizer.translation(in: self)
        let currentTranslation = translationY + Float(translation.y)
        if gestureRecognizer.state == .ended {
            translationY = currentTranslation
        }
        if (currentTranslation < 0) {
            // up - brighter
            exposureValue = 0.5 + min(abs(currentTranslation) / 400, 1) / 2
        } else if (currentTranslation >= 0) {
            // down - lower
            exposureValue = 0.5 - min(abs(currentTranslation) / 400, 1) / 2
        }
        
        self.delegate?.cameraPreviewView(self, applyExposureDuration: exposureValue)
        
        // UI Visualization
        if gestureRecognizer.state == .began {
            startPanPointInPreviewLayer = layer.convert(gestureRecognizer.location(in: self), to: previewLayer)
        }
        
        if let lastFocusPoint = self.lastFocusPoint {
            _showFocusRectangleAtPoint(lastFocusPoint, inLayer: layer, withBrightness: exposureValue)
        }
    }
    
    // MARK: - Animations
    
    /**
     Switches between the current and specified camera using a flip animation similar to the one used in the iOS stock camera app.
     */
    public func performFlipTransitionAnimation(direction: FlipTransition = .fromLeft, removeBlurOnComlpetion: Bool = true, completion: (() -> Void)?) {
        guard !transitionAnimating else {
            completion?()
            return
        }
        
        transitionAnimating = true
        _makeTransitionView()
        _flipTransitionView(direction) { finished in
            if finished {
                if removeBlurOnComlpetion {
                    self._removeTransistionView(completion: {
                        self.transitionAnimating = false
                        completion?()
                    })
                } else {
                    completion?()
                }
            }
        }
    }
    
    public func performBlurAnimation(completion: (() -> Void)?) {
        guard !transitionAnimating else {
            completion?()
            return
        }

        transitionAnimating = true
        _makeTransitionView()
    }
    
    public func removeTransitionView() {
        _removeTransistionView {
            self.transitionAnimating = false
        }
    }
    
    public func performShutterAnimation(_ completion: (() -> Void)?) {
        DispatchQueue.main.async {
            
            let duration = 0.1
            
            CATransaction.begin()
            
            if let completion = completion {
                CATransaction.setCompletionBlock(completion)
            }
            
            let fadeOutAnimation = CABasicAnimation(keyPath: "opacity")
            fadeOutAnimation.fromValue = 1.0
            fadeOutAnimation.toValue = 0.0
            self.layer.add(fadeOutAnimation, forKey: "opacity")
            
            let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
            fadeInAnimation.fromValue = 0.0
            fadeInAnimation.toValue = 1.0
            fadeInAnimation.beginTime = CACurrentMediaTime() + duration * 2.0
            self.layer.add(fadeInAnimation, forKey: "opacity")
            
            CATransaction.commit()
        }
    }
    
    private func _makeTransitionView() {
        let blurEffect = UIBlurEffect(style: .regular)
        let tempBlurView = UIVisualEffectView(effect: blurEffect)
        tempBlurView.frame = bounds
        
        addSubview(tempBlurView)
        bringSubviewToFront(tempBlurView)
        
        cameraGridView.alpha = 0
        
        let transitionView = snapshotView(afterScreenUpdates: true)
        
        tempBlurView.removeFromSuperview()
        
        if let validTransitonView = transitionView {
            addSubview(validTransitonView)
            
            customRenderView?.alpha = 0
            videoPreviewLayer?.opacity = 0
        }
        
        cameraTransitionView = transitionView
    }
    
    private func _flipTransitionView(_ direction: FlipTransition, completion: @escaping (Bool) -> Void) {
        UIView.transition(with: self,
                          duration: 0.5,
                          options: direction.transionOptions,
                          animations: nil,
                          completion: completion)
    }
    
    private func _removeTransistionView(completion: @escaping () -> Void) {
        guard let cameraTransitionView = cameraTransitionView else { return }
        
        customRenderView?.alpha = 1.0
        videoPreviewLayer?.opacity = 1.0
        cameraGridView.alpha = 1
        
        UIView.animate(withDuration: 0.25,
                       animations: {
                        cameraTransitionView.alpha = 0.0
        }, completion: { _ in
            cameraTransitionView.removeFromSuperview()
            self.cameraTransitionView = nil
            completion()
        })
    }
    
    // MARK: -
    
    private func _showFocusRectangleAtPoint(_ focusPoint: CGPoint, inLayer layer: CALayer, withBrightness brightness: Float? = nil) {
        
        if let lastFocusRectangle = lastFocusRectangleLayer {
            
            lastFocusRectangle.removeFromSuperlayer()
            self.lastFocusRectangleLayer = nil
        }
        
        let size = CGSize(width: 75, height: 75)
        let rect = CGRect(origin: CGPoint(x: focusPoint.x - size.width / 2.0, y: focusPoint.y - size.height / 2.0), size: size)
        
        let endPath = UIBezierPath(rect: rect)
        endPath.move(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.minY))
        endPath.addLine(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.minY + 5.0))
        endPath.move(to: CGPoint(x: rect.maxX, y: rect.minY + size.height / 2.0))
        endPath.addLine(to: CGPoint(x: rect.maxX - 5.0, y: rect.minY + size.height / 2.0))
        endPath.move(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.maxY))
        endPath.addLine(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.maxY - 5.0))
        endPath.move(to: CGPoint(x: rect.minX, y: rect.minY + size.height / 2.0))
        endPath.addLine(to: CGPoint(x: rect.minX + 5.0, y: rect.minY + size.height / 2.0))
        if (brightness != nil) {
            endPath.move(to: CGPoint(x: rect.minX + size.width + size.width / 4, y: rect.minY))
            endPath.addLine(to: CGPoint(x: rect.minX + size.width + size.width / 4, y: rect.minY + size.height))
            
            endPath.move(to: CGPoint(x: rect.minX + size.width + size.width / 4 - size.width / 16, y: rect.minY + size.height - CGFloat(brightness!) * size.height))
            endPath.addLine(to: CGPoint(x: rect.minX + size.width + size.width / 4 + size.width / 16, y: rect.minY + size.height - CGFloat(brightness!) * size.height))
        }
        
        let startPath = UIBezierPath(cgPath: endPath.cgPath)
        let scaleAroundCenterTransform = CGAffineTransform(translationX: -focusPoint.x, y: -focusPoint.y).concatenating(CGAffineTransform(scaleX: 2.0, y: 2.0).concatenating(CGAffineTransform(translationX: focusPoint.x, y: focusPoint.y)))
        startPath.apply(scaleAroundCenterTransform)
        
        let shapeLayer = CAShapeLayer()
        shapeLayer.path = endPath.cgPath
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor(red:1, green:0.83, blue:0, alpha:0.95).cgColor
        shapeLayer.lineWidth = 1.0
        shapeLayer.zPosition = 100
        
        layer.addSublayer(shapeLayer)
        lastFocusRectangleLayer = shapeLayer
        lastFocusPoint = focusPoint
        
        CATransaction.begin()
        
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut))
        
        CATransaction.setCompletionBlock {
            if shapeLayer.superlayer != nil {
                shapeLayer.removeFromSuperlayer()
                self.lastFocusRectangleLayer = nil
            }
        }
        
        if (brightness == nil) {
            let appearPathAnimation = CABasicAnimation(keyPath: "path")
            appearPathAnimation.fromValue = startPath.cgPath
            appearPathAnimation.toValue = endPath.cgPath
            shapeLayer.add(appearPathAnimation, forKey: "path")
            
            let appearOpacityAnimation = CABasicAnimation(keyPath: "opacity")
            appearOpacityAnimation.fromValue = 0.0
            appearOpacityAnimation.toValue = 1.0
            shapeLayer.add(appearOpacityAnimation, forKey: "opacity")
        }
        
        let disappearOpacityAnimation = CABasicAnimation(keyPath: "opacity")
        disappearOpacityAnimation.fromValue = 1.0
        disappearOpacityAnimation.toValue = 0.0
        disappearOpacityAnimation.beginTime = CACurrentMediaTime() + 0.8
        disappearOpacityAnimation.fillMode = CAMediaTimingFillMode.forwards
        disappearOpacityAnimation.isRemovedOnCompletion = false
        shapeLayer.add(disappearOpacityAnimation, forKey: "opacity")
        
        CATransaction.commit()
    }
    
    
}

@available(iOS 4.0, macCatalyst 14.0, *)
public extension CameraPreviewView {
    
    enum FlipTransition {
        case fromLeft
        case fromRight
        
        fileprivate var transionOptions: UIView.AnimationOptions {
            if self == .fromLeft {
                return .transitionFlipFromLeft
            } else {
                return .transitionFlipFromRight
            }
        }
    }
    
}
