// Sequences. coh_base_seq draws n_ops accesses from an address pool (line byte
// addresses) restricted to the words in word_mask, writing wr_pct% of the time.
// Each traffic mode is a subclass that only builds its pool in pre_body(); the
// test sets core_id / n_ops / hot lines before starting it.
class coh_base_seq extends uvm_sequence #(core_txn);
    `uvm_object_utils(coh_base_seq)

    int unsigned n_ops     = 1000;
    int unsigned core_id   = 0;
    int unsigned wr_pct    = 50;
    bit [3:0]    word_mask = 4'hF;   // bit w: word w of a line may be accessed
    bit [31:0]   pool[$];            // line-aligned byte addresses

    function new(string name = "coh_base_seq");
        super.new(name);
    endfunction

    // Line byte address from tag and set index (tag = addr[31:6], index = addr[5:4]).
    static function bit [31:0] line_addr(int unsigned tag, int unsigned idx);
        return (tag << 6) | (idx << 4);
    endfunction

    virtual task body();
        bit [31:0]   a;
        int unsigned w;
        if (pool.size() == 0) `uvm_fatal("SEQ", "empty address pool")
        repeat (n_ops) begin
            a = pool[$urandom_range(pool.size() - 1)];
            do w = $urandom_range(3); while (!word_mask[w]);
            a = a | (w << 2);
            req = core_txn::type_id::create("req");
            start_item(req);
            if (!req.randomize() with { addr == a; we dist {1 := wr_pct, 0 := 100 - wr_pct}; })
                `uvm_fatal("SEQ", "randomize failed")
            finish_item(req);
        end
    endtask
endclass

// Disjoint per core: 6 tags of its own in every set -> hits, misses, evictions,
// never any sharing.
class coh_private_seq extends coh_base_seq;
    `uvm_object_utils(coh_private_seq)
    function new(string name = "coh_private_seq");
        super.new(name);
    endfunction
    task pre_body();
        pool.delete();
        for (int t = 0; t < 6; t++)
            for (int s = 0; s < 4; s++)
                pool.push_back(line_addr(16 * (core_id + 1) + t, s));
    endtask
endclass

// 2-4 hot lines shared by all cores (lines chosen by the test, same for all).
class coh_share_seq extends coh_base_seq;
    `uvm_object_utils(coh_share_seq)
    bit [31:0] hot[$];
    function new(string name = "coh_share_seq");
        super.new(name);
    endfunction
    task pre_body();
        pool = hot;
    endtask
endclass

// Same index, different tags, shared by all cores: constant dirty and clean
// evictions plus sharing on the lines that survive.
class coh_conflict_seq extends coh_base_seq;
    `uvm_object_utils(coh_conflict_seq)
    int unsigned idx = 1;
    function new(string name = "coh_conflict_seq");
        super.new(name);
    endfunction
    task pre_body();
        pool.delete();
        for (int t = 0; t < 5; t++)
            pool.push_back(line_addr(32 + t, idx));
    endtask
endclass

// One line, every core writes it most of the time: ownership ping-pong.
class coh_pingpong_seq extends coh_base_seq;
    `uvm_object_utils(coh_pingpong_seq)
    function new(string name = "coh_pingpong_seq");
        super.new(name);
    endfunction
    task pre_body();
        pool.delete();
        pool.push_back(line_addr(48, 2));
        wr_pct = 80;
    endtask
endclass

// One line, core c only touches word c%4: coherence traffic with no true sharing.
class coh_falseshare_seq extends coh_base_seq;
    `uvm_object_utils(coh_falseshare_seq)
    function new(string name = "coh_falseshare_seq");
        super.new(name);
    endfunction
    task pre_body();
        pool.delete();
        pool.push_back(line_addr(56, 3));
        word_mask = 4'b0001 << (core_id % 4);
        wr_pct    = 60;
    endtask
endclass
