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

  localparam [1:0] ACTIVE_NONE   = 2'd0;
  localparam [1:0] ACTIVE_VISUAL = 2'd1;
  localparam [1:0] ACTIVE_AUDIO  = 2'd2;

  reg [1:0] active_core;
  reg command_error;

  wire visual_input_ready;
  wire visual_output_valid;
  wire [7:0] visual_output_data;
  wire visual_busy;
  wire visual_error;
  wire visual_output_first;
  wire visual_output_last;

  wire audio_input_ready;
  wire audio_output_valid;
  wire [7:0] audio_output_data;
  wire audio_busy;
  wire audio_error;
  wire audio_output_first;
  wire audio_output_last;

  wire select_visual_command =
      (active_core == ACTIVE_NONE) && (ui_in == 8'ha0);
  wire select_audio_command =
      (active_core == ACTIVE_NONE) && (ui_in == 8'hb0);
  wire visual_input_valid = uio_in[0]
      && ((active_core == ACTIVE_VISUAL) || select_visual_command);
  wire audio_input_valid = uio_in[0]
      && ((active_core == ACTIVE_AUDIO) || select_audio_command);

  wire input_ready = ena && ((active_core == ACTIVE_NONE)
      || ((active_core == ACTIVE_VISUAL) && visual_input_ready)
      || ((active_core == ACTIVE_AUDIO) && audio_input_ready));
  wire output_valid = (active_core == ACTIVE_VISUAL)
      ? visual_output_valid
      : (active_core == ACTIVE_AUDIO) ? audio_output_valid : 1'b0;
  wire [7:0] output_data = (active_core == ACTIVE_VISUAL)
      ? visual_output_data
      : (active_core == ACTIVE_AUDIO) ? audio_output_data : 8'h00;
  wire output_first = (active_core == ACTIVE_VISUAL)
      ? visual_output_first
      : (active_core == ACTIVE_AUDIO) ? audio_output_first : 1'b0;
  wire output_last = (active_core == ACTIVE_VISUAL)
      ? visual_output_last
      : (active_core == ACTIVE_AUDIO) ? audio_output_last : 1'b0;
  wire busy = (active_core != ACTIVE_NONE)
      || visual_busy || audio_busy;
  wire error = command_error
      || ((active_core == ACTIVE_VISUAL) && visual_error)
      || ((active_core == ACTIVE_AUDIO) && audio_error);

  // These physical pins are outputs in this profile; consume their unused input
  // paths so the standard TinyTapeout bidirectional interface lints cleanly.
  wire _unused = &{uio_in[7:2], 1'b0};

  mono_temporal_core visual_core (
      .clk          (clk),
      .rst_n        (rst_n),
      .enable       (ena),
      .input_data   (ui_in),
      .input_valid  (visual_input_valid),
      .input_ready  (visual_input_ready),
      .output_data  (visual_output_data),
      .output_valid (visual_output_valid),
      .output_ready (uio_in[1]),
      .output_first (visual_output_first),
      .output_last  (visual_output_last),
      .busy         (visual_busy),
      .error        (visual_error)
  );

  stereo_filterbank_core audio_core (
      .clk          (clk),
      .rst_n        (rst_n),
      .enable       (ena),
      .input_data   (ui_in),
      .input_valid  (audio_input_valid),
      .input_ready  (audio_input_ready),
      .output_data  (audio_output_data),
      .output_valid (audio_output_valid),
      .output_ready (uio_in[1]),
      .output_first (audio_output_first),
      .output_last  (audio_output_last),
      .busy         (audio_busy),
      .error        (audio_error)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_core <= ACTIVE_NONE;
      command_error <= 1'b0;
    end else if (active_core == ACTIVE_NONE) begin
      if (ena && uio_in[0]) begin
        if (ui_in == 8'ha0) begin
          active_core <= ACTIVE_VISUAL;
          command_error <= 1'b0;
        end else if (ui_in == 8'hb0) begin
          active_core <= ACTIVE_AUDIO;
          command_error <= 1'b0;
        end else begin
          command_error <= 1'b1;
        end
      end
    end else if (output_valid && uio_in[1] && output_last) begin
      active_core <= ACTIVE_NONE;
    end
  end

  assign uo_out = output_data;

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
