// The translation lookaside buffer (TLB) of the Almurut II CPU: the eight
// translations from a page of virtual memory to a page of physical
// memory that the CPU keeps at hand.
//
// A translation holds the number of the virtual page (the address
// without its low 12 bits; 19 bits, as only the lower half of the address
// space is translated), the number of the physical page (20 bits of a
// 32-bit address), and two permissions: the page may be written, and
// user mode may use it.
//
// Lookup: the CPU puts the number of a virtual page on vpn. All eight
// entries compare it with their own in the same clock, and hit tells
// whether one of them holds it. A page is never in two entries.
//
// Load: load writes a translation for the page on vpn. It replaces the
// entry of the same page if there is one, and the oldest loaded entry
// otherwise: next_q walks around the entries.
//
// flush forgets every translation.
module asc_tlb (
    input  logic        clk,
    input  logic        rst,
    input  logic        flush,
    input  logic [18:0] vpn,
    output logic        hit,
    output logic [19:0] pfn,
    output logic        writable,
    output logic        user,
    input  logic        load,
    input  logic [19:0] load_pfn,
    input  logic        load_writable,
    input  logic        load_user
);
    localparam int ENTRIES = 8;

    logic [ENTRIES-1:0] valid_q;
    logic [18:0]        vpn_q      [0:ENTRIES-1];
    logic [19:0]        pfn_q      [0:ENTRIES-1];
    logic [ENTRIES-1:0] writable_q;
    logic [ENTRIES-1:0] user_q;
    logic [2:0]         next_q;

    logic [ENTRIES-1:0] match;
    logic [2:0]         match_index;
    logic [2:0]         load_index;

    always_comb begin
        match_index = 3'd0;
        for (int i = 0; i < ENTRIES; i++) begin
            match[i] = valid_q[i] && (vpn_q[i] == vpn);
            if (match[i]) begin
                match_index = i[2:0];
            end
        end

        hit      = |match;
        pfn      = pfn_q[match_index];
        writable = writable_q[match_index];
        user     = user_q[match_index];

        load_index = hit ? match_index : next_q;
    end

    // The translations themselves need no reset: an entry counts only
    // while its bit of valid_q is set.
    always_ff @(posedge clk) begin
        if (load) begin
            vpn_q[load_index]      <= vpn;
            pfn_q[load_index]      <= load_pfn;
            writable_q[load_index] <= load_writable;
            user_q[load_index]     <= load_user;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            valid_q <= '0;
            next_q  <= 3'd0;
        end else if (load) begin
            valid_q[load_index] <= 1'b1;
            if (!hit) begin
                next_q <= next_q + 3'd1;
            end
        end
    end
endmodule
