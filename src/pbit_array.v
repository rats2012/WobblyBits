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
 *   External SPI view remains a 6 × 6 matrix with addr = 6·row + col.
 *   Internally we store only the 15 unique off-diagonal pairs and enforce
 *   J[i][j] == J[j][i]. Diagonal entries are hard-wired to 0.
 *   Reset default: ferromagnetic K=20 (all off-diagonal = 8'd20).
 *   SPI writes to either half of a symmetric pair update the same storage.
 *
 * rand_init input:
 *   When rand_init=1, the first trng_valid pulse after run is asserted seeds
 *   states[5:0] from that TRNG byte instead of performing a Gibbs update.
 *   This breaks the fixed-reset symmetry that would otherwise trap the chain
 *   in one of several degenerate ground-state basins (e.g. MAX-CUT problems
 *   where multiple optimal partitions exist).  With rand_init=0 behaviour is
 *   unchanged: states reset to 000000 and all TRNG bytes drive Gibbs updates.
 *   seed_done is cleared when run=0 so each new run=1 assertion gets a fresh
 *   seed.
 *
 * Cell cost estimate: dominated by the J store and its muxing.
 */

`default_nettype none

module pbit_array (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       run,        // 1 = updates enabled
    input  wire       rand_init,  // 1 = seed states from TRNG on run rising edge
    input  wire       trng_valid, // pulse: new TRNG byte ready
    input  wire [7:0] trng_data,  // random byte from neoTRNG
    // SPI write port from spi_j_slave (one-cycle pulse)
    input  wire        wr_en,
    input  wire  [5:0] wr_addr,
    input  wire  [7:0] wr_data,
    // SPI read port — combinatorial J register lookup for MISO readback
    input  wire  [5:0] rd_addr,  // register address from spi_j_slave (combinatorial)
    output wire  [7:0] rd_data,  // J register value (combinatorial mux)
    output reg   [5:0] states
);

  // ---- J coupling matrix register file ------------------------------------
  // Store only the 15 unique off-diagonal pairs:
  // (0,1) (0,2) (0,3) (0,4) (0,5) (1,2) (1,3) (1,4) (1,5)
  // (2,3) (2,4) (2,5) (3,4) (3,5) (4,5)
  // Reset: ferromagnetic K=20 for all off-diagonal, 0 on diagonal.
  // K=20 gives net_max = 5*20 = 100, thresh ∈ {28, 78, 128, 178, 228} — solid coupling.
  // K must be < 26 to avoid an all-zeros absorbing state (thresh_min = 128 - 5K > 0).
  // K=20 gives thresh_min = 28, so P(escape from all-zeros) ≈ 11% per update.
  reg signed [7:0] j_01, j_02, j_03, j_04, j_05;
  reg signed [7:0] j_12, j_13, j_14, j_15;
  reg signed [7:0] j_23, j_24, j_25;
  reg signed [7:0] j_34, j_35;
  reg signed [7:0] j_45;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      j_01 <= 8'sd20; j_02 <= 8'sd20; j_03 <= 8'sd20; j_04 <= 8'sd20; j_05 <= 8'sd20;
      j_12 <= 8'sd20; j_13 <= 8'sd20; j_14 <= 8'sd20; j_15 <= 8'sd20;
      j_23 <= 8'sd20; j_24 <= 8'sd20; j_25 <= 8'sd20;
      j_34 <= 8'sd20; j_35 <= 8'sd20;
      j_45 <= 8'sd20;
    end else if (wr_en) begin
      case (wr_addr)
        6'd1,  6'd6:  j_01 <= $signed(wr_data);
        6'd2,  6'd12: j_02 <= $signed(wr_data);
        6'd3,  6'd18: j_03 <= $signed(wr_data);
        6'd4,  6'd24: j_04 <= $signed(wr_data);
        6'd5,  6'd30: j_05 <= $signed(wr_data);
        6'd8,  6'd13: j_12 <= $signed(wr_data);
        6'd9,  6'd19: j_13 <= $signed(wr_data);
        6'd10, 6'd25: j_14 <= $signed(wr_data);
        6'd11, 6'd31: j_15 <= $signed(wr_data);
        6'd15, 6'd20: j_23 <= $signed(wr_data);
        6'd16, 6'd26: j_24 <= $signed(wr_data);
        6'd17, 6'd32: j_25 <= $signed(wr_data);
        6'd22, 6'd27: j_34 <= $signed(wr_data);
        6'd23, 6'd33: j_35 <= $signed(wr_data);
        6'd29, 6'd34: j_45 <= $signed(wr_data);
        default: begin
        end
      endcase
    end
  end

  // ---- Combinatorial J register read (for SPI MISO readback) ---------------
  // "real" addresses only (lower-index address of each symmetric pair).
  // Reading via the transposed address (e.g. J[1][0] instead of J[0][1])
  // returns 0 — use the lower-row address for reads.  This halves the decoder
  // logic relative to a full 30-entry alias map, saving area.
  // Diagonal and out-of-range addresses return 0.
  reg signed [7:0] rd_data_r;
  always @(*) begin
    case (rd_addr)
      6'd1:  rd_data_r = j_01;  // J[0][1]
      6'd2:  rd_data_r = j_02;  // J[0][2]
      6'd3:  rd_data_r = j_03;  // J[0][3]
      6'd4:  rd_data_r = j_04;  // J[0][4]
      6'd5:  rd_data_r = j_05;  // J[0][5]
      6'd8:  rd_data_r = j_12;  // J[1][2]
      6'd9:  rd_data_r = j_13;  // J[1][3]
      6'd10: rd_data_r = j_14;  // J[1][4]
      6'd11: rd_data_r = j_15;  // J[1][5]
      6'd15: rd_data_r = j_23;  // J[2][3]
      6'd16: rd_data_r = j_24;  // J[2][4]
      6'd17: rd_data_r = j_25;  // J[2][5]
      6'd22: rd_data_r = j_34;  // J[3][4]
      6'd23: rd_data_r = j_35;  // J[3][5]
      6'd29: rd_data_r = j_45;  // J[4][5]
      default: rd_data_r = 8'h00;
    endcase
  end
  assign rd_data = rd_data_r;

  // ---- Round-robin update index + rand_init seed tracking ----------------
  reg [2:0] upd_idx;
  reg       seed_done;   // cleared on run=0; set after first-byte seed

  // ---- J values for the row currently being updated ------------------------
  reg signed [7:0] Jrow0, Jrow1, Jrow2, Jrow3, Jrow4, Jrow5;
  always @(*) begin
    case (upd_idx)
      3'd0: begin
        Jrow0 = 8'sd0; Jrow1 = j_01;  Jrow2 = j_02;
        Jrow3 = j_03;  Jrow4 = j_04;  Jrow5 = j_05;
      end
      3'd1: begin
        Jrow0 = j_01;  Jrow1 = 8'sd0; Jrow2 = j_12;
        Jrow3 = j_13;  Jrow4 = j_14;  Jrow5 = j_15;
      end
      3'd2: begin
        Jrow0 = j_02;  Jrow1 = j_12;  Jrow2 = 8'sd0;
        Jrow3 = j_23;  Jrow4 = j_24;  Jrow5 = j_25;
      end
      3'd3: begin
        Jrow0 = j_03;  Jrow1 = j_13;  Jrow2 = j_23;
        Jrow3 = 8'sd0; Jrow4 = j_34;  Jrow5 = j_35;
      end
      3'd4: begin
        Jrow0 = j_04;  Jrow1 = j_14;  Jrow2 = j_24;
        Jrow3 = j_34;  Jrow4 = 8'sd0; Jrow5 = j_45;
      end
      3'd5: begin
        Jrow0 = j_05;  Jrow1 = j_15;  Jrow2 = j_25;
        Jrow3 = j_35;  Jrow4 = j_45;  Jrow5 = 8'sd0;
      end
      default: begin
        Jrow0 = 8'sd0; Jrow1 = 8'sd0; Jrow2 = 8'sd0;
        Jrow3 = 8'sd0; Jrow4 = 8'sd0; Jrow5 = 8'sd0;
      end
    endcase
  end

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
  // rand_init=1: the first trng_valid pulse after run is asserted seeds all
  // six states from that TRNG byte instead of doing a normal Gibbs update.
  // seed_done is cleared whenever run=0 so each new run=1 assertion can seed.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      states    <= 6'b0;
      upd_idx   <= 3'd0;
      seed_done <= 1'b0;
    end else begin
      if (!run) begin
        seed_done <= 1'b0;
      end else if (run && trng_valid) begin
        if (rand_init && !seed_done) begin
          // First TRNG byte with rand_init=1: seed all states.
          states    <= trng_data[5:0];
          seed_done <= 1'b1;
        end else begin
          // Normal Gibbs update.
          states[upd_idx] <= (trng_data < thresh) ? 1'b1 : 1'b0;
          upd_idx <= (upd_idx == 3'd5) ? 3'd0 : upd_idx + 3'd1;
        end
      end
    end
  end

endmodule
