import UIKit

protocol KeyboardInputDelegate: AnyObject {
    func keyboardSendKey(vk: UInt16, down: Bool)
    func keyboardSendText(_ text: String)
}

/// Invisible first responder that receives soft-keyboard text and hardware key presses.
final class KeyboardInputView: UIView, UIKeyInput {
    weak var delegate: KeyboardInputDelegate?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false

    private lazy var keyBar: KeyBarView = {
        let bar = KeyBarView(frame: CGRect(x: 0, y: 0, width: 320, height: 46))
        bar.onKey = { [weak self] vk in self?.pressWithModifiers(vk) }
        bar.onHide = { [weak self] in self?.resignFirstResponder() }
        return bar
    }()

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keyBar }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            pressWithModifiers(VK.enter)
            return
        }
        if text == "\t" {
            pressWithModifiers(VK.tab)
            return
        }
        let mods = keyBar.takeLatchedModifiers()
        if !mods.isEmpty, text.count == 1, let c = text.first, let vk = KeyMap.vk(forShortcutCharacter: c) {
            for m in mods { delegate?.keyboardSendKey(vk: m, down: true) }
            delegate?.keyboardSendKey(vk: vk, down: true)
            delegate?.keyboardSendKey(vk: vk, down: false)
            for m in mods.reversed() { delegate?.keyboardSendKey(vk: m, down: false) }
            return
        }
        delegate?.keyboardSendText(text)
    }

    func deleteBackward() {
        pressWithModifiers(VK.back)
    }

    private func pressWithModifiers(_ vk: UInt16) {
        let mods = keyBar.takeLatchedModifiers()
        for m in mods { delegate?.keyboardSendKey(vk: m, down: true) }
        delegate?.keyboardSendKey(vk: vk, down: true)
        delegate?.keyboardSendKey(vk: vk, down: false)
        for m in mods.reversed() { delegate?.keyboardSendKey(vk: m, down: false) }
    }

    // MARK: hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let vk = KeyMap.vk(for: key.keyCode) {
                delegate?.keyboardSendKey(vk: vk, down: true)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let vk = KeyMap.vk(for: key.keyCode) {
                delegate?.keyboardSendKey(vk: vk, down: false)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

/// Accessory bar above the soft keyboard: modifiers (latching) and special keys.
final class KeyBarView: UIView {
    var onKey: ((UInt16) -> Void)?
    var onHide: (() -> Void)?

    private struct Item {
        let title: String
        let vk: UInt16
        let modifier: Bool
    }

    private let items: [Item] = [
        Item(title: "Esc", vk: VK.escape, modifier: false),
        Item(title: "Tab", vk: VK.tab, modifier: false),
        Item(title: "Ctrl", vk: VK.control, modifier: true),
        Item(title: "Alt", vk: VK.menu, modifier: true),
        Item(title: "Shift", vk: VK.shift, modifier: true),
        Item(title: "Win", vk: VK.lwin, modifier: true),
        Item(title: "←", vk: VK.left, modifier: false),
        Item(title: "↑", vk: VK.up, modifier: false),
        Item(title: "↓", vk: VK.down, modifier: false),
        Item(title: "→", vk: VK.right, modifier: false),
        Item(title: "Del", vk: VK.delete, modifier: false),
        Item(title: "Home", vk: VK.home, modifier: false),
        Item(title: "End", vk: VK.end, modifier: false),
        Item(title: "PgUp", vk: VK.pageUp, modifier: false),
        Item(title: "PgDn", vk: VK.pageDown, modifier: false),
        Item(title: "Ins", vk: VK.insert, modifier: false),
        Item(title: "F1", vk: VK.f1, modifier: false),
        Item(title: "F2", vk: VK.f1 + 1, modifier: false),
        Item(title: "F3", vk: VK.f1 + 2, modifier: false),
        Item(title: "F4", vk: VK.f1 + 3, modifier: false),
        Item(title: "F5", vk: VK.f1 + 4, modifier: false),
        Item(title: "F6", vk: VK.f1 + 5, modifier: false),
        Item(title: "F7", vk: VK.f1 + 6, modifier: false),
        Item(title: "F8", vk: VK.f1 + 7, modifier: false),
        Item(title: "F9", vk: VK.f1 + 8, modifier: false),
        Item(title: "F10", vk: VK.f1 + 9, modifier: false),
        Item(title: "F11", vk: VK.f1 + 10, modifier: false),
        Item(title: "F12", vk: VK.f1 + 11, modifier: false),
    ]

    /// 0 = off, 1 = one-shot, 2 = locked
    private var modifierState: [UInt16: Int] = [:]
    private var modifierButtons: [UInt16: UIButton] = [:]
    private var repeatTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth]
        backgroundColor = UIColor(white: 0.12, alpha: 1)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let hide = makeButton(title: "▽")
        hide.translatesAutoresizingMaskIntoConstraints = false
        hide.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        addSubview(hide)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        for (i, item) in items.enumerated() {
            let b = makeButton(title: item.title)
            b.tag = i
            if item.modifier {
                b.addTarget(self, action: #selector(modifierTapped(_:)), for: .touchUpInside)
                modifierButtons[item.vk] = b
            } else {
                b.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
                b.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            }
            stack.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            hide.widthAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    /// Returns latched modifiers (in press order) and clears one-shot ones.
    func takeLatchedModifiers() -> [UInt16] {
        var result: [UInt16] = []
        for item in items where item.modifier {
            let s = modifierState[item.vk] ?? 0
            if s > 0 { result.append(item.vk) }
            if s == 1 {
                modifierState[item.vk] = 0
                updateModifierButton(item.vk)
            }
        }
        return result
    }

    private func makeButton(title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(white: 0.28, alpha: 1)
        b.layer.cornerRadius = 6
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }

    private func updateModifierButton(_ vk: UInt16) {
        guard let b = modifierButtons[vk] else { return }
        switch modifierState[vk] ?? 0 {
        case 1: b.backgroundColor = UIColor.systemBlue
        case 2: b.backgroundColor = UIColor.systemOrange
        default: b.backgroundColor = UIColor(white: 0.28, alpha: 1)
        }
    }

    @objc private func modifierTapped(_ sender: UIButton) {
        let item = items[sender.tag]
        let s = modifierState[item.vk] ?? 0
        modifierState[item.vk] = (s + 1) % 3
        updateModifierButton(item.vk)
    }

    @objc private func keyDown(_ sender: UIButton) {
        let vk = items[sender.tag].vk
        onKey?(vk)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                self?.onKey?(vk)
            }
        }
    }

    @objc private func keyUp(_ sender: UIButton) {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    @objc private func hideTapped() {
        onHide?()
    }
}
