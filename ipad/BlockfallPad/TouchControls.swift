import UIKit

enum TouchControlSize: Int, CaseIterable {
    case compact
    case large
    case extraLarge

    private static let defaultsKey = "ipadTouchControlSize"

    static var saved: TouchControlSize {
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return .large }
        return TouchControlSize(rawValue: UserDefaults.standard.integer(forKey: defaultsKey))
            ?? .large
    }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .large: "Large"
        case .extraLarge: "XL"
        }
    }

    var scale: CGFloat {
        switch self {
        case .compact: 0.82
        case .large: 1
        case .extraLarge: 1.18
        }
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

final class VirtualJoystick: UIView {
    var onChange: ((Float, Float) -> Void)?

    private let ring = UIView()
    private let knob = UIView()
    private weak var trackedTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = .clear

        ring.isUserInteractionEnabled = false
        ring.backgroundColor = UIColor(white: 0.05, alpha: 0.42)
        ring.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ring.layer.borderWidth = 3
        addSubview(ring)

        knob.isUserInteractionEnabled = false
        knob.backgroundColor = UIColor(red: 0.98, green: 0.72, blue: 0.24, alpha: 0.85)
        knob.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        knob.layer.borderWidth = 2
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        ring.frame = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        ring.layer.cornerRadius = side / 2
        if trackedTouch == nil { centerKnob() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        update(touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === trackedTouch }) else { return }
        update(touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0 === trackedTouch }) { reset() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        reset()
    }

    func reset() {
        trackedTouch = nil
        centerKnob()
        onChange?(0, 0)
    }

    private func update(_ point: CGPoint) {
        let radius = max(1, min(bounds.width, bounds.height) * 0.34)
        var vector = CGVector(dx: point.x - bounds.midX, dy: point.y - bounds.midY)
        let length = hypot(vector.dx, vector.dy)
        if length > radius {
            vector.dx = vector.dx / length * radius
            vector.dy = vector.dy / length * radius
        }
        let knobSide = min(bounds.width, bounds.height) * 0.42
        knob.frame = CGRect(
            x: bounds.midX + vector.dx - knobSide / 2,
            y: bounds.midY + vector.dy - knobSide / 2,
            width: knobSide,
            height: knobSide
        )
        knob.layer.cornerRadius = knobSide / 2
        onChange?(Float(vector.dx / radius), Float(-vector.dy / radius))
    }

    private func centerKnob() {
        let knobSide = min(bounds.width, bounds.height) * 0.42
        knob.frame = CGRect(
            x: bounds.midX - knobSide / 2,
            y: bounds.midY - knobSide / 2,
            width: knobSide,
            height: knobSide
        )
        knob.layer.cornerRadius = knobSide / 2
    }
}

final class LookPad: UIView {
    var onLook: ((Float, Float) -> Void)?
    var onTap: (() -> Void)?
    var onHoldChanged: ((Bool) -> Void)?

    private weak var trackedTouch: UITouch?
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var movedToLook = false
    private var mining = false
    private var holdWorkItem: DispatchWorkItem?
    private let holdDelay: TimeInterval = 0.30
    private let lookThreshold: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        accessibilityLabel = "World controls"
        accessibilityHint = "Drag to look, tap to use, or hold to mine"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        startPoint = touch.location(in: self)
        lastPoint = startPoint
        movedToLook = false
        mining = false

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.trackedTouch != nil, !self.movedToLook else { return }
            self.mining = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.onHoldChanged?(true)
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === trackedTouch }) else { return }
        let point = touch.location(in: self)
        if hypot(point.x - startPoint.x, point.y - startPoint.y) >= lookThreshold {
            movedToLook = true
            holdWorkItem?.cancel()
            holdWorkItem = nil
            stopMining()
        }
        let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        lastPoint = point
        if abs(delta.x) > 0.1 || abs(delta.y) > 0.1 {
            onLook?(Float(delta.x), Float(delta.y))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.contains(where: { $0 === trackedTouch }) else { return }
        holdWorkItem?.cancel()
        holdWorkItem = nil
        let wasMining = mining
        stopMining()
        if !wasMining && !movedToLook { onTap?() }
        clearTracking()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch != nil else { return }
        reset()
    }

    func reset() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        stopMining()
        clearTracking()
    }

    private func stopMining() {
        guard mining else { return }
        mining = false
        onHoldChanged?(false)
    }

    private func clearTracking() {
        trackedTouch = nil
        movedToLook = false
    }
}

final class TouchActionButton: UIButton {
    var onHoldChanged: ((Bool) -> Void)?

    init(title: String, tint: UIColor) {
        super.init(frame: .zero)
        configuration = .filled()
        configuration?.title = title
        configuration?.baseBackgroundColor = tint.withAlphaComponent(0.82)
        configuration?.baseForegroundColor = .white
        configuration?.cornerStyle = .capsule
        configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .boldSystemFont(ofSize: 17)
            return outgoing
        }
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.72).cgColor
        addTarget(self, action: #selector(pressed), for: .touchDown)
        addTarget(self, action: #selector(released), for: [
            .touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func pressed() {
        transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        onHoldChanged?(true)
    }

    @objc private func released() {
        transform = .identity
        onHoldChanged?(false)
    }
}
