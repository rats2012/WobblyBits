/*
 * Copyright (c) 2026 Isaac W
 * SPDX-License-Identifier: Apache-2.0
 *
 * WobblyBits — probabilistic computing chip
 *
 * Stage 2: 6 p-bits with SPI-loadable coupling matrix.
 *          Ring-oscillator TRNG drives sequential Gibbs sampling.
 *          p-bit states appear on uo_out[5:0].
 *
 * Pinout:
 *   ui_in[0]  — run         (1 = network running, 0 = paused)
 *   ui_in[1]  — rand_init   (1 = seed p-bit states from TRNG on run rising edge)
 *   ui_in[2]  — trng_bypass (1 = freeze TRNG and p-bit updates for deterministic sim)
 *   uio[0]    — SPI_CS      (input, active low)
 *   uio[1]    — SPI_MOSI    (input)
 *   uio[2]    — SPI_MISO    (output, tied 0 — write-only for now)
 *   uio[3]    — SPI_SCK     (input)
 *   uo_out[5:0] — live p-bit states (pbit0–pbit5)
 *   uo_out[7:6] — reserved (tied 0)
 *
 * SPI loading (before asserting run):
 *   Send 16-bit frames [addr_byte][data_byte].
 *   addr[5:0] = J register index (0-35 = J[row*6+col], row-major external view).
 *   Internally the matrix is stored symmetrically, so J[i][j] and J[j][i]
 *   share the same physical weight register.
 *   data = 8-bit signed coupling weight.
 *   J resets to ferromagnetic K=20 on rst_n, so chip works without SPI config.
 */

`default_nettype none

`ifdef SIM_MODE
  `define TRNG_SIM_MODE 1
`else
  `define TRNG_SIM_MODE 0
`endif

module tt_um_Rats2012_WobblyBits (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when powered
    input  wire       clk,
    input  wire       rst_n
);

  // trng_bypass (ui_in[2]) pauses p-bit updates as well as TRNG.
  wire run       = ui_in[0] & ~ui_in[2];
  wire rand_init = ui_in[1];

  // TRNG runs whenever the chip is out of reset and not bypassed — decoupled
  // from run so that trng_data holds valid entropy by the time run is asserted.
  // This is required for rand_init seeding to work correctly.
  wire trng_en = ~ui_in[2];

  // MISO (uio[2]) is the only output; all other bidir pins are inputs.
  assign uio_out = 8'h00;  // MISO tied 0 (write-only SPI)
  assign uio_oe  = 8'b0000_0100; // uio[2] = MISO as output

  // ---- TRNG ----------------------------------------------------------------
  wire       trng_valid;
  wire [7:0] trng_data;

  neoTRNG #(
    .NUM_CELLS     (3),
    .NUM_INV_START (5),   // cells have 5, 7, 9 inverters
    .NUM_RAW_BITS  (16),
    .SIM_MODE      (`TRNG_SIM_MODE)
  ) trng (
    .clk_i    (clk),
    .rstn_i   (rst_n),
    .enable_i (trng_en),
    .valid_o  (trng_valid),
    .data_o   (trng_data)
  );

  // ---- SPI J-matrix loader -------------------------------------------------
  wire        spi_wr_en;
  wire  [5:0] spi_wr_addr;
  wire  [7:0] spi_wr_data;

  spi_j_slave spi (
    .clk      (clk),
    .rst_n    (rst_n),
    .spi_cs_n (uio_in[0]),   // CS   active low
    .spi_mosi (uio_in[1]),   // MOSI data in
    .spi_sck  (uio_in[3]),   // SCK  serial clock
    .wr_en    (spi_wr_en),
    .wr_addr  (spi_wr_addr),
    .wr_data  (spi_wr_data)
  );

  // ---- P-bit array ---------------------------------------------------------
  wire [5:0] pbit_states;

  pbit_array pbits (
    .clk        (clk),
    .rst_n      (rst_n),
    .run        (run),
    .rand_init  (rand_init),
    .trng_valid (trng_valid),
    .trng_data  (trng_data),
    .wr_en      (spi_wr_en),
    .wr_addr    (spi_wr_addr),
    .wr_data    (spi_wr_data),
    .states     (pbit_states)
  );

  assign uo_out = {2'b0, pbit_states};

  // uio_in[0]=SPI_CS, [1]=SPI_MOSI, [3]=SPI_SCK used by spi_j_slave.
  // uio_in[2]=MISO input path (MISO is output-only, input path unused).
  // uio_in[7:4] = spare.
  wire _unused = &{ena, ui_in[7:3], uio_in[7:4], uio_in[2], 1'b0};

endmodule
