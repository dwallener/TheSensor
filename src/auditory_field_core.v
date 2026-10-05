/*
 * AUDITORY_FIELD_V0
 *
 * Input: 0xB1, then eight time slots. Each slot contains sixteen eight-byte
 * STEREO_FILTERBANK_V0 band records followed by that slot's status byte.
 * Output: 0x5D, sixteen temporal-field feature bytes, and one status byte.
 */

`default_nettype none

module auditory_field_core (
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

  localparam [2:0] ST_IDLE     = 3'd0;
  localparam [2:0] ST_LOAD     = 3'd1;
  localparam [2:0] ST_SCAN     = 3'd2;
  localparam [2:0] ST_FINALIZE = 3'd3;
  localparam [2:0] ST_OUTPUT   = 3'd4;

  reg [2:0] state;
  reg [2:0] slot_index;
  reg [3:0] band_index;
  reg [2:0] field_index;
  reg expect_status;
  reg [3:0] scan_index;
  reg [4:0] result_index;

  reg signed [7:0] tile_level;
  reg signed [7:0] tile_phase;

  reg [14:0] total_energy;
  reg [13:0] low_energy;
  reg [13:0] middle_energy;
  reg [13:0] high_energy;
  reg [18:0] weighted_band_sum;
  reg [18:0] weighted_spread_sum;
  reg [14:0] onset_sum;
  reg [14:0] offset_sum;
  reg [14:0] confidence_sum;
  reg signed [23:0] weighted_level_sum;
  reg signed [23:0] weighted_phase_sum;
  reg signed [13:0] early_level_sum;
  reg signed [13:0] late_level_sum;
  reg [11:0] slot_energy;
  reg [11:0] previous_slot_energy;
  reg [11:0] peak_slot_energy;
  reg [14:0] modulation_sum;
  reg [7:0] status_or;

  reg [11:0] band_energy [0:15];
  reg [7:0] baseline [0:15];
  reg [11:0] strongest_energy;
  reg [3:0] strongest_band;
  reg [11:0] novelty_sum;
  reg [7:0] result [0:17];

  wire signed [7:0] signed_input = $signed(input_data);
  wire [7:0] negative_delta = signed_input[7] ? -signed_input : 8'd0;
  wire [4:0] doubled_band = {band_index, 1'b0};
  wire [4:0] spread_factor = (band_index < 8)
      ? (5'd15 - doubled_band) : (doubled_band - 5'd15);
  wire [11:0] weighted_band_increment = band_index * input_data;
  wire [12:0] weighted_spread_increment = spread_factor * input_data;
  wire signed [8:0] confidence_signed = $signed({1'b0, input_data});
  wire signed [16:0] level_product = tile_level * confidence_signed;
  wire signed [16:0] phase_product = tile_phase * confidence_signed;

  wire [11:0] mean_slot_energy = total_energy[14:3];
  wire [11:0] impulsive_difference =
      (peak_slot_energy > mean_slot_energy)
      ? (peak_slot_energy - mean_slot_energy) : 12'd0;
  wire [11:0] impulsive_scaled = impulsive_difference >> 4;
  wire [14:0] modulation_scaled = modulation_sum >> 7;
  wire signed [14:0] lateral_difference =
      {{1{late_level_sum[13]}}, late_level_sum}
      - {{1{early_level_sum[13]}}, early_level_sum};

  wire [7:0] scan_average = band_energy[scan_index][10:3];
  wire signed [8:0] baseline_delta =
      $signed({1'b0, scan_average}) - $signed({1'b0, baseline[scan_index]});
  wire signed [8:0] baseline_next =
      $signed({1'b0, baseline[scan_index]}) + (baseline_delta >>> 3);
  wire [7:0] novelty_increment = abs_diff8(
      scan_average, baseline[scan_index]);

  integer i;

  function [7:0] abs_diff8;
    input [7:0] a;
    input [7:0] b;
    begin
      abs_diff8 = (a >= b) ? (a - b) : (b - a);
    end
  endfunction

  function [11:0] abs_diff12;
    input [11:0] a;
    input [11:0] b;
    begin
      abs_diff12 = (a >= b) ? (a - b) : (b - a);
    end
  endfunction

  function [7:0] saturate_unsigned8;
    input [15:0] value;
    begin
      saturate_unsigned8 = (value > 255) ? 8'hff : value[7:0];
    end
  endfunction

  function [7:0] saturate_signed8;
    input signed [23:0] value;
    begin
      if (value > 24'sd127)
        saturate_signed8 = 8'h7f;
      else if (value < -24'sd128)
        saturate_signed8 = 8'h80;
      else
        saturate_signed8 = value[7:0];
    end
  endfunction

  function [7:0] unsigned_ratio16;
    input [18:0] numerator;
    input [14:0] denominator;
    integer bit_index;
    integer highest_bit;
    reg [22:0] scaled;
    reg [22:0] quotient;
    begin
      highest_bit = 0;
      for (bit_index = 0; bit_index < 15; bit_index = bit_index + 1)
        if (denominator[bit_index])
          highest_bit = bit_index;
      scaled = {numerator, 4'b0000};
      quotient = scaled >> highest_bit;
      if (denominator == 0)
        unsigned_ratio16 = 0;
      else if (quotient > 255)
        unsigned_ratio16 = 8'hff;
      else
        unsigned_ratio16 = quotient[7:0];
    end
  endfunction

  function [7:0] signed_ratio;
    input signed [23:0] numerator;
    input [14:0] denominator;
    integer bit_index;
    integer highest_bit;
    reg signed [23:0] quotient;
    begin
      highest_bit = 0;
      for (bit_index = 0; bit_index < 15; bit_index = bit_index + 1)
        if (denominator[bit_index])
          highest_bit = bit_index;
      quotient = numerator >>> highest_bit;
      if (denominator == 0)
        signed_ratio = 0;
      else
        signed_ratio = saturate_signed8(quotient);
    end
  endfunction

  assign input_ready = enable && ((state == ST_IDLE) || (state == ST_LOAD));
  assign output_valid = enable && (state == ST_OUTPUT);
  assign output_data = (state == ST_OUTPUT) ? result[result_index] : 8'h00;
  assign output_first = output_valid && (result_index == 0);
  assign output_last = output_valid && (result_index == 17);
  assign busy = (state != ST_IDLE);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      slot_index <= 0;
      band_index <= 0;
      field_index <= 0;
      expect_status <= 0;
      scan_index <= 0;
      result_index <= 0;
      tile_level <= 0;
      tile_phase <= 0;
      total_energy <= 0;
      low_energy <= 0;
      middle_energy <= 0;
      high_energy <= 0;
      weighted_band_sum <= 0;
      weighted_spread_sum <= 0;
      onset_sum <= 0;
      offset_sum <= 0;
      confidence_sum <= 0;
      weighted_level_sum <= 0;
      weighted_phase_sum <= 0;
      early_level_sum <= 0;
      late_level_sum <= 0;
      slot_energy <= 0;
      previous_slot_energy <= 0;
      peak_slot_energy <= 0;
      modulation_sum <= 0;
      status_or <= 0;
      strongest_energy <= 0;
      strongest_band <= 0;
      novelty_sum <= 0;
      error <= 0;
      for (i = 0; i < 16; i = i + 1) begin
        band_energy[i] <= 0;
        baseline[i] <= 0;
      end
      for (i = 0; i < 18; i = i + 1)
        result[i] <= 0;
    end else begin
      case (state)
        ST_IDLE: begin
          slot_index <= 0;
          band_index <= 0;
          field_index <= 0;
          expect_status <= 0;
          result_index <= 0;
          if (enable && input_valid) begin
            if (input_data == 8'hb1) begin
              state <= ST_LOAD;
              error <= 0;
              total_energy <= 0;
              low_energy <= 0;
              middle_energy <= 0;
              high_energy <= 0;
              weighted_band_sum <= 0;
              weighted_spread_sum <= 0;
              onset_sum <= 0;
              offset_sum <= 0;
              confidence_sum <= 0;
              weighted_level_sum <= 0;
              weighted_phase_sum <= 0;
              early_level_sum <= 0;
              late_level_sum <= 0;
              slot_energy <= 0;
              previous_slot_energy <= 0;
              peak_slot_energy <= 0;
              modulation_sum <= 0;
              status_or <= 0;
              strongest_energy <= 0;
              strongest_band <= 0;
              novelty_sum <= 0;
              for (i = 0; i < 16; i = i + 1)
                band_energy[i] <= 0;
            end else begin
              error <= 1;
            end
          end
        end

        ST_LOAD: begin
          if (enable && input_valid) begin
            if (expect_status) begin
              status_or <= status_or | input_data;
              if (slot_energy > peak_slot_energy)
                peak_slot_energy <= slot_energy;
              if (slot_index != 0)
                modulation_sum <= modulation_sum
                    + {3'd0, abs_diff12(slot_energy, previous_slot_energy)};
              previous_slot_energy <= slot_energy;
              slot_energy <= 0;
              expect_status <= 0;
              band_index <= 0;
              field_index <= 0;
              if (slot_index == 7) begin
                scan_index <= 0;
                state <= ST_SCAN;
              end else begin
                slot_index <= slot_index + 1'b1;
              end
            end else begin
              case (field_index)
                3'd2: begin
                  total_energy <= total_energy + {7'd0, input_data};
                  slot_energy <= slot_energy + {4'd0, input_data};
                  band_energy[band_index] <= band_energy[band_index]
                      + {4'd0, input_data};
                  if (band_index < 4)
                    low_energy <= low_energy + {6'd0, input_data};
                  else if (band_index < 12)
                    middle_energy <= middle_energy + {6'd0, input_data};
                  else
                    high_energy <= high_energy + {6'd0, input_data};
                  weighted_band_sum <= weighted_band_sum
                      + {7'd0, weighted_band_increment};
                  weighted_spread_sum <= weighted_spread_sum
                      + {6'd0, weighted_spread_increment};
                end
                3'd3: begin
                  if (input_data[7])
                    offset_sum <= offset_sum + {7'd0, negative_delta};
                end
                3'd4: onset_sum <= onset_sum + {7'd0, input_data};
                3'd5: begin
                  tile_level <= $signed(input_data);
                  if (slot_index < 4)
                    early_level_sum <= early_level_sum
                        + {{6{input_data[7]}}, input_data};
                  else
                    late_level_sum <= late_level_sum
                        + {{6{input_data[7]}}, input_data};
                end
                3'd6: tile_phase <= $signed(input_data);
                3'd7: begin
                  confidence_sum <= confidence_sum + {7'd0, input_data};
                  weighted_level_sum <= weighted_level_sum
                      + {{7{level_product[16]}}, level_product};
                  weighted_phase_sum <= weighted_phase_sum
                      + {{7{phase_product[16]}}, phase_product};
                end
                default: begin end
              endcase

              if (field_index == 7) begin
                field_index <= 0;
                if (band_index == 15)
                  expect_status <= 1;
                else
                  band_index <= band_index + 1'b1;
              end else begin
                field_index <= field_index + 1'b1;
              end
            end
          end
        end

        ST_SCAN: begin
          if (band_energy[scan_index] > strongest_energy) begin
            strongest_energy <= band_energy[scan_index];
            strongest_band <= scan_index;
          end
          novelty_sum <= novelty_sum + {4'd0, novelty_increment};
          baseline[scan_index] <= baseline_next[7:0];
          if (scan_index == 15) begin
            state <= ST_FINALIZE;
          end else begin
            scan_index <= scan_index + 1'b1;
          end
        end

        ST_FINALIZE: begin
          result[0] <= 8'h5d;
          result[1] <= total_energy[14:7];
          result[2] <= low_energy[12:5];
          result[3] <= middle_energy[13:6];
          result[4] <= high_energy[12:5];
          result[5] <= unsigned_ratio16(weighted_band_sum, total_energy);
          result[6] <= unsigned_ratio16(weighted_spread_sum, total_energy);
          result[7] <= onset_sum[14:7];
          result[8] <= offset_sum[14:7];
          result[9] <= {strongest_band, strongest_band};
          result[10] <= saturate_unsigned8({4'd0, impulsive_scaled});
          result[11] <= saturate_unsigned8({1'b0, modulation_scaled});
          result[12] <= signed_ratio(weighted_level_sum, confidence_sum);
          result[13] <= signed_ratio(weighted_phase_sum, confidence_sum);
          result[14] <= saturate_signed8(
              $signed({{9{lateral_difference[14]}}, lateral_difference}) >>> 6);
          result[15] <= confidence_sum[14:7];
          result[16] <= novelty_sum[11:4];
          result[17] <= status_or;
          result_index <= 0;
          state <= ST_OUTPUT;
        end

        ST_OUTPUT: begin
          if (enable && output_ready) begin
            if (result_index == 17) begin
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

`default_nettype none
