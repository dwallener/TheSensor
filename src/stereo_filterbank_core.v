/*
 * STEREO_FILTERBANK_V0
 *
 * Input: 0xB0, then 256 little-endian signed PCM16 stereo sample pairs.
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
  reg [1:0] byte_phase;
  reg [7:0] sample_index;
  reg [3:0] band_index;
  reg [3:0] operation;
  reg [7:0] left_lsb;
  reg [7:0] right_lsb;
  reg signed [11:0] left_input;
  reg signed [11:0] right_input;

  reg signed [25:0] full_left_s1 [0:15];
  reg signed [25:0] full_left_s2 [0:15];
  reg signed [25:0] full_right_s1 [0:15];
  reg signed [25:0] full_right_s2 [0:15];
  reg signed [25:0] half_left_s1 [0:15];
  reg signed [25:0] half_left_s2 [0:15];
  reg signed [25:0] half_right_s1 [0:15];
  reg signed [25:0] half_right_s2 [0:15];

  reg signed [39:0] cross_accumulator [0:15];
  reg        [39:0] left_square_accumulator [0:15];
  reg        [39:0] right_square_accumulator [0:15];
  reg [7:0] early_level [0:15];
  reg [7:0] result [0:127];

  reg signed [27:0] temporary_left_real;
  reg signed [27:0] temporary_left_imag;
  reg signed [27:0] temporary_right_real;
  reg signed [27:0] temporary_right_imag;
  reg signed [27:0] temporary_half_left_real;
  reg signed [27:0] temporary_half_left_imag;
  reg signed [27:0] temporary_half_right_real;
  reg signed [27:0] temporary_half_right_imag;
  reg signed [55:0] phase_product;
  reg signed [55:0] phase_cross;
  reg signed [55:0] dot_product;

  reg [7:0] result_index;
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

  wire signed [11:0] narrowed_left =
      saturate_sample($signed({{38{full_left_s1[band_index][25]}},
                               full_left_s1[band_index]}) >>> 12);
  wire signed [11:0] narrowed_right =
      saturate_sample($signed({{38{full_right_s1[band_index][25]}},
                               full_right_s1[band_index]}) >>> 12);

  wire signed [55:0] final_dot = dot_product + multiply_result;
  wire [7:0] final_left_level = log_compress(
      abs28(temporary_left_real) + abs28(temporary_left_imag));
  wire [7:0] final_right_level = log_compress(
      abs28(temporary_right_real) + abs28(temporary_right_imag));
  wire [7:0] final_mono_level = log_compress(
      (abs28(temporary_left_real + temporary_right_real)
       + abs28(temporary_left_imag + temporary_right_imag)) >> 1);
  wire [7:0] final_late_level = log_compress(
      (abs28(temporary_half_left_real + temporary_half_right_real)
       + abs28(temporary_half_left_imag + temporary_half_right_imag)) >> 1);
  wire signed [8:0] level_delta_unscaled =
      $signed({1'b0, final_late_level})
      - $signed({1'b0, early_level[band_index]});
  wire signed [63:0] level_delta_scaled =
      {{53{level_delta_unscaled[8]}}, level_delta_unscaled, 2'b00};
  wire signed [7:0] final_delta = saturate_byte(level_delta_scaled);
  wire signed [8:0] level_difference_unscaled =
      $signed({1'b0, final_right_level})
      - $signed({1'b0, final_left_level});
  wire signed [7:0] final_level_difference = saturate_byte(
      {{55{level_difference_unscaled[8]}}, level_difference_unscaled});
  wire signed [7:0] final_phase = normalize_signed(phase_cross, final_dot);
  wire [7:0] coherence = coherence_value(
      cross_accumulator[band_index],
      left_square_accumulator[band_index],
      right_square_accumulator[band_index]);
  wire [7:0] confidence_gate = signal_gate(
      final_left_level, final_right_level);
  wire [7:0] final_confidence =
      (coherence < confidence_gate) ? coherence : confidence_gate;
  wire [6:0] result_base = {band_index, 3'b000};

  integer i;

  function signed [13:0] resonator_for_band;
    input [3:0] index;
    begin
      case (index)
        4'd0: resonator_for_band = 14'sd8191;
        4'd1: resonator_for_band = 14'sd8189;
        4'd2: resonator_for_band = 14'sd8185;
        4'd3: resonator_for_band = 14'sd8179;
        4'd4: resonator_for_band = 14'sd8168;
        4'd5: resonator_for_band = 14'sd8149;
        4'd6: resonator_for_band = 14'sd8120;
        4'd7: resonator_for_band = 14'sd8072;
        4'd8: resonator_for_band = 14'sd7998;
        4'd9: resonator_for_band = 14'sd7882;
        4'd10: resonator_for_band = 14'sd7703;
        4'd11: resonator_for_band = 14'sd7427;
        4'd12: resonator_for_band = 14'sd7009;
        4'd13: resonator_for_band = 14'sd6380;
        4'd14: resonator_for_band = 14'sd5447;
        default: resonator_for_band = 14'sd4096;
      endcase
    end
  endfunction

  function signed [12:0] cosine_for_band;
    input [3:0] index;
    begin
      case (index)
        4'd0: cosine_for_band = 13'sd4095;
        4'd1: cosine_for_band = 13'sd4094;
        4'd2: cosine_for_band = 13'sd4093;
        4'd3: cosine_for_band = 13'sd4089;
        4'd4: cosine_for_band = 13'sd4084;
        4'd5: cosine_for_band = 13'sd4075;
        4'd6: cosine_for_band = 13'sd4060;
        4'd7: cosine_for_band = 13'sd4036;
        4'd8: cosine_for_band = 13'sd3999;
        4'd9: cosine_for_band = 13'sd3941;
        4'd10: cosine_for_band = 13'sd3851;
        4'd11: cosine_for_band = 13'sd3714;
        4'd12: cosine_for_band = 13'sd3504;
        4'd13: cosine_for_band = 13'sd3190;
        4'd14: cosine_for_band = 13'sd2724;
        default: cosine_for_band = 13'sd2048;
      endcase
    end
  endfunction

  function signed [12:0] sine_for_band;
    input [3:0] index;
    begin
      case (index)
        4'd0: sine_for_band = 13'sd67;
        4'd1: sine_for_band = 13'sd112;
        4'd2: sine_for_band = 13'sd166;
        4'd3: sine_for_band = 13'sd233;
        4'd4: sine_for_band = 13'sd316;
        4'd5: sine_for_band = 13'sd418;
        4'd6: sine_for_band = 13'sd544;
        4'd7: sine_for_band = 13'sd698;
        4'd8: sine_for_band = 13'sd886;
        4'd9: sine_for_band = 13'sd1116;
        4'd10: sine_for_band = 13'sd1395;
        4'd11: sine_for_band = 13'sd1728;
        4'd12: sine_for_band = 13'sd2120;
        4'd13: sine_for_band = 13'sd2569;
        4'd14: sine_for_band = 13'sd3059;
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

  function signed [11:0] saturate_sample;
    input signed [63:0] value;
    begin
      if (value > 64'sd2047)
        saturate_sample = 12'sd2047;
      else if (value < -64'sd2048)
        saturate_sample = -12'sd2048;
      else
        saturate_sample = value[11:0];
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

  function [7:0] coherence_value;
    input signed [39:0] cross_value;
    input [39:0] left_square;
    input [39:0] right_square;
    reg [39:0] cross_abs;
    reg [63:0] quotient;
    integer left_highest;
    integer right_highest;
    integer bit_index;
    integer exponent;
    begin
      cross_abs = cross_value[39] ? -cross_value : cross_value;
      left_highest = 0;
      right_highest = 0;
      for (bit_index = 0; bit_index < 40; bit_index = bit_index + 1) begin
        if (left_square[bit_index])
          left_highest = bit_index;
        if (right_square[bit_index])
          right_highest = bit_index;
      end
      if ((left_square == 0) || (right_square == 0))
        coherence_value = 8'd0;
      else begin
        exponent = (left_highest + right_highest) >> 1;
        quotient = ({24'd0, cross_abs} << 8) >> exponent;
        coherence_value = (quotient > 255) ? 8'hff : quotient[7:0];
      end
    end
  endfunction

  function [7:0] signal_gate;
    input [7:0] left_level;
    input [7:0] right_level;
    reg [7:0] quietest;
    reg [9:0] scaled;
    begin
      quietest = (left_level < right_level) ? left_level : right_level;
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
          multiply_b = {{6{full_left_s1[band_index][25]}}, full_left_s1[band_index]};
          selected_s1 = full_left_s1[band_index];
          selected_s2 = full_left_s2[band_index];
          selected_input = left_input;
        end
        4'd1: begin
          multiply_a = {{18{resonator_coefficient[13]}}, resonator_coefficient};
          multiply_b = {{6{full_right_s1[band_index][25]}}, full_right_s1[band_index]};
          selected_s1 = full_right_s1[band_index];
          selected_s2 = full_right_s2[band_index];
          selected_input = right_input;
        end
        4'd2: begin
          multiply_a = {{18{resonator_coefficient[13]}}, resonator_coefficient};
          multiply_b = {{6{half_left_s1[band_index][25]}}, half_left_s1[band_index]};
          selected_s1 = half_left_s1[band_index];
          selected_s2 = half_left_s2[band_index];
          selected_input = left_input;
        end
        4'd3: begin
          multiply_a = {{18{resonator_coefficient[13]}}, resonator_coefficient};
          multiply_b = {{6{half_right_s1[band_index][25]}}, half_right_s1[band_index]};
          selected_s1 = half_right_s1[band_index];
          selected_s2 = half_right_s2[band_index];
          selected_input = right_input;
        end
        4'd4: begin
          multiply_a = {{20{narrowed_left[11]}}, narrowed_left};
          multiply_b = {{20{narrowed_right[11]}}, narrowed_right};
        end
        4'd5: begin
          multiply_a = {{20{narrowed_left[11]}}, narrowed_left};
          multiply_b = {{20{narrowed_left[11]}}, narrowed_left};
        end
        default: begin
          multiply_a = {{20{narrowed_right[11]}}, narrowed_right};
          multiply_b = {{20{narrowed_right[11]}}, narrowed_right};
        end
      endcase
    end else if (state == ST_EARLY) begin
      case (operation)
        4'd0: begin multiply_a = cosine_coefficient; multiply_b = half_left_s2[band_index]; end
        4'd1: begin multiply_a = sine_coefficient; multiply_b = half_left_s2[band_index]; end
        4'd2: begin multiply_a = cosine_coefficient; multiply_b = half_right_s2[band_index]; end
        default: begin multiply_a = sine_coefficient; multiply_b = half_right_s2[band_index]; end
      endcase
    end else if (state == ST_FINAL) begin
      case (operation)
        4'd0: begin multiply_a = cosine_coefficient; multiply_b = full_left_s2[band_index]; end
        4'd1: begin multiply_a = sine_coefficient; multiply_b = full_left_s2[band_index]; end
        4'd2: begin multiply_a = cosine_coefficient; multiply_b = full_right_s2[band_index]; end
        4'd3: begin multiply_a = sine_coefficient; multiply_b = full_right_s2[band_index]; end
        4'd4: begin multiply_a = cosine_coefficient; multiply_b = half_left_s2[band_index]; end
        4'd5: begin multiply_a = sine_coefficient; multiply_b = half_left_s2[band_index]; end
        4'd6: begin multiply_a = cosine_coefficient; multiply_b = half_right_s2[band_index]; end
        4'd7: begin multiply_a = sine_coefficient; multiply_b = half_right_s2[band_index]; end
        4'd8: begin multiply_a = temporary_left_real; multiply_b = temporary_right_imag; end
        4'd9: begin multiply_a = temporary_left_imag; multiply_b = temporary_right_real; end
        4'd10: begin multiply_a = temporary_left_real; multiply_b = temporary_right_real; end
        default: begin multiply_a = temporary_left_imag; multiply_b = temporary_right_imag; end
      endcase
    end
  end

  assign input_ready = enable && ((state == ST_IDLE) || (state == ST_LOAD));
  assign output_valid = enable && (state == ST_OUTPUT);
  assign output_data = (result_index == 0) ? 8'h5b
      : (result_index == 8'd129) ? {4'd0, error, saturation_seen, 1'b0, clipping_seen}
      : result[result_index - 1'b1];
  assign output_first = output_valid && (result_index == 0);
  assign output_last = output_valid && (result_index == 8'd129);
  assign busy = (state != ST_IDLE);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      byte_phase <= 0;
      sample_index <= 0;
      band_index <= 0;
      operation <= 0;
      left_lsb <= 0;
      right_lsb <= 0;
      left_input <= 0;
      right_input <= 0;
      result_index <= 0;
      clipping_seen <= 0;
      saturation_seen <= 0;
      error <= 0;
      temporary_left_real <= 0;
      temporary_left_imag <= 0;
      temporary_right_real <= 0;
      temporary_right_imag <= 0;
      temporary_half_left_real <= 0;
      temporary_half_left_imag <= 0;
      temporary_half_right_real <= 0;
      temporary_half_right_imag <= 0;
      phase_product <= 0;
      phase_cross <= 0;
      dot_product <= 0;
      for (i = 0; i < 16; i = i + 1) begin
        full_left_s1[i] <= 0; full_left_s2[i] <= 0;
        full_right_s1[i] <= 0; full_right_s2[i] <= 0;
        half_left_s1[i] <= 0; half_left_s2[i] <= 0;
        half_right_s1[i] <= 0; half_right_s2[i] <= 0;
        cross_accumulator[i] <= 0;
        left_square_accumulator[i] <= 0;
        right_square_accumulator[i] <= 0;
        early_level[i] <= 0;
      end
      for (i = 0; i < 128; i = i + 1)
        result[i] <= 0;
    end else begin
      case (state)
        ST_IDLE: begin
          byte_phase <= 0;
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
                full_left_s1[i] <= 0; full_left_s2[i] <= 0;
                full_right_s1[i] <= 0; full_right_s2[i] <= 0;
                half_left_s1[i] <= 0; half_left_s2[i] <= 0;
                half_right_s1[i] <= 0; half_right_s2[i] <= 0;
                cross_accumulator[i] <= 0;
                left_square_accumulator[i] <= 0;
                right_square_accumulator[i] <= 0;
                early_level[i] <= 0;
              end
            end else begin
              error <= 1;
            end
          end
        end

        ST_LOAD: begin
          if (enable && input_valid) begin
            case (byte_phase)
              2'd0: begin left_lsb <= input_data; byte_phase <= 2'd1; end
              2'd1: begin
                left_input <= $signed({input_data, left_lsb}) >>> 4;
                if ({input_data, left_lsb} == 16'h7fff
                    || {input_data, left_lsb} == 16'h8000)
                  clipping_seen <= 1;
                byte_phase <= 2'd2;
              end
              2'd2: begin right_lsb <= input_data; byte_phase <= 2'd3; end
              default: begin
                right_input <= $signed({input_data, right_lsb}) >>> 4;
                if ({input_data, right_lsb} == 16'h7fff
                    || {input_data, right_lsb} == 16'h8000)
                  clipping_seen <= 1;
                byte_phase <= 0;
                band_index <= 0;
                operation <= 0;
                state <= ST_PROCESS;
              end
            endcase
          end
        end

        ST_PROCESS: begin
          case (operation)
            4'd0: begin
              full_left_s2[band_index] <= selected_s1;
              full_left_s1[band_index] <= resonator_next;
              saturation_seen <= saturation_seen || resonator_saturated;
              operation <= 4'd1;
            end
            4'd1: begin
              full_right_s2[band_index] <= selected_s1;
              full_right_s1[band_index] <= resonator_next;
              saturation_seen <= saturation_seen || resonator_saturated;
              operation <= 4'd2;
            end
            4'd2: begin
              half_left_s2[band_index] <= selected_s1;
              half_left_s1[band_index] <= resonator_next;
              saturation_seen <= saturation_seen || resonator_saturated;
              operation <= 4'd3;
            end
            4'd3: begin
              half_right_s2[band_index] <= selected_s1;
              half_right_s1[band_index] <= resonator_next;
              saturation_seen <= saturation_seen || resonator_saturated;
              operation <= 4'd4;
            end
            4'd4: begin
              cross_accumulator[band_index] <=
                  cross_accumulator[band_index] + multiply_result;
              operation <= 4'd5;
            end
            4'd5: begin
              left_square_accumulator[band_index] <=
                  left_square_accumulator[band_index] + multiply_result;
              operation <= 4'd6;
            end
            default: begin
              right_square_accumulator[band_index] <=
                  right_square_accumulator[band_index] + multiply_result;
              operation <= 0;
              if (band_index == 15) begin
                band_index <= 0;
                if (sample_index == 8'd127)
                  state <= ST_EARLY;
                else if (sample_index == 8'd255)
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
              temporary_half_left_real <= half_left_s1[band_index]
                  - ($signed(multiply_result) >>> 12);
              operation <= 4'd1;
            end
            4'd1: begin
              temporary_half_left_imag <= $signed(multiply_result) >>> 12;
              operation <= 4'd2;
            end
            4'd2: begin
              temporary_half_right_real <= half_right_s1[band_index]
                  - ($signed(multiply_result) >>> 12);
              operation <= 4'd3;
            end
            default: begin
              early_level[band_index] <= log_compress(
                  (abs28(temporary_half_left_real + temporary_half_right_real)
                   + abs28(temporary_half_left_imag
                           + ($signed(multiply_result) >>> 12))) >> 1);
              half_left_s1[band_index] <= 0; half_left_s2[band_index] <= 0;
              half_right_s1[band_index] <= 0; half_right_s2[band_index] <= 0;
              operation <= 0;
              if (band_index == 15) begin
                band_index <= 0;
                sample_index <= 8'd128;
                state <= ST_LOAD;
              end else begin
                band_index <= band_index + 1'b1;
              end
            end
          endcase
        end

        ST_FINAL: begin
          case (operation)
            4'd0: begin temporary_left_real <= full_left_s1[band_index] - ($signed(multiply_result) >>> 12); operation <= 4'd1; end
            4'd1: begin temporary_left_imag <= $signed(multiply_result) >>> 12; operation <= 4'd2; end
            4'd2: begin temporary_right_real <= full_right_s1[band_index] - ($signed(multiply_result) >>> 12); operation <= 4'd3; end
            4'd3: begin temporary_right_imag <= $signed(multiply_result) >>> 12; operation <= 4'd4; end
            4'd4: begin temporary_half_left_real <= half_left_s1[band_index] - ($signed(multiply_result) >>> 12); operation <= 4'd5; end
            4'd5: begin temporary_half_left_imag <= $signed(multiply_result) >>> 12; operation <= 4'd6; end
            4'd6: begin temporary_half_right_real <= half_right_s1[band_index] - ($signed(multiply_result) >>> 12); operation <= 4'd7; end
            4'd7: begin temporary_half_right_imag <= $signed(multiply_result) >>> 12; operation <= 4'd8; end
            4'd8: begin phase_product <= multiply_result; operation <= 4'd9; end
            4'd9: begin phase_cross <= phase_product - multiply_result; operation <= 4'd10; end
            4'd10: begin dot_product <= multiply_result; operation <= 4'd11; end
            default: begin
              result[result_base] <= final_left_level;
              result[result_base + 1] <= final_right_level;
              result[result_base + 2] <= final_mono_level;
              result[result_base + 3] <= final_delta;
              result[result_base + 4] <= final_delta[7] ? 8'd0 : final_delta;
              result[result_base + 5] <= final_level_difference;
              result[result_base + 6] <= final_phase;
              result[result_base + 7] <= final_confidence;
              operation <= 0;
              if (band_index == 15) begin
                band_index <= 0;
                result_index <= 0;
                state <= ST_OUTPUT;
              end else begin
                band_index <= band_index + 1'b1;
              end
            end
          endcase
        end

        ST_OUTPUT: begin
          if (enable && output_ready) begin
            if (result_index == 8'd129) begin
              result_index <= 0;
              state <= ST_IDLE;
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
