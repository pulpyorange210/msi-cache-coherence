// rr_arbiter -- round-robin arbiter, N requests -> one-hot grant.
// gnt is combinational from req and the priority pointer. When `take` is high
// (the grant is being used this cycle), the pointer moves to one past the
// granted index, so the winner has lowest priority next time.
module rr_arbiter #(
    parameter N  = 2,
    // Derived -- do not override.
    parameter IW = (N > 1) ? $clog2(N) : 1
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [N-1:0] req,
    input  wire         take,
    output reg  [N-1:0] gnt     // one-hot; bit i = requester i
);
    reg  [IW-1:0] ptr;          // index with highest priority this cycle
    reg  [IW:0]   idx;
    reg  [IW-1:0] g_idx;
    reg           found;
    integer       k;

    always @* begin
        gnt   = {N{1'b0}};
        g_idx = {IW{1'b0}};
        found = 1'b0;
        idx   = {(IW+1){1'b0}};
        for (k = 0; k < N; k = k + 1) begin
            idx = {1'b0, ptr} + k[IW:0];
            if (idx >= N) idx = idx - N;
            if (!found && req[idx]) begin
                found    = 1'b1;
                gnt[idx] = 1'b1;
                g_idx    = idx[IW-1:0];
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            ptr <= {IW{1'b0}};
`ifdef MUT_4
        // MUT_4: fixed priority -- the pointer never moves, requester 0 always wins.
        else
            ptr <= {IW{1'b0}};
`else
        else if (take && found)
            ptr <= (g_idx == N - 1) ? {IW{1'b0}} : g_idx + 1'b1;
`endif
    end
endmodule
