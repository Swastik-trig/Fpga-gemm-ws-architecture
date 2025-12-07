# FPGA GEMM Accelerator — Weight-Stationary Systolic Array

This project implements a hardware accelerator for matrix multiplication (GEMM) using a **Weight-Stationary (WS) systolic array** architecture on FPGA. The design focuses on maximizing on-chip weight reuse, reducing external memory bandwidth, and achieving high-throughput MAC operations.

## Overview
- Fully parameterizable systolic array (M × N)
- Weight-Stationary dataflow: each PE stores a dedicated weight locally
- Streamed activations and vertical partial-sum propagation
- RTL design in SystemVerilog
- Synthesized and verified using Vivado

## Processing Element (PE)
Each PE performs one MAC per cycle:
`psum_out = psum_in + (activation × weight)`

Weights are pre-loaded and remain fixed for the entire computation tile, enabling high reuse and reduced memory traffic.

## Architecture Highlights
- Pipelined systolic flow for continuous data movement
- Localized PE storage for weight reuse
- Parallel MAC computation across the array
- Suitable for accelerating GEMM, CNN layers, and linear algebra workloads

## Repository Structure
- `sources/` — SystemVerilog RTL (PE, array, top module)
- `constrs/` — FPGA constraints (XDC)
- `sim/` — Testbenches
- Vivado project file included for reference

## Summary
This project demonstrates hardware acceleration of matrix multiplication using a WS systolic array optimized for FPGA implementation. It showcases skills in RTL architecture design, hardware dataflow optimization, and FPGA synthesis.

