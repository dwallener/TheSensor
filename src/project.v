/*
 * Copyright (c) 2026 Damir Wallener
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_dwallener_sensor (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire input_ready;
  wire output_valid;
  wire busy;
  wire error;
  wire output_first;
  wire output_last;

  // These physical pins are outputs in this profile; consume their unused input
  // paths so the standard TinyTapeout bidirectional interface lints cleanly.
  wire _unused = &{uio_in[7:2], 1'b0};

  mono_temporal_core core (
      .clk          (clk),
      .rst_n        (rst_n),
      .enable       (ena),
      .input_data   (ui_in),
      .input_valid  (uio_in[0]),
      .input_ready  (input_ready),
      .output_data  (uo_out),
      .output_valid (output_valid),
      .output_ready (uio_in[1]),
      .output_first (output_first),
      .output_last  (output_last),
      .busy         (busy),
      .error        (error)
  );

  assign uio_out = {
      output_last,
      output_first,
      error,
      busy,
      output_valid,
      input_ready,
      2'b00
  };
  assign uio_oe = 8'b11111100;

endmodule

`default_nettype none
