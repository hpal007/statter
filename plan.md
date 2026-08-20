# gpuer — Modernization & Improvement Plan

A build spec to upgrade Simon Willison's `gpuer` (single-file SwiftUI menu-bar
RAM/GPU monitor, ~880 lines, ~5 months old) to current SwiftUI recommendations,
fix known correctness bugs, and add features for an always-on `.app`.

- Repo: https://github.com/simonw/gpuer
- Write-up: https://simonwillison.net/2026/Mar/27/vibe-coding-swiftui/

---

## Goal
A single modernized `GpuerApp.swift` that is:
- Built on the latest SwiftUI menu-bar + state APIs (no legacy AppKit glue)
- Free of subprocess/text-parsing (reads system interfaces directly)
- Correct on memory math and memory pressure
- Race-free in sampling
- Richer in data representation (real charts + gauges)
- Shippable as a proper always-on `.app` with launch-at-login

---

## Baseline — what the app does today
| Layer | Current implementation |
|-------|------------------------|
| Menu bar shell | `NSStatusItem` + `NSPopover` + `NSHostingController` + `NSApplicationDelegate` |
| State | `SystemMonitor: ObservableObject` with `@Published` arrays |
| Refresh | Two `Timer.scheduledTimer` loops (2s mem/GPU, 5s processes) → GCD |
| GPU data | Spawns `ioreg -r -c AGXAccelerator` and parses text output |
| Memory pressure | Spawns `memory_pressure`, parses `"free percentage: XX%"` |
| Memory stats | `sysctlbyname(hw.memsize)`, `host_statistics64()`, `vm.swapusage` |
| Processes | `/bin/ps` + `proc_pid_rusage(RUSAGE_INFO_V4)` per PID |
| Charts | Hand-rolled `SparklineView` (Path in a `GeometryReader`) |

Weakest spots map exactly to the goals: **legacy shell, fragile text-parsing,
hand-drawn charts.**

---

## Tier 1 — Correctness fixes (do these regardless)

1. **Read IOKit directly instead of parsing `ioreg` text.**
   - `IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))`
   - `IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics", …)` → dictionary
     with `Device Utilization %`, `In use system memory`, `Alloc system memory`.
   - Wins: no subprocess, no parsing fragility, instant, can't break on OS output changes.

2. **Fix "available memory" math (the 5 GB bug).**
   - Match Activity Monitor: **Memory Used = App (anonymous) + Wired + Compressed**;
     treat **purgeable + file-backed (external) pages as available**.
   - From `host_statistics64` (`vm_statistics64`) use `internal_page_count`,
     `wire_count`, `compressor_page_count`, `external_page_count`, `purgeable_count`
     — not a raw free-page count.

3. **Use the real memory-pressure signal, not a parsed percentage.**
   - `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`
     (or read `kern.memorystatus_vm_pressure_level`).
   - Removes the `memory_pressure` subprocess and matches what the OS itself acts on.

4. **De-dupe processes by PID, not by binary name.**
   - Key on PID; optionally group under a display name but keep identity distinct
     (fixes merging unrelated `Helper` processes).

5. **Surface errors with unified logging.**
   - Replace silent `catch { return 0 }` with `os.Logger` so failed reads are visible
     instead of showing a plausible-but-wrong zero.

---

## Tier 2 — Modern architecture (latest SwiftUI recommendations)

1. **`MenuBarExtra` (SwiftUI, macOS 13+)** replaces the whole
   `NSStatusItem` + `NSPopover` + `NSHostingController` + `AppDelegate` stack.
   - Use `.menuBarExtraStyle(.window)` for the popover-style panel.
   - The label can be **live text** → show the actual number (`12.3 GB`, `GPU 47%`)
     right in the menu bar (the glanceable "always available" readout).

2. **Observation framework (`@Observable`, macOS 14+)** replaces
   `ObservableObject` / `@Published`.
   - Less boilerplate, fine-grained updates (only views reading a changed field re-render).
   - Hold with `@State private var monitor = SystemMonitor()` in the `App`.

3. **Swift Concurrency instead of `Timer` + GCD.** One `@MainActor` model with a
   background sampling `Task` loop:
   ```swift
   while !Task.isCancelled {
       let sample = await sampler.read()   // nonisolated / off-main
       apply(sample)                       // back on main
       try await Task.sleep(for: .seconds(interval))
   }
   ```
   - Structurally fixes the "timer fires before previous read finishes" race.
   - Lets you pause sampling when the panel is closed.

4. **Swift 6 strict concurrency / actor-isolate the sampler** so data collection is
   provably off the main thread.

---

## Tier 3 — Better data representation

1. **Swift Charts (macOS 13+)** replaces the hand-drawn `SparklineView`.
   - `LineMark` / `AreaMark` for real time axes, gradient fills,
     hover-to-read exact value at a timestamp. Less code, more useful.
2. **SwiftUI `Gauge`** for GPU utilization and memory headroom (radial/linear beats a bare number).
3. **Honest unified-memory bar.** Don't draw GPU-mapped and Apps/OS as non-overlapping
   — on Apple Silicon they overlap. Represent the shared region explicitly
   (layered/hatched "shared" segment) or annotate it.
4. **Color-blind-safe semantic palette** (`.green/.orange/.red` via semantic roles)
   so thresholds survive light/dark and accessibility settings.

---

## Tier 4 — Features to add

1. **Launch-at-login in-app** via `SMAppService.mainApp.register()`
   (ServiceManagement, macOS 13+) — a toggle inside the app, no manual System Settings.
2. **`Settings` scene** (SwiftUI): refresh interval, units (GB/GiB),
   which metric shows in the menu bar, login toggle.
3. **Threshold notifications** (`UserNotifications`): ping on warn/critical pressure
   or when available RAM drops below a threshold (useful during heavy local LLM/ETL jobs).
4. **Proper signed `.app`** with icon + version string for the always-on build.

---

## Target shape
A single modernized `GpuerApp.swift`:
- `@main struct GpuerApp: App` → `MenuBarExtra` (live-value label) + `Settings` scene
- `@Observable @MainActor final class SystemMonitor` → owns state + async sampling loop
- `actor MetricsSampler` → IOKit/Mach reads, **zero subprocesses**
- SwiftUI `Charts` + `Gauge` views for display

**Net effect:** fewer lines, no shell-outs, race-free sampling, correct memory math,
and a live menu-bar number.

---

## Suggested sequencing
1. Tier 1 (correctness) + Tier 2 (MenuBarExtra / Observation / async) — core rewrite.
2. Tier 3 (Charts + Gauges).
3. Tier 4 features (login toggle, CSV/SQLite logging, alerts), then package the signed `.app`.

## Minimum-OS note
`@Observable` + Swift Charts favor **macOS 14+**. If you must support macOS 13,
fall back to `ObservableObject` (Charts is still fine on 13).
