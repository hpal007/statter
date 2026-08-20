# Statter

SwiftUI menu bar app for monitoring macOS GPU and memory stats.

![Screenshot of the Statter app on macOS showing memory usage for an Apple M5 Max with 40 GPU cores. Left panel: a large orange "38 GB Available" readout showing usage of 128.0 GB unified memory, "Room for ~18 more large apps before pressure", a warning banner reading "1.5 GB pushed to disk — system was under pressure recently", a horizontal segmented bar chart labeled "Where your memory is going" with green, blue, and grey segments and a legend, an explanatory note about GPU unified memory, a GPU Utilization section showing 0%, and a History graph showing Available and GPU Utilization over time as line charts. Right panel: a Memory Footprint list sorted by Memory, showing process names with horizontal pink/purple usage bars and CPU percentage labels beside each entry, covering processes including Dropbox, WebKit, Virtualization, node, Claude Helper, Safari, LM Studio, WindowServer, Finder, and others.](screenshot.png)

## Features

- **Live menu bar numbers** — `10.6/16 GB` in the menu bar, tinted by headroom threshold, so used-vs-total is readable without opening the panel. Hover for the full breakdown.
- **RAM gets the wide half** of the panel: a thin stick gauge scaled to physical memory with tick marks alongside, the used/total/available figures, and the "where it is going" breakdown, all in one card.
- **CPU and GPU stack beside it** as compact cards, each with the same thin stick gauge, so all three read on one visual grammar without spending width on chunky bars.
- **Network throughput** — live download and upload rates from `getifaddrs` byte counters.
- **"Where it is going"** — a unified memory pool visualization showing GPU-mapped memory, apps/OS, and available space as competing claims on one shared pool — no more pretending GPU has its own VRAM
- Live Apple Silicon GPU utilization from `AGXAccelerator` `PerformanceStatistics`
- **Physical footprint** for per-process memory (the same metric Activity Monitor uses) instead of RSS, which inflates numbers by counting shared pages multiple times
- Swap usage with contextual explanation
- **System-wide CPU utilization** with user/system split and P/E core counts, read from `host_statistics(HOST_CPU_LOAD_INFO)`

## How measurement works

Statter uses macOS system interfaces and command-line tools rather than private frameworks.

### Memory

- Total physical memory comes from `sysctl hw.memsize`.
- Memory breakdown comes from `host_statistics64(HOST_VM_INFO64)`, using page counters such as active, inactive, wired, compressed, speculative, free, and purgeable.
- **Available memory** is computed as `total - used`, where used follows Activity Monitor's formula: `used = app memory + wired + compressed`, with app memory taken as `active - purgeable`. Inactive, speculative, purgeable, and free pages are all treated as available, because macOS can reclaim them on demand. Every subtraction is clamped at zero and `used` is capped at physical RAM, since the page counters are sampled independently and are not guaranteed to be mutually consistent.
- Swap usage comes from `sysctl vm.swapusage`.

### Network

- Download and upload rates come from `getifaddrs`, summing `if_data` byte counters across every non-loopback interface and differencing against the previous sample.
- Those counters are 32-bit and wrap every 4 GB. A wrap shows up as the total going backwards; Statter drops that single sample rather than reporting a spike.
- Like CPU, throughput is a rate, so the first reading after launch only establishes a baseline.

### CPU

- CPU utilization is derived from `host_statistics(HOST_CPU_LOAD_INFO)` tick counters, differenced against the previous sample. Utilization is a rate, so the first reading after launch has no baseline and reports idle.
- Core counts come from `sysctl hw.logicalcpu`, `hw.perflevel0.logicalcpu` (performance) and `hw.perflevel1.logicalcpu` (efficiency).

### GPU and unified memory

On Apple Silicon, there is no separate VRAM. The CPU and GPU share the same physical memory pool. Statter shows this as a single unified bar rather than separate sections:

- GPU model, core count, utilization, and tracked memory come from `/usr/sbin/ioreg -r -c AGXAccelerator -d 2`, specifically the `PerformanceStatistics` dictionary.
- **GPU mapped** (`Alloc system memory` from IOKit) is the total memory the GPU driver has reserved. On machines running local AI models, this can be very large (e.g. 70 GB for a large LLM) because the model weights are memory-mapped for GPU access.
- **GPU active** (`In use system memory` from IOKit) is the subset actively being read/written by the GPU right now.
- The gap between mapped and active is memory that's allocated (often wired/pinned) but idle — for example, model weights that aren't being processed this instant.
- When GPU mapped memory is large, Statter explains why: this memory is your RAM shared with the GPU, not separate VRAM. This is typically the reason "wired" memory appears very high on machines running local inference.

### Per-process memory

- Process list comes from `ps -eo pid,rss,pcpu,comm -r`, and **every** returned process is measured. Earlier versions kept only the first 200 rows, but `ps -r` orders by CPU, so idle-but-memory-heavy processes were silently missing from what is a memory panel.
- Each process's memory is measured using **physical footprint** via `proc_pid_rusage(RUSAGE_INFO_V4)` and the `ri_phys_footprint` field. This is the same metric Activity Monitor shows in its "Memory" column. It avoids the problem where RSS (Resident Set Size) double-counts shared libraries and memory-mapped files across processes.
- Processes are aggregated by executable name with a count shown (e.g. `node (10)`).
- If `proc_pid_rusage` fails for a process (e.g. insufficient permissions for system processes), Statter falls back to RSS from `ps`.

### Important limitations

- GPU stats are Apple-Silicon-specific. The current implementation depends on `AGXAccelerator`, so non-AGX Macs may show `Unknown` and zeroed GPU values.
- There is no memory-pressure readout. Available memory and swap usage are shown instead; neither is a substitute for the kernel's real VM pressure level.
- The unified pool bar shows GPU-mapped, Apps/OS, and Available as non-overlapping segments, but in reality GPU allocations overlap with the wired memory category. The bar caps GPU-mapped at `total - available` to ensure it never exceeds 100%.
- The `ioreg` parsing is text-based, so future macOS formatting changes could break some fields.
- Process aggregation by binary name can merge unrelated processes with the same executable name.

## Building

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -framework IOKit -o statter StatterApp.swift
./statter
```

Requires macOS and Xcode command line tools (`xcode-select --install`).
