/*
 * Copyright (c) 2026 Isaac W
 * SPDX-License-Identifier: Apache-2.0
 *
 * pbit_array — 6 probabilistic bits with a software-loadable J coupling matrix.
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
 *   36 × 8-bit signed registers, j_reg[6·row + col] = J[row][col].
 *   Diagonal entries (row == col) are never accessed by the update logic.
 *   Reset default: ferromagnetic K=20 (all off-diagonal = 8'd20).
 *   SPI write port (wr_en / wr_addr / wr_data) loads new values at runtime.
 *
 * Cell cost estimate: ~350–450 cells (J reg file dominates).
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
    input  wire  [5:0] wr_addr,
    input  wire  [7:0] wr_data,
    output reg   [5:0] states
);

  // ---- J coupling matrix register file ------------------------------------
  // j_reg[6*row + col] = J[row][col], 8-bit signed
  // Reset: ferromagnetic K=20 for all off-diagonal, 0 on diagonal.
  // K=20 gives net_max = 5*20 = 100, thresh ∈ {28, 78, 128, 178, 228} — solid coupling.
  // K must be < 26 to avoid an all-zeros absorbing state (thresh_min = 128 - 5K > 0).
  // K=20 gives thresh_min = 28, so P(escape from all-zeros) ≈ 11% per update.
  reg signed [7:0] j_reg [0:35];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Row 0
      j_reg[0]  <= 8'sd0;  j_reg[1]  <= 8'sd20; j_reg[2]  <= 8'sd20;
      j_reg[3]  <= 8'sd20; j_reg[4]  <= 8'sd20; j_reg[5]  <= 8'sd20;
      // Row 1
      j_reg[6]  <= 8'sd20; j_reg[7]  <= 8'sd0;  j_reg[8]  <= 8'sd20;
      j_reg[9]  <= 8'sd20; j_reg[10] <= 8'sd20; j_reg[11] <= 8'sd20;
      // Row 2
      j_reg[12] <= 8'sd20; j_reg[13] <= 8'sd20; j_reg[14] <= 8'sd0;
      j_reg[15] <= 8'sd20; j_reg[16] <= 8'sd20; j_reg[17] <= 8'sd20;
      // Row 3
      j_reg[18] <= 8'sd20; j_reg[19] <= 8'sd20; j_reg[20] <= 8'sd20;
      j_reg[21] <= 8'sd0;  j_reg[22] <= 8'sd20; j_reg[23] <= 8'sd20;
      // Row 4
      j_reg[24] <= 8'sd20; j_reg[25] <= 8'sd20; j_reg[26] <= 8'sd20;
      j_reg[27] <= 8'sd20; j_reg[28] <= 8'sd0;  j_reg[29] <= 8'sd20;
      // Row 5
      j_reg[30] <= 8'sd20; j_reg[31] <= 8'sd20; j_reg[32] <= 8'sd20;
      j_reg[33] <= 8'sd20; j_reg[34] <= 8'sd20; j_reg[35] <= 8'sd0;
    end else if (wr_en) begin
      j_reg[wr_addr] <= $signed(wr_data);
    end
  end

  // ---- Round-robin update index -------------------------------------------
  reg [2:0] upd_idx;

  // ---- Base address of the row currently being updated --------------------
  // row_base = upd_idx * 6; computed via case to avoid implicit multiplier.
  reg [5:0] row_base;
  always @(*) begin
    case (upd_idx)
      3'd0: row_base = 6'd0;
      3'd1: row_base = 6'd6;
      3'd2: row_base = 6'd12;
      3'd3: row_base = 6'd18;
      3'd4: row_base = 6'd24;
      3'd5: row_base = 6'd30;
      default: row_base = 6'd0;
    endcase
  end

  // ---- J values for the row currently being updated (combinational mux) ---
  wire signed [7:0] Jrow0 = j_reg[row_base + 6'd0]; // J[upd_idx][0]
  wire signed [7:0] Jrow1 = j_reg[row_base + 6'd1]; // J[upd_idx][1]
  wire signed [7:0] Jrow2 = j_reg[row_base + 6'd2]; // J[upd_idx][2]
  wire signed [7:0] Jrow3 = j_reg[row_base + 6'd3]; // J[upd_idx][3]
  wire signed [7:0] Jrow4 = j_reg[row_base + 6'd4]; // J[upd_idx][4]
  wire signed [7:0] Jrow5 = j_reg[row_base + 6'd5]; // J[upd_idx][5]

  // ---- Spin contributions (+J if state=1, −J if state=0) ------------------
  // Sign-extend each J to 11 bits then conditionally negate.
  // Max |contribution| = 128; max |net| (5 terms) = 640, fits in 11-bit signed.
  wire signed [10:0] c0 = states[0] ? {{3{Jrow0[7]}}, Jrow0} : -({{3{Jrow0[7]}}, Jrow0});
  wire signed [10:0] c1 = states[1] ? {{3{Jrow1[7]}}, Jrow1} : -({{3{Jrow1[7]}}, Jrow1});
  wire signed [10:0] c2 = states[2] ? {{3{Jrow2[7]}}, Jrow2} : -({{3{Jrow2[7]}}, Jrow2});
  wire signed [10:0] c3 = states[3] ? {{3{Jrow3[7]}}, Jrow3} : -({{3{Jrow3[7]}}, Jrow3});
  wire signed [10:0] c4 = states[4] ? {{3{Jrow4[7]}}, Jrow4} : -({{3{Jrow4[7]}}, Jrow4});
  wire signed [10:0] c5 = states[5] ? {{3{Jrow5[7]}}, Jrow5} : -({{3{Jrow5[7]}}, Jrow5});

  // ---- Net field (exclude self-coupling) -----------------------------------
  reg signed [10:0] net;
  always @(*) begin
    case (upd_idx)
      3'd0: net = c1 + c2 + c3 + c4 + c5;
      3'd1: net = c0 + c2 + c3 + c4 + c5;
      3'd2: net = c0 + c1 + c3 + c4 + c5;
      3'd3: net = c0 + c1 + c2 + c4 + c5;
      3'd4: net = c0 + c1 + c2 + c3 + c5;
      3'd5: net = c0 + c1 + c2 + c3 + c4;
      default: net = 11'sd0;
    endcase
  end

  // ---- Saturate net to 8-bit signed [-128, +127] ---------------------------
  wire signed [7:0] net_sat = (net > 11'sd127) ? 8'sd127 :
                              (net < -11'sd128) ? 8'sh80  : net[7:0];

  // ---- Probability threshold -----------------------------------------------
  // thresh = 128 + net_sat, mapping [-128,127] → [0,255]
  // Unsigned 8-bit: 0x80 + 2's-complement(net_sat) gives the correct result
  // because the mathematical sum always lies in [0,255] after saturation.
  wire [7:0] thresh = 8'd128 + $unsigned(net_sat);

  // ---- Sequential Gibbs update ---------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      states  <= 6'b0;
      upd_idx <= 3'd0;
    end else if (run && trng_valid) begin
      states[upd_idx] <= (trng_data < thresh) ? 1'b1 : 1'b0;
      upd_idx <= (upd_idx == 3'd5) ? 3'd0 : upd_idx + 3'd1;
    end
  end

endmodule
