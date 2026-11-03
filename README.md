# Statter

SwiftUI menu bar app for monitoring macOS GPU and memory stats.

![Screenshot of the Statter app on macOS showing memory usage for an Apple M5 Max with 40 GPU cores. Left panel: a large orange "38 GB Available" readout showing usage of 128.0 GB unified memory, "Room for ~18 more large apps before pressure", a warning banner reading "1.5 GB pushed to disk — system was under pressure recently", a horizontal segmented bar chart labeled "Where your memory is going" with green, blue, and grey segments and a legend, an explanatory note about GPU unified memory, a GPU Utilization section showing 0%, and a History graph showing Available and GPU Utilization over time as line charts. Right panel: a Memory Footprint list sorted by Memory, showing process names with horizontal pink/purple usage bars and CPU percentage labels beside each entry, covering processes including Dropbox, WebKit, Virtualization, node, Claude Helper, Safari, LM Studio, WindowServer, Finder, and others.](screenshot.png)

## Features

- **Live menu bar numbers** — `10.6/16 GB` in the menu bar beside a chip icon that carries the headroom colour (green / orange / red), so the digits stay in the normal menu bar colour and only the icon signals pressure. Hover for the full breakdown.
- **RAM gets the wide half** of the panel: a thin stick gauge scaled to physical memory with tick marks alongside, the used/total/available figures, and the "where it is going" breakdown, all in one card.
- **CPU and GPU stack beside it** as compact cards, each with the same thin stick gauge, so all three read on one visual grammar without spending width on chunky bars.
- **Network throughput** — live download and upload rates from `getifaddrs` byte counters.
- **"Where it is going"** — a unified memory pool visualization showing GPU-mapped memory, apps/OS, and available space as competing claims on one shared pool — no more pretending GPU has its own VRAM
- Live Apple Silicon GPU utilization read straight from the `AGXAccelerator` IORegistry entry — no `ioreg` subprocess
- **Kernel memory pressure** (`kern.memorystatus_vm_pressure_level`) shown in the RAM card and folded into the chip colour
- **Physical footprint** for per-process memory (the same metric Activity Monitor uses) instead of RSS, which inflates numbers by counting shared pages multiple times
- Swap usage with contextual explanation
- **System-wide CPU utilization** with user/system split and P/E core counts, read from `host_statistics(HOST_CPU_LOAD_INFO)`

## How measurement works

Statter uses public macOS system interfaces rather than private frameworks. The only subprocess is `ps`, and it only runs while the panel is open (see below).

### Sampling

- One `@Observable` model on the main actor. A single `Task` loop asks a `SystemSampler` actor for a sample every 2 seconds, so reads happen off the main thread and a slow read can never overlap the next one.
- The process list has its own loop (every 3 seconds) that starts when the panel opens and stops when it closes. With the panel closed, Statter spawns no processes at all.
- The app compiles in Swift 6 language mode, so data races are compile errors.
- Failed reads go to the unified log (`log stream --predicate 'subsystem == "com.hpal007.statter"'`) instead of silently turning into zeros; an unreadable GPU shows `—`.

### Memory

- Total physical memory comes from `sysctl hw.memsize`.
- Memory breakdown comes from `host_statistics64(HOST_VM_INFO64)`, using page counters such as active, inactive, wired, compressed, speculative, free, and purgeable.
- **Available memory** is computed as `total - used`, where used follows Activity Monitor's formula: `used = app memory + wired + compressed`, with app memory taken as `active - purgeable`. Inactive, speculative, purgeable, and free pages are all treated as available, because macOS can reclaim them on demand. Every subtraction is clamped at zero and `used` is capped at physical RAM, since the page counters are sampled independently and are not guaranteed to be mutually consistent.
- Swap usage comes from `sysctl vm.swapusage`.
- Memory pressure comes from `sysctl kern.memorystatus_vm_pressure_level` (normal / warning / critical) — the level the kernel itself acts on. The chip and RAM tint use the worse of this and the headroom thresholds (30% / 15% available): pressure alone stays "normal" on a large machine that is 95% used, while headroom alone misses the kernel already compressing and swapping.

### Network

- Download and upload rates come from `getifaddrs`, summing `if_data` byte counters across every non-loopback interface and differencing against the previous sample.
- Those counters are 32-bit and wrap every 4 GB. A wrap shows up as the total going backwards; Statter drops that single sample rather than reporting a spike.
- Like CPU, throughput is a rate, so the first reading after launch only establishes a baseline.

### CPU

- CPU utilization is derived from `host_statistics(HOST_CPU_LOAD_INFO)` tick counters, differenced against the previous sample. Utilization is a rate, so the first reading after launch has no baseline and reports idle.
- Core counts come from `sysctl hw.logicalcpu`, `hw.perflevel0.logicalcpu` (performance) and `hw.perflevel1.logicalcpu` (efficiency).

### GPU and unified memory

On Apple Silicon, there is no separate VRAM. The CPU and GPU share the same physical memory pool. Statter shows this as a single unified bar rather than separate sections:

- GPU model, core count, utilization, and tracked memory are read from the `AGXAccelerator` IORegistry entry with `IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperty`, specifically its `PerformanceStatistics` dictionary. Model and core count are read once and cached.
- **GPU mapped** (`Alloc system memory` from IOKit) is the total memory the GPU driver has reserved. On machines running local AI models, this can be very large (e.g. 70 GB for a large LLM) because the model weights are memory-mapped for GPU access.
- **GPU active** (`In use system memory` from IOKit) is the subset actively being read/written by the GPU right now.
- The gap between mapped and active is memory that's allocated (often wired/pinned) but idle — for example, model weights that aren't being processed this instant.
- When GPU mapped memory is large, Statter explains why: this memory is your RAM shared with the GPU, not separate VRAM. This is typically the reason "wired" memory appears very high on machines running local inference.

### Per-process memory

- Process list comes from `ps -eo pid,rss,pcpu,comm -r`, and **every** returned process is measured. `ps` is kept on purpose: `proc_pid_rusage` and `proc_pidinfo` are refused for processes owned by other users (WindowServer, `mds_stores`, `launchd` and ~160 other daemons), but `ps` can still report their RSS, so replacing it would hide them. Earlier versions kept only the first 200 rows, but `ps -r` orders by CPU, so idle-but-memory-heavy processes were silently missing from what is a memory panel.
- Each process's memory is measured using **physical footprint** via `proc_pid_rusage(RUSAGE_INFO_V4)` and the `ri_phys_footprint` field. This is the same metric Activity Monitor shows in its "Memory" column. It avoids the problem where RSS (Resident Set Size) double-counts shared libraries and memory-mapped files across processes.
- Processes are aggregated by executable name with a count shown (e.g. `node (10)`).
- If `proc_pid_rusage` fails for a process (e.g. insufficient permissions for system processes), Statter falls back to RSS from `ps`.

### Important limitations

- GPU stats are Apple-Silicon-specific. The current implementation depends on `AGXAccelerator`, so non-AGX Macs show `—` for the GPU.
- Per-process CPU is `ps`'s `%cpu`, a decaying average rather than an instantaneous rate.
- The unified pool bar shows GPU-mapped, Apps/OS, and Available as non-overlapping segments, but in reality GPU allocations overlap with the wired memory category. The bar caps GPU-mapped at `total - available` to ensure it never exceeds 100%.
- `PerformanceStatistics` key names are undocumented and could change in a future macOS; a missing key is logged rather than shown as 0.
- Process aggregation by binary name can merge unrelated processes with the same executable name.

## Building

```bash
./build.sh            # produces ./Statter.app
./build.sh --install  # also copies it to /Applications and launches it
```

`build.sh` compiles `StatterApp.swift`, wraps the binary in a `Statter.app` bundle
(marked `LSUIElement`, so it lives in the menu bar with no Dock icon) and ad-hoc
signs it. The icon is drawn from code by `make-icon.swift` — the `memorychip`
symbol over a capacity bar, cut into a colourless glass plate that picks up whatever
is behind it — so the repo carries no image assets. `build.sh` runs it automatically when `Statter.icns` is missing; run
`swift make-icon.swift` by hand after editing the artwork. Ad-hoc signing keeps the bundle identity stable across rebuilds, so macOS
does not re-ask for permissions every time.

Double-click `Statter.app` to run it, or launch the raw binary for a quick iteration:

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -framework IOKit -o statter StatterApp.swift
./statter
```

To have it start at login, add `Statter.app` under System Settings → General →
Login Items.

Requires macOS and Xcode command line tools (`xcode-select --install`).
