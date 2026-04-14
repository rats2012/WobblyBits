# SPDX-FileCopyrightText: © 2026 WobblyBits
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

# GL_TEST=1 is exported by the Makefile GL section.  In GL mode we skip
# statistical tests (those belong at RTL level) and shorten functional tests
# to avoid delta-cycle storms from the ring-oscillator netlist.
GL_TEST = os.environ.get('GL_TEST') == '1'


@cocotb.test(skip=GL_TEST)  # ring-osc delta-cycle storm; covered by RTL test
async def test_trng_drives_pbits(dut):
    """
    Smoke test: TRNG is running and driving p-bit state changes.

    In SIM_MODE the ring oscillators are registered inverters and produce
    TRNG bytes deterministically.  P-bits start at 0 after reset; with
    ferromagnetic coupling the initial flip probability is 12.5% per TRNG
    byte, so we wait 2500 clocks (>>8× the expected first-flip latency)
    and verify uo_out[3:0] has changed from its post-reset value of 0.
    Skipped in GL mode — statistical TRNG behaviour is an RTL concern.
    """
    dut._log.info("Start — TRNG/p-bit smoke test")

    clock = Clock(dut.clk, 40, unit="ns")  # 25 MHz
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0   # run=0, trng_bypass=0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    assert (int(dut.uo_out.value) & 0x0F) == 0, \
        f"Expected uo_out[3:0]=0 after reset, got {int(dut.uo_out.value) & 0x0F}"

    # Enable run
    dut.ui_in.value = 0b001  # ui[0]=run

    # Collect samples over 2500 clocks; look for at least two distinct values.
    # With K=8 ferromagnetic coupling, initial flip probability per TRNG byte
    # is 12.5%.  2500 clocks gives >99.9% confidence of seeing at least one flip.
    samples = set()
    for _ in range(500):           # 500 × 5 = 2500 clock cycles
        await ClockCycles(dut.clk, 5)
        samples.add(int(dut.uo_out.value) & 0x0F)

    dut._log.info(f"Distinct uo_out[3:0] values seen: {sorted(samples)}")
    assert len(samples) > 1, \
        f"P-bit states never changed — TRNG not driving pbit_array. Stuck at {samples}"


@cocotb.test()
async def test_trng_bypass_freezes_output(dut):
    """
    trng_bypass=1 should freeze uo_out even while run=1.
    """
    dut._log.info("Start — TRNG bypass test")

    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset and run for a while to get a non-zero byte
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut.ui_in.value = 0b001  # run=1
    await ClockCycles(dut.clk, 20 if GL_TEST else 400)  # GL: minimal warmup

    # Freeze
    dut.ui_in.value = 0b101  # run=1, bypass=1
    frozen_value = int(dut.uo_out.value)
    dut._log.info(f"Frozen at uo_out=0x{frozen_value:02x}")

    # Run 200 more cycles — output must not change (20 in GL to cut sim time)
    for _ in range(20 if GL_TEST else 200):
        await ClockCycles(dut.clk, 1)
        assert int(dut.uo_out.value) == frozen_value, \
            f"uo_out changed while bypassed: {int(dut.uo_out.value):#04x} != {frozen_value:#04x}"

    dut._log.info("Bypass held correctly")


# ---------------------------------------------------------------------------
# P-bit array tests
# ---------------------------------------------------------------------------

async def _reset_and_run(dut, run_cycles):
    """Helper: reset, then run for run_cycles clocks with run=1.
    In GL mode caps at 100 cycles to limit ring-oscillator simulation events."""
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    dut.ui_in.value = 0b001  # run=1
    await ClockCycles(dut.clk, min(run_cycles, 100) if GL_TEST else run_cycles)


@cocotb.test(skip=GL_TEST)  # needs 800 cycles; covered by RTL test
async def test_pbit_states_on_output(dut):
    """
    P-bit states appear on uo_out[3:0].

    After reset all p-bits start at 0.  With run=1 and the TRNG producing
    bytes, at least one p-bit should flip to 1 within 800 clocks.
    Skipped in GL mode — statistical liveness is an RTL concern.
    """
    dut._log.info("Start — p-bit output liveness test")
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    await _reset_and_run(dut, 800)

    pbit_out = int(dut.uo_out.value) & 0x0F
    dut._log.info(f"uo_out[3:0] = 0b{pbit_out:04b}")
    assert pbit_out != 0, \
        "P-bit states never left 0 — pbit_array not wired to uo_out or TRNG not firing"


@cocotb.test()
async def test_pbit_run_paused(dut):
    """
    run=0 freezes p-bit state even while TRNG would continue to produce bytes.

    (trng_bypass=0 so neoTRNG keeps running internally, but the pbit_array
    gate on 'run' should prevent updates.)
    """
    dut._log.info("Start — p-bit run/pause test")
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # Warm up
    await _reset_and_run(dut, 600)

    # Pause (run=0, bypass=0 so TRNG still ticks internally)
    dut.ui_in.value = 0b000
    frozen = int(dut.uo_out.value) & 0x0F
    dut._log.info(f"Frozen p-bits at 0b{frozen:04b}")

    for _ in range(20 if GL_TEST else 300):  # GL: 20 cycles is sufficient
        await ClockCycles(dut.clk, 1)
        current = int(dut.uo_out.value) & 0x0F
        assert current == frozen, \
            f"P-bit state changed while paused: 0b{current:04b} != 0b{frozen:04b}"

    dut._log.info("Run/pause held correctly")


@cocotb.test(skip=GL_TEST)  # Boltzmann statistics — RTL concern only
async def test_pbit_ferromagnetic_alignment(dut):
    """
    Ferromagnetic Ising ground-state test.

    With all-positive coupling, the Boltzmann distribution strongly favours
    the two ground states: all-0 (0b0000) and all-1 (0b1111).
    After a warm-up period we sample 500 times and assert that aligned states
    appear in >20% of samples — far above the 2/16 = 12.5% expected from a
    uniform distribution over all 16 states.
    """
    dut._log.info("Start — ferromagnetic alignment test")
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # Warm up (give network time to relax toward ground states)
    await _reset_and_run(dut, 1000)

    # Collect samples
    aligned = 0
    total = 500
    for _ in range(total):
        await ClockCycles(dut.clk, 5)
        s = int(dut.uo_out.value) & 0x0F
        if s == 0x0 or s == 0xF:
            aligned += 1

    fraction = aligned / total
    dut._log.info(f"Aligned states: {aligned}/{total} = {fraction:.1%}")
    assert fraction > 0.20, \
        f"Ferromagnetic alignment too weak: {fraction:.1%} (expected >20%)"


# ---------------------------------------------------------------------------
# MAX-CUT demo test
# ---------------------------------------------------------------------------

def _ring_cut(s):
    """Number of ring edges (0-1-2-3-0) crossing the partition s (int, 4 bits)."""
    b = [(s >> i) & 1 for i in range(4)]
    return (b[0] ^ b[1]) + (b[1] ^ b[2]) + (b[2] ^ b[3]) + (b[3] ^ b[0])


@cocotb.test(skip=GL_TEST)  # statistical + slow SPI load; covered by RTL test
async def test_max_cut_4_ring(dut):
    """
    MAX-CUT on a 4-node ring — a real combinatorial optimisation problem.

    Graph topology:  pbit0 ── pbit1 ── pbit2 ── pbit3 ── pbit0
    All edge weights = 1.  MAX-CUT = 4 (all edges), achieved by the unique
    bipartite 2-colouring: {pbit0, pbit2} vs {pbit1, pbit3}.
    Optimal states: 0101 (int 5) and 1010 (int 10).

    Ising encoding  (±1 spin convention):
      J[i][j] = -40 for ring edges  → antiferromagnetic
      J[i][j] =   0 for non-edges (0,2) and (1,3)

    Energy landscape (K=40):
      cut = 4  →  E = -160  ← ground state (MAX-CUT solution)
      cut = 2  →  E =    0  ← 12 sub-optimal states
      cut = 0  →  E = +160  ← worst states (0000 / 1111)

    In each ground state every bit has ≥81.25 % probability of staying correct
    on each Gibbs step (thresh ∈ {48, 208}).

    Assertions:
      • ground-state fraction > 25 %  (baseline random = 2/16 = 12.5 %)
      • high-energy states (0000, 1111) < 8 % combined
      • the single most-sampled state is one of the two ground states
    """
    dut._log.info("Start — MAX-CUT 4-ring test")
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value  = 0b000
    dut.uio_in.value = _SPI_IDLE
    dut.rst_n.value  = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    # Load antiferromagnetic ring J matrix.
    # Ring edges: (0,1), (1,2), (2,3), (3,0)  →  J = -40
    # Non-edges:  (0,2), (1,3)                 →  J =  0  (overwrite reset default K=32)
    ring_j = [
        (0, 1, -40), (0, 2,   0), (0, 3, -40),
        (1, 0, -40), (1, 2, -40), (1, 3,   0),
        (2, 0,   0), (2, 1, -40), (2, 3, -40),
        (3, 0, -40), (3, 1,   0), (3, 2, -40),
    ]
    for row, col, val in ring_j:
        await _spi_write_j(dut, row, col, val)

    # Start network
    dut.uio_in.value = _SPI_IDLE
    dut.ui_in.value  = 0b001  # run=1
    await ClockCycles(dut.clk, 2000)  # warm-up

    # Collect samples
    N = 1000
    counts = [0] * 16
    for _ in range(N):
        await ClockCycles(dut.clk, 5)
        counts[int(dut.uo_out.value) & 0x0F] += 1

    # ---- Results histogram ---------------------------------------------------
    GROUND = {5, 10}       # 0b0101=5, 0b1010=10 → cut=4, E=-160
    WORST  = {0, 15}       # 0b0000=0, 0b1111=15 → cut=0, E=+160

    dut._log.info(f"MAX-CUT 4-ring  —  {N} samples")
    dut._log.info("  state | count |  frac  | cut | E(K=40) | distribution")
    dut._log.info("  ------+-------+--------+-----+---------+--...")
    for s in range(16):
        cnt  = counts[s]
        frac = cnt / N
        cut  = _ring_cut(s)
        E    = 160 - 80 * cut          # E = K*(4-2*cut) = 40*(4-2*cut) = 160-80*cut
        bar  = "█" * round(frac * 60)  # scale: 60 chars = 100 %
        tag  = "  ◄ OPTIMAL"  if s in GROUND else \
               "  ← worst"   if s in WORST  else ""
        dut._log.info(
            f"  {s:04b}  |  {cnt:4d}  | {frac:5.1%}  |  {cut}  |  {E:+5d}  | {bar}{tag}"
        )

    gs_frac = sum(counts[s] for s in GROUND) / N
    wo_frac = sum(counts[s] for s in WORST)  / N
    best    = max(range(16), key=lambda s: counts[s])

    dut._log.info(f"Ground-state (cut=4) fraction : {gs_frac:.1%}  (random baseline 12.5 %)")
    dut._log.info(f"High-energy  (cut=0) fraction : {wo_frac:.1%}")
    dut._log.info(f"Most-sampled state            : {best:04b} (int {best})"
                  f"  {'✓ ground state' if best in GROUND else '✗ NOT a ground state'}")

    # ---- Assertions ----------------------------------------------------------
    assert gs_frac > 0.25, (
        f"Ground states underrepresented: {gs_frac:.1%} < 25 % — "
        "chip not converging to MAX-CUT solution"
    )
    assert wo_frac < 0.08, (
        f"High-energy states not suppressed: {wo_frac:.1%} ≥ 8 % — "
        "Boltzmann distribution not working"
    )
    assert best in GROUND, (
        f"Most frequent state 0b{best:04b} (cut={_ring_cut(best)}) is not a MAX-CUT solution"
    )


# ---------------------------------------------------------------------------
# SPI loading tests
# ---------------------------------------------------------------------------

# uio_in bit assignments (from project.v / info.yaml):
#   bit 0 = SPI_CS_n (active low)
#   bit 1 = SPI_MOSI
#   bit 2 = SPI_MISO (output — don't drive)
#   bit 3 = SPI_SCK
_SPI_CS_N = 0x01
_SPI_MOSI = 0x02
_SPI_SCK  = 0x08
_SPI_IDLE = _SPI_CS_N  # CS deasserted, SCK=0, MOSI=0


async def _spi_write_j(dut, row, col, value, sck_half=8):
    """
    Bit-bang one SPI frame to write J[row][col] = value (signed int).

    Protocol: 16-bit transfer (addr byte then data byte), MSB first,
    SPI Mode 0.  sck_half is the SCK half-period in system clock cycles;
    default 8 clocks gives ~1.56 MHz SCK at 25 MHz sysclk, well within
    the 2-FF synchroniser's safe operating range.
    """
    addr = (row * 4 + col) & 0xFF
    data = value & 0xFF  # two's-complement encode if negative

    # CS low — begin transaction
    dut.uio_in.value = 0x00   # CS=0, SCK=0, MOSI=0
    await ClockCycles(dut.clk, 4)

    for byte_val in [addr, data]:
        for bit_idx in range(7, -1, -1):
            mosi_bit = (byte_val >> bit_idx) & 1
            # SCK low, MOSI valid
            dut.uio_in.value = mosi_bit * _SPI_MOSI
            await ClockCycles(dut.clk, sck_half)
            # SCK high — slave samples MOSI here
            dut.uio_in.value = (mosi_bit * _SPI_MOSI) | _SPI_SCK
            await ClockCycles(dut.clk, sck_half)

    # SCK low final
    dut.uio_in.value = 0x00
    await ClockCycles(dut.clk, 4)
    # CS high — end transaction
    dut.uio_in.value = _SPI_IDLE
    await ClockCycles(dut.clk, 8)


async def _load_j_matrix(dut, k):
    """
    Write all 12 off-diagonal J entries to k (8-bit signed) via SPI.
    Diagonal entries (J[i][i]) are left at their reset default (0).
    """
    for row in range(4):
        for col in range(4):
            if row != col:
                await _spi_write_j(dut, row, col, k)


@cocotb.test(skip=GL_TEST)  # statistical assertion needs many cycles; RTL concern
async def test_spi_strong_ferromagnet(dut):
    """
    SPI loading: write K=40 (stronger coupling than reset default K=8).

    With K=40, thresh for a fully-aligned neighbourhood is 128+3*40=248,
    making the ground states (all-0, all-1) extremely stable.  We expect
    ferromagnetic alignment well above the default K=8 result (~32%).
    """
    dut._log.info("Start — SPI strong ferromagnet test")
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset (j_reg → ferromagnetic K=8 defaults, states → 0)
    dut.ena.value = 1
    dut.ui_in.value  = 0b000
    dut.uio_in.value = _SPI_IDLE
    dut.rst_n.value  = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    # Load K=40 for all 12 off-diagonal entries (run=0 during load)
    await _load_j_matrix(dut, 40)

    # Deassert CS, start network
    dut.uio_in.value = _SPI_IDLE
    dut.ui_in.value  = 0b001  # run=1
    await ClockCycles(dut.clk, 1000)  # warm-up

    aligned = 0
    total = 500
    for _ in range(total):
        await ClockCycles(dut.clk, 5)
        s = int(dut.uo_out.value) & 0x0F
        if s == 0x0 or s == 0xF:
            aligned += 1

    fraction = aligned / total
    dut._log.info(f"K=40 aligned: {aligned}/{total} = {fraction:.1%}")
    assert fraction > 0.50, \
        f"Strong ferromagnet alignment too low: {fraction:.1%} (expected >50%)"


@cocotb.test(skip=GL_TEST)  # statistical assertion needs many cycles; RTL concern
async def test_spi_uncoupled(dut):
    """
    SPI loading: write J=0 for all entries (completely decouple p-bits).

    With J=0 every p-bit flips independently at 50/50.  The stationary
    distribution is uniform over all 16 states, so the aligned fraction
    (0000 or 1111) should be close to 2/16 = 12.5% — well below the
    ferromagnetic default of ~32%.
    """
    dut._log.info("Start — SPI uncoupled J=0 test")
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value  = 0b000
    dut.uio_in.value = _SPI_IDLE
    dut.rst_n.value  = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    # Load J=0 (fully uncoupled)
    await _load_j_matrix(dut, 0)

    dut.uio_in.value = _SPI_IDLE
    dut.ui_in.value  = 0b001  # run=1
    await ClockCycles(dut.clk, 2000)  # warm-up

    aligned = 0
    total = 500
    for _ in range(total):
        await ClockCycles(dut.clk, 5)
        s = int(dut.uo_out.value) & 0x0F
        if s == 0x0 or s == 0xF:
            aligned += 1

    fraction = aligned / total
    dut._log.info(f"J=0 aligned: {aligned}/{total} = {fraction:.1%}")
    # Uniform distribution → ~12.5% aligned.  Assert clearly below ferromagnet.
    assert fraction < 0.22, \
        f"Uncoupled alignment too high: {fraction:.1%} (expected <22%; " \
        f"ferromagnet gives ~32%, suggesting SPI write did not take effect)"
