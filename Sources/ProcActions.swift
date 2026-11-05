import Foundation
import Darwin
import AppKit

// MARK: - 聚合后的条目（面板里显示的一行）

struct AggregatedEntry: Identifiable {
    let id: String              // bundleID 或 进程名
    var title: String
    var subtitle: String
    var cpu: Double
    var memBytes: UInt64
    var procCount: Int
    var pids: [pid_t]
    var appPath: String?
    var bundleID: String?
    var icon: NSImage?
    var isProtected: Bool       // 系统进程，不给杀

    var kind: Kind
    enum Kind { case app, process }
}

enum ProcActions {
    /// 图标缓存：路径 → 图标。图标是静态资源，绝不每轮采样重读
    private static var iconCache: [String: NSImage] = [:]
    private static let iconLock = NSLock()

    static func cachedIcon(appPath: String) -> NSImage? {
        iconLock.lock()
        if let hit = iconCache[appPath] { iconLock.unlock(); return hit }
        iconLock.unlock()

        let img = loadIcon(appPath: appPath)
        if let img {
            iconLock.lock()
            iconCache[appPath] = img
            iconLock.unlock()
        }
        return img
    }

    private static func loadIcon(appPath: String) -> NSImage? {
        if let icns = bundleIcon(appPath: appPath) { return icns }
        let sys = NSWorkspace.shared.icon(forFile: appPath)
        return sys.size.width > 0 ? sys : nil
    }

    /// 直接读 .app 的 CFBundleIconFile 指向的 icns，避免 NSWorkspace 对第三方 app 返回空白
    static func bundleIcon(appPath: String) -> NSImage? {
        let plistPath = appPath + "/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: plistPath) else { return nil }
        var iconName = dict["CFBundleIconFile"] as? String
        if iconName == nil, let icons = dict["CFBundleIconName"] as? String { iconName = icons }
        guard var name = iconName, !name.isEmpty else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        let full = appPath + "/Contents/Resources/" + name
        if let img = NSImage(contentsOfFile: full), img.size.width > 0 { return img }
        return nil
    }

    /// 只读的操作：超时等待，避免 UI 卡住
    static func runs(pid: pid_t, within seconds: Double = 1.0) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "pid=,ppid=,pcpu=,rss=,comm=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "") }

        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if p.isRunning {
            p.terminate()
            return (false, "TIMEOUT")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// 结束一个 PID。先 SIGTERM，宽限期后没死再 SIGKILL。
    /// 返回 nil = 成功；否则是错误说明
    static func kill(pid: pid_t, force: Bool = false) -> String? {
        if pid <= 1 { return "拒绝操作系统进程" }
        let sig = force ? SIGKILL : SIGTERM
        if Darwin.kill(pid, sig) != 0 {
            let e = errno
            switch e {
            case EPERM: return "权限不足"
            case ESRCH: return "进程已不存在"
            default: return String(cString: strerror(e))
            }
        }
        return nil
    }

    /// 优雅结束一组 PID：SIGTERM → 等 → SIGKILL
    /// completion 在后台队列回调
    static func terminate(pids: [pid_t], grace: Double = 3.0, completion: @escaping ([pid_t: String]) -> Void) {
        let targets = pids.filter { $0 > 1 }
        guard !targets.isEmpty else { completion([:]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [pid_t: String] = [:]
            for pid in targets {
                if let err = kill(pid: pid, force: false) {
                    failures[pid] = err
                }
            }
            // 宽限期
            let deadline = Date().addingTimeInterval(grace)
            var alive = targets.filter { Darwin.kill($0, 0) == 0 || errno == EPERM }
            while !alive.isEmpty && Date() < deadline {
                usleep(100_000)
                alive = alive.filter { Darwin.kill($0, 0) == 0 || errno == EPERM }
            }
            for pid in alive {
                if let err = kill(pid: pid, force: true), failures[pid] == nil {
                    failures[pid] = err
                }
            }
            DispatchQueue.main.async { completion(failures) }
        }
    }

    /// 系统关键进程白名单：这些不给杀
    static let protectedNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "Dock", "Finder",
        "SystemUIServer", "MenuBarAgent", "ControlCenter", "NotificationCenter",
        "sysmond", "coreaudiod", "runningboardd", "distnoted", "cfprefsd",
        "powerd", "opendirectoryd", "securityd", "tccd", "symptomsd", "configd",
        "mds", "mds_stores", "mdworker", "mdworker_shared", "UserEventAgent",
        "AirPlayUIAgent", "universalaccessd", "SkyLight", "spotlightknowledged",
        "Alma", "SysMon"    // 别把自己杀了
    ]
}

// MARK: - 聚合

enum Aggregator {
    /// 白名单 App：这些即使点也不杀（避免自伤）
    static let neverKillBundleIDs: Set<String> = [
        "com.alma.app", "com.apple.finder"
    ]

    static func aggregate(_ procs: [ProcSample]) -> [AggregatedEntry] {
        struct Bucket {
            var title: String
            var cpu: Double = 0
            var mem: UInt64 = 0
            var pids: [pid_t] = []
            var appPath: String?
            var bundleID: String?
            var names: [String] = []
        }
        var buckets: [String: Bucket] = [:]

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for p in procs {
            // 跳过自己
            if p.pid == selfPID { continue }
            // 跳过 0 CPU 0 内存的僵尸
            guard p.memBytes > 0 || p.cpu > 0.01 else { continue }
            let key: String
            if let bid = p.appBundleID {
                key = "app:" + bid
            } else if p.appPath != nil {
                key = "path:" + (p.appPath ?? p.displayName)
            } else {
                key = "bin:" + p.name
            }
            if var b = buckets[key] {
                b.cpu += p.cpu
                b.mem += p.memBytes
                b.pids.append(p.pid)
                b.names.append(p.name)
                buckets[key] = b
            } else {
                buckets[key] = Bucket(title: p.displayName,
                                       cpu: p.cpu,
                                       mem: p.memBytes,
                                       pids: [p.pid],
                                       appPath: p.appPath,
                                       bundleID: p.appBundleID,
                                       names: [p.name])
            }
        }

        return buckets.map { key, b -> AggregatedEntry in
            let kind: AggregatedEntry.Kind = key.hasPrefix("app:") ? .app : .process
            let icon: NSImage? = b.appPath.flatMap { ProcActions.cachedIcon(appPath: $0) }
            let protected: Bool
            if let bid = b.bundleID {
                protected = neverKillBundleIDs.contains(bid)
            } else {
                protected = ProcActions.protectedNames.contains(b.title)
            }
            var subtitle: String
            if kind == .app {
                let helpers = b.pids.count - 1
                subtitle = helpers > 0 ? "App · \(b.pids.count) 个进程" : "App"
            } else {
                subtitle = "PID \(b.pids.first ?? 0)"
            }
            if protected { subtitle += " · 受保护" }
            return AggregatedEntry(id: key,
                                    title: b.title,
                                    subtitle: subtitle,
                                    cpu: b.cpu,
                                    memBytes: b.mem,
                                    procCount: b.pids.count,
                                    pids: b.pids.sorted(),
                                    appPath: b.appPath,
                                    bundleID: b.bundleID,
                                    icon: icon,
                                    isProtected: protected,
                                    kind: kind)
        }
    }
}
