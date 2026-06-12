module i2c_master # (
    parameter CLK_FREQ = 50_000_000,  // 50 MHz clock frequency
    parameter I2C_FREQ = 100_000      // 100 kHz I2C frequency
)(
    input logic clk,
    input logic reset,
    input logic start,
    input logic rw,
    input logic [6:0] slave_addr,
    input logic [7:0] data_in,        // Data to be transmitted
    output logic [7:0] data_out,      // Data received from slave
    output logic busy,
    output logic done,
    output logic ack_error,
    inout sda,
    output logic scl
);
  // SCL generation logic------
  localparam CLKS_PER_HALF_SCL = CLK_FREQ / (2 * I2C_FREQ);
  logic [$clog2(CLKS_PER_HALF_SCL)-1:0] count;

  always_ff @(posedge clk) begin
    if (reset) begin
      scl <= 1;
      count <= 0;
    end 
    else begin
      if (state == ADDRESS || state == ACK1 || state == DATA || state == ACK2) begin
        if (count == CLKS_PER_HALF_SCL-1) begin
          scl <= ~scl;
          count <= 0;
        end
        else begin
          count <= count + 1;
        end
      end
      else begin
        scl <= 1;
        count <= 0;
      end
    end
  end
  // -------------------------

  // Detect scl rise and fall exactly on the clock edges
  logic scl_prev;
  always_ff @(posedge clk) begin
      scl_prev <= scl;
  end
  wire scl_rise = (scl_prev == 0 && scl == 1);
  wire scl_fall = (scl_prev == 1 && scl == 0);
  // -------------------------

  typedef enum logic [3:0] {IDLE,START,ADDRESS,ACK1,DATA,ACK2,STOP_LOW,STOP_HIGH,DONE} state_t;
  state_t state;

  // State machine logic------
  logic sda_drive_low;
  logic sda_in;
  assign sda = sda_drive_low ? 1'b0 : 1'bz;
  assign sda_in = sda;

  logic [7:0] addr_shift_reg;
  logic [3:0] bit_count;

  logic [7:0] data_shift_reg;

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= IDLE;
      busy <= 0;
      done <= 0;
      ack_error <= 0;
      data_out <= 8'h00;
      sda_drive_low <= 0; // SDA idle high
      bit_count <= 0;
      addr_shift_reg <= 0;
      data_shift_reg <= 0;
    end 
    else begin
      case (state)
        IDLE: begin
          busy <= 0;
          done <= 0;
          ack_error <= 0;
          if (start) state <= START;
        end

        START: begin
          if (scl) begin
            busy <= 1;
            // Generate start condition on SDA
            sda_drive_low <= 1; // Pull SDA low while SCL is high

            addr_shift_reg <= {slave_addr, rw};
            bit_count <= 0;

            state <= ADDRESS;
          end
        end

        ADDRESS: begin
          // Shift out slave address and R/W bit on SDA
          if (scl_fall) begin
            if (bit_count < 8) begin
              sda_drive_low <= ~addr_shift_reg[7]; // Output MSB first (~ because sd_drive_low is active low/opposite to sda value)
              addr_shift_reg <= addr_shift_reg << 1; // Shift left
              bit_count <= bit_count + 1;
            end
            else begin
                bit_count <= 0;
                sda_drive_low <= 0; // Release SDA to allow slave to drive ACK bit
                state <= ACK1;
            end
          end
        end

        ACK1: begin
          // Check for ACK from slave
          if (scl_rise) begin
            if (sda_in) ack_error <= 1;           // No ACK received
          end
          if (scl_fall) begin
            if (ack_error) begin
              state <= STOP_LOW;                  // Abort safely on falling edge
            end else begin
              if (!rw) begin
                sda_drive_low <= ~data_in[7];
                data_shift_reg <= data_in << 1; // Load data to be sent into shift register
                bit_count <= 1;                 // Start counting at 1 since we just sent a bit
              end else bit_count <= 0;
              state <= DATA;                    // ACK received, proceed to data transfer
            end
          end
        end

        DATA: begin
          if (!rw) begin
            if (scl_fall) begin
              if (bit_count < 8) begin
                sda_drive_low <= ~data_shift_reg[7];
                data_shift_reg <= data_shift_reg << 1;
                bit_count <= bit_count + 1;
              end
              else begin
                sda_drive_low <= 0; // Release SDA after last bit
                state <= ACK2;      // Wait for ACK
              end
            end
          end 
          else begin
            sda_drive_low <= 0; // Release SDA to allow slave to drive it

            if (scl_rise) begin
              if (bit_count < 8) begin
                data_shift_reg <= {data_shift_reg[6:0], sda_in}; 
              end
            end

            if (scl_fall) begin
              if (bit_count < 8) begin
                 bit_count <= bit_count + 1;
              end else begin
                 data_out <= data_shift_reg; // Capture full byte
                 bit_count <= 0;
                 state <= ACK2;
              end
            end
          end
        end

        ACK2: begin
          // Check for ACK from slave after data transfer
          if (!rw) begin
            if (scl_rise) begin
              if (sda_in) ack_error <= 1;
            end
          end else begin
            sda_drive_low <= 0; // Master NACK to signal end of read
          end
          
          if (scl_fall) begin
            state <= STOP_LOW; // Transition to STOP safely on falling edge
          end
        end

        STOP_LOW: begin
          // Generate stop condition on SDA
          sda_drive_low <= 1;               // Pull SDA low while SCL is low
          if (scl_rise) state <= STOP_HIGH; // Wait for SCL to naturally rise
        end
        STOP_HIGH: begin
          sda_drive_low <= 0; // Release SDA to go high while SCL is high
          state <= DONE;
        end
        DONE: begin
          busy <= 0;
          done <= 1;
          if (!start) state <= IDLE; // Wait for start to go low before returning to IDLE
        end
      endcase
    end
  end
  // -------------------------
endmodule