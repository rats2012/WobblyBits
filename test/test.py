# SPDX-FileCopyrightText: © 2026 WobblyBits
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


@cocotb.test()
async def test_trng_produces_output(dut):
    """
    Smoke test: TRNG wired up and producing bytes.

    In SIM_MODE the ring oscillators are registered inverters, so they
    oscillate deterministically. After ~150 clocks the first valid byte
    should appear; we wait 600 to be safe and check uo_out has changed
    from its post-reset value.
    """
    dut._log.info("Start — TRNG smoke test")

    clock = Clock(dut.clk, 40, unit="ns")  # 25 MHz
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0   # run=0, trng_bypass=0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    assert dut.uo_out.value == 0, \
        f"Expected uo_out=0 after reset, got {dut.uo_out.value}"

    # Enable TRNG (run=1)
    dut.ui_in.value = 0b001  # ui[0]=run

    # Collect samples and look for at least two distinct values,
    # proving the TRNG is producing varying bytes.
    samples = set()
    for _ in range(120):           # 120 × 5 = 600 clock cycles
        await ClockCycles(dut.clk, 5)
        samples.add(int(dut.uo_out.value))

    dut._log.info(f"Distinct uo_out values seen: {sorted(samples)}")
    assert len(samples) > 1, \
        f"uo_out never changed — TRNG not producing output. Stuck at {samples}"


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
    await ClockCycles(dut.clk, 400)

    # Freeze
    dut.ui_in.value = 0b101  # run=1, bypass=1
    frozen_value = int(dut.uo_out.value)
    dut._log.info(f"Frozen at uo_out=0x{frozen_value:02x}")

    # Run 200 more cycles — output must not change
    for _ in range(200):
        await ClockCycles(dut.clk, 1)
        assert int(dut.uo_out.value) == frozen_value, \
            f"uo_out changed while bypassed: {int(dut.uo_out.value):#04x} != {frozen_value:#04x}"

    dut._log.info("Bypass held correctly")
