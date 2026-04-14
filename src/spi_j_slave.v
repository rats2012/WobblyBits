/*
 * Copyright (c) 2026 Isaac W
 * SPDX-License-Identifier: Apache-2.0
 *
 * spi_j_slave — SPI slave for loading the J coupling matrix.
 *
 * Protocol: SPI Mode 0 (CPOL=0, CPHA=0), MSB first.
 * Frame: 16 bits per transaction = 8-bit address byte + 8-bit data byte.
 *   addr[3:0] selects the register (0-15 = J[row*4 + col] in row-major order)
 *   data = 8-bit signed weight to write
 *
 * The SPI inputs are synchronised into the main clock domain with a 2-FF
 * synchroniser.  This constrains SPI clock to ≤ ~12 MHz at 25 MHz sysclk;
 * in practice the RP2040 drives it at ≤ 4 MHz.
 *
 * If CS goes high mid-transaction the state machine resets silently (no
 * partial write: wr_en is only pulsed after all 16 bits are received).
 *
 * Outputs wr_en (one-cycle pulse), wr_addr[3:0], wr_data[7:0].
 */

`default_nettype none

module spi_j_slave (
    input  wire       clk,
    input  wire       rst_n,
    // Raw SPI pins (potentially metastable)
    input  wire       spi_cs_n,   // active low chip select
    input  wire       spi_sck,    // serial clock
    input  wire       spi_mosi,   // master-out / slave-in
    // Write port (one-cycle pulse; wr_addr is valid only when wr_en=1)
    output reg        wr_en,
    output reg  [3:0] wr_addr,
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

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift_reg  <= 8'h00;
      bit_cnt    <= 4'd0;
      addr_latch <= 8'h00;
      wr_en      <= 1'b0;
      wr_addr    <= 4'd0;
      wr_data    <= 8'h00;
    end else begin
      wr_en <= 1'b0; // default: no write this cycle

      if (cs_n) begin
        // CS inactive: abort and reset for next transaction
        bit_cnt   <= 4'd0;
        shift_reg <= 8'h00;
      end else if (sck_rise) begin
        // Shift MOSI in MSB-first
        shift_reg <= {shift_reg[6:0], mosi_d};

        if (bit_cnt == 4'd7) begin
          // End of address byte: latch it, advance counter
          addr_latch <= {shift_reg[6:0], mosi_d};
          bit_cnt    <= 4'd8;
        end else if (bit_cnt == 4'd15) begin
          // End of data byte: issue write pulse then reset counter
          wr_en   <= 1'b1;
          wr_addr <= addr_latch[3:0]; // lower 4 bits = register index 0–15
          wr_data <= {shift_reg[6:0], mosi_d};
          bit_cnt <= 4'd0;
        end else begin
          bit_cnt <= bit_cnt + 4'd1;
        end
      end
    end
  end

endmodule
