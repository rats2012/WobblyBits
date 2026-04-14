/*
 * Copyright (c) 2026 Isaac W
 * SPDX-License-Identifier: Apache-2.0
 *
 * WobblyBits — probabilistic computing chip
 *
 * Stage 1: TRNG wired up, raw random bytes on uo_out.
 *          P-bit array and SPI coupling matrix to follow.
 *
 * Pinout:
 *   ui_in[0]  — run         (1 = TRNG running, 0 = paused)
 *   ui_in[1]  — step        (reserved, unused this stage)
 *   ui_in[2]  — trng_bypass (1 = freeze output register)
 *   uio[0]    — SPI_CS      (input, reserved)
 *   uio[1]    — SPI_MOSI    (input, reserved)
 *   uio[2]    — SPI_MISO    (output, reserved)
 *   uio[3]    — SPI_SCK     (input, reserved)
 *   uo_out    — live p-bit states (currently: raw TRNG byte)
 */

`default_nettype none

// Pass SIM_MODE=1 when building for simulation (add -DSIM_MODE to Makefile).
// Physical synthesis leaves SIM_MODE=0 so ring oscillators are real.
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

  wire run         = ui_in[0];
  wire trng_bypass = ui_in[2];

  // SPI pins: MISO (uio[2]) is output; CS/MOSI/SCK are inputs.
  assign uio_out = 8'h00;
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
    .enable_i (run),
    .valid_o  (trng_valid),
    .data_o   (trng_data)
  );

  // ---- Output register -----------------------------------------------------
  // Captures latest TRNG byte. Frozen when trng_bypass=1.
  // TODO: replace with p-bit state register once p-bit array is implemented.
  reg [7:0] rnd_reg;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      rnd_reg <= 8'h00;
    else if (trng_valid && !trng_bypass)
      rnd_reg <= trng_data;
  end

  assign uo_out = rnd_reg;

  wire _unused = &{ena, uio_in, ui_in[7:3], ui_in[1], 1'b0};

endmodule
