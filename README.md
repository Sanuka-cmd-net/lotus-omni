# LOTUS OMNI

**A Superscalar Out-of-Order RISC-V Processor with Systolic Tensor Acceleration,
Structured Sparsity, and a Congestion-Aware Network-on-Chip**

*Developed with AI pair-programming assistance. All synthesis, simulation and timing
results below were produced and independently verified by the author using Xilinx Vivado.*

---

## Overview

LOTUS OMNI is a from-scratch, 4-wide superscalar out-of-order RISC-V processor augmented
with an AI accelerator subsystem. The design was developed, debugged, simulated and
timing-closed by a single self-taught engineer over approximately nine months of focused
RTL work. It targets the "AI edge processor" class: a general-purpose out-of-order scalar
pipeline fused with a systolic tensor engine, a three-level memory hierarchy, TAGE branch
prediction, a 2-D mesh Network-on-Chip, and credit-based congestion control.

The scalar pipeline is 4-wide from decode through rename, dispatch, issue and commit, backed
by a 128-entry physical register file with 8 read and 4 write ports. Out-of-order execution is
managed by partitioned reservation stations with vectorised wakeup and a 32-entry reorder
buffer that enforces in-order retirement with precise exception support. The tensor subsystem
orchestrates complete 8x8 matrix multiplications in the background while the scalar pipeline
continues executing, sharing the memory hierarchy through a CPU-priority arbiter.

---

## Key Results

| Metric | Result |
|---|---|
| Target device | Xilinx Artix-7 `xc7a200tl-ffv1156-2L` |
| ISA | RV64I + custom tensor opcode `0x0B` |
| Timing (OOC, post-route) | **Met @ 80 MHz** — WNS +0.141 ns, WHS +0.020 ns |
| Timing endpoints | 0 failing / 157,103 total |
| Tensor verification | **PASS 64/64** (8x8 MATMUL, all results = 2x3x8 = 48) |
| Slice LUTs | 55,450 / 134,600 (41.2%) |
| Slice Registers | 38,173 / 269,200 (14.2%), 0 latches |
| Block RAM | 17 / 365 tiles (4.7%) |
| DSP48E1 | 64 / 740 (8.7%) |

---

## Architecture

The figure below shows the complete data-flow architecture. The scalar path runs
`Fetch -> L1I -> Decode -> Rename -> Reservation Stations -> {ALU, Branch, AGU/LSQ,
Tensor/CSR} -> CDB -> PRF/ROB -> Commit`. The tensor path streams weights and activations
through a CPU-priority memory arbiter into dual systolic arrays, and writes results back to
the physical register file over the Common Data Bus.

<!-- IMAGE 1: place your architecture block diagram at images/architecture.png -->
<p align="center">
  <img src="images/architecture.png" alt="LOTUS OMNI microarchitecture block diagram" width="900"/>
</p>

---

## Tensor Acceleration & Supported Workloads

The accelerator computes 8x8 BF16 and INT8 matrix multiplications at a peak of 64
multiply-accumulate operations per cycle, doubling effective throughput when 2:4 structured
sparsity is enabled. Larger matrices are handled by tiling weight and activation blocks across
successive tensor operations.

The datapath targets the GEMM kernel that underlies neural-network inference. Representative
deployment classes include:

- **Fully-connected and small convolutional networks** (e.g. MNIST-scale classifiers)
- **INT8 quantised TinyML models** such as keyword spotting and micro-speech
- **BF16 inference** for workloads requiring higher numeric accuracy
- **Any GEMM-expressible workload**, the dominant primitive in deep-learning inference

Because tensor operations run in the background under a CPU-priority arbiter, scalar
instruction throughput is preserved while the accelerator streams data.

---

## Module Summary

The design comprises 30 SystemVerilog source files (26 architecturally distinct modules plus
4 supporting files). Every module is completed, synthesised and behaviourally simulated.
Full mathematics, worked numerical examples, and per-module fix histories are documented in
[`Docs and Reports/ARCHITECTURE.md`](Docs%20and%20Reports/ARCHITECTURE.md).

| Module | Function |
|---|---|
| `lotus_ifu_masterpiece` | 16-wide fetch with deadlock-free decoupled request channel |
| `lotus_l1i_cache` | 32 KB direct-mapped instruction cache, BRAM-inferred |
| `lotus_tage_predictor` | TAGE + BTB predictor with pipelined training and GHR snapshot FIFO |
| `lotus_decoder_masterpiece` | 16-wide decode into a 128-entry LUTRAM DIQ |
| `lotus_renamer_masterpiece` | Register renaming with 8 branch checkpoints, 1-cycle recovery |
| `lotus_reservation_station_v4` | Partitioned reservation stations with vectorised wakeup |
| `lotus_prf` | 128x64b 8R/4W physical register file, registered one-hot arbitration |
| `lotus_alu_masterpiece` | RV64I ALU, 2-stage pipeline with OR-AND forwarding |
| `lotus_branch_exec` | Branch/jump resolution and mispredict detection |
| `lotus_agu` | Address generation, write masks, misalignment detection |
| `lotus_lsq_masterpiece` | Store queue with CAM store-to-load forwarding |
| `lotus_l1d_cache` | 4 KB write-back data cache, full 512-bit line response |
| `lotus_l2_cache` | 16-set 4-way PLRU unified L2, LUTRAM-only |
| `lotus_prefetcher` | Stride prefetcher with reference-prediction table |
| `lotus_rob_masterpiece` | 32-entry reorder buffer, 4-wide in-order commit |
| `lotus_tensor_engine` | 6-state MATMUL orchestration FSM with CDB writeback |
| `lotus_bf16_systolic_array_8x8_v3` | 8x8 BF16 outer-product broadcast array |
| `lotus_int8_systolic_array_8x8` | 8x8 INT8 outer-product broadcast array |
| `lotus_bf16_tensor_pe` | DSP-mapped BF16 MAC processing element |
| `lotus_tensor_pe` | INT8 MAC processing element with AI saturation |
| `lotus_sparsity_engine_v3` | 2:4 structured sparsity compressor |
| `lotus_tensor_mem_arbiter` | CPU-priority L1D memory arbiter, formally asserted |
| `lotus_noc_router_masterpiece` | 5-port XY-mesh Network-on-Chip router |
| `congestion_aware_flow_gate` | Credit-based flow control with PID throttle |
| `lotus_csr` | Machine-mode and custom tensor/sparsity CSRs |
| `lotus_pmu` | 13-counter hardware performance monitor |
| `lotus_axi4_wrapper` | AXI4-Lite control-plane interface |
| `lotus_omni_core_top_v2` | Top-level integration and timing pipelines |
| `lotus_pkg` | Shared typedef and parameter package |
| `lotus_bf16_mult` | ASIC-portable 3-stage BF16 multiplier |

---

## Implementation Results

The design was implemented out-of-context with Vivado and closes timing at 80 MHz on the
slowest Artix-7 speed grade. The screenshot below shows the post-route timing summary.

<!-- IMAGE 2: place your Vivado timing summary screenshot at images/implementation_complete.png -->
<p align="center">
  <img src="images/implementation_complete.png" alt="Vivado implementation complete, timing met at 80 MHz" width="900"/>
</p>

### Timing-Closure Campaign

Worst Negative Slack progressed from **-7.019 ns to +0.141 ns** across six targeted iterations.
The most impactful fixes were the PRF registered one-hot grant arbitration, the ALU 2-stage
pipeline split, renamer output registration with pipelined TAGE training, and registered
CDB-to-ROB paths. The subsequent tensor-subsystem integration and L1D full-line datapath
widening added roughly 7,300 endpoints while maintaining positive slack. The complete
iteration log is in [`Docs and Reports/ARCHITECTURE.md`](Docs%20and%20Reports/ARCHITECTURE.md).

---

## Verification

- **Scalar functional:** the full fetch, decode, rename, dispatch, issue, execute, writeback
  and commit pipeline is observed running concurrently in behavioural simulation.
- **Tensor functional:** a self-checking testbench loads weights=2 and activations=3, runs a
  full 8x8 MATMUL through the systolic array, and verifies all 64 physical-register results
  equal the expected value 48 (0x30), reporting PASS 64/64.
- **Formal assertions:** 15 SystemVerilog Assertions guard the tensor-engine protocol and
  12 assertions plus 7 cover points guard the memory-arbiter protocol.
- Raw synthesis, implementation, timing and utilisation reports are archived in
  `Docs and Reports/reports/`.

---

## Getting Started

**Requirements:** Xilinx Vivado 2025.2, Xilinx Simulator (XSim).

1. Create a new RTL project and add all files under `RTL/` (compile `lotus_pkg.sv` first) and `Constraints/`.
2. Set the top module to `lotus_axi4_wrapper`, run synthesis, then implementation, then
   `report_timing_summary` (expect timing met at 80 MHz).
3. For behavioural simulation, set a testbench under `TB/` as the simulation top and run:
   - `tb_lotus_core_demo3` - full-core scalar plus tensor MATMUL with self-check (64/64)
   - `tb_lotus_ifu_demo2` - instruction-fetch demonstration
   - `tb_lotus_axi4_wrapper` - AXI control-plane demonstration

---

## Repository Structure

```
lotus-omni/
├── RTL/                 # 30 SystemVerilog source files
├── TB/                  # Self-checking testbenches
├── Constraints/         # Out-of-context timing constraints (80 MHz)
├── Docs and Reports/    # ARCHITECTURE.md and raw Vivado reports
├── images/              # architecture.png, implementation_complete.png
└── README.md
```

---

## Documentation

The primary reference is [`Docs and Reports/ARCHITECTURE.md`](Docs%20and%20Reports/ARCHITECTURE.md),
which documents every module with its mathematical formulation, a worked numerical example, and
a complete fix history. Timing-closure details are in `Docs and Reports/reports/`.

---

## AI-Assistance Disclosure

AI pair-programming tools were used for code review, debugging and documentation. The RTL
design decisions, synthesis runs, simulation verification and timing closure were performed
and confirmed by the author using real Vivado tool output, archived in this repository.

---

## Author

**Sanuka Nethmira Amarasekara**
Lotus Omni - fabless AI-semiconductor concept

- Email: ______________________
- LinkedIn: ______________________
- Website / Portfolio: ______________________