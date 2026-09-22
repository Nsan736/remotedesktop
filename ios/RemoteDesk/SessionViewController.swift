import AVFoundation
import UIKit

final class SessionViewController: UIViewController, TouchInputDelegate, KeyboardInputDelegate {
    let host: String
    let port: UInt16
    let pin: String
    var onClose: (() -> Void)?

    private var connection: Connection?
    private let renderer = H264Renderer()
    private let videoView = UIView()
    private let touchView = TouchInputView()
    private let keyboardView = KeyboardInputView()
    private let toolbar = UIView()
    private let statsLabel = UILabel()
    private let statusLabel = UILabel()
    private var modeButton: UIButton!

    private var remoteSize = CGSize(width: 1920, height: 1080)
    private var keyboardInset: CGFloat = 0
    private var lastLayoutSize = CGSize.zero
    private var relAccum = CGPoint.zero
    private var frameCounter = 0
    private var lastStatsBytes = 0
    private var rttMs: Double = 0
    private var statsTimer: Timer?
    private var toolbarOffset = CGPoint.zero

    init(host: String, port: UInt16, pin: String) {
        self.host = host
        self.port = port
        self.pin = pin
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.backgroundColor = .black
        videoView.layer.addSublayer(renderer.layer)
        view.addSubview(videoView)

        touchView.frame = view.bounds
        touchView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        touchView.delegate = self
        touchView.mode = InputMode(rawValue: UserDefaults.standard.integer(forKey: "inputMode")) ?? .touch
        view.addSubview(touchView)

        keyboardView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyboardView.isHidden = false
        keyboardView.alpha = 0.01
        keyboardView.delegate = self
        view.addSubview(keyboardView)

        statusLabel.text = "接続中…  \(host):\(port)"
        statusLabel.textColor = .white
        statusLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        buildToolbar()

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        if connection == nil { connect() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        statsTimer?.invalidate()
        connection?.close()
        connection = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != lastLayoutSize {
            lastLayoutSize = view.bounds.size
            layoutVideo()
        }
    }

    // MARK: connection

    private func connect() {
        let c = Connection(host: host, port: port, pin: pin)
        c.onInfo = { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                if let w = info["width"] as? Double, let h = info["height"] as? Double, w > 0, h > 0 {
                    self.remoteSize = CGSize(width: w, height: h)
                    self.layoutVideo()
                }
                self.statusLabel.text = "映像を待っています…"
            }
        }
        c.onVideo = { [weak self] au, key in
            guard let self else { return }
            self.renderer.feed(au, isKeyframe: key)
            self.frameCounter += 1
            if self.frameCounter == 1 {
                DispatchQueue.main.async { self.statusLabel.isHidden = true }
            }
        }
        c.onPong = { [weak self] t in
            let now = DispatchTime.now().uptimeNanoseconds
            let rtt = Double(now &- t) / 1_000_000
            DispatchQueue.main.async { self?.rttMs = rtt }
        }
        c.onFailed = { [weak self] msg in
            DispatchQueue.main.async { self?.showError(msg) }
        }
        connection = c
        c.start()

        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickStats()
        }
    }

    private func tickStats() {
        guard let c = connection else { return }
        c.send(.ping, Proto.ping(DispatchTime.now().uptimeNanoseconds))
        let bytes = c.bytesReceived
        let mbps = Double(bytes - lastStatsBytes) * 8 / 1_000_000
        lastStatsBytes = bytes
        statsLabel.text = String(format: "%d fps  %.0f ms  %.1f Mb/s", frameCounter, rttMs, mbps)
        frameCounter = 0
    }

    private func showError(_ msg: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "接続終了", message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default) { [weak self] _ in
            self?.onClose?()
        })
        present(alert, animated: true)
    }

    @objc private func appDidBecomeActive() {
        renderer.reset()
    }

    // MARK: layout / zoom

    private var contentArea: CGRect {
        CGRect(x: 0, y: 0, width: view.bounds.width, height: max(1, view.bounds.height - keyboardInset))
    }

    private func layoutVideo() {
        let area = contentArea
        let scale = min(area.width / remoteSize.width, area.height / remoteSize.height)
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        videoView.transform = .identity
        videoView.frame = CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2,
                                 width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = videoView.bounds
        CATransaction.commit()
    }

    private var currentScale: CGFloat {
        let t = videoView.transform
        return sqrt(t.a * t.a + t.c * t.c)
    }

    private func clampVideo() {
        let f = videoView.frame
        let b = contentArea
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if f.width <= b.width + 0.5 {
            dx = b.midX - f.midX
        } else {
            if f.minX > b.minX { dx = b.minX - f.minX }
            if f.maxX < b.maxX { dx = b.maxX - f.maxX }
        }
        if f.height <= b.height + 0.5 {
            dy = b.midY - f.midY
        } else {
            if f.minY > b.minY { dy = b.minY - f.minY }
            if f.maxY < b.maxY { dy = b.maxY - f.maxY }
        }
        if dx != 0 || dy != 0 {
            videoView.transform = videoView.transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
        }
    }

    // MARK: TouchInputDelegate

    func touchMoveAbs(_ p: CGPoint) {
        let q = videoView.convert(p, from: touchView)
        let w = videoView.bounds.width
        let h = videoView.bounds.height
        guard w > 0, h > 0 else { return }
        connection?.send(.mouseAbs, Proto.mouseAbs(Double(q.x / w), Double(q.y / h)))
    }

    func touchMoveRel(dx: CGFloat, dy: CGFloat) {
        let w = videoView.bounds.width
        guard w > 0 else { return }
        let pxPerPt = remoteSize.width / (w * currentScale)
        relAccum.x += dx * pxPerPt
        relAccum.y += dy * pxPerPt
        let ix = Int(relAccum.x)
        let iy = Int(relAccum.y)
        if ix != 0 || iy != 0 {
            relAccum.x -= CGFloat(ix)
            relAccum.y -= CGFloat(iy)
            connection?.send(.mouseRel, Proto.mouseRel(ix, iy))
        }
    }

    func touchButton(_ button: Int, down: Bool) {
        connection?.send(.button, Proto.button(button, down: down))
    }

    func touchWheel(dy: Int, dx: Int) {
        connection?.send(.wheel, Proto.wheel(dy: dy, dx: dx))
    }

    func touchZoom(scale: CGFloat, anchor: CGPoint) {
        let cur = currentScale
        var k = scale
        if cur * k < 1 { k = 1 / cur }
        if cur * k > 6 { k = 6 / cur }
        let c = videoView.center
        let ax = anchor.x - c.x
        let ay = anchor.y - c.y
        videoView.transform = videoView.transform
            .concatenating(CGAffineTransform(translationX: -ax, y: -ay))
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: ax, y: ay))
        clampVideo()
    }

    func touchPan(dx: CGFloat, dy: CGFloat) {
        guard currentScale > 1.001 else { return }
        videoView.transform = videoView.transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
        clampVideo()
    }

    func touchResetZoom() {
        UIView.animate(withDuration: 0.15) { self.layoutVideo() }
    }

    func touchToggleToolbar() {
        toolbar.isHidden.toggle()
    }

    // MARK: KeyboardInputDelegate

    func keyboardSendKey(vk: UInt16, down: Bool) {
        connection?.send(.key, Proto.key(vk, down: down))
    }

    func keyboardSendText(_ text: String) {
        connection?.send(.text, Proto.text(text))
    }

    // MARK: keyboard frame

    @objc private func keyboardWillChange(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frameInView = view.convert(end, from: nil)
        let inset = max(0, view.bounds.maxY - frameInView.minY)
        applyKeyboardInset(inset, notification: n)
    }

    @objc private func keyboardWillHide(_ n: Notification) {
        applyKeyboardInset(0, notification: n)
    }

    private func applyKeyboardInset(_ inset: CGFloat, notification n: Notification) {
        guard abs(inset - keyboardInset) > 0.5 else { return }
        keyboardInset = inset
        let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration) { self.layoutVideo() }
    }

    // MARK: toolbar

    private func buildToolbar() {
        toolbar.backgroundColor = UIColor(white: 0, alpha: 0.6)
        toolbar.layer.cornerRadius = 18
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)

        let grip = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
        grip.tintColor = UIColor(white: 1, alpha: 0.6)
        grip.contentMode = .center
        grip.widthAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(grip)

        stack.addArrangedSubview(makeToolButton("keyboard", #selector(toggleKeyboard)))
        modeButton = makeToolButton(touchView.mode == .touch ? "hand.tap" : "cursorarrow", #selector(toggleMode))
        stack.addArrangedSubview(modeButton)
        stack.addArrangedSubview(makeToolButton("arrow.down.right.and.arrow.up.left", #selector(resetZoomTapped)))

        statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = UIColor(white: 1, alpha: 0.8)
        statsLabel.text = "-"
        stack.addArrangedSubview(statsLabel)

        stack.addArrangedSubview(makeToolButton("xmark", #selector(disconnectTapped)))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -2),
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 36),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(toolbarPanned(_:)))
        toolbar.addGestureRecognizer(pan)
    }

    private func makeToolButton(_ symbol: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.addTarget(self, action: action, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return b
    }

    @objc private func toolbarPanned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        toolbar.transform = toolbar.transform.translatedBy(x: t.x, y: t.y)
    }

    @objc private func toggleKeyboard() {
        if keyboardView.isFirstResponder {
            keyboardView.resignFirstResponder()
        } else {
            keyboardView.becomeFirstResponder()
        }
    }

    @objc private func toggleMode() {
        touchView.mode = touchView.mode == .touch ? .trackpad : .touch
        UserDefaults.standard.set(touchView.mode.rawValue, forKey: "inputMode")
        modeButton.setImage(UIImage(systemName: touchView.mode == .touch ? "hand.tap" : "cursorarrow"), for: .normal)
    }

    @objc private func resetZoomTapped() {
        touchResetZoom()
    }

    @objc private func disconnectTapped() {
        connection?.close()
        connection = nil
        onClose?()
    }
}
