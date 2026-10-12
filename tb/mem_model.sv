// mem_model -- flat line-addressed memory with random LAT_MIN..LAT_MAX cycle
// latency per transaction ($urandom_range, so seeded by -sv_seed).
// Protocol: mem_req is held until mem_ack; mem_ack is a one-cycle pulse that
// arrives LAT cycles after the request is first sampled. Writes commit on ack.
// Untouched lines read as mem_init_line(). peek() is for checkers (hierarchical).
`timescale 1ns/1ps
module mem_model #(
    parameter LAW     = 28,
    parameter LINE_W  = 128,
    parameter LAT_MIN = 2,
    parameter LAT_MAX = 8
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              mem_req,
    input  logic              mem_we,
    input  logic [LAW-1:0]    mem_addr,
    input  logic [LINE_W-1:0] mem_wdata,
    output logic [LINE_W-1:0] mem_rdata,
    output logic              mem_ack
);
    `include "mem_init.svh"

    logic [LINE_W-1:0] mem [logic [LAW-1:0]];

    function automatic logic [LINE_W-1:0] peek(input logic [LAW-1:0] a);
        return mem.exists(a) ? mem[a] : mem_init_line(a);
    endfunction

    initial mem_ack = 1'b0;

    logic        busy;
    int unsigned cnt;
    int unsigned n_reads, n_writes;
    int unsigned lat_max_seen;
    int unsigned lat_cur;

    always @(posedge clk) begin
        mem_ack <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            cnt  <= 0;
        end else if (mem_ack) begin
            // Ack cycle: mem_req is still high but this request is finished.
        end else if (!busy && mem_req) begin
            lat_cur = $urandom_range(LAT_MAX, LAT_MIN);
            if (lat_cur > lat_max_seen) lat_max_seen = lat_cur;
            busy <= 1'b1;
            cnt  <= lat_cur - 1;
        end else if (busy) begin
            if (cnt == 0) begin
                busy    <= 1'b0;
                mem_ack <= 1'b1;
                if (mem_we) begin
                    mem[mem_addr] = mem_wdata;   // blocking: xsim rejects NBA into an assoc array
                    n_writes++;
                end else begin
                    mem_rdata <= peek(mem_addr);
                    n_reads++;
                end
            end else begin
                cnt <= cnt - 1;
            end
        end
    end
endmodule
