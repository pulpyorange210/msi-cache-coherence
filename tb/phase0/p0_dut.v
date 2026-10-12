// p0_dut -- Phase 0 toolchain probe. Not part of the design.
// Gives the checker a 2-bit "state" to cover/assert on and a generate block
// (g_way[*]) for the testbench to reference hierarchically.
module p0_dut #(
    parameter WAYS = 2
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] in,
    output reg  [1:0] st
);
    genvar w;
    generate
        for (w = 0; w < WAYS; w = w + 1) begin : g_way
            reg [7:0] cnt;   // 8 bits: a 4-bit count stepping by 2 wraps to 0 at the probe cycle
            always @(posedge clk) begin
                if (rst) cnt <= 8'd0;
                else     cnt <= cnt + w + 1;
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) st <= 2'b00;
        else     st <= in;
    end
endmodule
