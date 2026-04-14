/*
 * Copyright (c) 2026 Isaac W
 * SPDX-License-Identifier: Apache-2.0
 *
 * pbit_array — 4 probabilistic bits with a software-loadable J coupling matrix.
 *
 * Update rule (sequential Gibbs sampling):
 *   Each TRNG byte drives one p-bit update in round-robin order.
 *   p(s_i = 1) ≈ sigmoid(net_i) ≈ thresh_i / 256
 *
 * Net field (±1 spin convention):
 *   net_i = Σ_{j≠i} J[i][j] · (2·s_j − 1)
 *   where J[i][j] is the 8-bit signed coupling weight.
 *
 * Sigmoid approximation:
 *   thresh = clamp(128 + net_i, 0, 255)
 *   (linear approximation; saturates at |net| > 127)
 *   s_i_new = (trng_byte < thresh) ? 1 : 0
 *
 * J register file:
 *   16 × 8-bit signed registers, j_reg[4·row + col] = J[row][col].
 *   Diagonal entries (row == col) are never accessed by the update logic.
 *   Reset default: ferromagnetic K=32 (all off-diagonal = 8'd32).
 *   SPI write port (wr_en / wr_addr / wr_data) loads new values at runtime.
 *
 * Cell cost estimate: ~220–280 cells (J reg file dominates).
 */

`default_nettype none

module pbit_array (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       run,        // 1 = updates enabled
    input  wire       trng_valid, // pulse: new TRNG byte ready
    input  wire [7:0] trng_data,  // random byte from neoTRNG
    // SPI write port from spi_j_slave (one-cycle pulse)
    input  wire        wr_en,
    input  wire  [3:0] wr_addr,
    input  wire  [7:0] wr_data,
    output reg   [3:0] states
);

  // ---- J coupling matrix register file ------------------------------------
  // j_reg[4*row + col] = J[row][col], 8-bit signed
  // Reset: ferromagnetic K=32 for all off-diagonal, 0 on diagonal.
  // K=32 gives net_max = 3*32 = 96, thresh ∈ {32, 96, 160, 224} — strong coupling.
  // (K=8 is too weak with the ±1 net computation; K=32 reproduces the same
  //  probability spread as the previous hardcoded-LUT design.)
  reg signed [7:0] j_reg [0:15];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      j_reg[0]  <= 8'sd0;  j_reg[1]  <= 8'sd32; j_reg[2]  <= 8'sd32; j_reg[3]  <= 8'sd32;
      j_reg[4]  <= 8'sd32; j_reg[5]  <= 8'sd0;  j_reg[6]  <= 8'sd32; j_reg[7]  <= 8'sd32;
      j_reg[8]  <= 8'sd32; j_reg[9]  <= 8'sd32; j_reg[10] <= 8'sd0;  j_reg[11] <= 8'sd32;
      j_reg[12] <= 8'sd32; j_reg[13] <= 8'sd32; j_reg[14] <= 8'sd32; j_reg[15] <= 8'sd0;
    end else if (wr_en) begin
      j_reg[wr_addr] <= $signed(wr_data);
    end
  end

  // ---- Round-robin update index -------------------------------------------
  reg [1:0] upd_idx;

  // ---- J values for the row currently being updated (combinational mux) ---
  // j_reg[{upd_idx, 2'b00}] = J[upd_idx][0], etc.
  wire signed [7:0] Jrow0 = j_reg[{upd_idx, 2'd0}]; // J[upd_idx][0]
  wire signed [7:0] Jrow1 = j_reg[{upd_idx, 2'd1}]; // J[upd_idx][1]
  wire signed [7:0] Jrow2 = j_reg[{upd_idx, 2'd2}]; // J[upd_idx][2]
  wire signed [7:0] Jrow3 = j_reg[{upd_idx, 2'd3}]; // J[upd_idx][3]

  // ---- Spin contributions (+J if state=1, −J if state=0) ------------------
  // Sign-extend each J to 10 bits then conditionally negate.
  // Max |contribution| = 128; max |net| (3 terms) = 384, fits in 10-bit signed.
  wire signed [9:0] c0 = states[0] ? {{2{Jrow0[7]}}, Jrow0} : -({{2{Jrow0[7]}}, Jrow0});
  wire signed [9:0] c1 = states[1] ? {{2{Jrow1[7]}}, Jrow1} : -({{2{Jrow1[7]}}, Jrow1});
  wire signed [9:0] c2 = states[2] ? {{2{Jrow2[7]}}, Jrow2} : -({{2{Jrow2[7]}}, Jrow2});
  wire signed [9:0] c3 = states[3] ? {{2{Jrow3[7]}}, Jrow3} : -({{2{Jrow3[7]}}, Jrow3});

  // ---- Net field (exclude self-coupling) -----------------------------------
  reg signed [9:0] net;
  always @(*) begin
    case (upd_idx)
      2'd0: net = c1 + c2 + c3;
      2'd1: net = c0 + c2 + c3;
      2'd2: net = c0 + c1 + c3;
      2'd3: net = c0 + c1 + c2;
      default: net = 10'sd0;
    endcase
  end

  // ---- Saturate net to 8-bit signed [-128, +127] ---------------------------
  wire signed [7:0] net_sat = (net > 10'sd127) ? 8'sd127 :
                              (net < -10'sd128) ? 8'sh80  : net[7:0];

  // ---- Probability threshold -----------------------------------------------
  // thresh = 128 + net_sat, mapping [-128,127] → [0,255]
  // Unsigned 8-bit: 0x80 + 2's-complement(net_sat) gives the correct result
  // because the mathematical sum always lies in [0,255] after saturation.
  wire [7:0] thresh = 8'd128 + $unsigned(net_sat);

  // ---- Sequential Gibbs update ---------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      states  <= 4'b0;
      upd_idx <= 2'd0;
    end else if (run && trng_valid) begin
      states[upd_idx] <= (trng_data < thresh) ? 1'b1 : 1'b0;
      upd_idx <= upd_idx + 2'd1; // wraps 3→0 naturally
    end
  end

endmodule
