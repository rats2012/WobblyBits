/*
 * neoTRNG v3.4 — Verilog port
 * Original VHDL: https://github.com/stnolting/neoTRNG
 * BSD 3-Clause License, Copyright (c) 2026 Stephan Nolting. All rights reserved.
 *
 * Architecture summary:
 *   NUM_CELLS ring-oscillator cells, each with an increasing odd number of
 *   inverters. An enable shift-register gives every inverter a unique enable
 *   signal so the synthesiser cannot merge "identical" inverters.
 *
 *   Cell outputs are XOR-combined → von Neumann de-biaser (edge extraction) →
 *   CRC-8 shift register collects NUM_RAW_BITS de-biased bits → one output byte.
 *
 * SIM_MODE:
 *   SIM_MODE=0  Physical synthesis — inverters are combinational (~inv_in).
 *               The latch+inverter chain forms a real ring oscillator.
 *               Do NOT use in iverilog/cocotb simulation (combinational loop).
 *   SIM_MODE=1  Simulation — inverters are registered FFs that break the loop.
 *               No true randomness, but the pipeline exercises correctly.
 */

`default_nettype none

// ============================================================================
// neoTRNG top
// ============================================================================
module neoTRNG #(
  parameter integer NUM_CELLS     = 3,   // ring-oscillator cells (>= 1)
  parameter integer NUM_INV_START = 5,   // inverters in first cell (odd, >= 3)
  parameter integer NUM_RAW_BITS  = 16,  // raw bits per output byte (power of 2)
  parameter integer SIM_MODE      = 0    // 1 = simulation mode
) (
  input  wire       clk_i,
  input  wire       rstn_i,
  input  wire       enable_i,
  output wire       valid_o,
  output wire [7:0] data_o
);

  localparam CNT_BITS = $clog2(NUM_RAW_BITS) + 1;

  // CRC-8: x^8 + x^2 + x + 1
  localparam [7:0] POLY = 8'h07;

  // ---- Enable chain --------------------------------------------------------
  wire [NUM_CELLS-1:0] cell_en_in;
  wire [NUM_CELLS-1:0] cell_en_out;
  wire [NUM_CELLS-1:0] cell_rnd;

  reg sample_en;

  assign cell_en_in[0] = sample_en;

  genvar ci;
  generate
    for (ci = 1; ci < NUM_CELLS; ci = ci + 1) begin : en_chain
      assign cell_en_in[ci] = cell_en_out[ci-1];
    end
  endgenerate

  // ---- Entropy cells -------------------------------------------------------
  genvar gi;
  generate
    for (gi = 0; gi < NUM_CELLS; gi = gi + 1) begin : cells
      neoTRNG_cell #(
        .NUM_INV  (NUM_INV_START + 2*gi),
        .SIM_MODE (SIM_MODE)
      ) u (
        .clk_i  (clk_i),
        .rstn_i (rstn_i),
        .en_i   (cell_en_in[gi]),
        .en_o   (cell_en_out[gi]),
        .rnd_o  (cell_rnd[gi])
      );
    end
  endgenerate

  // ---- XOR combine ---------------------------------------------------------
  wire cell_sum = ^cell_rnd;

  // ---- Von Neumann de-biasing ----------------------------------------------
  // Samples pairs of bits; keeps only transitions (01 → 0, 10 → 1).
  // Runs every second clock once the last enable chain has propagated.
  reg [1:0] debias_sreg;
  reg       debias_state;

  always @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      debias_sreg  <= 2'b00;
      debias_state <= 1'b0;
    end else begin
      debias_sreg  <= {debias_sreg[0], cell_sum};
      debias_state <= (~debias_state) & cell_en_out[NUM_CELLS-1];
    end
  end

  wire debias_valid = debias_state & (debias_sreg[1] ^ debias_sreg[0]);
  wire debias_data  = debias_sreg[0];

  // ---- Sampling + CRC-8 mixing ---------------------------------------------
  reg [CNT_BITS-1:0] sample_cnt;
  reg [7:0]          sample_sreg;

  always @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      sample_en   <= 1'b0;
      sample_cnt  <= 0;
      sample_sreg <= 8'h00;
    end else begin
      sample_en <= enable_i;
      if (!sample_en || sample_cnt[CNT_BITS-1]) begin
        // start new byte accumulation
        sample_cnt  <= 0;
        sample_sreg <= 8'h00;
      end else if (debias_valid) begin
        sample_cnt <= sample_cnt + 1'b1;
        // CRC-style mixing: shift left, XOR poly when feedback=1
        if (sample_sreg[7] ^ debias_data)
          sample_sreg <= {sample_sreg[6:0], 1'b0} ^ POLY;
        else
          sample_sreg <= {sample_sreg[6:0], 1'b0};
      end
    end
  end

  assign data_o  = sample_sreg;
  assign valid_o = sample_cnt[CNT_BITS-1];

endmodule


// ============================================================================
// neoTRNG_cell — single ring-oscillator entropy source
// ============================================================================
module neoTRNG_cell #(
  parameter integer NUM_INV  = 5,  // inverters (odd, >= 3)
  parameter integer SIM_MODE = 0   // 1 = simulation mode
) (
  input  wire clk_i,
  input  wire rstn_i,
  input  wire en_i,
  output wire en_o,
  output wire rnd_o
);

  // ---- Enable shift register -----------------------------------------------
  // Each inverter gets a unique enable from its own sreg stage. This prevents
  // the synthesiser from seeing all inverters as "logically identical" and
  // merging/removing them — the key trick that makes neoTRNG tool-independent.
  reg [NUM_INV-1:0] sreg;

  always @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) sreg <= 0;
    else         sreg <= {sreg[NUM_INV-2:0], en_i};
  end

  assign en_o = sreg[NUM_INV-1];

  // ---- Ring oscillator -----------------------------------------------------
  // (* keep *) prevents Yosys from removing nets it considers dead.

  (* keep *) wire [NUM_INV-1:0] latch_out;
  (* keep *) wire [NUM_INV-1:0] inv_out;

  // Rotate: inv_in[i] = latch_out[(i+1) % NUM_INV]
  // Matches VHDL: inv_in <= latch(N-2 downto 0) & latch(N-1)
  (* keep *) wire [NUM_INV-1:0] inv_in;
  assign inv_in = {latch_out[NUM_INV-2:0], latch_out[NUM_INV-1]};

  genvar i;
  generate
    for (i = 0; i < NUM_INV; i = i + 1) begin : ring

      // Latch: async reset when !en_i, transparent when sreg[i]=1, holds otherwise.
      // The incomplete always@(*) intentionally infers a latch.
      (* keep *) reg latch_r;
      // verilator lint_off LATCH
      always @(*) begin
        if (!en_i)        latch_r = 1'b0;
        else if (sreg[i]) latch_r = inv_out[i];
        // no else → implicit hold → latch
      end
      // verilator lint_on LATCH
      assign latch_out[i] = latch_r;

      if (SIM_MODE != 0) begin : sim_path
        // Simulation: registered inverter breaks combinational loop
        reg inv_r;
        always @(posedge clk_i or negedge rstn_i) begin
          if (!rstn_i) inv_r <= 1'b0;
          else         inv_r <= ~inv_in[i];
        end
        assign inv_out[i] = inv_r;
      end else begin : phy_path
        // Physical synthesis: combinational inverter oscillates via latch feedback
        assign inv_out[i] = ~inv_in[i];
      end

    end
  endgenerate

  // ---- Output synchroniser -------------------------------------------------
  // Two-FF synchroniser moves ring output into the clocked domain.
  reg [1:0] sync;

  always @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) sync <= 2'b00;
    else         sync <= {sync[0], latch_out[NUM_INV-1]};
  end

  assign rnd_o = sync[1];

endmodule
