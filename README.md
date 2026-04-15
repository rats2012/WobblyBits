![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

## WobblyBits
 
WobblyBits is a probabilistic computing demonstration chip - 6 p-bits (probabilistic bits) driven by hardware randomness from a bunch of on-chip ring oscillators.

A p-bit is a device that fluctuates randomly between 0 and 1 with a probability defined by its neighbouring p-bit. It sits between a classical bit and a q-bit. The "coupling" matrix (referred to as a J matrix in the code), the network will sample the encoded probability distribution - this allows combinatorial optimisation (MAX-CUT etc...)

The idea here is to try to effectivly have an "Ising model" which is a model in statistical phyics ([https://www.youtube.com/watch?v=1CCZkHPrhzk](https://www.youtube.com/watch?v=1CCZkHPrhzk))

- [Full documentation](docs/info.md)
- I aim to fabricate on SKY130 via [Tiny Tapeout](https://tinytapeout.com)

## Architecture

SPI on the `uio` ports of the tiny tapout can be used to load in the J coupling matrix, which are stored in 15 8-bit  signed registers

Ring oscilators are then used to generate randomness (I pretty much used neoTRNG but ported to verilog), which feeds the states of the P-bit array, which feeds the outputs of the chip (`uo_out[0..5]`) and obviously is used with the J matrix to update the P bit states so we can settle on a solution.

```
SPI (uio[0..3])
    ↓
J coupling matrix  ←─────────────────┐
(15 × 8-bit signed registers)        │
    ↓                                │
neoTRNG (3 ring-osc cells)           │
    ↓                                │
P-bit array [0..5]  (Gibbs update) ──┘
    ↓
uo_out[5:0]  →  live p-bit states
```

**neoTRNG** — three inverter rings (5, 7, 9 inverters) with XOR combining - Thermal jitter should provide the true entropy. [MIT licensed - ported from VHDL](https://github.com/stnolting/neoTRNG).

**Gibbs update** — each TRNG byte drives one p-bit update in round-robin order. The update rule is `p(s_i=1) = sigmoid(128 + Σ J_ij·(2s_j−1))`, approximated as a threshold comparison against the random byte. The 15 unique coupling weights are 8-bit signed and stored in a compact symmetric register file.

**SPI interface** — SPI Mode 0, 16-bit frames (`[addr_byte][data_byte]`). `addr[5:0]` selects the matrix entry in row-major order (0–35); symmetric pairs alias the same physical register. Resets to ferromagnetic K=20 so the chip works without any SPI configuration.

## Pinout

| Pin | Direction | Function |
|-----|-----------|----------|
| `ui[0]` | in | `run` — 1 = network running, 0 = paused |
| `ui[1]` | in | `rand_init` — 1 = seed p-bits from TRNG on rising edge of `run` |
| `ui[2]` | in | `trng_bypass` — freeze TRNG and updates for more deterministic testing |
| `uo[5:0]` | out | live p-bit states (`pbit0`–`pbit5`) |
| `uio[0]` | in | `SPI_CS` (active low) |
| `uio[1]` | in | `SPI_MOSI` |
| `uio[2]` | out | `SPI_MISO` (tied 0 — write-only) |
| `uio[3]` | in | `SPI_SCK` |


## A subset of the many amazing resources i used for this project

- [Tiny Tapeout FAQ](https://tinytapeout.com/faq/)
- [neoTRNG source](https://github.com/stnolting/neoTRNG)
- [Ising model explanation video](https://www.youtube.com/watch?v=1CCZkHPrhzk)

