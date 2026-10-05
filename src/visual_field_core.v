/*
 * VISUAL_FIELD_V0
 *
 * Input: 0xA1, then 64 raster-order MONO_TEMPORAL_V0 records without
 * their 0x5A marker (ten feature bytes plus status per tile).
 * Output: 0x5C, sixteen field-level feature bytes, and one status byte.
 */

`default_nettype none

module visual_field_core (
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

  localparam [1:0] ST_IDLE     = 2'd0;
  localparam [1:0] ST_LOAD     = 2'd1;
  localparam [1:0] ST_FINALIZE = 2'd2;
  localparam [1:0] ST_OUTPUT   = 2'd3;

  reg [1:0] state;
  reg [5:0] tile_index;
  reg [3:0] field_index;
  reg [4:0] result_index;

  reg [7:0] tile_contrast;
  reg signed [7:0] tile_temporal;
  reg signed [7:0] tile_motion_x;

  reg [13:0] luminance_sum;
  reg [13:0] contrast_sum;
  reg [13:0] horizontal_sum;
  reg [13:0] rising_sum;
  reg [13:0] vertical_sum;
  reg [13:0] falling_sum;
  reg signed [14:0] temporal_sum;
  reg signed [14:0] motion_x_sum;
  reg signed [14:0] motion_y_sum;
  reg [13:0] confidence_sum;
  reg signed [17:0] expansion_sum;
  reg signed [17:0] rotation_sum;
  reg signed [17:0] saliency_x_sum;
  reg signed [17:0] saliency_y_sum;
  reg [13:0] activity_sum;
  reg [7:0] status_or;

  reg [7:0] result [0:17];

  wire signed [4:0] x_center =
      $signed({1'b0, tile_index[2:0], 1'b0}) - 5'sd7;
  wire signed [4:0] y_center =
      $signed({1'b0, tile_index[5:3], 1'b0}) - 5'sd7;
  wire signed [7:0] current_motion_y = $signed(input_data);
  wire [7:0] temporal_magnitude = abs_signed8(tile_temporal);
  wire [9:0] activity_raw = {2'b00, tile_contrast}
      + {2'b00, temporal_magnitude}
      + {2'b00, input_data};
  wire [7:0] activity_increment =
      (activity_raw > 10'd255) ? 8'hff : activity_raw[7:0];

  wire signed [12:0] expansion_x = x_center * tile_motion_x;
  wire signed [12:0] expansion_y = y_center * current_motion_y;
  wire signed [13:0] expansion_increment =
      {{1{expansion_x[12]}}, expansion_x}
      + {{1{expansion_y[12]}}, expansion_y};
  wire signed [12:0] rotation_x = x_center * current_motion_y;
  wire signed [12:0] rotation_y = y_center * tile_motion_x;
  wire signed [13:0] rotation_increment =
      {{1{rotation_x[12]}}, rotation_x}
      - {{1{rotation_y[12]}}, rotation_y};
  wire signed [8:0] activity_signed = $signed({1'b0, activity_increment});
  wire signed [13:0] saliency_x_increment = x_center * activity_signed;
  wire signed [13:0] saliency_y_increment = y_center * activity_signed;

  wire [14:0] motion_x_magnitude = abs_signed15(motion_x_sum);
  wire [14:0] motion_y_magnitude = abs_signed15(motion_y_sum);
  wire [15:0] directional_raw =
      {1'b0, motion_x_magnitude} + {1'b0, motion_y_magnitude};
  wire [15:0] directional_scaled = directional_raw >> 5;

  integer i;

  function [7:0] abs_signed8;
    input signed [7:0] value;
    begin
      abs_signed8 = value[7] ? -value : value;
    end
  endfunction

  function [14:0] abs_signed15;
    input signed [14:0] value;
    begin
      abs_signed15 = value[14] ? -value : value;
    end
  endfunction

  function [7:0] saturate_signed8;
    input signed [17:0] value;
    begin
      if (value > 18'sd127)
        saturate_signed8 = 8'h7f;
      else if (value < -18'sd128)
        saturate_signed8 = 8'h80;
      else
        saturate_signed8 = value[7:0];
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
      tile_index <= 0;
      field_index <= 0;
      result_index <= 0;
      tile_contrast <= 0;
      tile_temporal <= 0;
      tile_motion_x <= 0;
      luminance_sum <= 0;
      contrast_sum <= 0;
      horizontal_sum <= 0;
      rising_sum <= 0;
      vertical_sum <= 0;
      falling_sum <= 0;
      temporal_sum <= 0;
      motion_x_sum <= 0;
      motion_y_sum <= 0;
      confidence_sum <= 0;
      expansion_sum <= 0;
      rotation_sum <= 0;
      saliency_x_sum <= 0;
      saliency_y_sum <= 0;
      activity_sum <= 0;
      status_or <= 0;
      error <= 0;
      for (i = 0; i < 18; i = i + 1)
        result[i] <= 0;
    end else begin
      case (state)
        ST_IDLE: begin
          tile_index <= 0;
          field_index <= 0;
          result_index <= 0;
          if (enable && input_valid) begin
            if (input_data == 8'ha1) begin
              state <= ST_LOAD;
              error <= 0;
              luminance_sum <= 0;
              contrast_sum <= 0;
              horizontal_sum <= 0;
              rising_sum <= 0;
              vertical_sum <= 0;
              falling_sum <= 0;
              temporal_sum <= 0;
              motion_x_sum <= 0;
              motion_y_sum <= 0;
              confidence_sum <= 0;
              expansion_sum <= 0;
              rotation_sum <= 0;
              saliency_x_sum <= 0;
              saliency_y_sum <= 0;
              activity_sum <= 0;
              status_or <= 0;
            end else begin
              error <= 1;
            end
          end
        end

        ST_LOAD: begin
          if (enable && input_valid) begin
            case (field_index)
              4'd0: luminance_sum <= luminance_sum + {6'd0, input_data};
              4'd1: begin
                contrast_sum <= contrast_sum + {6'd0, input_data};
                tile_contrast <= input_data;
              end
              4'd2: horizontal_sum <= horizontal_sum + {6'd0, input_data};
              4'd3: rising_sum <= rising_sum + {6'd0, input_data};
              4'd4: vertical_sum <= vertical_sum + {6'd0, input_data};
              4'd5: falling_sum <= falling_sum + {6'd0, input_data};
              4'd6: begin
                tile_temporal <= $signed(input_data);
                temporal_sum <= temporal_sum
                    + {{7{input_data[7]}}, input_data};
              end
              4'd7: begin
                tile_motion_x <= $signed(input_data);
                motion_x_sum <= motion_x_sum
                    + {{7{input_data[7]}}, input_data};
              end
              4'd8: begin
                motion_y_sum <= motion_y_sum
                    + {{7{input_data[7]}}, input_data};
                expansion_sum <= expansion_sum
                    + {{4{expansion_increment[13]}}, expansion_increment};
                rotation_sum <= rotation_sum
                    + {{4{rotation_increment[13]}}, rotation_increment};
              end
              4'd9: begin
                confidence_sum <= confidence_sum + {6'd0, input_data};
                activity_sum <= activity_sum + {6'd0, activity_increment};
                saliency_x_sum <= saliency_x_sum
                    + {{4{saliency_x_increment[13]}}, saliency_x_increment};
                saliency_y_sum <= saliency_y_sum
                    + {{4{saliency_y_increment[13]}}, saliency_y_increment};
              end
              default: begin
                status_or <= status_or | input_data;
                if (tile_index == 6'd63) begin
                  state <= ST_FINALIZE;
                end else begin
                  tile_index <= tile_index + 1'b1;
                  field_index <= 0;
                end
              end
            endcase
            if (field_index != 4'd10)
              field_index <= field_index + 1'b1;
          end
        end

        ST_FINALIZE: begin
          result[0] <= 8'h5c;
          result[1] <= luminance_sum[13:6];
          result[2] <= contrast_sum[13:6];
          result[3] <= horizontal_sum[13:6];
          result[4] <= rising_sum[13:6];
          result[5] <= vertical_sum[13:6];
          result[6] <= falling_sum[13:6];
          result[7] <= saturate_signed8(
              $signed({{3{temporal_sum[14]}}, temporal_sum}) >>> 6);
          result[8] <= saturate_signed8(
              $signed({{3{motion_x_sum[14]}}, motion_x_sum}) >>> 6);
          result[9] <= saturate_signed8(
              $signed({{3{motion_y_sum[14]}}, motion_y_sum}) >>> 6);
          result[10] <= confidence_sum[13:6];
          result[11] <= saturate_signed8(expansion_sum >>> 8);
          result[12] <= saturate_signed8(rotation_sum >>> 8);
          result[13] <= saturate_signed8(saliency_x_sum >>> 9);
          result[14] <= saturate_signed8(saliency_y_sum >>> 9);
          result[15] <= activity_sum[13:6];
          result[16] <= (directional_scaled > 255)
              ? 8'hff : directional_scaled[7:0];
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
