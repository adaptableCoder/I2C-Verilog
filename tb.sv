`timescale 1ns / 1ps

module tb_i2c_master();

    parameter CLK_FREQ = 50_000_000;
    parameter I2C_FREQ = 100_000;
    localparam CLK_PERIOD = 1_000_000_000 / CLK_FREQ; 
    localparam I2C_PERIOD = 1_000_000_000 / I2C_FREQ; 

    logic clk;
    logic reset;
    logic start;
    logic rw;           // Renamed to rw (0 = Write, 1 = Read)
    logic [6:0] slave_addr;
    logic [7:0] data_in;
    
    logic [7:0] data_out;
    logic busy;
    logic done;
    logic ack_error;

    wire sda;
    logic scl;

    // Simulate physical pull-up resistor
    pullup(sda); 

    logic sda_slave_en;
    logic sda_slave_out;
    assign sda = (sda_slave_en && sda_slave_out == 1'b0) ? 1'b0 : 1'bz;

    i2c_master #(
        .CLK_FREQ(CLK_FREQ),
        .I2C_FREQ(I2C_FREQ)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .rw(rw), // Updated port mapping
        .slave_addr(slave_addr), .data_in(data_in), .data_out(data_out),
        .busy(busy), .done(done), .ack_error(ack_error),
        .sda(sda), .scl(scl)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // =========================================================================
    // BACKGROUND HARDWARE MOCK SLAVE
    // =========================================================================
    integer slave_bit_cnt = 0;
    logic transaction_active = 0;
    logic is_read_op = 0;
    logic [7:0] tx_data = 8'h87; 
    logic [7:0] rx_data = 8'h00; 

    always @(negedge sda) begin
        if (scl === 1'b1) begin
            transaction_active = 1;
            slave_bit_cnt = 0;
        end
    end

    always @(posedge sda) begin
        if (scl === 1'b1) begin
            transaction_active = 0;
            sda_slave_en <= 0;
        end
    end

    always @(posedge scl) begin
        if (transaction_active && slave_bit_cnt == 8) begin
            is_read_op <= sda;
        end
        if (transaction_active && slave_bit_cnt >= 10 && slave_bit_cnt <= 17 && !is_read_op) begin
            rx_data[17 - slave_bit_cnt] <= sda;
        end
    end

    always @(negedge scl) begin
        if (transaction_active) begin
            slave_bit_cnt = slave_bit_cnt + 1;
            
            if (slave_bit_cnt == 9) begin
                sda_slave_en <= 1;
                sda_slave_out <= 0;
            end 
            else if (slave_bit_cnt == 10) begin
                sda_slave_en <= 0;
                if (is_read_op) begin
                    sda_slave_en <= 1;
                    sda_slave_out <= tx_data[7];
                end
            end 
            else if (slave_bit_cnt >= 11 && slave_bit_cnt <= 17 && is_read_op) begin
                sda_slave_out <= tx_data[17 - slave_bit_cnt];
            end 
            else if (slave_bit_cnt == 18) begin
                if (!is_read_op) begin
                    sda_slave_en <= 1;
                    sda_slave_out <= 0;
                end else begin
                    sda_slave_en <= 0;
                end
            end 
            else if (slave_bit_cnt == 19) begin
                sda_slave_en <= 0;
            end
        end
    end

    // =========================================================================
    // MAIN STIMULUS
    // =========================================================================
    initial begin
        reset = 1;
        start = 0;
        rw = 0;
        slave_addr = 7'h00;
        data_in = 8'h00;
        sda_slave_en = 0;
        sda_slave_out = 1;
        
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_i2c_master);
        
        $display("Starting I2C Master Testbench...");

        #100;
        @(posedge clk);
        reset = 0;
        #500;

        // --- TEST CASE 1: Master Write ---
        $display("\n--- Test Case 1: Master Write ---");
        slave_addr = 7'h5A; 
        data_in    = 8'hC3; 
        rw         = 0;     // 0 = physical protocol bit for WRITE
        
        @(posedge clk);
        start = 1;
        #(I2C_PERIOD); 
        @(posedge clk);
        start = 0;
        
        @(posedge done);

        if (rx_data == 8'hC3 && ack_error == 1'b0)
            $display("[PASS] Master successfully wrote 0xC3 to slave.");
        else
            $display("[FAIL] Master Write failed. rx_data=0x%0h, ack_error=%0b", rx_data, ack_error);

        #100_000; 

        // --- TEST CASE 2: Master Read ---
        $display("\n--- Test Case 2: Master Read ---");
        slave_addr = 7'h5A; 
        rw         = 1;     // 1 = physical protocol bit for READ
        
        @(posedge clk);
        start = 1;
        #(I2C_PERIOD);
        @(posedge clk);
        start = 0;
        
        @(posedge done);

        if (data_out == 8'h87 && ack_error == 1'b0)
            $display("[PASS] Master successfully read 0x87 from slave.");
        else
            $display("[FAIL] Master Read failed. data_out=0x%0h, ack_error=%0b", data_out, ack_error);

        #100_000;

        // --- TEST CASE 3: NACK Handling ---
        $display("\n--- Test Case 3: NACK Handling ---");
        slave_addr = 7'h77; 
        rw         = 0;     // Testing a Write to a missing slave
        
        force transaction_active = 0; 
        
        @(posedge clk);
        start = 1;
        #(I2C_PERIOD);
        @(posedge clk);
        start = 0;

        @(posedge done);

        if (ack_error == 1'b1)
            $display("[PASS] Master correctly flagged an ack_error for a missing slave.");
        else
            $display("[FAIL] Master failed to detect NACK.");

        release transaction_active; 
        
        $display("\n--- All Tests Finished ---");
        $finish;
    end

    // Global Timeout
    initial begin
        #(I2C_PERIOD * 500); 
        $display("\n[FATAL ERROR] Global timeout reached! The DUT state machine is stuck.");
        $finish;
    end

endmodule