/*
 * MONO_TEMPORAL_V0
 *
 * Input: 0xA0, then 256 repetitions of {current_pixel, previous_pixel}.
 * Output: 0x5A, ten feature bytes, and one status byte.
 */

`default_nettype none

module mono_temporal_core (
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
  reg       sample_phase;
  reg [7:0] pixel_index;
  reg [7:0] current_sample;

  reg [7:0] current_line [0:15];
  reg [3:0] previous_line [0:15];
  reg [7:0] current_left;
  reg [3:0] previous_left;
  reg [7:0] current_up_left;

  reg [15:0] luminance_sum;
  reg [7:0]  minimum_value;
  reg [7:0]  maximum_value;
  reg [17:0] edge_horizontal_sum;
  reg [17:0] edge_diag_rising_sum;
  reg [17:0] edge_vertical_sum;
  reg [17:0] edge_diag_falling_sum;
  reg signed [17:0] temporal_sum;
  reg signed [19:0] motion_x_sum;
  reg signed [19:0] motion_y_sum;
  reg [19:0] motion_confidence_sum;

  reg [7:0] result [0:11];
  reg [3:0] result_index;

  wire [3:0] x = pixel_index[3:0];
  wire [3:0] y = pixel_index[7:4];
  wire [7:0] current_up = current_line[x];
  wire [3:0] previous_up = previous_line[x];
  wire [7:0] current_up_right = current_line[x + 4'd1];

  wire [7:0] product_h_forward = previous_left * current_sample[7:4];
  wire [7:0] product_h_reverse = current_left[7:4] * input_data[7:4];
  wire [7:0] product_v_forward = previous_up * current_sample[7:4];
  wire [7:0] product_v_reverse = current_up[7:4] * input_data[7:4];
  wire signed [8:0] horizontal_correlation =
      $signed({1'b0, product_h_forward}) - $signed({1'b0, product_h_reverse});
  wire signed [8:0] vertical_correlation =
      $signed({1'b0, product_v_forward}) - $signed({1'b0, product_v_reverse});
  wire [19:0] confidence_increment =
      ((x != 0) ? {11'd0, abs_signed9(horizontal_correlation)} : 20'd0)
      + ((y != 0) ? {11'd0, abs_signed9(vertical_correlation)} : 20'd0);

  wire signed [17:0] temporal_average = temporal_sum >>> 8;
  wire signed [19:0] motion_x_average = motion_x_sum >>> 8;
  wire signed [19:0] motion_y_average = motion_y_sum >>> 8;
  wire [19:0] motion_confidence_average = motion_confidence_sum >> 9;

  integer i;

  function [7:0] abs_diff8;
    input [7:0] a;
    input [7:0] b;
    begin
      abs_diff8 = (a >= b) ? (a - b) : (b - a);
    end
  endfunction

  function [8:0] abs_signed9;
    input signed [8:0] value;
    begin
      abs_signed9 = value[8] ? -value : value;
    end
  endfunction

  function [7:0] saturate_signed8;
    input signed [19:0] value;
    begin
      if (value > 20'sd127)
        saturate_signed8 = 8'h7f;
      else if (value < -20'sd128)
        saturate_signed8 = 8'h80;
      else
        saturate_signed8 = value[7:0];
    end
  endfunction

  assign input_ready = enable && ((state == ST_IDLE) || (state == ST_LOAD));
  assign output_valid = enable && (state == ST_OUTPUT);
  assign output_data = (state == ST_OUTPUT) ? result[result_index] : 8'h00;
  assign output_first = output_valid && (result_index == 4'd0);
  assign output_last = output_valid && (result_index == 4'd11);
  assign busy = (state != ST_IDLE);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      sample_phase <= 1'b0;
      pixel_index <= 8'd0;
      current_sample <= 8'd0;
      current_left <= 8'd0;
      previous_left <= 4'd0;
      current_up_left <= 8'd0;
      luminance_sum <= 16'd0;
      minimum_value <= 8'hff;
      maximum_value <= 8'h00;
      edge_horizontal_sum <= 18'd0;
      edge_diag_rising_sum <= 18'd0;
      edge_vertical_sum <= 18'd0;
      edge_diag_falling_sum <= 18'd0;
      temporal_sum <= 18'sd0;
      motion_x_sum <= 20'sd0;
      motion_y_sum <= 20'sd0;
      motion_confidence_sum <= 20'd0;
      result_index <= 4'd0;
      error <= 1'b0;
      for (i = 0; i < 16; i = i + 1) begin
        current_line[i] <= 8'd0;
        previous_line[i] <= 4'd0;
      end
      for (i = 0; i < 12; i = i + 1)
        result[i] <= 8'd0;
    end else begin
      case (state)
        ST_IDLE: begin
          sample_phase <= 1'b0;
          pixel_index <= 8'd0;
          result_index <= 4'd0;
          if (enable && input_valid) begin
            if (input_data == 8'ha0) begin
              state <= ST_LOAD;
              error <= 1'b0;
              current_left <= 8'd0;
              previous_left <= 4'd0;
              current_up_left <= 8'd0;
              luminance_sum <= 16'd0;
              minimum_value <= 8'hff;
              maximum_value <= 8'h00;
              edge_horizontal_sum <= 18'd0;
              edge_diag_rising_sum <= 18'd0;
              edge_vertical_sum <= 18'd0;
              edge_diag_falling_sum <= 18'd0;
              temporal_sum <= 18'sd0;
              motion_x_sum <= 20'sd0;
              motion_y_sum <= 20'sd0;
              motion_confidence_sum <= 20'd0;
              for (i = 0; i < 16; i = i + 1) begin
                current_line[i] <= 8'd0;
                previous_line[i] <= 4'd0;
              end
            end else begin
              error <= 1'b1;
            end
          end
        end

        ST_LOAD: begin
          if (enable && input_valid) begin
            if (!sample_phase) begin
              current_sample <= input_data;
              sample_phase <= 1'b1;
            end else begin
              sample_phase <= 1'b0;
              luminance_sum <= luminance_sum + {8'd0, current_sample};
              if (current_sample < minimum_value)
                minimum_value <= current_sample;
              if (current_sample > maximum_value)
                maximum_value <= current_sample;

              temporal_sum <= temporal_sum
                  + $signed({10'd0, current_sample})
                  - $signed({10'd0, input_data});

              motion_confidence_sum <= motion_confidence_sum
                  + confidence_increment;

              if (x != 0) begin
                edge_vertical_sum <= edge_vertical_sum
                    + {10'd0, abs_diff8(current_sample, current_left)};
                motion_x_sum <= motion_x_sum
                    + {{11{horizontal_correlation[8]}}, horizontal_correlation};
              end

              if (y != 0) begin
                edge_horizontal_sum <= edge_horizontal_sum
                    + {10'd0, abs_diff8(current_sample, current_up)};
                motion_y_sum <= motion_y_sum
                    + {{11{vertical_correlation[8]}}, vertical_correlation};
                if (x != 0)
                  edge_diag_rising_sum <= edge_diag_rising_sum
                      + {10'd0, abs_diff8(current_sample, current_up_left)};
                if (x != 15)
                  edge_diag_falling_sum <= edge_diag_falling_sum
                      + {10'd0, abs_diff8(current_sample, current_up_right)};
              end

              current_left <= current_sample;
              previous_left <= input_data[7:4];
              current_up_left <= current_up;
              current_line[x] <= current_sample;
              previous_line[x] <= input_data[7:4];

              if (pixel_index == 8'hff) begin
                state <= ST_FINALIZE;
              end else begin
                pixel_index <= pixel_index + 8'd1;
              end
            end
          end
        end

        ST_FINALIZE: begin
          result[0] <= 8'h5a;
          result[1] <= luminance_sum[15:8];
          result[2] <= maximum_value - minimum_value;
          result[3] <= edge_horizontal_sum[15:8];
          result[4] <= edge_diag_rising_sum[15:8];
          result[5] <= edge_vertical_sum[15:8];
          result[6] <= edge_diag_falling_sum[15:8];
          result[7] <= saturate_signed8({{2{temporal_average[17]}}, temporal_average});
          result[8] <= saturate_signed8(motion_x_average);
          result[9] <= saturate_signed8(motion_y_average);
          result[10] <= (motion_confidence_average > 20'd255)
              ? 8'hff : motion_confidence_average[7:0];
          result[11] <= {
              4'b0000,
              (motion_confidence_average > 20'd255),
              (motion_y_average > 20'sd127) || (motion_y_average < -20'sd128),
              (motion_x_average > 20'sd127) || (motion_x_average < -20'sd128),
              (temporal_average > 18'sd127) || (temporal_average < -18'sd128)
          };
          result_index <= 4'd0;
          state <= ST_OUTPUT;
        end

        ST_OUTPUT: begin
          if (enable && output_ready) begin
            if (result_index == 4'd11) begin
              result_index <= 4'd0;
              state <= ST_IDLE;
            end else begin
              result_index <= result_index + 4'd1;
            end
          end
        end

        default: begin
          state <= ST_IDLE;
          error <= 1'b1;
        end
      endcase
    end
  end

endmodule

`default_nettype none
