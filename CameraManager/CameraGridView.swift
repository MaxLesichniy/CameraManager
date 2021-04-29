//
//  CameraGridView.swift
//  Nymf
//
//  Created by Max Lesichniy on 29.12.2020.
//  Copyright © 2020 OnCreate. All rights reserved.
//

import UIKit

public class CameraGridView: UIView {
    
    public var showCorners: Bool = true
    public var corners: UIRectCorner = .allCorners
    
    public var horizontalLinesCount: UInt = 2 {
        didSet {
            setNeedsDisplay()
        }
    }

    public var verticalLinesCount: UInt = 2 {
        didSet {
            setNeedsDisplay()
        }
    }

    public var cornersColor: UIColor = .white {
        didSet {
            setNeedsLayout()
        }
    }
    
    public var cornersLineWidth: CGFloat = 2.0 {
        didSet {
            setNeedsLayout()
        }
    }
    
    public var lineColor: UIColor = UIColor(white: 1, alpha: 0.5) {
        didSet {
            setNeedsDisplay()
        }
    }

    public var lineWidth: CGFloat = 1.0 / UIScreen.main.scale {
        didSet {
            setNeedsDisplay()
        }
    }
    
    private var cornerLayers: [UInt: CornerLayer] = [:]
    
    func setupCorners() {
        for corner: UIRectCorner in [.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let cornerLayer = CornerLayer()
            layer.addSublayer(cornerLayer)
            cornerLayers[corner.rawValue] = cornerLayer
        }
    }
    
    public override func draw(_ rect: CGRect) {
        super.draw(rect)

        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }

        context.setLineWidth(lineWidth)
        context.setStrokeColor(lineColor.cgColor)

        let horizontalLineSpacing = frame.size.width / CGFloat(horizontalLinesCount + 1)
        let verticalLineSpacing = frame.size.height / CGFloat(verticalLinesCount + 1)

        for i in 1 ..< horizontalLinesCount + 1 {
            context.move(to: CGPoint(x: CGFloat(i) * horizontalLineSpacing, y: 0))
            context.addLine(to: CGPoint(x: CGFloat(i) * horizontalLineSpacing, y: frame.size.height))
        }

        for i in 1 ..< verticalLinesCount + 1 {
            context.move(to: CGPoint(x: 0, y: CGFloat(i) * verticalLineSpacing))
            context.addLine(to: CGPoint(x: frame.size.width, y: CGFloat(i) * verticalLineSpacing))
        }

        context.strokePath()
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        if cornerLayers.isEmpty {
            setupCorners()
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        cornerLayers.forEach { (cornerRaw, layer) in
            layer.isHidden = !showCorners
            
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = cornersColor.cgColor
            layer.lineWidth = cornersLineWidth
            layer.bounds.size = CGSize(width: 30, height: 30)

            let layerHalfHeight = layer.bounds.size.height / 2
            let layerHalfWidth = layer.bounds.size.width / 2
            
            let corner = UIRectCorner(rawValue: cornerRaw)
            switch corner {
            case .topLeft:
                layer.position = CGPoint(x: bounds.minX + layerHalfWidth, y: bounds.minY + layerHalfHeight)
            case .topRight:
                layer.transform = CATransform3DMakeScale(-1, 1, 1)
                layer.position = CGPoint(x: bounds.maxX - layerHalfWidth, y: bounds.minY + layerHalfHeight)
            case .bottomLeft:
                layer.transform = CATransform3DMakeScale(1, -1, 1)
                layer.position = CGPoint(x: bounds.minX + layerHalfWidth, y: bounds.maxY - layerHalfHeight)
            case .bottomRight:
                layer.transform = CATransform3DMakeScale(-1, -1, 1)
                layer.position = CGPoint(x: bounds.maxX - layerHalfWidth, y: bounds.maxY - layerHalfHeight)
            default:
                break
            }
            
        }
        
        CATransaction.commit()
    }
}

public extension CameraGridView {
    
    class CornerLayer: CAShapeLayer {
        
        public override func layoutSublayers() {
            super.layoutSublayers()
            
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: bounds.height))
            path.addLine(to: .zero)
            path.addLine(to: CGPoint(x: bounds.width, y: 0))
            self.path = path.cgPath
        }
        
    }
    
}
