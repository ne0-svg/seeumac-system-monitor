import AppKit

// MARK: - 颜色

enum Theme {
    static let accent   = NSColor.controlAccentColor
    static let warn     = NSColor.systemOrange
    static let danger   = NSColor.systemRed
    static let ok       = NSColor.systemGreen
    static let dim      = NSColor.secondaryLabelColor
    static let rowBG    = NSColor.labelColor.withAlphaComponent(0.045)
    static let rowHover = NSColor.labelColor.withAlphaComponent(0.085)

    static func level(_ v: Double) -> NSColor {
        if v < 60 { return accent }
        if v < 80 { return warn }
        return danger
    }
}

// MARK: - 迷你折线图

final class SparklineView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var color: NSColor = Theme.accent { didSet { needsDisplay = true } }
    var cap: Double = 100

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1 else { return }
        let maxV = max(20, values.max() ?? cap)
        let h = bounds.height - 2
        let w = bounds.width
        let step = w / CGFloat(values.count - 1)

        let area = NSBezierPath()
        area.move(to: NSPoint(x: 0, y: h + 1))
        var last = NSPoint.zero
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * step
            let norm = min(1, max(0, v / maxV))
            let y = h + 1 - CGFloat(norm) * h
            area.line(to: NSPoint(x: x, y: y))
            last = NSPoint(x: x, y: y)
        }
        area.line(to: NSPoint(x: w, y: h + 1))
        area.close()
        color.withAlphaComponent(0.13).setFill()
        area.fill()

        let line = NSBezierPath()
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * step
            let norm = min(1, max(0, v / maxV))
            let y = h + 1 - CGFloat(norm) * h
            if i == 0 { line.move(to: NSPoint(x: x, y: y)) } else { line.line(to: NSPoint(x: x, y: y)) }
        }
        line.lineWidth = 1.3
        color.withAlphaComponent(0.85).setStroke()
        line.stroke()
        _ = last
    }
}

// MARK: - 进度条

final class BarView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var maxValue: Double = 100
    var color: NSColor = Theme.accent { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: (bounds.height - 6) / 2)
        let track = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: 6),
                                 xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        track.fill()

        let frac = max(0, min(1, value / max(maxValue, 0.001)))
        let fw = max(3, r.width * CGFloat(frac))
        let fill = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: fw, height: 6),
                                xRadius: 3, yRadius: 3)
        color.setFill()
        fill.fill()
    }
}

// MARK: - 一行进程

final class ProcRowView: NSView {
    let entry: AggregatedEntry
    var onKill: ((AggregatedEntry) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var killBtn: NSButton!

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let cpuLabel = NSTextField(labelWithString: "")
    private let memLabel = NSTextField(labelWithString: "")

    init(entry: AggregatedEntry) {
        self.entry = entry
        super.init(frame: NSRect(x: 0, y: 0, width: 372, height: 38))
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let img = entry.icon {
            iconView.image = img
        } else {
            iconView.image = NSImage(systemSymbolName: "gearshape.2.fill", accessibilityDescription: nil)
            iconView.contentTintColor = Theme.dim
        }
        addSubview(iconView)

        titleLabel.stringValue = entry.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subLabel.stringValue = entry.subtitle
        subLabel.font = .systemFont(ofSize: 9.5)
        subLabel.textColor = Theme.dim
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subLabel)

        cpuLabel.stringValue = String(format: "%.1f%%", entry.cpu)
        cpuLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        cpuLabel.textColor = entry.cpu > 50 ? Theme.danger : (entry.cpu > 15 ? Theme.warn : .labelColor)
        cpuLabel.alignment = .right
        cpuLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cpuLabel)

        memLabel.stringValue = Fmt.bytes(entry.memBytes)
        memLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        memLabel.textColor = Theme.dim
        memLabel.alignment = .right
        memLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(memLabel)

        killBtn = NSButton()
        killBtn.bezelStyle = .inline
        killBtn.isBordered = false
        killBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "结束")
        killBtn.contentTintColor = entry.isProtected ? Theme.dim.withAlphaComponent(0.35) : Theme.danger
        killBtn.target = self
        killBtn.action = #selector(killTapped)
        killBtn.isEnabled = !entry.isProtected
        killBtn.toolTip = entry.isProtected ? "系统保护，不可结束" : "结束 \(entry.title)"
        killBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(killBtn)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cpuLabel.leadingAnchor, constant: -8),

            subLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 0),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: cpuLabel.leadingAnchor, constant: -8),

            cpuLabel.trailingAnchor.constraint(equalTo: memLabel.trailingAnchor),
            cpuLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            cpuLabel.widthAnchor.constraint(equalToConstant: 52),

            memLabel.trailingAnchor.constraint(equalTo: killBtn.leadingAnchor, constant: -8),
            memLabel.topAnchor.constraint(equalTo: cpuLabel.bottomAnchor, constant: 0),
            memLabel.widthAnchor.constraint(equalToConstant: 52),

            killBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            killBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            killBtn.widthAnchor.constraint(equalToConstant: 18),
            killBtn.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    /// 只更新数值，不重建视图
    func update(cpu: Double, mem: UInt64) {
        cpuLabel.stringValue = String(format: "%.1f%%", cpu)
        cpuLabel.textColor = cpu > 50 ? Theme.danger : (cpu > 15 ? Theme.warn : .labelColor)
        memLabel.stringValue = Fmt.bytes(mem)
    }

    @objc private func killTapped() { onKill?(entry) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let bg = hovered ? Theme.rowHover : Theme.rowBG
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - 分页按钮

final class TabButton: NSButton {
    var selected = false { didSet { refresh() } }
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.labelColor : Theme.dim
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attrs)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - 信息小块

final class StatBox: NSView {
    private let titleL = NSTextField(labelWithString: "")
    private let valueL = NSTextField(labelWithString: "")
    init(title: String) {
        super.init(frame: .zero)
        titleL.stringValue = title
        titleL.font = .systemFont(ofSize: 9)
        titleL.textColor = Theme.dim
        valueL.stringValue = "—"
        valueL.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        for v in [titleL, valueL] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleL.topAnchor.constraint(equalTo: topAnchor),
            titleL.leadingAnchor.constraint(equalTo: leadingAnchor),
            valueL.topAnchor.constraint(equalTo: titleL.bottomAnchor, constant: 1),
            valueL.leadingAnchor.constraint(equalTo: leadingAnchor),
            valueL.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ v: String) { valueL.stringValue = v }
}
