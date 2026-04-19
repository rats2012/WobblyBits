/*
 * Copyright (c) 2026 Isaac W
 * SPDX-License-Identifier: Apache-2.0
 *
 * spi_j_slave — SPI slave for loading the J coupling matrix.
 *
 * Protocol: SPI Mode 0 (CPOL=0, CPHA=0), MSB first.
 * Frame: 16 bits per transaction = 8-bit address byte + 8-bit data byte.
 *   addr[5:0] selects the external matrix entry
 *   (0-35 = J[row*6 + col] in row-major order)
 *   addr[7]   is the R/W̄ flag: 0 = write (existing behaviour), 1 = read.
 *   data = 8-bit signed weight to write (ignored for reads)
 *
 * Read protocol (addr[7] = 1):
 *   Send 16-bit frame [1|0|addr5:0][don't-care data byte].
 *   During the data byte the corresponding J register is shifted out MSB-first
 *   on MISO.  No wr_en pulse is generated.
 *
 * The SPI inputs are synchronised into the main clock domain with a 2-FF
 * synchroniser.  This constrains SPI clock to ≤ ~12 MHz at 25 MHz sysclk;
 * in practice the RP2040 drives it at ≤ 4 MHz.
 *
 * If CS goes high mid-transaction the state machine resets silently (no
 * partial write: wr_en is only pulsed after all 16 bits are received).
 *
 * Outputs wr_en (one-cycle pulse), wr_addr[5:0], wr_data[7:0].
 * Output  miso_out: connect to uio_out[2] (output-enable already set in project.v).
 */

`default_nettype none

module spi_j_slave (
    input  wire       clk,
    input  wire       rst_n,
    // Raw SPI pins (potentially metastable)
    input  wire       spi_cs_n,   // active low chip select
    input  wire       spi_sck,    // serial clock
    input  wire       spi_mosi,   // master-out / slave-in
    // Read port — combinatorial lookup in pbit_array for MISO readback
    input  wire [7:0] rd_data,    // J register value from pbit_array (combinatorial)
    output wire [5:0] rd_addr,    // register address to look up (combinatorial)
    // MISO shift-out
    output wire       miso_out,   // connect to uio_out[2]
    // Write port (one-cycle pulse; wr_addr is valid only when wr_en=1)
    output reg        wr_en,
    output reg  [5:0] wr_addr,
    output reg  [7:0] wr_data
);

  // ---- 2-FF synchronisers ---------------------------------------------------
  reg [1:0] cs_r, sck_r, mosi_r;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs_r   <= 2'b11; // CS idle (inactive high)
      sck_r  <= 2'b00;
      mosi_r <= 2'b00;
    end else begin
      cs_r   <= {cs_r[0],   spi_cs_n};
      sck_r  <= {sck_r[0],  spi_sck};
      mosi_r <= {mosi_r[0], spi_mosi};
    end
  end

  wire cs_n     = cs_r[1];           // synchronised CS (active low)
  wire sck_rise = (sck_r == 2'b01);  // rising-edge detector
  wire mosi_d   = mosi_r[1];         // synchronised MOSI

  // ---- SPI shift register ---------------------------------------------------
  reg [7:0] shift_reg;
  reg [3:0] bit_cnt;    // 0–15: counts SCK pulses within a 16-bit frame
  reg [7:0] addr_latch; // captured after the first 8 bits
  reg       is_read;    // 1 = current transaction is a read (addr byte bit 7 = 1)
  reg [7:0] miso_sreg;  // MISO shift register; pre-loaded after address byte; MSB-first

  // pre_byte: the complete address byte that addr_latch WILL become after this
  // SCK rise.  Using it (not addr_latch) lets us look up rd_data and load
  // miso_sreg on the same clock edge that we latch the address, with no extra
  // pipeline stage.
  wire [7:0] pre_byte = {shift_reg[6:0], mosi_d};

  // rd_addr is combinatorial: lower 6 bits of the incoming address byte.
  // pbit_array drives rd_data as a combinatorial mux; it is valid whenever
  // rd_addr is stable, so miso_sreg can be loaded in the same cycle as
  // addr_latch (the pre_byte expression gives the settled, registered value).
  assign rd_addr  = pre_byte[5:0];

  // Drive MISO from the MSB of the shift register while in a read transaction.
  // is_read is cleared on CS deassert, so MISO is 0 between transactions.
  assign miso_out = is_read ? miso_sreg[7] : 1'b0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift_reg  <= 8'h00;
      bit_cnt    <= 4'd0;
      addr_latch <= 8'h00;
      is_read    <= 1'b0;
      miso_sreg  <= 8'h00;
      wr_en      <= 1'b0;
      wr_addr    <= 6'd0;
      wr_data    <= 8'h00;
    end else begin
      wr_en <= 1'b0; // default: no write this cycle

      if (cs_n) begin
        // CS inactive: abort and reset for next transaction
        bit_cnt   <= 4'd0;
        shift_reg <= 8'h00;
        is_read   <= 1'b0;
        miso_sreg <= 8'h00;
      end else if (sck_rise) begin
        // Shift MOSI in MSB-first
        shift_reg <= {shift_reg[6:0], mosi_d};

        if (bit_cnt == 4'd7) begin
          // End of address byte: latch it, set R/W̄, pre-load MISO shift register.
          // pre_byte = {shift_reg[6:0], mosi_d} is the full address byte.
          // rd_addr = pre_byte[5:0]; rd_data from pbit_array is already valid.
          addr_latch <= pre_byte;
          is_read    <= pre_byte[7];   // bit 7 = R/W̄: 1 = read, 0 = write
          miso_sreg  <= rd_data;       // load J register value for MSB-first shift-out
          bit_cnt    <= 4'd8;
        end else if (bit_cnt == 4'd15) begin
          // End of data byte: issue write pulse for writes; reset for both.
          if (!is_read) begin
            wr_en   <= 1'b1;
            wr_addr <= addr_latch[5:0]; // lower 6 bits = register index 0–35
            wr_data <= {shift_reg[6:0], mosi_d};
          end
          bit_cnt <= 4'd0;
          is_read <= 1'b0;
        end else begin
          bit_cnt <= bit_cnt + 4'd1;
          // During the data byte (bit_cnt 8–14): shift MISO left on each SCK rise.
          // The 2-FF synchroniser means we update ~2 sysclk cycles after the
          // physical SCK edge, well after the master has already sampled MISO.
          if (bit_cnt >= 4'd8) begin
            miso_sreg <= {miso_sreg[6:0], 1'b0};
          end
        end
      end
    end
  end

endmodule
