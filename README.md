# AXI DMA Subsystem - Design, Verification and RTL-to-GDS

I am creating a small chip subsystem in which a DMA copies the data between memory locations over the AMBA AXI bus, from sratch using SystemVerilog.
Then everyfile is verified before commiting to GitHub, screenshots are also attached for reference.

Then I will take it through synthesis and place-and-route to a GDS layout in a 45nm Technology.

I am building this project over my last project where i only built AXI protocol and verified it using UVM testbench.

The main objective of building this project is to learn digital design and verification the it is done in industry.

## What this chip will do

A testbench writes source address, destination address, and length into DMA's Registers. The DMA then copies data on its own, in bursts, using the AXI read and write channels at the same time, and raises interrupt when it is done.

A round-robin arbiter lets two masters share one AXI memory.

**RULEBOOK:** I am using AMBA AXI Protocol specification, ARM IHI 0022 Issue L (2025).

The design uses the core AXI feature set with optional AXI5 extentions switched off.

## BLOCKS

| Block | Job | Status |
|---|---|---|
| `soc_pkg` | All sizes and AXI code numbers in one place | ✅ done |
| FIFO | Buffer between the read and write sides | next |
| AXI interface | Standard bundle of the AXI wires | planned |
| AXI memory | 256-byte AXI subordinate (the "warehouse") | planned |
| DMA read channel | Issues AR requests, collects R data | planned |
| DMA write channel | Issues AW/W, checks B responses | planned |
| DMA control FSM | Splits a copy into legal bursts | planned |
| Register file | AXI-Lite registers + interrupt | planned |
| Arbiter | Round-robin sharing of the memory | planned |
| SoC top | Connects all blocks | planned |
| UVM environment | Agents, scoreboard, coverage, assertions | planned |


## ROADMAP

| Step | What | Status |
|---|---|---|
| 1 | Project setup, settings package, run flow | ✅ done ([notes](docs/step1.md)) |
| 2 | FIFO + unit test | next |
| 3 | AXI interface + memory subordinate + assertions | planned |
| 4 | DMA read channel, write channel, control FSM | planned |
| 5 | AXI-Lite registers + interrupt | planned |
| 6 | Round-robin arbiter | planned |
| 7 | SoC top + smoke test | planned |
| 8 | UVM environment + regression | planned |
| 9 | Synthesis (Genus) + equivalence check (Conformal) | planned |
| 10 | Place and route (Innovus), sign-off, GDS | planned |

## TOOLS USED/ Plan to use

- **Simulation:** Cadence Xcelium 20.09, SimVision (waveforms)
- **Synthesis / layout (later):** Cadence Genus, Conformal, Innovus, gpdk045
- **Editor and version control:** VS Code, Git, GitHub Desktop
- **SSH Connection from my mac:** Tabby

## How to run

On the lab server:

```
cd sim
csh
source setup.csh                # loads Cadence tools, sets PROJ_ROOT
make xrun TEST=pkg_smoke        # run, text output
make gui  TEST=pkg_smoke        # run in SimVision
make clean                      # delete simulation outputs
```

## Folder map

```
ip/common/rtl/   shared settings package (soc_pkg.sv)
ip/common/tb/    tests for the common block
ip/common/       common.f file list
sim/             Makefile, setup.csh, outputs (sim/out, not committed)
docs/            notes for each step + screenshots
```

## Results so far

| Test | Simulator | Result |
|---|---|---|
| `pkg_smoke` | Xcelium 20.09 | PASS (5/5 checks) |
| `pkg_smoke` with injected bug (FIFO_DEPTH = 8) | Xcelium 20.09 | FAIL caught as expected |

## About

Built by Mayank Ratnakar (M.Tech, Microelectronics and VLSI, IIT BHILAI) while learning SystemVerilog and verification from scratch, with an AI assistant (Claude) as a guide. Every result in this repository comes from a real run.
