## How it works

WobblyBits is a probabilistic computing chip. It contains **6 p-bits** (probabilistic bits) that fluctuate randomly between 0 and 1 with a probability controlled by their neighbours. Together the six p-bits form a small Ising/Boltzmann machine: load a coupling matrix over SPI, release the `run` pin, and the network samples from the encoded probability distribution.

### Architecture

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

#### True random number generator

Hardware randomness comes from the [neoTRNG](https://github.com/stnolting/neoTRNG) core — three inverter rings of 5, 7, and 9 stages with XOR combining. Thermal jitter in the ring oscillation frequencies provides true entropy. The TRNG outputs a fresh random byte whenever `valid_o` pulses; that byte drives the next p-bit update.

#### P-bit update rule (sequential Gibbs sampling)

Each TRNG byte triggers one p-bit update in round-robin order (pbit0 → pbit1 → … → pbit5 → pbit0 …).

The update rule is a hardware approximation of the sigmoid:

```
net_i   = Σ_{j≠i} J[i][j] · (2·s_j − 1)   (±1 spin convention)
thresh  = clamp(128 + net_i, 0, 255)
s_i_new = (trng_byte < thresh) ? 1 : 0
```

`thresh` maps the net field linearly into a probability: `net=0` gives 50/50 fluctuation, positive net biases toward 1, negative toward 0. The linear approximation saturates at `|net| > 127`.

#### J coupling matrix

The 6×6 coupling matrix has 15 unique off-diagonal entries (the matrix is symmetric; diagonal is 0). These are stored as 8-bit signed registers and accessible via SPI using row-major addressing (`addr = 6·row + col`). Writing either `J[i][j]` or `J[j][i]` updates the same physical register.

**Reset default:** ferromagnetic K=20 (`J[i][j] = 20` for all i≠j). This puts the network near the critical temperature of the all-to-all 6-spin model, giving solid correlated fluctuations out-of-the-box without any SPI configuration.

#### SPI interface

SPI Mode 0 (CPOL=0, CPHA=0), MSB first. Each transaction is 16 bits: an address byte (`addr[5:0]` = register 0–35) followed by a data byte (8-bit signed weight). If CS is deasserted mid-frame the partial transaction is silently discarded. The SPI inputs are double-FF synchronised into the 25 MHz system clock domain, limiting SCK to ≈12 MHz (the RP2040 demo board uses ≤4 MHz).

### Control pins

| Pin | Function |
|-----|----------|
| `ui[0]` run | 1 = network running, 0 = paused (p-bits and TRNG frozen) |
| `ui[1]` step | reserved (unused) |
| `ui[2]` trng_bypass | 1 = freeze TRNG and p-bit updates (deterministic simulation) |

### Boltzmann sampling

With suitable J values the stationary distribution of the Markov chain converges to the Boltzmann distribution `P(s) ∝ exp(−E(s)/T)` where the energy is the Ising Hamiltonian `E = −Σ_{i<j} J[i][j]·s_i·s_j` and the effective temperature is set by the TRNG noise level. Sampling the output long enough recovers the full distribution; the most-visited states are the lowest-energy (ground) states.

## How to test

**Hardware required:** Tiny Tapeout demo board (RP2040 + MicroPython)

### Bring-up

1. Power on with `ui[0]` (run) = 0
2. Load coupling weights via SPI — send `[addr, weight]` byte pairs for each `J[i][j]` entry you want to set (0–35 addresses, 8-bit signed weights)
3. Deassert SPI CS, then assert `ui[0]` = 1 to start the network
4. Sample `uo_out[5:0]` repeatedly — this is the live 6-bit p-bit state vector

### No-config smoke test

Without any SPI write, the chip resets to ferromagnetic K=20. Assert `run` and observe `uo_out[5:0]`. You should see correlated random fluctuations — all six bits tend to be in the same state (0 or 1) but occasionally flip together. This confirms TRNG → p-bit datapath is working.

### TRNG quality check

Set J=0 for all entries (fully uncoupled) via SPI. Each p-bit now fluctuates independently at 50/50. Capture a long bitstream from a single output pin and run NIST SP 800-22 tests to verify entropy quality.

### TRNG bypass (deterministic simulation)

Assert `ui[2]` = 1 to freeze all updates. Output holds its last value indefinitely. Release to resume. Useful for verifying SPI loads take effect before randomness obscures the result.

### Ising ground-state test (ferromagnetic)

With default K=20, after sufficient warm-up (a few thousand clock cycles) the network should spend noticeably more time in the all-0 or all-1 states than in mixed states — those are the ferromagnetic ground states.

For stronger alignment: load K=40 via SPI (addr pairs for all 30 off-diagonal positions). With K=40 the all-aligned probability is >50%.

### MAX-CUT demo

Load a K₃,₃ graph (anti-feromagnetic coupling J=−40 for cross-partition edges 0↔3, 0↔4, 0↔5, 1↔3, 1↔4, 1↔5, 2↔3, 2↔4, 2↔5; J=0 for intra-partition pairs). The two MAX-CUT ground states are `000111` (pbit0–2 low, pbit3–5 high) and `111000`. After warm-up, whichever ground state basin the chain entered will dominate the sample histogram.

**Symmetry breaking / basin trapping:** Hardware reset initialises all p-bits to 0 (`states=000000`), so the chain always falls into the `000111` basin first. The two ground states are separated by a large energy barrier (~9×2×J = 720 in coupling units), making spontaneous basin crossing extremely unlikely within a practical run length. To observe `111000`, run a second independent trial with a different initial state (e.g. initialise states to `111111` before asserting `run=1`). This requires SPI-writable initial state, which is a planned future addition to the hardware (see architecture note above). In the RTL tests we observe only `000111`:
```
3960.00ns INFO     cocotb.regression                  running test.test_max_cut_k33_bipartite (6/12)
                                                            MAX-CUT on K_{3,3} — 6-node complete bipartite graph.
413960.01ns INFO     cocotb.tb                          Start — MAX-CUT K_{3,3} bipartite test
1020760.01ns INFO     cocotb.tb                          MAX-CUT K_{3,3}  —  1000 samples
1020760.01ns INFO     cocotb.tb                             state  | count |  frac  | cut | distribution
1020760.01ns INFO     cocotb.tb                            --------+-------+--------+-----+--...
1020760.01ns INFO     cocotb.tb                            000101  |    41  |  4.1%  |  6  | ██
1020760.01ns INFO     cocotb.tb                            000111  |   595  | 59.5%  |  9  | ████████████████████████████████████  ◄ OPTIMAL
1020760.01ns INFO     cocotb.tb                            001110  |    22  |  2.2%  |  5  | █
1020760.01ns INFO     cocotb.tb                            010100  |    19  |  1.9%  |  4  | █
1020760.01ns INFO     cocotb.tb                            010101  |    40  |  4.0%  |  5  | ██
1020760.01ns INFO     cocotb.tb                            010110  |    36  |  3.6%  |  5  | ██
1020760.01ns INFO     cocotb.tb                            011110  |    20  |  2.0%  |  4  | █
1020760.01ns INFO     cocotb.tb                            100101  |    80  |  8.0%  |  5  | █████
1020760.01ns INFO     cocotb.tb                            100111  |    73  |  7.3%  |  6  | ████
1020760.01ns INFO     cocotb.tb                            101101  |    37  |  3.7%  |  4  | ██
1020760.01ns INFO     cocotb.tb                            101110  |    20  |  2.0%  |  4  | █
1020760.01ns INFO     cocotb.tb                            101111  |    17  |  1.7%  |  3  | █
1020760.01ns INFO     cocotb.tb                          Ground-state (cut=9) fraction : 59.5%  (random baseline 3.1 %)
1020760.01ns INFO     cocotb.tb                          High-energy  (cut=0) fraction : 0.0%
1020760.01ns INFO     cocotb.tb                          Most-sampled state            : 000111 (int 7)  ✓ ground state
1020760.01ns INFO     cocotb.regression                  test.test_max_cut_k33_bipartite passed
```

## External hardware

- **Tiny Tapeout demo board** — RP2040 + MicroPython for SPI loading and output sampling
- Oscilloscope or logic analyser might be helpful for watching p-bit fluctuations in real time...
