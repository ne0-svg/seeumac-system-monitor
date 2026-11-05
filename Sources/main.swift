import AppKit
import Foundation

// MARK: - 全局状态

final class Monitor {
    static let shared = Monitor()
    var latest: SystemSample?
    var topCPU: [AggregatedEntry] = []
    var topMem: [AggregatedEntry] = []
    var history: [Double] = []

    let sampler = SystemSampler()
    private var timer: Timer?
    var onChange: (() -> Void)?

    func start(interval: TimeInterval = 2.0) {
        _ = sampler.sample()          // 建基线
        tick()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var ticking = false
    private let workQ = DispatchQueue(label: "sysmon.sample", qos: .utility)

    /// 采样放到后台线程，主线程只做 UI 更新，避免菜单栏和界面卡顿
    func tick() {
        if ticking { return }
        ticking = true
        workQ.async { [weak self] in
            guard let self else { return }
            let s = self.sampler.sample()
            let entries = Aggregator.aggregate(s.procs)
            let byCPU = entries.sorted { $0.cpu > $1.cpu }
            let byMem = entries.sorted { $0.memBytes > $1.memBytes }
            DispatchQueue.main.async {
                self.latest = s
                self.topCPU = byCPU
                self.topMem = byMem
                self.history.append(s.cpuTotal)
                if self.history.count > 60 { self.history.removeFirst(self.history.count - 60) }
                self.ticking = false
                self.onChange?()
            }
        }
    }

    func terminate(_ entry: AggregatedEntry, done: @escaping (Int, Bool) -> Void) {
        guard !entry.isProtected else { done(0, false); return }
        ProcActions.terminate(pids: entry.pids) { failures in
            done(entry.pids.count - failures.count, failures.isEmpty)
            self.tick()
        }
    }
}

// MARK: - 菜单栏图标

enum TrayIcon {
    static func make(cpu: Double, mem: Double) -> NSImage {
        let size = NSSize(width: 32, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let bars = [cpu, mem, max(cpu, mem)]
            let barW: CGFloat = 5
            let gap: CGFloat = 3.5
            let totalW = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
            var x = (rect.width - totalW) / 2
            for (i, v) in bars.enumerated() {
                let pct = min(1, max(0, v / 100))
                let h = max(2.5, rect.height * 0.94 * CGFloat(pct))
                let r = NSRect(x: x, y: 1, width: barW, height: h)
                let path = NSBezierPath(roundedRect: r, xRadius: 1.2, yRadius: 1.2)
                NSColor.black.withAlphaComponent(i == 2 ? 1.0 : 0.68).setFill()
                path.fill()
                x += barW + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - 应用信息

enum AppInfo {
    /// 面板标题显示的名字。固定值，不跟随系统主机名
    static let displayName = "seeuMac"
    static let version = "1.0"
}

// MARK: - 格式化

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1fG", gb) }
        let mb = Double(b) / 1_048_576
        if mb >= 1 { return String(format: "%.0fM", mb) }
        return String(format: "%.0fK", Double(b) / 1024)
    }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "更新于 " + f.string(from: d)
    }
}

// MARK: - 面板控制器

final class PanelController: NSViewController {
    private let m = Monitor.shared
    private var scroll: NSScrollView!
    private var stack: NSStackView!
    private var tab: Int = 0
    private var tabButtons: [TabButton] = []

    // 需要动态更新的控件
    private var cpuBar: BarView!
    private var memBar: BarView!
    private var spark: SparklineView!
    private var cpuValueLabel: NSTextField!
    private var memValueLabel: NSTextField!
    private var loadLabel: NSTextField!
    private var thermalDot: NSView!
    private var thermalLabel: NSTextField!
    private var wiredBox: StatBox!
    private var compBox: StatBox!
    private var swapBox: StatBox!
    private var footerLabel: NSTextField!
    private var lastRowsKey: String = ""

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 688))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        view = root
        buildHeader()
        buildGauges()
        buildTabs()
        buildList()
        buildFooter()
        ready = true
        refresh()
    }

    // MARK: 头部

    private func buildHeader() {
        let host = NSTextField(labelWithString: AppInfo.displayName)
        host.font = .systemFont(ofSize: 13, weight: .semibold)

        loadLabel = NSTextField(labelWithString: "负载 —")
        loadLabel.font = .systemFont(ofSize: 10)
        loadLabel.textColor = Theme.dim

        let left = NSStackView(views: [host, loadLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2

        thermalDot = NSView()
        thermalDot.wantsLayer = true
        thermalDot.layer?.cornerRadius = 3
        thermalDot.layer?.backgroundColor = Theme.ok.cgColor
        thermalDot.translatesAutoresizingMaskIntoConstraints = false
        thermalDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        thermalDot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        thermalLabel = NSTextField(labelWithString: "温度")
        thermalLabel.font = .systemFont(ofSize: 10, weight: .medium)
        thermalLabel.textColor = Theme.dim

        let badge = NSStackView(views: [thermalDot, thermalLabel])
        badge.orientation = .horizontal
        badge.spacing = 4
        badge.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor

        let refresh = NSButton()
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refresh.bezelStyle = .inline
        refresh.isBordered = false
        refresh.target = self
        refresh.action = #selector(doRefresh)
        refresh.toolTip = "立即刷新"
        refresh.translatesAutoresizingMaskIntoConstraints = false
        refresh.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let row = NSStackView(views: [left, NSView(), badge, refresh])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 11),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14)
        ])
    }

    // MARK: 仪表

    private func buildGauges() {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        box.translatesAutoresizingMaskIntoConstraints = false

        // CPU
        let cpuTitle = NSTextField(labelWithString: "CPU")
        cpuTitle.font = .systemFont(ofSize: 11, weight: .medium)
        cpuValueLabel = NSTextField(labelWithString: "—")
        cpuValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        cpuValueLabel.textColor = Theme.dim
        cpuValueLabel.alignment = .right
        let cpuHead = NSStackView(views: [cpuTitle, NSView(), cpuValueLabel])
        cpuHead.orientation = .horizontal
        cpuHead.distribution = .fill

        cpuBar = BarView()
        cpuBar.translatesAutoresizingMaskIntoConstraints = false
        cpuBar.heightAnchor.constraint(equalToConstant: 10).isActive = true

        spark = SparklineView()
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.heightAnchor.constraint(equalToConstant: 26).isActive = true

        // 内存
        let memTitle = NSTextField(labelWithString: "内存")
        memTitle.font = .systemFont(ofSize: 11, weight: .medium)
        memValueLabel = NSTextField(labelWithString: "—")
        memValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        memValueLabel.textColor = Theme.dim
        memValueLabel.alignment = .right
        let memHead = NSStackView(views: [memTitle, NSView(), memValueLabel])
        memHead.orientation = .horizontal
        memHead.distribution = .fill

        memBar = BarView()
        memBar.translatesAutoresizingMaskIntoConstraints = false
        memBar.heightAnchor.constraint(equalToConstant: 10).isActive = true

        // 三个小方块
        wiredBox = StatBox(title: "已连线")
        compBox = StatBox(title: "压缩")
        swapBox = StatBox(title: "交换")
        let stats = NSStackView(views: [wiredBox, compBox, swapBox])
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.spacing = 10

        box.addArrangedSubview(cpuHead)
        box.addArrangedSubview(cpuBar)
        box.addArrangedSubview(spark)
        box.addArrangedSubview(spacer(6))
        box.addArrangedSubview(memHead)
        box.addArrangedSubview(memBar)
        box.addArrangedSubview(spacer(4))
        box.addArrangedSubview(stats)

        view.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: view.topAnchor, constant: 56),
            box.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            box.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14)
        ])
        for v in [cpuHead, cpuBar, spark, memHead, memBar, stats] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        }
        self.gaugeBox = box
    }

    private var gaugeBox: NSStackView!

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: 分页

    private func buildTabs() {
        let names = ["CPU", "内存", "App"]
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 2
        for (i, n) in names.enumerated() {
            let b = TabButton(title: n)
            b.tag = i
            b.target = self
            b.action = #selector(tabChanged(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            tabButtons.append(b)
            row.addArrangedSubview(b)
        }
        tabButtons[0].selected = true
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: gaugeBox.bottomAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10)
        ])
        tabsRow = row
    }

    private var tabsRow: NSStackView!

    @objc private func tabChanged(_ sender: NSButton) {
        tab = sender.tag
        for (i, b) in tabButtons.enumerated() { b.selected = (i == tab) }
        lastRowsKey = ""
        rebuildList()
    }

    // MARK: 列表

    private func buildList() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: tabsRow.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 356),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        ])
        // 内容顶部对齐
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
    }

    private var currentRows: [AggregatedEntry] {
        switch tab {
        case 0: return Array(m.topCPU.prefix(9))
        case 1: return Array(m.topMem.prefix(9))
        default: return Array(m.topCPU.filter { $0.kind == .app }.prefix(14))
        }
    }

    private func rebuildList() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        let rows = currentRows
        if rows.isEmpty {
            let l = NSTextField(labelWithString: "暂无数据")
            l.font = .systemFont(ofSize: 11)
            l.textColor = Theme.dim
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            l.heightAnchor.constraint(equalToConstant: 40).isActive = true
            l.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            stack.addArrangedSubview(l)
            return
        }
        for e in rows {
            let row = ProcRowView(entry: e)
            row.onKill = { [weak self] entry in self?.askKill(entry) }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: 38).isActive = true
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
    }

    /// 刷新已有行的数值，不重建视图
    private func updateLive(_ rows: [AggregatedEntry]) {
        let rowViews = stack.arrangedSubviews.compactMap { $0 as? ProcRowView }
        guard rowViews.count == rows.count else { rebuildList(); return }
        for (view, e) in zip(rowViews, rows) {
            view.update(cpu: e.cpu, mem: e.memBytes)
        }
    }

    private func askKill(_ entry: AggregatedEntry) {
        // 重要目标二次确认
        if entry.cpu > 40 || entry.procCount > 3 {
            let alert = NSAlert()
            alert.messageText = "结束 \(entry.title)？"
            alert.informativeText = "将向 \(entry.procCount) 个进程发送退出信号，3 秒内没退出的会强制结束。未保存的内容会丢失。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "结束")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        m.terminate(entry) { killed, allOK in
            self.toast(allOK ? "已结束 \(entry.title)（\(killed) 个进程）"
                             : "部分进程无法结束（权限不足）")
        }
    }

    private func toast(_ text: String) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.alignment = .center
        l.wantsLayer = true
        l.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        l.layer?.cornerRadius = 8
        l.layer?.borderWidth = 1
        l.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70),
            l.heightAnchor.constraint(equalToConstant: 32),
            l.widthAnchor.constraint(equalToConstant: 240)
        ])
        l.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            l.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                l.animator().alphaValue = 0
            } completionHandler: {
                l.removeFromSuperview()
            }
        }
    }

    // MARK: 尾部

    private func buildFooter() {
        footerLabel = NSTextField(labelWithString: "—")
        footerLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        footerLabel.textColor = Theme.dim

        let close = NSButton(title: "退出", target: self, action: #selector(quit))
        close.bezelStyle = .inline
        close.isBordered = false
        close.font = .systemFont(ofSize: 10)
        close.contentTintColor = Theme.dim

        let act = NSButton(title: "活动监视器", target: self, action: #selector(openActivity))
        act.bezelStyle = .inline
        act.isBordered = false
        act.font = .systemFont(ofSize: 10)
        act.contentTintColor = Theme.dim

        let row = NSStackView(views: [footerLabel, NSView(), act, close])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9),
            row.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    @objc private func doRefresh() { m.tick() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openActivity() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    // MARK: 刷新

    private var ready = false

    func refresh() {
        guard ready, let s = m.latest else { return }
        cpuBar.value = s.cpuTotal
        cpuBar.color = Theme.level(s.cpuTotal)
        let la = s.loadAvg.count >= 3 ? s.loadAvg : [0, 0, 0]
        cpuValueLabel.stringValue = String(format: "%.0f%%", s.cpuTotal)
        spark.values = m.history
        spark.color = Theme.level(s.cpuTotal)

        memBar.value = s.memPressure
        memBar.color = Theme.level(s.memPressure)
        memValueLabel.stringValue = "\(Fmt.bytes(s.memUsed)) / \(Fmt.bytes(s.memTotal))"

        wiredBox.set(Fmt.bytes(s.memWired))
        compBox.set(Fmt.bytes(s.memCompressed))
        swapBox.set(s.swapTotal == 0 ? "无" : Fmt.bytes(s.swapUsed))

        let (color, label): (NSColor, String) = {
            switch s.thermalPressure {
            case "Normal": return (Theme.ok, "温度正常")
            case "Fair": return (.systemYellow, "偏热")
            case "Serious": return (Theme.warn, "很热")
            case "Critical": return (Theme.danger, "过热")
            default: return (Theme.dim, "温度 —")
            }
        }()
        thermalDot.layer?.backgroundColor = color.cgColor
        thermalLabel.stringValue = label
        loadLabel.stringValue = String(format: "负载 %.2f %.2f %.2f", la[0], la[1], la[2])

        footerLabel.stringValue = Fmt.clock(Date())

        // 行内容变了才重建，避免每 2 秒闪一次
        let rows = currentRows
        // 只有「哪些条目、什么顺序」变化时才重建视图；
        // 纯数值变化走 updateLive()，避免每 3 秒拆一遍视图层级
        let key = rows.map { $0.id }.joined(separator: "|")
        if key != lastRowsKey {
            lastRowsKey = key
            rebuildList()
        } else {
            updateLive(rows)
        }
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelWindow: NSPanel!
    private let monitor = Monitor.shared
    private var panel: PanelController!
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel = PanelController()
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 688),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        w.contentViewController = panel
        w.isFloatingPanel = true
        w.level = .statusBar
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.animationBehavior = .none
        panelWindow = w

        monitor.onChange = { [weak self] in
            guard let self else { return }
            self.updateIcon()
            if self.panelWindow.isVisible { self.panel.refresh() }
        }
        monitor.start(interval: 3.0)
        updateIcon()

    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        if let s = monitor.latest {
            button.image = TrayIcon.make(cpu: s.cpuTotal, mem: s.memPressure)
            button.toolTip = String(format: "CPU %.0f%% · 内存 %.0f%% · 负载 %.2f",
                                    s.cpuTotal, s.memPressure, s.loadAvg.first ?? 0)
        } else {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "SysMon")
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if panelWindow.isVisible { hidePanel(); return }
        if let ev = NSApp.currentEvent, ev.type == .rightMouseUp { showMenu(); return }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        monitor.tick()
        panel.refresh()

        let size = NSSize(width: 420, height: 688)
        let buttonFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        var origin = NSPoint(x: buttonFrame.midX - size.width / 2, y: buttonFrame.minY - size.height - 6)
        // 屏幕边界夹紧
        if let screen = button.window?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
            if origin.y < vf.minY + 8 { origin.y = buttonFrame.minY - size.height - 6 }
            if origin.y < vf.minY + 8 { origin.y = vf.minY + 8 }
        }
        panelWindow.setFrame(NSRect(origin: origin, size: size), display: true)
        panelWindow.orderFrontRegardless()
        panelWindow.makeKey()

        // 点面板外面就收起
        localMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        if let lm = localMonitor { NSEvent.removeMonitor(lm); localMonitor = nil }
        panelWindow?.orderOut(nil)
    }

    private func showMenu() {
        let menu = NSMenu()
        let mi = menu.addItem(withTitle: "打开面板", action: #selector(openPanel), keyEquivalent: "")
        mi.target = self
        menu.addItem(.separator())
        let am = menu.addItem(withTitle: "活动监视器", action: #selector(openActivity), keyEquivalent: "")
        am.target = self
        menu.addItem(.separator())
        let q = menu.addItem(withTitle: "退出 SysMon", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() { showPanel() }
    @objc private func openActivity() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
