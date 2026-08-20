import SwiftUI
import AppKit
import Darwin
import Foundation
import IOKit

// MARK: - Data Models

/// Subtraction that clamps at zero. The VM page counters are sampled
/// independently and are not guaranteed to be mutually consistent, so plain
/// `-` on UInt64 can trap at runtime.
func saturatingSub(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }

struct MemoryStats {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let appBytes: UInt64  // approximate app-associated memory
    let swapUsedBytes: UInt64

    var usedFraction: Double { Double(usedBytes) / Double(max(totalBytes, 1)) }
    var freeFraction: Double { Double(freeBytes) / Double(max(totalBytes, 1)) }
    var availableBytes: UInt64 { saturatingSub(totalBytes, usedBytes) }  // everything OS can reclaim
    var availableFraction: Double { Double(availableBytes) / Double(max(totalBytes, 1)) }
}

struct NetworkStats {
    let downBytesPerSec: Double
    let upBytesPerSec: Double
    let hasBaseline: Bool
}

struct CPUStats {
    let userPercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let logicalCores: Int
    let performanceCores: Int
    let efficiencyCores: Int

    var busyPercent: Double { min(100, max(0, 100 - idlePercent)) }
}

struct GPUStats {
    let deviceUtilization: Int
    let rendererUtilization: Int
    let tilerUtilization: Int
    let inUseMemory: UInt64
    let allocatedMemory: UInt64
    let coreCount: Int
    let model: String
}

struct ProcessMemory: Identifiable {
    let id: String
    let name: String
    let pid: Int
    let residentMB: Double
    let cpuPercent: Double
}

/// Headroom thresholds. Shared so the menu bar gauge and the panel can never
/// disagree about what colour the machine is.
enum MemoryLevel {
    case ok, warn, critical

    init(availableFraction f: Double) {
        if f > 0.30 { self = .ok }
        else if f > 0.15 { self = .warn }
        else { self = .critical }
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

func getSwapUsage() -> UInt64 {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
    return swap.xsu_used
}

func readMemoryStats() -> MemoryStats {
    let total = getPhysicalMemory()
    let pageSize = UInt64(vm_kernel_page_size)

    guard let vm = getVMStats() else {
        return MemoryStats(totalBytes: total, usedBytes: 0, activeBytes: 0, inactiveBytes: 0,
                           wiredBytes: 0, compressedBytes: 0, freeBytes: total, appBytes: 0,
                           swapUsedBytes: 0)
    }

    let active = UInt64(vm.active_count) * pageSize
    let inactive = UInt64(vm.inactive_count) * pageSize
    let wired = UInt64(vm.wire_count) * pageSize
    let compressed = UInt64(vm.compressor_page_count) * pageSize
    let _ = UInt64(vm.speculative_count) * pageSize
    let _ = UInt64(vm.free_count) * pageSize
    let purgeable = UInt64(vm.purgeable_count) * pageSize

    // Used memory matching Activity Monitor: app memory + wired + compressed
    // Inactive, speculative, purgeable, and free pages are all reclaimable.
    // purgeable_count spans every queue while active_count does not, so this
    // subtraction can go negative and must be clamped.
    let appMem = saturatingSub(active, purgeable)
    let usedApprox = min(appMem + wired + compressed, total)
    let swap = getSwapUsage()

    return MemoryStats(
        totalBytes: total, usedBytes: usedApprox, activeBytes: active,
        inactiveBytes: inactive, wiredBytes: wired, compressedBytes: compressed,
        freeBytes: saturatingSub(total, usedApprox), appBytes: appMem,
        swapUsedBytes: swap
    )
}

// MARK: - Network throughput via getifaddrs

private var previousNetSample: (rx: UInt64, tx: UInt64, at: Date)?
private let netSampleLock = NSLock()

/// Sums byte counters across every non-loopback interface. Like CPU, throughput
/// is a rate, so the first call after launch only establishes a baseline.
func readNetworkStats() -> NetworkStats {
    var rx: UInt64 = 0, tx: UInt64 = 0
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
        return NetworkStats(downBytesPerSec: 0, upBytesPerSec: 0, hasBaseline: false)
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

    let now = Date()
    netSampleLock.lock()
    let previous = previousNetSample
    previousNetSample = (rx, tx, now)
    netSampleLock.unlock()

    guard let prev = previous else {
        return NetworkStats(downBytesPerSec: 0, upBytesPerSec: 0, hasBaseline: false)
    }
    let elapsed = now.timeIntervalSince(prev.at)
    guard elapsed > 0 else {
        return NetworkStats(downBytesPerSec: 0, upBytesPerSec: 0, hasBaseline: true)
    }

    // ifi_ibytes / ifi_obytes are 32-bit and wrap every 4 GB. A wrap shows up as
    // the sum going backwards; drop that one sample rather than report a spike.
    let down = rx >= prev.rx ? Double(rx - prev.rx) / elapsed : 0
    let up = tx >= prev.tx ? Double(tx - prev.tx) / elapsed : 0
    return NetworkStats(downBytesPerSec: down, upBytesPerSec: up, hasBaseline: true)
}

// MARK: - CPU Stats via Mach

private var previousCPUTicks: host_cpu_load_info?
private let cpuTicksLock = NSLock()

func sysctlInt(_ name: String) -> Int {
    var value: Int32 = 0
    var len = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return 0 }
    return Int(value)
}

/// CPU utilisation is a rate, so it only exists relative to the previous
/// sample. The first call after launch has no baseline and reports idle.
func readCPUStats() -> CPUStats {
    let logical = sysctlInt("hw.logicalcpu")
    let pCores = sysctlInt("hw.perflevel0.logicalcpu")
    let eCores = sysctlInt("hw.perflevel1.logicalcpu")

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
        return CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100,
                        logicalCores: logical, performanceCores: pCores, efficiencyCores: eCores)
    }

    cpuTicksLock.lock()
    let previous = previousCPUTicks
    previousCPUTicks = info
    cpuTicksLock.unlock()

    guard let prev = previous else {
        return CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100,
                        logicalCores: logical, performanceCores: pCores, efficiencyCores: eCores)
    }

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

    guard total > 0 else {
        return CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100,
                        logicalCores: logical, performanceCores: pCores, efficiencyCores: eCores)
    }

    return CPUStats(userPercent: (user + nice) / total * 100,
                    systemPercent: system / total * 100,
                    idlePercent: idle / total * 100,
                    logicalCores: logical, performanceCores: pCores, efficiencyCores: eCores)
}

// MARK: - GPU Stats via IOKit

func readGPUStats() -> GPUStats {
    var model = "Unknown"
    var coreCount = 0
    var deviceUtil = 0
    var rendererUtil = 0
    var tilerUtil = 0
    var inUse: UInt64 = 0
    var allocated: UInt64 = 0

    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    proc.arguments = ["-r", "-c", "AGXAccelerator", "-d", "2"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "Unknown") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8) else {
        return GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "Unknown")
    }

    // Parse model
    if let range = output.range(of: "\"model\" = \"") {
        let after = output[range.upperBound...]
        if let end = after.firstIndex(of: "\"") {
            model = String(after[after.startIndex..<end])
        }
    }

    // Parse gpu-core-count
    if let range = output.range(of: "\"gpu-core-count\" = ") {
        let after = output[range.upperBound...]
        let numStr = after.prefix(while: { $0.isNumber })
        coreCount = Int(numStr) ?? 0
    }

    // Parse PerformanceStatistics
    if let range = output.range(of: "\"PerformanceStatistics\" = {") {
        let after = output[range.upperBound...]
        if let end = after.firstIndex(of: "}") {
            let block = String(after[after.startIndex..<end])
            func extractInt(_ key: String) -> Int {
                if let r = block.range(of: "\"\(key)\"=") {
                    let a = block[r.upperBound...]
                    let numStr = a.prefix(while: { $0.isNumber || $0 == "-" })
                    return Int(numStr) ?? 0
                }
                return 0
            }
            func extractUInt64(_ key: String) -> UInt64 {
                if let r = block.range(of: "\"\(key)\"=") {
                    let a = block[r.upperBound...]
                    let numStr = a.prefix(while: { $0.isNumber })
                    return UInt64(numStr) ?? 0
                }
                return 0
            }
            deviceUtil = extractInt("Device Utilization %")
            rendererUtil = extractInt("Renderer Utilization %")
            tilerUtil = extractInt("Tiler Utilization %")
            inUse = extractUInt64("In use system memory")
            allocated = extractUInt64("Alloc system memory")
        }
    }

    return GPUStats(deviceUtilization: deviceUtil, rendererUtilization: rendererUtil,
                    tilerUtilization: tilerUtil, inUseMemory: inUse, allocatedMemory: allocated,
                    coreCount: coreCount, model: model)
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

func readTopProcesses(limit: Int = 30) -> [ProcessMemory] {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-eo", "pid,rss,pcpu,comm", "-r"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

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
    var aggregated: [String: (totalMB: Double, totalCPU: Double, pids: [Int], count: Int)] = [:]
    for p in results {
        var entry = aggregated[p.name] ?? (totalMB: 0, totalCPU: 0, pids: [], count: 0)
        entry.totalMB += p.residentMB
        entry.totalCPU += p.cpuPercent
        entry.pids.append(p.pid)
        entry.count += 1
        aggregated[p.name] = entry
    }

    return aggregated.map { name, data in
        let displayName = data.count > 1 ? "\(name) (\(data.count))" : name
        return ProcessMemory(id: name, name: displayName, pid: data.pids.first ?? 0,
                      residentMB: data.totalMB, cpuPercent: data.totalCPU)
    }
    .sorted { $0.residentMB > $1.residentMB }
    .prefix(limit)
    .map { $0 }
}

// MARK: - Monitor

class SystemMonitor: ObservableObject {
    @Published var memoryStats = MemoryStats(totalBytes: 0, usedBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, freeBytes: 0, appBytes: 0, swapUsedBytes: 0)
    @Published var gpuStats = GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "")
    @Published var cpuStats = CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100, logicalCores: 0, performanceCores: 0, efficiencyCores: 0)
    @Published var networkStats = NetworkStats(downBytesPerSec: 0, upBytesPerSec: 0, hasBaseline: false)
    @Published var processes: [ProcessMemory] = []
    @Published var processSortKey: ProcessSortKey = .memory
    @Published var processSortAscending: Bool = false

    /// Called on the main queue after each sample lands, so non-SwiftUI
    /// observers (the menu bar item) can refresh too.
    var onUpdate: (() -> Void)?

    private var fastTimer: Timer?
    private var slowTimer: Timer?

    init() {
        refresh()
        refreshProcesses()
        // Memory + GPU stats every 2s
        fastTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Process list every 5s (ps is heavier)
        slowTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshProcesses()
        }
    }

    deinit {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mem = readMemoryStats()
            let gpu = readGPUStats()
            let cpu = readCPUStats()
            let net = readNetworkStats()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.memoryStats = mem
                self.gpuStats = gpu
                self.cpuStats = cpu
                self.networkStats = net

                self.onUpdate?()
            }
        }
    }

    func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let procs = readTopProcesses()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.processes = self.sortProcesses(procs)
            }
        }
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

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(proc.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
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
    @ObservedObject var monitor: SystemMonitor

    private var availableGB: Double {
        Double(monitor.memoryStats.availableBytes) / 1_073_741_824
    }
    private var usedPercent: Double {
        let t = monitor.memoryStats.totalBytes
        return t == 0 ? 0 : Double(monitor.memoryStats.usedBytes) / Double(t) * 100
    }
    private var memoryTint: Color {
        MemoryLevel(availableFraction: monitor.memoryStats.availableFraction).color
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Statter")
                    .font(.system(size: 20, weight: .bold))
                Text("\(monitor.gpuStats.model) \u{2022} \(monitor.cpuStats.logicalCores) CPU cores \u{2022} \(monitor.gpuStats.coreCount) GPU cores")
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
        MetricCard(tint: .green) {
            MetricCardHeader(title: "GPU", icon: "display",
                             value: "\(monitor.gpuStats.deviceUtilization)%", tint: .green)
            HStack(alignment: .top, spacing: 6) {
                VerticalCapacityBarView(fraction: Double(monitor.gpuStats.deviceUtilization) / 100, tint: .green,
                                        scaleLabels: compactPercentLabels, barWidth: 6, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    cardDetail("Rend \(monitor.gpuStats.rendererUtilization)%")
                    cardDetail("Tiler \(monitor.gpuStats.tilerUtilization)%")
                    cardDetail("\(formatMemory(monitor.gpuStats.allocatedMemory)) mapped")
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
        let gpuAlloc = Double(monitor.gpuStats.allocatedMemory)
        let gpuActive = Double(monitor.gpuStats.inUseMemory)
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
                    legendSwatch(.green, "GPU active \(formatMemory(monitor.gpuStats.inUseMemory))")
                    Spacer(minLength: 0)
                    legendSwatch(.green.opacity(0.3), "GPU mapped \(formatMemory(monitor.gpuStats.allocatedMemory))")
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

            if monitor.gpuStats.allocatedMemory > 10_000_000_000 {
                Text("GPU has mapped \(formatMemory(monitor.gpuStats.allocatedMemory)) of your unified memory (likely model weights for local AI). This isn\u{2019}t separate VRAM \u{2014} it\u{2019}s your RAM, shared with the GPU.")
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
                            ProcessRowView(proc: proc, maxMB: maxMB)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - App Delegate for Menu Bar

class AppDelegate: NSObject, NSApplicationDelegate {
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

    /// Redraws the menu bar readout. Called on the main queue after each sample.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let mem = monitor.memoryStats

        // Before the first sample lands there is nothing honest to show.
        guard mem.totalBytes > 0 else { return }

        let level = MemoryLevel(availableFraction: mem.availableFraction)
        let usedFraction = Double(mem.usedBytes) / Double(mem.totalBytes)

        // Numbers only. Monospaced digits, otherwise the item resizes every
        // 2 seconds and shoves the rest of the menu bar around.
        button.image = nil
        let usedGB = Double(mem.usedBytes) / 1_073_741_824
        let totalGB = Double(mem.totalBytes) / 1_073_741_824
        button.attributedTitle = NSAttributedString(
            string: String(format: "%.1f/%.0f GB", usedGB, totalGB),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: level.nsColor,
            ]
        )

        button.toolTip = """
        Statter
        \(formatMemory(mem.usedBytes)) RAM used of \(formatMemory(mem.totalBytes)) (\(Int(usedFraction * 100))%)
        \(formatMemory(mem.availableBytes)) available
        GPU \(monitor.gpuStats.deviceUtilization)% \u{2022} \(formatMemory(monitor.gpuStats.allocatedMemory)) mapped
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

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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
