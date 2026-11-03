import SwiftUI
import AppKit
import Darwin
import Foundation
import IOKit
import os

/// Failed reads go to the unified log (Console.app, subsystem
/// com.hpal007.statter) instead of silently becoming a plausible zero.
let logger = Logger(subsystem: "com.hpal007.statter", category: "sampling")

// MARK: - Data Models

/// Subtraction that clamps at zero. The VM page counters are sampled
/// independently and are not guaranteed to be mutually consistent, so plain
/// `-` on UInt64 can trap at runtime.
func saturatingSub(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }

struct MemoryStats: Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let appBytes: UInt64  // approximate app-associated memory
    let swapUsedBytes: UInt64
    /// The kernel's own VM pressure level; nil if it could not be read.
    var pressure: MemoryPressure? = nil

    static let empty = MemoryStats(totalBytes: 0, usedBytes: 0, activeBytes: 0, inactiveBytes: 0,
                                   wiredBytes: 0, compressedBytes: 0, freeBytes: 0, appBytes: 0,
                                   swapUsedBytes: 0)

    var usedFraction: Double { Double(usedBytes) / Double(max(totalBytes, 1)) }
    var freeFraction: Double { Double(freeBytes) / Double(max(totalBytes, 1)) }
    var availableBytes: UInt64 { saturatingSub(totalBytes, usedBytes) }  // everything OS can reclaim
    var availableFraction: Double { Double(availableBytes) / Double(max(totalBytes, 1)) }
}

struct NetworkStats: Sendable {
    let downBytesPerSec: Double
    let upBytesPerSec: Double
    let hasBaseline: Bool
}

struct CPUStats: Sendable {
    let userPercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let logicalCores: Int
    let performanceCores: Int
    let efficiencyCores: Int

    var busyPercent: Double { min(100, max(0, 100 - idlePercent)) }
}

struct GPUStats: Sendable {
    let deviceUtilization: Int
    let rendererUtilization: Int
    let tilerUtilization: Int
    let inUseMemory: UInt64
    let allocatedMemory: UInt64
    let coreCount: Int
    let model: String
}

struct ProcessMemory: Identifiable, Sendable {
    let id: String
    /// Display name, with a count for grouped rows: `node (10)`.
    let name: String
    let pid: Int
    let residentMB: Double
    let cpuPercent: Double
    /// Executable name every PID in the row was seen under.
    var executable: String = ""
    /// Every PID merged into this row; killing the row signals all of them.
    var pids: [Int] = []
    /// PID -> start time, captured at scan time. A PID plus its start time
    /// names one process for good, so a reused PID is never signalled.
    var startTimes: [Int: UInt64] = [:]
}

/// `kern.memorystatus_vm_pressure_level` — the same signal the kernel uses to
/// decide when to compress, swap and ask apps to free memory.
enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// Shared so the menu bar chip and the panel can never disagree about what
/// colour the machine is.
enum MemoryLevel: Int, Comparable {
    case ok, warn, critical

    static func < (a: MemoryLevel, b: MemoryLevel) -> Bool { a.rawValue < b.rawValue }

    init(availableFraction f: Double) {
        if f > 0.30 { self = .ok }
        else if f > 0.15 { self = .warn }
        else { self = .critical }
    }

    init(_ pressure: MemoryPressure) {
        switch pressure {
        case .normal: self = .ok
        case .warning: self = .warn
        case .critical: self = .critical
        }
    }

    /// The worse of headroom and kernel pressure. Pressure alone stays "normal"
    /// on a big machine at 95% used, and headroom alone misses the kernel
    /// already compressing and swapping; either one can raise the alarm.
    init(_ stats: MemoryStats) {
        let headroom = MemoryLevel(availableFraction: stats.availableFraction)
        self = stats.pressure.map { max(headroom, MemoryLevel($0)) } ?? headroom
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .critical: return .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

enum ProcessSortKey: String, CaseIterable {
    case memory = "Memory"
    case cpu = "CPU"
    case name = "Name"
    case pid = "PID"

    /// Direction to apply when this column is first selected: biggest-first for
    /// magnitudes, A-Z / lowest-first for labels and identifiers.
    var defaultAscending: Bool {
        switch self {
        case .memory, .cpu: return false
        case .name, .pid: return true
        }
    }
}

// MARK: - System Info Helpers

func getPhysicalMemory() -> UInt64 {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return size
}

func getVMStats() -> vm_statistics64? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()

    let result = withUnsafeMutablePointer(to: &stats) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
        }
    }
    // mach_host_self() returns a send right we own; without this the port
    // reference count grows on every sample.
    mach_port_deallocate(mach_task_self_, host)

    return result == KERN_SUCCESS ? stats : nil
}

func getSwapUsage() -> UInt64? {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else {
        logger.error("sysctl vm.swapusage failed: errno \(errno)")
        return nil
    }
    return swap.xsu_used
}

func readMemoryPressure() -> MemoryPressure? {
    var level: Int32 = 0
    var len = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0) == 0 else {
        logger.error("sysctl kern.memorystatus_vm_pressure_level failed: errno \(errno)")
        return nil
    }
    return MemoryPressure(rawValue: Int(level))
}

/// The unit host_statistics64 counts pages in. Asked for once via
/// host_page_size rather than read from the mutable global vm_kernel_page_size.
let kernelPageSize: UInt64 = {
    var size: vm_size_t = 0
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    return host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : 16_384
}()

/// Returns nil when the VM counters cannot be read, so the caller keeps the
/// last good sample rather than painting an empty machine.
func readMemoryStats() -> MemoryStats? {
    let total = getPhysicalMemory()
    let pageSize = kernelPageSize

    guard let vm = getVMStats() else {
        logger.error("host_statistics64(HOST_VM_INFO64) failed")
        return nil
    }

    let active = UInt64(vm.active_count) * pageSize
    let inactive = UInt64(vm.inactive_count) * pageSize
    let wired = UInt64(vm.wire_count) * pageSize
    let compressed = UInt64(vm.compressor_page_count) * pageSize
    let purgeable = UInt64(vm.purgeable_count) * pageSize

    // Used memory matching Activity Monitor: app memory + wired + compressed
    // Inactive, speculative, purgeable, and free pages are all reclaimable.
    // purgeable_count spans every queue while active_count does not, so this
    // subtraction can go negative and must be clamped.
    let appMem = saturatingSub(active, purgeable)
    let usedApprox = min(appMem + wired + compressed, total)

    return MemoryStats(
        totalBytes: total, usedBytes: usedApprox, activeBytes: active,
        inactiveBytes: inactive, wiredBytes: wired, compressedBytes: compressed,
        freeBytes: saturatingSub(total, usedApprox), appBytes: appMem,
        swapUsedBytes: getSwapUsage() ?? 0,
        pressure: readMemoryPressure()
    )
}

func sysctlInt(_ name: String) -> Int {
    var value: Int32 = 0
    var len = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return 0 }
    return Int(value)
}

/// One sample of everything the menu bar and the left half of the panel show.
struct SystemSample: Sendable {
    let memory: MemoryStats?
    let cpu: CPUStats?
    let gpu: GPUStats?
    let network: NetworkStats?
}

// MARK: - Sampler

/// Owns every piece of state that only means something relative to the
/// previous sample (CPU ticks, network byte counters) plus values that never
/// change (core counts, GPU model). Being an actor, reads run off the main
/// thread and can never overlap — the old Timer + GCD design could start a
/// new sample while the previous one was still in flight.
actor SystemSampler {
    private var previousCPUTicks: host_cpu_load_info?
    private var previousNet: (rx: UInt64, tx: UInt64, at: ContinuousClock.Instant)?
    private var loggedFailures: Set<String> = []

    private let logicalCores = sysctlInt("hw.logicalcpu")
    private let performanceCores = sysctlInt("hw.perflevel0.logicalcpu")
    private let efficiencyCores = sysctlInt("hw.perflevel1.logicalcpu")
    private var gpuIdentity: (model: String, cores: Int)?

    func sample() -> SystemSample {
        SystemSample(memory: readMemoryStats(), cpu: readCPU(), gpu: readGPU(), network: readNetwork())
    }

    /// A read that fails once will fail every 2 seconds; log it once.
    private func logOnce(_ key: String, _ message: String) {
        guard loggedFailures.insert(key).inserted else { return }
        logger.error("\(message, privacy: .public)")
    }

    // MARK: CPU via host_statistics

    /// CPU utilisation is a rate, so it only exists relative to the previous
    /// sample. The first call after launch has no baseline and reports idle.
    private func readCPU() -> CPUStats? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics(host, HOST_CPU_LOAD_INFO, p, &count)
            }
        }
        mach_port_deallocate(mach_task_self_, host)

        guard result == KERN_SUCCESS else {
            logOnce("cpu", "host_statistics(HOST_CPU_LOAD_INFO) failed: \(result)")
            return nil
        }

        let idleStats = CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100,
                                 logicalCores: logicalCores, performanceCores: performanceCores,
                                 efficiencyCores: efficiencyCores)
        defer { previousCPUTicks = info }
        guard let prev = previousCPUTicks else { return idleStats }

        // Tick counters are monotonic but wrap; clamp so a wrap reports 0 rather
        // than a nonsense spike.
        func delta(_ now: UInt32, _ before: UInt32) -> Double {
            now >= before ? Double(now - before) : 0
        }
        let user = delta(info.cpu_ticks.0, prev.cpu_ticks.0)
        let system = delta(info.cpu_ticks.1, prev.cpu_ticks.1)
        let idle = delta(info.cpu_ticks.2, prev.cpu_ticks.2)
        let nice = delta(info.cpu_ticks.3, prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return idleStats }

        return CPUStats(userPercent: (user + nice) / total * 100,
                        systemPercent: system / total * 100,
                        idlePercent: idle / total * 100,
                        logicalCores: logicalCores, performanceCores: performanceCores,
                        efficiencyCores: efficiencyCores)
    }

    // MARK: Network via getifaddrs

    /// Sums byte counters across every non-loopback interface. Like CPU,
    /// throughput is a rate, so the first call only establishes a baseline.
    private func readNetwork() -> NetworkStats? {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            logOnce("net", "getifaddrs failed: errno \(errno)")
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               !name.hasPrefix("lo"), !name.hasPrefix("gif"), !name.hasPrefix("stf"),
               let d = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(d.pointee.ifi_ibytes)
                tx += UInt64(d.pointee.ifi_obytes)
            }
            ptr = cur.pointee.ifa_next
        }

        let now = ContinuousClock.now
        defer { previousNet = (rx, tx, now) }
        guard let prev = previousNet else {
            return NetworkStats(downBytesPerSec: 0, upBytesPerSec: 0, hasBaseline: false)
        }
        let elapsed = (now - prev.at) / .seconds(1)
        guard elapsed > 0 else {
            return NetworkStats(downBytesPerSec: 0, upBytesPerSec: 0, hasBaseline: true)
        }

        // ifi_ibytes / ifi_obytes are 32-bit and wrap every 4 GB. A wrap shows up
        // as the sum going backwards; drop that one sample rather than report a spike.
        let down = rx >= prev.rx ? Double(rx - prev.rx) / elapsed : 0
        let up = tx >= prev.tx ? Double(tx - prev.tx) / elapsed : 0
        return NetworkStats(downBytesPerSec: down, upBytesPerSec: up, hasBaseline: true)
    }

    // MARK: GPU via IOKit

    /// Reads the AGXAccelerator registry entry directly — the same data
    /// `ioreg -r -c AGXAccelerator` prints, without spawning a process every
    /// two seconds or depending on its text format. Nil on Macs without an
    /// Apple Silicon GPU, or if the entry stops exposing PerformanceStatistics.
    private func readGPU() -> GPUStats? {
        // IOServiceGetMatchingService consumes the matching dictionary.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != IO_OBJECT_NULL else {
            logOnce("gpu-service", "No AGXAccelerator in the IORegistry; GPU stats unavailable")
            return nil
        }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }

        if gpuIdentity == nil {
            var model = "Unknown GPU"
            switch property("model") {
            case let s as String: model = s
            case let d as Data:
                // Some registry entries store strings as NUL-terminated bytes.
                model = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
            default: break
            }
            let cores = (property("gpu-core-count") as? NSNumber)?.intValue ?? 0
            gpuIdentity = (model, cores)
        }

        guard let perf = property("PerformanceStatistics") as? [String: Any] else {
            logOnce("gpu-perf", "AGXAccelerator has no PerformanceStatistics dictionary")
            return nil
        }
        func number(_ key: String) -> NSNumber? { perf[key] as? NSNumber }
        guard let device = number("Device Utilization %") else {
            logOnce("gpu-util", "PerformanceStatistics lacks 'Device Utilization %'; keys: \(perf.keys.sorted())")
            return nil
        }

        return GPUStats(deviceUtilization: device.intValue,
                        rendererUtilization: number("Renderer Utilization %")?.intValue ?? 0,
                        tilerUtilization: number("Tiler Utilization %")?.intValue ?? 0,
                        inUseMemory: number("In use system memory")?.uint64Value ?? 0,
                        allocatedMemory: number("Alloc system memory")?.uint64Value ?? 0,
                        coreCount: gpuIdentity?.cores ?? 0,
                        model: gpuIdentity?.model ?? "Unknown GPU")
    }
}

// MARK: - Physical Footprint (accurate memory, same metric as Activity Monitor)

func getPhysFootprint(_ pid: Int32) -> UInt64 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
            proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), reboundPtr)
        }
    }
    return result == 0 ? info.ri_phys_footprint : 0
}

// MARK: - Top Processes by Memory

/// Start time in microseconds since the epoch; nil for processes we may not
/// inspect (other users' — which we could not signal anyway).
func processStartTime(_ pid: Int32) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

/// `ps` stays deliberately: proc_pid_rusage / proc_pidinfo are refused for
/// processes owned by other users (WindowServer, mds_stores, launchd, ~160
/// daemons), while the system `ps` can still report their RSS. Dropping it
/// would hide them from the list. It only runs while the panel is open.
/// Returns nil if `ps` could not be run, so the panel keeps the last list.
func readTopProcesses(limit: Int = 30) -> [ProcessMemory]? {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-eo", "pid,rss,pcpu,comm", "-r"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch {
        logger.error("Could not run /bin/ps: \(error.localizedDescription, privacy: .public)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
        logger.error("/bin/ps exited with status \(proc.terminationStatus)")
        return nil
    }

    var results: [ProcessMemory] = []
    let lines = output.split(separator: "\n").dropFirst() // skip header

    // Scan every process. `ps -r` orders by CPU, so any cap here silently drops
    // idle-but-memory-heavy processes from what is a memory panel. A full
    // proc_pid_rusage sweep over ~500 PIDs costs single-digit milliseconds.
    for line in lines {
        let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard cols.count >= 4 else { continue }
        guard let pid = Int(cols[0]) else { continue }
        guard let rssKB = Double(cols[1]) else { continue }
        guard let cpu = Double(cols[2]) else { continue }
        var name = String(cols[3])
        if let lastSlash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: lastSlash)...])
        }
        // Use physical footprint (accurate) instead of RSS (inflated by shared pages)
        let footprint = getPhysFootprint(Int32(pid))
        let mb = footprint > 0 ? Double(footprint) / 1_048_576.0 : rssKB / 1024.0
        if mb < 1 { continue }
        results.append(ProcessMemory(id: "\(name).\(pid)", name: name, pid: pid, residentMB: mb, cpuPercent: cpu))
    }

    // Aggregate by process name
    var aggregated: [String: (totalMB: Double, totalCPU: Double, pids: [Int], count: Int, starts: [Int: UInt64])] = [:]
    for p in results {
        var entry = aggregated[p.name] ?? (totalMB: 0, totalCPU: 0, pids: [], count: 0, starts: [:])
        entry.starts[p.pid] = processStartTime(Int32(p.pid))
        entry.totalMB += p.residentMB
        entry.totalCPU += p.cpuPercent
        entry.pids.append(p.pid)
        entry.count += 1
        aggregated[p.name] = entry
    }

    return aggregated.map { name, data in
        let displayName = data.count > 1 ? "\(name) (\(data.count))" : name
        return ProcessMemory(id: name, name: displayName, pid: data.pids.first ?? 0,
                      residentMB: data.totalMB, cpuPercent: data.totalCPU,
                      executable: name, pids: data.pids.sorted(), startTimes: data.starts)
    }
    .sorted { $0.residentMB > $1.residentMB }
    .prefix(limit)
    .map { $0 }
}

// MARK: - Killing processes

enum TerminationMode: Sendable {
    /// Asks politely: apps get a normal quit (and may prompt to save),
    /// everything else gets SIGTERM.
    case quit
    /// Cannot be refused: SIGKILL. Unsaved work is lost.
    case forceQuit

    var verb: String { self == .quit ? "Quit" : "Force Quit" }
}

struct TerminationOutcome {
    var signalled = 0
    var denied = 0     // EPERM: owned by another user (root, _windowserver, ...)
    var gone = 0       // exited already, or the PID now belongs to something else
    var protected = 0  // Statter itself, launchd, kernel_task

    var summary: String {
        var parts: [String] = []
        if signalled > 0 { parts.append(signalled == 1 ? "Sent to 1 process" : "Sent to \(signalled) processes") }
        if denied > 0 { parts.append("\(denied) not permitted (owned by another user)") }
        if gone > 0 { parts.append("\(gone) already gone") }
        if protected > 0 { parts.append("\(protected) protected") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: " \u{2022} ")
    }
}


/// Processes whose death ends the session rather than just an app.
let sessionCriticalProcesses: Set<String> = ["loginwindow", "WindowServer"]

@MainActor
func terminate(_ proc: ProcessMemory, mode: TerminationMode) -> TerminationOutcome {
    var outcome = TerminationOutcome()
    let me = getpid()
    for raw in proc.pids {
        let pid = pid_t(raw)
        guard pid > 1, pid != me else { outcome.protected += 1; continue }

        // The list is a few seconds old. If the PID has exited and been reused,
        // the start time will not match — never signal a stranger. (Names are
        // no good for this: ps reports argv[0], e.g. `-zsh` or `python` for a
        // binary called `zsh` or `python3.13`.) Without a recorded start time
        // we could not inspect the process, and kill() will be refused too.
        if let expected = proc.startTimes[raw] {
            guard processStartTime(pid) == expected else { outcome.gone += 1; continue }
        }

        // GUI apps get the same treatment as Quit / Force Quit in the Dock.
        if let app = NSRunningApplication(processIdentifier: pid) {
            let sent = mode == .quit ? app.terminate() : app.forceTerminate()
            if sent { outcome.signalled += 1; continue }
        }

        if kill(pid, mode == .quit ? SIGTERM : SIGKILL) == 0 {
            outcome.signalled += 1
        } else if errno == EPERM {
            outcome.denied += 1
        } else {
            outcome.gone += 1
        }
    }
    logger.notice("\(mode.verb, privacy: .public) \(proc.executable, privacy: .public) pids \(proc.pids, privacy: .public): \(outcome.summary, privacy: .public)")
    return outcome
}

// MARK: - Monitor

@Observable @MainActor
final class SystemMonitor {
    var memoryStats = MemoryStats.empty
    /// Nil when the GPU cannot be read (non-Apple-Silicon, registry changes);
    /// the UI shows a dash rather than a convincing 0%.
    var gpuStats: GPUStats?
    var cpuStats = CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100, logicalCores: 0, performanceCores: 0, efficiencyCores: 0)
    var networkStats = NetworkStats(downBytesPerSec: 0, upBytesPerSec: 0, hasBaseline: false)
    var processes: [ProcessMemory] = []
    var processSortKey: ProcessSortKey = .memory
    var processSortAscending: Bool = false

    /// Called on the main actor after each sample lands, so non-SwiftUI
    /// observers (the menu bar item) can refresh too.
    @ObservationIgnored var onUpdate: (() -> Void)?

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?

    private static let sampleInterval: Duration = .seconds(2)
    private static let processInterval: Duration = .seconds(3)

    init() {
        // The menu bar shows memory all the time, so this loop never stops.
        // Each iteration awaits its sample before sleeping, so samples can
        // never pile up behind a slow read.
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let sampler = self?.sampler else { return }
                let sample = await sampler.sample()
                self?.apply(sample)
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    private func apply(_ sample: SystemSample) {
        // Memory and CPU reads essentially never fail; if one does, it has
        // been logged and the last good value stays up.
        if let mem = sample.memory { memoryStats = mem }
        if let cpu = sample.cpu { cpuStats = cpu }
        if let net = sample.network { networkStats = net }
        gpuStats = sample.gpu
        onUpdate?()
    }

    /// The process list is only visible in the panel, and a full scan
    /// (`ps` plus a proc_pid_rusage per PID) is the heaviest thing Statter
    /// does — so it runs only while the panel is open.
    func setPanelVisible(_ visible: Bool) {
        processTask?.cancel()
        processTask = nil
        guard visible else { return }
        processTask = Task { [weak self] in
            while !Task.isCancelled {
                let procs = await Self.scanProcesses()
                guard !Task.isCancelled, let self else { return }
                if let procs { self.processes = self.sortProcesses(procs) }
                try? await Task.sleep(for: Self.processInterval)
            }
        }
    }

    /// After a kill, rescan shortly so the row disappears without waiting for
    /// the next tick. The delay gives a quitting app a moment to exit.
    func rescanProcessesSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.processTask != nil else { return }
            self.setPanelVisible(true)  // restarts the loop with an immediate scan
        }
    }

    /// nonisolated + async: runs on the global executor, off the main thread.
    nonisolated private static func scanProcesses() async -> [ProcessMemory]? {
        readTopProcesses()
    }

    func sortProcesses(_ procs: [ProcessMemory]) -> [ProcessMemory] {
        // Every comparator below is ascending, so the chevron direction and the
        // actual order always agree.
        let ascending: [ProcessMemory]
        switch processSortKey {
        case .memory: ascending = procs.sorted { $0.residentMB < $1.residentMB }
        case .cpu: ascending = procs.sorted { $0.cpuPercent < $1.cpuPercent }
        case .name: ascending = procs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: ascending = procs.sorted { $0.pid < $1.pid }
        }
        return processSortAscending ? ascending : ascending.reversed()
    }

    func resortProcesses() {
        processes = sortProcesses(processes)
    }
}

// MARK: - Formatting

func formatMemory(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1.0 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

func formatRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSec / 1_048_576) }
    if bytesPerSec >= 1024 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
    return String(format: "%.0f B/s", max(0, bytesPerSec))
}

func formatMB(_ mb: Double) -> String {
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
}

// MARK: - Views

struct SortButton: View {
    let label: String
    let key: ProcessSortKey
    @Binding var currentKey: ProcessSortKey
    @Binding var ascending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            if currentKey == key {
                ascending.toggle()
            } else {
                currentKey = key
                ascending = key.defaultAscending
            }
            action()
        }) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: currentKey == key ? .bold : .medium))
                if currentKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .foregroundColor(currentKey == key ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ProcessRowView: View {
    let proc: ProcessMemory
    let maxMB: Double
    let onTerminate: (TerminationMode) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(proc.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if hovering {
                    Button { onTerminate(.quit) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Quit \(proc.executable)\u{2026} (right-click for Force Quit)")
                    .accessibilityLabel("Quit \(proc.name)")
                }
                Text(formatMB(proc.residentMB))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            HStack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.purple.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.purple.opacity(0.5))
                            .frame(width: max(0, geo.size.width * CGFloat(proc.residentMB / max(maxMB, 1))))
                    }
                }
                .frame(height: 4)
                if proc.cpuPercent > 0 {
                    Text(String(format: "%.1f%% CPU", proc.cpuPercent))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Quit \(proc.name)\u{2026}") { onTerminate(.quit) }
            Button("Force Quit \(proc.name)\u{2026}") { onTerminate(.forceQuit) }
            Divider()
            Button(proc.pids.count > 1 ? "Copy PIDs" : "Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(proc.pids.map(String.init).joined(separator: " "), forType: .string)
            }
        }
    }
}

/// Inline rather than an alert: a modal would steal focus from the transient
/// popover and close it.
struct TerminationConfirmView: View {
    let proc: ProcessMemory
    let mode: TerminationMode
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var detail: String {
        var lines: [String] = []
        let count = proc.pids.count
        lines.append(count > 1 ? "\(count) processes \u{2022} \(formatMB(proc.residentMB))"
                               : "PID \(proc.pid) \u{2022} \(formatMB(proc.residentMB))")
        if sessionCriticalProcesses.contains(proc.executable) {
            lines.append("This ends your login session.")
        } else if mode == .forceQuit {
            lines.append("Unsaved work will be lost.")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(mode.verb) \(proc.executable)?")
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(mode.verb, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .tint(mode == .forceQuit ? .red : nil)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.25), lineWidth: 1))
    }
}

/// One consistent header per metric block, so MEMORY / CPU / GPU are
/// unmistakable rather than something you infer from the numbers.
/// A thin capsule gauge: the stick is the full scale, the fill is the current
/// value, and tick marks sit alongside so the scale is still readable without
/// spending width on a chunky bar.
struct VerticalCapacityBarView: View {
    let fraction: Double
    let tint: Color
    /// Five labels, zero first, full scale last.
    let scaleLabels: [String]
    var barWidth: CGFloat = 7
    var height: CGFloat = 120

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.6)],
                                         startPoint: .bottom, endPoint: .top))
                    // A visible floor so a small non-zero value still reads,
                    // but exactly zero must paint nothing.
                    .frame(height: clamped <= 0 ? 0 : max(barWidth, height * CGFloat(clamped)))
            }
            .frame(width: barWidth, height: height)

            ZStack(alignment: .topLeading) {
                ForEach(0..<scaleLabels.count, id: \.self) { i in
                    HStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.28))
                            .frame(width: 3, height: 1)
                        Text(scaleLabels[i])
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .offset(y: labelY(i))
                }
            }
            .frame(width: 42, height: height, alignment: .topLeading)
        }
    }

    /// Zero sits at the bottom, full scale at the top; both ends are clamped so
    /// the end labels are not clipped by the frame.
    private func labelY(_ i: Int) -> CGFloat {
        let steps = CGFloat(max(scaleLabels.count - 1, 1))
        let y = height - height * CGFloat(i) / steps - 5
        return min(max(y, 0), height - 10)
    }
}

struct MetricCardHeader: View {
    let title: String
    let icon: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.6)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            // fixedSize: the value must never wrap onto a second line in the
            // narrow side-by-side cards.
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(tint)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct MetricCard<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            Spacer(minLength: 0)
        }
        .padding(10)
        // maxHeight so peer cards laid out side by side share one height
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.16), lineWidth: 1))
    }
}

struct ContentView: View {
    // Owned by the AppDelegate so the menu bar item and this panel read the
    // same samples.
    @Bindable var monitor: SystemMonitor

    @State private var pendingKill: (proc: ProcessMemory, mode: TerminationMode)?
    @State private var killMessage: String?

    private var availableGB: Double {
        Double(monitor.memoryStats.availableBytes) / 1_073_741_824
    }
    private var usedPercent: Double {
        let t = monitor.memoryStats.totalBytes
        return t == 0 ? 0 : Double(monitor.memoryStats.usedBytes) / Double(t) * 100
    }
    private var memoryTint: Color {
        MemoryLevel(monitor.memoryStats).color
    }
    private var cpuTint: Color {
        let b = monitor.cpuStats.busyPercent
        if b > 85 { return .red }
        if b > 60 { return .orange }
        return .blue
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    metricRow
                    swapWarning
                }
                .padding(16)
            }
            .frame(width: 470)

            Divider()

            processSection
                .padding(12)
                .frame(width: 340)
        }
        .frame(width: 810, height: 480)
        .background(.background)
    }

    private var subtitle: String {
        let cpu = "\(monitor.cpuStats.logicalCores) CPU cores"
        guard let gpu = monitor.gpuStats else { return "\(cpu) \u{2022} GPU unavailable" }
        return "\(gpu.model) \u{2022} \(cpu) \u{2022} \(gpu.coreCount) GPU cores"
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Statter")
                    .font(.system(size: 20, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            // The app runs as an .accessory (no Dock icon, no app menu), so this
            // and the status-item right-click menu are the only ways to quit.
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .help("Quit Statter (\u{2318}Q)")
        }
    }

    // MARK: RAM gets the wide half; CPU / GPU stack beside it

    private var metricRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ramCard
            VStack(spacing: 10) {
                cpuCard
                gpuCard
                networkCard
            }
            .frame(width: 172)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Quarter marks of physical memory, e.g. 0 / 4 / 8 / 12 / 16 GB.
    private var memoryScaleLabels: [String] {
        let totalGB = Double(monitor.memoryStats.totalBytes) / 1_073_741_824
        return (0..<5).map { i in
            let v = totalGB * Double(i) / 4
            return i == 4 ? String(format: "%.0f GB", v) : String(format: "%.0f", v)
        }
    }

    private var percentScaleLabels: [String] { ["0", "25", "50", "75", "100%"] }
    /// Coarser scale for the short stacked gauges, where five labels overlap.
    private var compactPercentLabels: [String] { ["0", "50", "100%"] }

    private func cardDetail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var ramCard: some View {
        MetricCard(tint: memoryTint) {
            MetricCardHeader(title: "RAM", icon: "memorychip",
                             value: String(format: "%.0f%%", usedPercent), tint: memoryTint)

            HStack(alignment: .top, spacing: 10) {
                VerticalCapacityBarView(fraction: usedPercent / 100, tint: memoryTint,
                                        scaleLabels: memoryScaleLabels, barWidth: 9, height: 150)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(formatMemory(monitor.memoryStats.usedBytes))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(memoryTint)
                            .lineLimit(1)
                            .fixedSize()
                        Text("used")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    Text("of \(formatMemory(monitor.memoryStats.totalBytes)) total")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Divider().padding(.vertical, 3)

                    Text("\(formatMemory(monitor.memoryStats.availableBytes)) available")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(memoryTint)
                    Text("room for ~\(max(1, Int(availableGB / 2))) more large apps")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let pressure = monitor.memoryStats.pressure {
                        Text("Pressure: \(pressure.label)")
                            .font(.system(size: 10, weight: pressure == .normal ? .regular : .semibold))
                            .foregroundColor(pressure == .normal ? .secondary : MemoryLevel(pressure).color)
                            .help("The kernel\u{2019}s own memory pressure level \u{2014} what macOS acts on when it compresses, swaps or asks apps to free memory.")
                    }
                }
                Spacer(minLength: 0)
            }

            Divider().padding(.vertical, 2)

            Text("WHERE IT IS GOING")
                .font(.system(size: 10, weight: .bold))
                .kerning(1.0)
                .foregroundColor(.secondary)

            unifiedPoolBar
        }
    }

    private var cpuCard: some View {
        MetricCard(tint: cpuTint) {
            MetricCardHeader(title: "CPU", icon: "cpu",
                             value: String(format: "%.0f%%", monitor.cpuStats.busyPercent), tint: cpuTint)
            HStack(alignment: .top, spacing: 6) {
                VerticalCapacityBarView(fraction: monitor.cpuStats.busyPercent / 100, tint: cpuTint,
                                        scaleLabels: compactPercentLabels, barWidth: 6, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    cardDetail(String(format: "User %.0f%%", monitor.cpuStats.userPercent))
                    cardDetail(String(format: "Sys %.0f%%", monitor.cpuStats.systemPercent))
                    cardDetail("\(monitor.cpuStats.performanceCores)P + \(monitor.cpuStats.efficiencyCores)E")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var gpuCard: some View {
        let gpu = monitor.gpuStats
        return MetricCard(tint: .green) {
            MetricCardHeader(title: "GPU", icon: "display",
                             value: gpu.map { "\($0.deviceUtilization)%" } ?? "\u{2014}", tint: .green)
            HStack(alignment: .top, spacing: 6) {
                VerticalCapacityBarView(fraction: Double(gpu?.deviceUtilization ?? 0) / 100, tint: .green,
                                        scaleLabels: compactPercentLabels, barWidth: 6, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    if let gpu {
                        cardDetail("Rend \(gpu.rendererUtilization)%")
                        cardDetail("Tiler \(gpu.tilerUtilization)%")
                        cardDetail("\(formatMemory(gpu.allocatedMemory)) mapped")
                    } else {
                        cardDetail("Not readable on this Mac")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// No gauge: throughput has no fixed ceiling to scale a bar against, so the
    /// rates are shown as numbers rather than an invented percentage.
    private var networkCard: some View {
        MetricCard(tint: .teal) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.teal)
                Text("NETWORK")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            rateRow("arrow.down", monitor.networkStats.downBytesPerSec, .teal)
            rateRow("arrow.up", monitor.networkStats.upBytesPerSec, .orange)
        }
    }

    private func rateRow(_ icon: String, _ rate: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
            Text(formatRate(rate))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var swapWarning: some View {
        if monitor.memoryStats.swapUsedBytes > 0 {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                Text("\(formatMemory(monitor.memoryStats.swapUsedBytes)) pushed to disk \u{2014} system was under pressure recently")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(6)
        }
    }

    private var unifiedPoolBar: some View {
        let total = Double(max(monitor.memoryStats.totalBytes, 1))
        let gpu = monitor.gpuStats
        let gpuAlloc = Double(gpu?.allocatedMemory ?? 0)
        let gpuActive = Double(gpu?.inUseMemory ?? 0)
        let gpuLabel: (UInt64?) -> String = { $0.map(formatMemory) ?? "\u{2014}" }
        let available = Double(monitor.memoryStats.availableBytes)
        let gpuShown = min(gpuAlloc, total - available)
        let otherUsed = max(0, total - gpuShown - available)

        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 0) {
                    Rectangle().fill(Color.green)
                        .frame(width: max(gpuActive > 0 ? 2 : 0, w * CGFloat(gpuActive / total)))
                    Rectangle().fill(Color.green.opacity(0.3))
                        .frame(width: max(0, w * CGFloat(max(0, gpuShown - gpuActive) / total)))
                    Rectangle().fill(Color.blue.opacity(0.6))
                        .frame(width: max(0, w * CGFloat(otherUsed / total)))
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    legendSwatch(.green, "GPU active \(gpuLabel(gpu?.inUseMemory))")
                    Spacer(minLength: 0)
                    legendSwatch(.green.opacity(0.3), "GPU mapped \(gpuLabel(gpu?.allocatedMemory))")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    legendSwatch(.blue.opacity(0.6), "Apps & OS \(formatMemory(UInt64(otherUsed)))")
                    Spacer(minLength: 0)
                    legendSwatch(Color.primary.opacity(0.1), "Available \(formatMemory(UInt64(available)))")
                    Spacer(minLength: 0)
                }
            }
            .foregroundColor(.secondary)

            if let gpu, gpu.allocatedMemory > 10_000_000_000 {
                Text("GPU has mapped \(formatMemory(gpu.allocatedMemory)) of your unified memory (likely model weights for local AI). This isn\u{2019}t separate VRAM \u{2014} it\u{2019}s your RAM, shared with the GPU.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: Processes (right column)

    private func showKillMessage(_ text: String) {
        killMessage = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if killMessage == text { killMessage = nil }
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.purple)
                Text("TOP PROCESSES")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1.1)
                    .foregroundColor(.secondary)
                Spacer()
                let totalProc = monitor.processes.reduce(0.0) { $0 + $1.residentMB }
                Text("\(monitor.processes.count) \u{2022} \(formatMB(totalProc))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Text("Sort:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ForEach(ProcessSortKey.allCases, id: \.self) { key in
                    SortButton(
                        label: key.rawValue, key: key,
                        currentKey: $monitor.processSortKey,
                        ascending: $monitor.processSortAscending,
                        action: { monitor.resortProcesses() }
                    )
                }
            }

            if let pending = pendingKill {
                TerminationConfirmView(
                    proc: pending.proc, mode: pending.mode,
                    onConfirm: {
                        let outcome = terminate(pending.proc, mode: pending.mode)
                        pendingKill = nil
                        showKillMessage(outcome.summary)
                        monitor.rescanProcessesSoon()
                    },
                    onCancel: { pendingKill = nil })
            } else if let message = killMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            let maxMB = monitor.processes.map(\.residentMB).max() ?? 1.0

            if monitor.processes.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading\u{2026}")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    // Plain VStack, not Lazy: re-measuring a LazyVStack when the
                    // process list refreshes yanks the scroll position.
                    VStack(spacing: 0) {
                        ForEach(monitor.processes) { proc in
                            ProcessRowView(proc: proc, maxMB: maxMB) { mode in
                                pendingKill = (proc, mode)
                                killMessage = nil
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - App Delegate for Menu Bar

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let monitor = SystemMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // variableLength: the item has to grow to fit the live readout.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Statter")
            button.imagePosition = .imageLeading
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let popover = NSPopover()
        // Must match ContentView's frame, or the popover shows dead space.
        popover.contentSize = NSSize(width: 810, height: 480)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
        self.popover = popover

        monitor.onUpdate = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()

        NSApp.setActivationPolicy(.accessory)
    }

    /// A small used/total gauge drawn for the menu bar, so the ratio is legible
    /// at a glance without reading the digits.
    private func gaugeImage(fraction: Double, color: NSColor) -> NSImage {
        let w: CGFloat = 26, h: CGFloat = 12
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let track = NSRect(x: 0.5, y: 1.5, width: w - 1, height: h - 3)
            let trackPath = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            trackPath.fill()

            let inner = track.insetBy(dx: 1.5, dy: 1.5)
            let fillW = max(1.5, inner.width * CGFloat(min(max(fraction, 0), 1)))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                             width: fillW, height: inner.height),
                         xRadius: 1.5, yRadius: 1.5).fill()

            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            trackPath.lineWidth = 1
            trackPath.stroke()
            return true
        }
        image.isTemplate = false   // keep the threshold colour
        return image
    }

    /// The menu bar chip, tinted by headroom level. Tinting means the symbol can
    /// no longer be a template image, so each level is drawn once and cached —
    /// this runs on every sample.
    private var chipCache: [MemoryLevel: NSImage] = [:]

    private func chipImage(for level: MemoryLevel) -> NSImage? {
        if let cached = chipCache[level] { return cached }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let base = NSImage(systemSymbolName: "memorychip",
                                 accessibilityDescription: "Statter")?
            .withSymbolConfiguration(cfg) else { return nil }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            level.nsColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false   // keep the threshold colour
        chipCache[level] = tinted
        return tinted
    }

    /// Redraws the menu bar readout. Called on the main queue after each sample.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let mem = monitor.memoryStats

        // Before the first sample lands there is nothing honest to show.
        guard mem.totalBytes > 0 else { return }

        let level = MemoryLevel(mem)
        let usedFraction = Double(mem.usedBytes) / Double(mem.totalBytes)

        // The chip carries the headroom colour; the digits stay in the menu bar's
        // own label colour so they read like every other item up there rather
        // than as an alert. Monospaced digits, otherwise the item resizes every
        // 2 seconds and shoves the rest of the menu bar around.
        button.image = chipImage(for: level)
        button.imagePosition = .imageLeading
        let usedGB = Double(mem.usedBytes) / 1_073_741_824
        let totalGB = Double(mem.totalBytes) / 1_073_741_824
        button.attributedTitle = NSAttributedString(
            string: String(format: " %.1f/%.0f GB", usedGB, totalGB),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        button.toolTip = """
        Statter
        \(formatMemory(mem.usedBytes)) RAM used of \(formatMemory(mem.totalBytes)) (\(Int(usedFraction * 100))%)
        \(formatMemory(mem.availableBytes)) available
        \(mem.pressure.map { "Memory pressure: \($0.label)" } ?? "Memory pressure: unknown")
        \(monitor.gpuStats.map { "GPU \($0.deviceUtilization)% \u{2022} \(formatMemory($0.allocatedMemory)) mapped" } ?? "GPU unavailable")
        """
    }

    /// Left click toggles the panel; right click opens a menu so the app can
    /// always be quit even if the panel fails to open.
    @objc func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Quit Statter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePopover()
    }

    // The process scan follows the panel: started as it opens, stopped as it
    // closes, whichever way it was dismissed.
    func popoverWillShow(_ notification: Notification) { monitor.setPanelVisible(true) }
    func popoverDidClose(_ notification: Notification) { monitor.setPanelVisible(false) }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - App Entry Point

@main
struct StatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
