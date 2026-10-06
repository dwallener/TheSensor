/*
 * STEREO_FILTERBANK_V0
 *
 * Input: 0xB0, then 128 signed PCM8 left samples followed by the matching
 * 128 signed PCM8 right samples at 24 kHz.
 * Output: 0x5B, sixteen eight-byte band records, and one status byte.
 */

`default_nettype none

// The datapath intentionally widens through the shared multiplier and narrows
// only at the documented fixed-point boundaries below.
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module stereo_filterbank_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire [7:0] input_data,
    input  wire       input_valid,
    output wire       input_ready,
    output wire [7:0] output_data,
    output wire       output_valid,
    input  wire       output_ready,
    output wire       output_first,
    output wire       output_last,
    output wire       busy,
    output reg        error
);

  localparam [2:0] ST_IDLE    = 3'd0;
  localparam [2:0] ST_LOAD    = 3'd1;
  localparam [2:0] ST_PROCESS = 3'd2;
  localparam [2:0] ST_EARLY   = 3'd3;
  localparam [2:0] ST_FINAL   = 3'd4;
  localparam [2:0] ST_OUTPUT  = 3'd5;

  reg [2:0] state;
  reg channel_select;
  reg [7:0] sample_index;
  reg [3:0] band_index;
  reg [3:0] operation;
  reg signed [11:0] current_input;

  // The same resonator bank is used first for the left block and then for the
  // right block.  Only compact left-ear summaries survive the bank reset.
  reg signed [25:0] full_s1 [0:15];
  reg signed [25:0] full_s2 [0:15];
  reg signed [25:0] half_s1 [0:15];
  reg signed [25:0] half_s2 [0:15];
  reg signed [27:0] left_real [0:15];
  reg signed [27:0] left_imag [0:15];
  reg [7:0] left_level [0:15];
  reg [7:0] left_early_level [0:15];
  reg [7:0] left_late_level [0:15];
  reg [7:0] right_early_level [0:15];
  reg signed [27:0] temporary_real;
  reg signed [27:0] temporary_imag;
  reg signed [27:0] temporary_half_real;
  reg signed [27:0] temporary_half_imag;
  reg signed [55:0] phase_product;
  reg signed [55:0] phase_cross;
  reg signed [55:0] dot_product;

  // B0 is deliberately fire-and-forget.  A completed band is serialized
  // directly from the retained summaries instead of being copied into a
  // 128-byte response register file.
  reg [3:0] result_index;
  reg clipping_seen;
  reg saturation_seen;

  reg signed [31:0] multiply_a;
  reg signed [31:0] multiply_b;
  wire signed [63:0] multiply_result = multiply_a * multiply_b;

  wire signed [13:0] resonator_coefficient = resonator_for_band(band_index);
  wire signed [12:0] cosine_coefficient = cosine_for_band(band_index);
  wire signed [12:0] sine_coefficient = sine_for_band(band_index);

  reg signed [25:0] selected_s1;
  reg signed [25:0] selected_s2;
  reg signed [11:0] selected_input;
  wire signed [63:0] resonator_candidate =
      $signed({{52{selected_input[11]}}, selected_input})
      + ($signed(multiply_result) >>> 12)
      - $signed({{38{selected_s2[25]}}, selected_s2});
  wire signed [25:0] resonator_next = saturate_state(resonator_candidate);
  wire resonator_saturated =
      (resonator_candidate > 64'sd33554431)
      || (resonator_candidate < -64'sd33554432);

  wire signed [55:0] final_dot = dot_product + multiply_result;
  wire [7:0] final_right_level = log_compress(
      abs28(temporary_real) + abs28(temporary_imag));
  wire [7:0] final_mono_level = log_compress(
      (abs28(left_real[band_index] + temporary_real)
       + abs28(left_imag[band_index] + temporary_imag)) >> 1);
  wire [7:0] final_late_level = log_compress(
      abs28(temporary_half_real) + abs28(temporary_half_imag));
  wire [8:0] early_pair_level =
      ({2'b0, left_early_level[band_index]}
       + {2'b0, right_early_level[band_index]}) >> 1;
  wire [8:0] late_pair_level =
      ({2'b0, left_late_level[band_index]}
       + {2'b0, final_late_level}) >> 1;
  wire signed [8:0] level_delta_unscaled =
      $signed(late_pair_level) - $signed(early_pair_level);
  wire signed [63:0] level_delta_scaled =
      {{53{level_delta_unscaled[8]}}, level_delta_unscaled, 2'b00};
  wire signed [7:0] final_delta = saturate_byte(level_delta_scaled);
  wire signed [8:0] level_difference_unscaled =
      $signed({1'b0, final_right_level})
      - $signed({1'b0, left_level[band_index]});
  wire signed [7:0] final_level_difference = saturate_byte(
      {{55{level_difference_unscaled[8]}}, level_difference_unscaled});
  wire signed [7:0] final_phase = normalize_signed(phase_cross, final_dot);
  wire [7:0] confidence_gate = signal_gate(
      left_level[band_index], final_right_level);
  wire [8:0] level_mismatch = level_difference_unscaled[8]
      ? -level_difference_unscaled : level_difference_unscaled;
  wire [7:0] balance_gate = (level_mismatch >= 9'd32)
      ? 8'd0 : 8'd255 - {level_mismatch[4:0], 3'b000};
  wire [7:0] final_confidence =
      ((confidence_gate < balance_gate) ? confidence_gate : balance_gate) >> 1;
  integer i;

  function signed [13:0] resonator_for_band;
    input [3:0] index;
    begin
      case (index)
        4'd0: resonator_for_band = 14'sd8188;
        4'd1: resonator_for_band = 14'sd8180;
        4'd2: resonator_for_band = 14'sd8165;
        4'd3: resonator_for_band = 14'sd8139;
        4'd4: resonator_for_band = 14'sd8094;
        4'd5: resonator_for_band = 14'sd8021;
        4'd6: resonator_for_band = 14'sd7903;
        4'd7: resonator_for_band = 14'sd7716;
        4'd8: resonator_for_band = 14'sd7425;
        4'd9: resonator_for_band = 14'sd6975;
        4'd10: resonator_for_band = 14'sd6293;
        4'd11: resonator_for_band = 14'sd5276;
        4'd12: resonator_for_band = 14'sd3801;
        4'd13: resonator_for_band = 14'sd1745;
        4'd14: resonator_for_band = -14'sd948;
        default: resonator_for_band = -14'sd4096;
      endcase
    end
  endfunction

  function signed [12:0] cosine_for_band;
    input [3:0] index;
    begin
      case (index)
        4'd0: cosine_for_band = 13'sd4094;
        4'd1: cosine_for_band = 13'sd4090;
        4'd2: cosine_for_band = 13'sd4083;
        4'd3: cosine_for_band = 13'sd4069;
        4'd4: cosine_for_band = 13'sd4047;
        4'd5: cosine_for_band = 13'sd4011;
        4'd6: cosine_for_band = 13'sd3952;
        4'd7: cosine_for_band = 13'sd3858;
        4'd8: cosine_for_band = 13'sd3713;
        4'd9: cosine_for_band = 13'sd3487;
        4'd10: cosine_for_band = 13'sd3146;
        4'd11: cosine_for_band = 13'sd2638;
        4'd12: cosine_for_band = 13'sd1901;
        4'd13: cosine_for_band = 13'sd873;
        4'd14: cosine_for_band = -13'sd474;
        default: cosine_for_band = -13'sd2048;
      endcase
    end
  endfunction

  function signed [12:0] sine_for_band;
    input [3:0] index;
    begin
      case (index)
        4'd0: sine_for_band = 13'sd134;
        4'd1: sine_for_band = 13'sd223;
        4'd2: sine_for_band = 13'sd331;
        4'd3: sine_for_band = 13'sd465;
        4'd4: sine_for_band = 13'sd630;
        4'd5: sine_for_band = 13'sd832;
        4'd6: sine_for_band = 13'sd1078;
        4'd7: sine_for_band = 13'sd1375;
        4'd8: sine_for_band = 13'sd1730;
        4'd9: sine_for_band = 13'sd2148;
        4'd10: sine_for_band = 13'sd2622;
        4'd11: sine_for_band = 13'sd3133;
        4'd12: sine_for_band = 13'sd3628;
        4'd13: sine_for_band = 13'sd4002;
        4'd14: sine_for_band = 13'sd4068;
        default: sine_for_band = 13'sd3547;
      endcase
    end
  endfunction

  function signed [25:0] saturate_state;
    input signed [63:0] value;
    begin
      if (value > 64'sd33554431)
        saturate_state = 26'sd33554431;
      else if (value < -64'sd33554432)
        saturate_state = -26'sd33554432;
      else
        saturate_state = value[25:0];
    end
  endfunction

  function signed [7:0] saturate_byte;
    input signed [63:0] value;
    begin
      if (value > 64'sd127)
        saturate_byte = 8'sd127;
      else if (value < -64'sd128)
        saturate_byte = -8'sd128;
      else
        saturate_byte = value[7:0];
    end
  endfunction

  function [27:0] abs28;
    input signed [27:0] value;
    begin
      abs28 = value[27] ? -value : value;
    end
  endfunction

  function [7:0] log_compress;
    input [63:0] value;
    integer bit_index;
    integer exponent;
    reg [2:0] mantissa;
    begin
      exponent = 0;
      for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1)
        if (value[bit_index])
          exponent = bit_index;
      if (value == 0)
        log_compress = 8'd0;
      else begin
        if (exponent >= 3)
          mantissa = (value >> (exponent - 3)) & 3'b111;
        else
          mantissa = (value << (3 - exponent)) & 3'b111;
        if (exponent >= 32)
          log_compress = 8'hff;
        else
          log_compress = (exponent << 3) + mantissa;
      end
    end
  endfunction

  function signed [7:0] normalize_signed;
    input signed [55:0] numerator;
    input signed [55:0] companion;
    reg [55:0] numerator_abs;
    reg [55:0] companion_abs;
    reg [55:0] scale_source;
    reg signed [63:0] normalized;
    integer bit_index;
    integer highest_bit;
    integer shift;
    begin
      numerator_abs = numerator[55] ? -numerator : numerator;
      companion_abs = companion[55] ? -companion : companion;
      scale_source = (numerator_abs > companion_abs)
          ? numerator_abs : companion_abs;
      highest_bit = 0;
      for (bit_index = 0; bit_index < 56; bit_index = bit_index + 1)
        if (scale_source[bit_index])
          highest_bit = bit_index;
      shift = highest_bit - 6;
      if (scale_source == 0)
        normalize_signed = 8'sd0;
      else begin
        if (shift >= 0)
          normalized = numerator >>> shift;
        else
          normalized = numerator <<< (-shift);
        normalize_signed = saturate_byte(normalized);
      end
    end
  endfunction

  function [7:0] signal_gate;
    input [7:0] left_value;
    input [7:0] right_value;
    reg [7:0] quietest;
    reg [9:0] scaled;
    begin
      quietest = (left_value < right_value) ? left_value : right_value;
      if (quietest <= 40)
        signal_gate = 8'd0;
      else begin
        scaled = (quietest - 40) << 2;
        signal_gate = (scaled > 255) ? 8'hff : scaled[7:0];
      end
    end
  endfunction

  always @* begin
    multiply_a = 32'sd0;
    multiply_b = 32'sd0;
    selected_s1 = 26'sd0;
    selected_s2 = 26'sd0;
    selected_input = 12'sd0;
    if (state == ST_PROCESS) begin
      case (operation)
        4'd0: begin
          multiply_a = {{18{resonator_coefficient[13]}}, resonator_coefficient};
          multiply_b = {{6{full_s1[band_index][25]}}, full_s1[band_index]};
          selected_s1 = full_s1[band_index];
          selected_s2 = full_s2[band_index];
          selected_input = current_input;
        end
        default: begin
          multiply_a = {{18{resonator_coefficient[13]}}, resonator_coefficient};
          multiply_b = {{6{half_s1[band_index][25]}}, half_s1[band_index]};
          selected_s1 = half_s1[band_index];
          selected_s2 = half_s2[band_index];
          selected_input = current_input;
        end
      endcase
    end else if (state == ST_EARLY) begin
      case (operation)
        4'd0: begin multiply_a = cosine_coefficient; multiply_b = half_s2[band_index]; end
        default: begin multiply_a = sine_coefficient; multiply_b = half_s2[band_index]; end
      endcase
    end else if ((state == ST_FINAL) || (state == ST_OUTPUT)) begin
      case (operation)
        4'd0: begin multiply_a = cosine_coefficient; multiply_b = full_s2[band_index]; end
        4'd1: begin multiply_a = sine_coefficient; multiply_b = full_s2[band_index]; end
        4'd2: begin multiply_a = cosine_coefficient; multiply_b = half_s2[band_index]; end
        4'd3: begin multiply_a = sine_coefficient; multiply_b = half_s2[band_index]; end
        4'd4: begin multiply_a = left_real[band_index]; multiply_b = temporary_imag; end
        4'd5: begin multiply_a = left_imag[band_index]; multiply_b = temporary_real; end
        4'd6: begin multiply_a = left_real[band_index]; multiply_b = temporary_real; end
        default: begin multiply_a = left_imag[band_index]; multiply_b = temporary_imag; end
      endcase
    end
  end

  assign input_ready = enable && ((state == ST_IDLE) || (state == ST_LOAD));
  assign output_valid = enable && (state == ST_OUTPUT);
  assign output_data = (result_index == 4'd0) ? 8'h5b
      : (result_index == 4'd1) ? left_level[band_index]
      : (result_index == 4'd2) ? final_right_level
      : (result_index == 4'd3) ? final_mono_level
      : (result_index == 4'd4) ? final_delta
      : (result_index == 4'd5) ? (final_delta[7] ? 8'd0 : final_delta)
      : (result_index == 4'd6) ? final_level_difference
      : (result_index == 4'd7) ? final_phase
      : (result_index == 4'd8) ? final_confidence
      : {4'd0, error, saturation_seen, 1'b0, clipping_seen};
  assign output_first = output_valid && (result_index == 0);
  assign output_last = output_valid && (result_index == 4'd9);
  assign busy = (state != ST_IDLE);

  // Kept in the module interface so the other command engines can retain the
  // shared ready/valid pinout.  B0 intentionally does not consume readiness.
  wire _unused_output_ready = output_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      channel_select <= 0;
      sample_index <= 0;
      band_index <= 0;
      operation <= 0;
      current_input <= 0;
      result_index <= 0;
      clipping_seen <= 0;
      saturation_seen <= 0;
      error <= 0;
      temporary_real <= 0;
      temporary_imag <= 0;
      temporary_half_real <= 0;
      temporary_half_imag <= 0;
      phase_product <= 0;
      phase_cross <= 0;
      dot_product <= 0;
      for (i = 0; i < 16; i = i + 1) begin
        full_s1[i] <= 0; full_s2[i] <= 0;
        half_s1[i] <= 0; half_s2[i] <= 0;
        left_real[i] <= 0; left_imag[i] <= 0;
        left_level[i] <= 0;
        left_early_level[i] <= 0; left_late_level[i] <= 0;
        right_early_level[i] <= 0;
      end
    end else begin
      case (state)
        ST_IDLE: begin
          channel_select <= 0;
          sample_index <= 0;
          band_index <= 0;
          operation <= 0;
          result_index <= 0;
          if (enable && input_valid) begin
            if (input_data == 8'hb0) begin
              state <= ST_LOAD;
              error <= 0;
              clipping_seen <= 0;
              saturation_seen <= 0;
              for (i = 0; i < 16; i = i + 1) begin
                full_s1[i] <= 0; full_s2[i] <= 0;
                half_s1[i] <= 0; half_s2[i] <= 0;
                left_real[i] <= 0; left_imag[i] <= 0;
                left_level[i] <= 0;
                left_early_level[i] <= 0; left_late_level[i] <= 0;
                right_early_level[i] <= 0;
              end
            end else begin
              error <= 1;
            end
          end
        end

        ST_LOAD: begin
          if (enable && input_valid) begin
            current_input <= $signed(input_data);
            if ((input_data == 8'h7f) || (input_data == 8'h80))
              clipping_seen <= 1;
            band_index <= 0;
            operation <= 0;
            state <= ST_PROCESS;
          end
        end

        ST_PROCESS: begin
          case (operation)
            4'd0: begin
              full_s2[band_index] <= selected_s1;
              full_s1[band_index] <= resonator_next;
              saturation_seen <= saturation_seen || resonator_saturated;
              operation <= 4'd1;
            end
            default: begin
              half_s2[band_index] <= selected_s1;
              half_s1[band_index] <= resonator_next;
              saturation_seen <= saturation_seen || resonator_saturated;
              operation <= 0;
              if (band_index == 15) begin
                band_index <= 0;
                if (sample_index == 8'd63)
                  state <= ST_EARLY;
                else if (sample_index == 8'd127)
                  state <= ST_FINAL;
                else begin
                  sample_index <= sample_index + 1'b1;
                  state <= ST_LOAD;
                end
              end else begin
                band_index <= band_index + 1'b1;
              end
            end
          endcase
        end

        ST_EARLY: begin
          case (operation)
            4'd0: begin
              temporary_half_real <= half_s1[band_index]
                  - ($signed(multiply_result) >>> 12);
              operation <= 4'd1;
            end
            default: begin
              if (!channel_select)
                left_early_level[band_index] <= log_compress(
                    abs28(temporary_half_real)
                    + abs28($signed(multiply_result) >>> 12));
              else
                right_early_level[band_index] <= log_compress(
                    abs28(temporary_half_real)
                    + abs28($signed(multiply_result) >>> 12));
              half_s1[band_index] <= 0; half_s2[band_index] <= 0;
              operation <= 0;
              if (band_index == 15) begin
                band_index <= 0;
                sample_index <= 8'd64;
                state <= ST_LOAD;
              end else begin
                band_index <= band_index + 1'b1;
              end
            end
          endcase
        end

        ST_FINAL: begin
          case (operation)
            4'd0: begin temporary_real <= full_s1[band_index] - ($signed(multiply_result) >>> 12); operation <= 4'd1; end
            4'd1: begin temporary_imag <= $signed(multiply_result) >>> 12; operation <= 4'd2; end
            4'd2: begin temporary_half_real <= half_s1[band_index] - ($signed(multiply_result) >>> 12); operation <= 4'd3; end
            4'd3: begin
              temporary_half_imag <= $signed(multiply_result) >>> 12;
              operation <= channel_select ? 4'd4 : 4'd8;
            end
            4'd4: begin phase_product <= multiply_result; operation <= 4'd5; end
            4'd5: begin phase_cross <= phase_product - multiply_result; operation <= 4'd6; end
            4'd6: begin dot_product <= multiply_result; operation <= 4'd7; end
            default: begin
              if (!channel_select) begin
                left_real[band_index] <= temporary_real;
                left_imag[band_index] <= temporary_imag;
                left_level[band_index] <= log_compress(
                    abs28(temporary_real) + abs28(temporary_imag));
                left_late_level[band_index] <= final_late_level;
                operation <= 0;
              end else begin
                // Keep operation at seven while these final combinational
                // values are serialized over the next eight clocks.
                result_index <= (band_index == 0) ? 0 : 1;
                state <= ST_OUTPUT;
              end
              if (!channel_select && (band_index == 15)) begin
                band_index <= 0;
                channel_select <= 1;
                sample_index <= 0;
                for (i = 0; i < 16; i = i + 1) begin
                  full_s1[i] <= 0; full_s2[i] <= 0;
                  half_s1[i] <= 0; half_s2[i] <= 0;
                end
                state <= ST_LOAD;
              end else if (!channel_select) begin
                band_index <= band_index + 1'b1;
              end
            end
          endcase
        end

        ST_OUTPUT: begin
          if (enable) begin
            if (result_index == 4'd9) begin
              result_index <= 0;
              state <= ST_IDLE;
            end else if (result_index == 4'd8) begin
              if (band_index == 15) begin
                result_index <= 4'd9;
              end else begin
                band_index <= band_index + 1'b1;
                operation <= 0;
                result_index <= 1;
                state <= ST_FINAL;
              end
            end else begin
              result_index <= result_index + 1'b1;
            end
          end
        end

        default: begin
          state <= ST_IDLE;
          error <= 1;
        end
      endcase
    end
  end

endmodule

/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */

`default_nettype none
