// mem_init.svh -- THE initial-memory function. Included by mem_model (module
// scope), tb_smoke, and coh_pkg (scoreboard), so every reference model agrees on
// untouched addresses. Deterministic from the address: never $random.
// No include guard: it is included into separate scopes on purpose.

// Initial value of the 32-bit word at byte address `addr` (low 2 bits ignored).
function automatic logic [31:0] mem_init_word(input logic [31:0] addr);
    logic [31:0] x;
    x = {addr[31:2], 2'b00} ^ 32'hA5A5_5A5A;
    x = x * 32'h9E37_79B1;
    return x ^ (x >> 15);
endfunction

// Initial value of a whole line; word w sits at bits [w*32 +: 32].
function automatic logic [127:0] mem_init_line(input logic [27:0] line_addr);
    logic [127:0] line;
    for (int w = 0; w < 4; w++)
        line[w*32 +: 32] = mem_init_word({line_addr, w[1:0], 2'b00});
    return line;
endfunction
