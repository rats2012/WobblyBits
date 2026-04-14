<!---
This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works


WobblyBits is a probabilistic chip — a few p-bits (probabilistic bits) driven by
hardware randomness from a bunch of on-chip ring oscillators.

A p-bit is a device that fluctuates randomly between 0 and 1 with a _controllable-ish_ probability. It kinda between classical bit and a qubit, but should work at room temp.

### Architecture

idk but it might end up like this (this next bit was written with ChatGPT based on my txt notes so it might be bulshit (GIGO lol) - i will re-write it at some point later...)

```
SPI (uio[0..3])
    ↓
Weight registers  ←──────────────────┐
    ↓                                │
Ring oscillator TRNG                 │
    ↓                                │
P-bit array [0..7] ──────────────────┘
    ↓
uo_out[7:0]  →  live p-bit states
```

**Ring oscillator TRNG** — multiple inverter rings of slightly different lengths, with XOR combining.
Thermal jitter in each ring's oscillation frequency provides the true entropy. Uses the
[neoTRNG](https://github.com/stnolting/neoTRNG) core (MIT licensed, ASIC-proven).

**P-bit update rule** — each p-bit flips with probability `sigmoid(bias + Σ J_ij * s_j)`, where `J_ij`
are the coupling weights loaded via SPI and `s_j` are the current states of neighbouring p-bits.
With the right J matrix the network performs Gibbs/Boltzmann sampling over the distribution it encodes.

**SPI interface** — a simple SPI slave on `uio[0..3]` accepts the coupling matrix weights at startup.
Weights are 8-bit signed values. Address byte selects which weight register to write.

### Control

| Pin | Function |
|-----|----------|
| `ui[0]` run | 1 = network running, 0 = paused |
| `ui[1]` step | rising edge = single update cycle (debug) |
| `ui[2]` trng_bypass | freeze TRNG output for deterministic simulation |

### Validation target

Load a small [Ising problem](https://en.wikipedia.org/wiki/Ising_model) into the J matrix and verify the
chip finds the ground state — this is the canonical test distinguishing real probabilistic computation
from mere noise generation.

## How to test

**Hardware required:** Tiny Tapeout demo board (RP2040 + MicroPython)

### Bring-up sequence

1. Power on with `ui[0]` (run) = 0
2. Load the coupling matrix via SPI: send `[addr, weight]` byte pairs for each J_ij entry
3. Assert `ui[0]` = 1 to start the network
4. Sample `uo_out[7:0]` repeatedly — this is the live p-bit state vector

### TRNG quality check

With all weights = 0 (no coupling), each p-bit should fluctuate independently at ~50% duty cycle.
Capture a long bitstream from any single output pin and run NIST SP 800-22 tests.

### Ising ground state test

Load the ferromagnetic J matrix (all positive couplings). After sufficient relaxation time all p-bits
should align (all-0 or all-1). This is the ground state.

### TRNG bypass

Assert `ui[2]` = 1 to freeze the TRNG. The network becomes deterministic for unit testing.

## External hardware

- **Tiny Tapeout demo board** — RP2040 + MicroPython for SPI weight loading and output sampling
- mabey a scope
