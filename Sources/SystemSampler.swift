import Foundation
import Darwin

// MARK: - 数据结构

struct ProcSample {
    var pid: pid_t
    var name: String            // 可执行文件名（短）
    var displayName: String     // 本地化名字，如“微信”
    var appBundleID: String?
    var appPath: String?
    var cpu: Double             // 单核百分比，可 >100。多线程合计
    var memBytes: UInt64        // 常驻内存物理占用
    var isAppChild: Bool        // 是否属于某个 .app 的子进程（Helper / Renderer 之类）
}

struct SystemSample {
    var cpuTotal: Double        // 0-100
    var cpuUser: Double
    var cpuSystem: Double
    var loadAvg: [Double]
    var memTotal: UInt64
    var memUsed: UInt64
    var memWired: UInt64
    var memCompressed: UInt64
    var memApp: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var thermalPressure: String   // Nominal / Fair / Serious / Critical
    var procs: [ProcSample]

    var memPressure: Double {
        memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) * 100
    }
}

// MARK: - 采样器

final class SystemSampler {
    private var prevCPU: [pid_t: (total: UInt64, time: UInt64)] = [:]
    private var prevCPUTicks: (busy: UInt64, total: UInt64)?
    private let pageSize: UInt64 = UInt64(vm_kernel_page_size)
    private let cpuCount: Int = max(1, Int(ProcessInfo.processInfo.processorCount))

    let memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory

    private lazy var runningApps: [String: AppOwner] = {
        Self.buildAppIndex()
    }()

    // MARK: 一次完整采样

    func sample() -> SystemSample {
        let cpu = sampleSystemCPU()
        let mem = sampleMemory()
        let loads = sampleLoad()
        let procs = sampleProcesses()
        return SystemSample(
            cpuTotal: cpu.total,
            cpuUser: cpu.user,
            cpuSystem: cpu.system,
            loadAvg: loads,
            memTotal: memTotal,
            memUsed: mem.used,
            memWired: mem.wired,
            memCompressed: mem.compressed,
            memApp: mem.app,
            swapUsed: mem.swapUsed,
            swapTotal: mem.swapTotal,
            thermalPressure: Self.thermalPressure(),
            procs: procs
        )
    }

    // MARK: 整机 CPU（host_statistics）

    private func sampleSystemCPU() -> (total: Double, user: Double, system: Double) {
        // 只需总占用率；user/system 拆分不在这里算
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0) }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { prevCPUTicks = (busy, total) }
        guard let prev = prevCPUTicks, total > prev.total else {
            return (0, 0, 0)
        }
        let dBusy = Double(busy &- prev.busy)
        let dTotal = Double(total &- prev.total)
        guard dTotal > 0 else { return (0, 0, 0) }
        return (dBusy / dTotal * 100, 0, 0)
    }

    private func sampleLoad() -> [Double] {
        var lavg = [Double](repeating: 0, count: 3)
        getloadavg(&lavg, 3)
        return lavg
    }

    // MARK: 内存

    private func sampleMemory() -> (used: UInt64, wired: UInt64, compressed: UInt64, app: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var wired: UInt64 = 0, compressed: UInt64 = 0, app: UInt64 = 0, used: UInt64 = 0
        if kr == KERN_SUCCESS {
            wired = UInt64(stats.wire_count) * pageSize
            compressed = UInt64(stats.compressor_page_count) * pageSize
            app = UInt64(stats.internal_page_count) * pageSize
            // 已用 = total - free - purgeable(可回收) 更接近活动监视器
            let free = UInt64(stats.free_count) * pageSize
            let purgeable = UInt64(stats.purgeable_count) * pageSize
            used = memTotal > (free + purgeable) ? memTotal - free - purgeable : 0
        }
        // swap
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }
        return (used, wired, compressed, app, swapUsed, swapTotal)
    }

    // MARK: 进程列表

    private func sampleProcesses() -> [ProcSample] {
        let pids = Self.listPIDs()
        var result: [ProcSample] = []
        result.reserveCapacity(pids.count)

        var newCPU: [pid_t: (total: UInt64, time: UInt64)] = [:]
        newCPU.reserveCapacity(pids.count)
        let now = UInt64(DispatchTime.now().uptimeNanoseconds)

        for pid in pids {
            guard let kp = Self.taskInfo(pid: pid) else { continue }
            // 注意：pti_total_user/system 只统计主线程，多线程进程会严重偏低。
            // 必须逐线程累加 PROC_PIDTHREADINFO 的 pth_user_time + pth_system_time。
            let total = Self.threadCPUTime(pid: pid)
            newCPU[pid] = (total, now)

            var cpu: Double = 0
            if let prev = prevCPU[pid] {
                let dTime = Double(now &- prev.time)
                if dTime > 0 && total >= prev.total {
                    // 单位是 nanoseconds，除以 1e9 得核·秒
                    cpu = Double(total &- prev.total) / dTime * 100.0
                }
            }

            let path = Self.executablePath(pid: pid) ?? Self.procName(pid: pid) ?? "pid-\(pid)"
            let shortName = (path as NSString).lastPathComponent

            // 归属到 .app
            let owner = Self.ownerApp(path: path, index: runningApps)

            result.append(ProcSample(
                pid: pid,
                name: shortName,
                displayName: owner?.displayName ?? Self.prettyName(shortName),
                appBundleID: owner?.bundleID,
                appPath: owner?.path,
                cpu: cpu,
                memBytes: UInt64(kp.pti_resident_size),
                isAppChild: owner != nil
            ))
        }
        prevCPU = newCPU
        return result
    }

    static func listPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard got > 0 else { return [] }
        return pids.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func taskInfo(pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let got = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(size))
        }
        return got == Int32(size) ? info : nil
    }

    /// 逐线程累加的真实 CPU 时间（纳秒）。
    /// pti_total_user 只含主线程，普通单线程小进程看不出差别，
    /// 但 Chrome/Alma 这种几十线程的进程会低到只有真实值的 1/40。
    static func threadCPUTime(pid: pid_t) -> UInt64 {
        let maxThreads = 1024
        var buf = [UInt64](repeating: 0, count: maxThreads)
        let n = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &buf,
                             Int32(maxThreads * MemoryLayout<UInt64>.size))
        guard n > 0 else { return 0 }
        let cnt = Int(n) / MemoryLayout<UInt64>.size
        let sz = Int32(MemoryLayout<proc_threadinfo>.size)

        // 先试批量接口：一次系统调用拿回全部线程信息（比逐条快得多）
        var batches = [proc_threadinfo](repeating: proc_threadinfo(), count: cnt)
        let need = Int32(cnt * MemoryLayout<proc_threadinfo>.size)
        let gotBytes = batches.withUnsafeMutableBufferPointer { ptr in
            proc_pidinfo(pid, PROC_PIDTHREADINFO, 0, ptr.baseAddress, need)
        }
        if gotBytes == need {
            var sum: UInt64 = 0
            for t in batches {
                sum &+= UInt64(t.pth_user_time) &+ UInt64(t.pth_system_time)
            }
            return sum
        }
        // 兜底：逐条查
        var sum: UInt64 = 0
        var ti = proc_threadinfo()
        for i in 0..<cnt {
            let tid = buf[i]
            if tid == 0 { continue }
            let got = withUnsafeMutablePointer(to: &ti) {
                proc_pidinfo(pid, PROC_PIDTHREADINFO, tid, $0, sz)
            }
            if got == sz {
                sum &+= UInt64(ti.pth_user_time) &+ UInt64(ti.pth_system_time)
            }
        }
        return sum
    }

    static func procName(pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        let got = proc_name(pid, &name, UInt32(name.count))
        guard got > 0 else { return nil }
        return String(cString: name)
    }

    static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let got = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard got > 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: .app 归属映射

    struct AppOwner {
        var displayName: String
        var bundleID: String
        var path: String
    }

    static func buildAppIndex() -> [String: AppOwner] {
        var idx: [String: AppOwner] = [:]
        let roots = ["/Applications",
                     "/System/Applications",
                     "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
        let fm = FileManager.default
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for e in entries where e.hasSuffix(".app") {
                let appPath = root + "/" + e
                let name = (e as NSString).deletingPathExtension
                let bid = Bundle(path: appPath)?.bundleIdentifier ?? name
                idx[appPath] = AppOwner(displayName: localizedName(appPath: appPath, fallback: name),
                                        bundleID: bid, path: appPath)
            }
            // 一层子目录（如 Microsoft Office 之类）
            for e in entries where !e.hasSuffix(".app") && !e.hasPrefix(".") {
                let sub = root + "/" + e
                guard let subs = try? fm.contentsOfDirectory(atPath: sub) else { continue }
                for s in subs where s.hasSuffix(".app") {
                    let appPath = sub + "/" + s
                    let name = (s as NSString).deletingPathExtension
                    let bid = Bundle(path: appPath)?.bundleIdentifier ?? name
                    idx[appPath] = AppOwner(displayName: localizedName(appPath: appPath, fallback: name),
                                            bundleID: bid, path: appPath)
                }
            }
        }
        return idx
    }

    static func localizedName(appPath: String, fallback: String) -> String {
        let plist = appPath + "/Contents/Info.plist"
        if let dict = NSDictionary(contentsOfFile: plist) {
            if let dn = dict["CFBundleDisplayName"] as? String, !dn.isEmpty { return dn }
            if let n = dict["CFBundleName"] as? String, !n.isEmpty { return n }
        }
        return fallback
    }

    /// 从可执行路径反推它属于哪个 .app。
    /// 例：/Applications/Alma.app/Contents/Frameworks/Alma Helper (Renderer).app/.../Alma Helper (Renderer)
    ///   → 取最后一个 ".app" 前面的部分作为根 bundle
    static func ownerApp(path: String, index: [String: AppOwner]) -> AppOwner? {
        guard let dotApp = path.range(of: ".app", options: .backwards) else { return nil }
        let appPath = String(path[path.startIndex..<dotApp.upperBound])
        if let hit = index[appPath] { return hit }
        // 不在索引里（如用户自定义位置），直接问那个 bundle
        guard FileManager.default.fileExists(atPath: appPath + "/Contents/Info.plist") else { return nil }
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return AppOwner(displayName: localizedName(appPath: appPath, fallback: name),
                        bundleID: Bundle(path: appPath)?.bundleIdentifier ?? name,
                        path: appPath)
    }

    static func prettyName(_ exec: String) -> String {
        // "Alma Helper (Renderer)" 这类保留，其他原样
        exec
    }

    // MARK: 热压力

    static func thermalPressure() -> String {
        var state: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let kr = sysctlbyname("kern.thermal_pressure_level", &state, &size, nil, 0)
        guard kr == 0 else { return "—" }
        switch state {
        case 0: return "Normal"
        case 1: return "Fair"
        case 2: return "Serious"
        case 3: return "Critical"
        default: return "—"
        }
    }
}
