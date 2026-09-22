import UIKit

enum InputMode: Int {
    case touch = 0
    case trackpad = 1
}

protocol TouchInputDelegate: AnyObject {
    func touchMoveAbs(_ p: CGPoint)
    func touchMoveRel(dx: CGFloat, dy: CGFloat)
    func touchButton(_ button: Int, down: Bool)
    func touchWheel(dy: Int, dx: Int)
    func touchZoom(scale: CGFloat, anchor: CGPoint)
    func touchPan(dx: CGFloat, dy: CGFloat)
    func touchResetZoom()
    func touchToggleToolbar()
}

/// Full-screen overlay that turns raw touches into remote mouse events.
///
/// Touch mode (absolute):
///   tap = left click, drag = left drag, long press = right click,
///   two-finger tap = right click, two-finger drag = scroll, pinch = local zoom,
///   three-finger drag = pan zoomed view, three-finger tap = toggle toolbar,
///   two-finger double tap = reset zoom.
/// Trackpad mode (relative):
///   one finger = move cursor, tap = click, tap then drag = left drag,
///   everything else as touch mode.
final class TouchInputView: UIView {
    weak var delegate: TouchInputDelegate?
    var mode: InputMode = .touch
    var trackpadSensitivity: CGFloat = 1.5
    var scrollPointsPerNotch: CGFloat = 22
    var longPressInterval: TimeInterval = 0.5

    private enum State { case idle, single, drag, longPressed, two, three, waitAllUp }
    private enum TwoMode { case undecided, scroll, pinch }

    private var state: State = .idle
    private var active: [UITouch] = []
    private var dragTouch: UITouch?
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var startTime: TimeInterval = 0
    private var longPressTimer: Timer?

    private var twoMode: TwoMode = .undecided
    private var twoStartCentroid = CGPoint.zero
    private var twoStartDist: CGFloat = 0
    private var lastCentroid = CGPoint.zero
    private var lastDist: CGFloat = 0
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0

    private var lastTapTime: TimeInterval = 0
    private var lastTapPoint = CGPoint.zero
    private var lastTwoTapTime: TimeInterval = 0

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        lightHaptic.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var moveThreshold: CGFloat { mode == .touch ? 10 : 3 }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where !active.contains(t) { active.append(t) }
        let now = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime

        switch active.count {
        case 1:
            let t = active[0]
            let p = t.location(in: self)
            startPoint = p
            lastPoint = p
            startTime = now
            if mode == .trackpad, now - lastTapTime < 0.3, distance(p, lastTapPoint) < 60 {
                state = .drag
                dragTouch = t
                delegate?.touchButton(0, down: true)
                lastTapTime = 0
                return
            }
            state = .single
            if mode == .touch { delegate?.touchMoveAbs(p) }
            startLongPress()
        case 2:
            cancelLongPress()
            if state == .drag { return }
            state = .two
            twoMode = .undecided
            twoStartCentroid = centroid()
            twoStartDist = fingerDistance()
            lastCentroid = twoStartCentroid
            lastDist = twoStartDist
            scrollAccumX = 0
            scrollAccumY = 0
            startTime = now
        case 3:
            cancelLongPress()
            if state == .drag { return }
            state = .three
            lastCentroid = centroid()
            startTime = now
        default:
            cancelLongPress()
            if state != .drag { state = .waitAllUp }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let first = active.first else { return }
        let p = (dragTouch ?? first).location(in: self)

        switch state {
        case .single:
            if distance(p, startPoint) > moveThreshold {
                cancelLongPress()
                state = .drag
                dragTouch = first
                if mode == .touch {
                    delegate?.touchMoveAbs(startPoint)
                    delegate?.touchButton(0, down: true)
                    delegate?.touchMoveAbs(p)
                } else {
                    sendRel(from: lastPoint, to: p)
                }
            }
        case .drag:
            if mode == .touch {
                delegate?.touchMoveAbs(p)
            } else {
                sendRel(from: lastPoint, to: p)
            }
        case .two:
            guard active.count >= 2 else { break }
            let c = centroid()
            let d = fingerDistance()
            if twoMode == .undecided {
                if abs(d - twoStartDist) > 30 {
                    twoMode = .pinch
                    lastDist = d
                    lastCentroid = c
                } else if distance(c, twoStartCentroid) > 12 {
                    twoMode = .scroll
                    lastCentroid = c
                }
            }
            switch twoMode {
            case .pinch:
                if lastDist > 0 { delegate?.touchZoom(scale: d / lastDist, anchor: c) }
                delegate?.touchPan(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y)
                lastDist = d
                lastCentroid = c
            case .scroll:
                scrollAccumY += c.y - lastCentroid.y
                scrollAccumX += c.x - lastCentroid.x
                lastCentroid = c
                let ny = Int(scrollAccumY / scrollPointsPerNotch)
                let nx = Int(scrollAccumX / scrollPointsPerNotch)
                if ny != 0 || nx != 0 {
                    scrollAccumY -= CGFloat(ny) * scrollPointsPerNotch
                    scrollAccumX -= CGFloat(nx) * scrollPointsPerNotch
                    delegate?.touchWheel(dy: ny * 120, dx: -nx * 120)
                }
            case .undecided:
                break
            }
        case .three:
            let c = centroid()
            delegate?.touchPan(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y)
            lastCentroid = c
        default:
            break
        }
        lastPoint = p
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ ended: Set<UITouch>, cancelled: Bool) {
        let now = ended.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let before = active.count
        active.removeAll { ended.contains($0) }
        let remaining = active.count
        cancelLongPress()

        switch state {
        case .single:
            if !cancelled {
                if mode == .touch { delegate?.touchMoveAbs(startPoint) }
                delegate?.touchButton(0, down: true)
                delegate?.touchButton(0, down: false)
                lightHaptic.impactOccurred()
                lastTapTime = now
                lastTapPoint = startPoint
            }
            state = remaining == 0 ? .idle : .waitAllUp
        case .drag:
            if let d = dragTouch, ended.contains(d) {
                delegate?.touchButton(0, down: false)
                dragTouch = nil
                state = remaining == 0 ? .idle : .waitAllUp
            } else if remaining == 0 {
                delegate?.touchButton(0, down: false)
                dragTouch = nil
                state = .idle
            }
        case .longPressed:
            state = remaining == 0 ? .idle : .waitAllUp
        case .two:
            if twoMode == .undecided && before == 2 && !cancelled && now - startTime < 0.35 {
                if now - lastTwoTapTime < 0.4 {
                    delegate?.touchResetZoom()
                    lastTwoTapTime = 0
                } else {
                    if mode == .touch { delegate?.touchMoveAbs(startPoint) }
                    delegate?.touchButton(1, down: true)
                    delegate?.touchButton(1, down: false)
                    mediumHaptic.impactOccurred()
                    lastTwoTapTime = now
                }
            }
            state = remaining == 0 ? .idle : .waitAllUp
        case .three:
            if before == 3 && !cancelled && now - startTime < 0.3 {
                delegate?.touchToggleToolbar()
            }
            state = remaining == 0 ? .idle : .waitAllUp
        case .waitAllUp, .idle:
            if remaining == 0 { state = .idle }
        }
    }

    // MARK: helpers

    private func startLongPress() {
        cancelLongPress()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressInterval, repeats: false) { [weak self] _ in
            self?.longPressFired()
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func longPressFired() {
        guard state == .single else { return }
        if mode == .touch { delegate?.touchMoveAbs(startPoint) }
        delegate?.touchButton(1, down: true)
        delegate?.touchButton(1, down: false)
        mediumHaptic.impactOccurred()
        state = .longPressed
    }

    private func sendRel(from a: CGPoint, to b: CGPoint) {
        delegate?.touchMoveRel(dx: (b.x - a.x) * trackpadSensitivity, dy: (b.y - a.y) * trackpadSensitivity)
    }

    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return .zero }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for t in active {
            let p = t.location(in: self)
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / CGFloat(active.count), y: y / CGFloat(active.count))
    }

    private func fingerDistance() -> CGFloat {
        guard active.count >= 2 else { return 0 }
        return distance(active[0].location(in: self), active[1].location(in: self))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        return hypot(a.x - b.x, a.y - b.y)
    }
}
