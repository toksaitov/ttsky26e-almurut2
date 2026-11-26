// The CPU of Almurut II.
//
// The rules of the machine are in the comments of asc2-emulated/asc.h:
// the instruction word, the registers, the traps, and the translation of
// addresses. This file follows them and does not repeat them.
// asc2-kb/cpu-design.md tells why the CPU is built this way.
//
// One instruction is done before the next one starts, in several clocks:
//
//   BOUNDARY  between two instructions: an interrupt is taken here, a
//             halted CPU waits here, and stop holds the CPU here
//   FETCH     starts the read of the instruction at ip
//   DECODE    checks the instruction; a_q takes the first operand
//   READ_B    b_q takes the second operand
//   EXEC      the first step of the instruction, for most the only one
//   WRITE     the destination register and the flags
//   RETIRE    ip moves to the next instruction
//
// Every access of memory goes through three states, which the fetch and
// the accesses of data share:
//
//   XLATE      checks the address and looks for its translation
//   BUS_START  hands a request to the bus unit
//   BUS_WAIT   waits for the answer
//
// The registers of the datapath:
//
//   ir_q    the instruction
//   a_q     the first operand: register A or the immediate value
//   b_q     the second operand: the value of the destination register
//   alu_q   the result of the ALU: a value on its way to a register, or
//           the address of an access of data
//
// The ALU has the one adder of the CPU. It does the arithmetic of the
// instructions, the addresses of data, the targets of jumps, and ip + 4.
// A shift moves b_q by one bit in a clock, mul adds and shifts for 32
// clocks, and popcnt counts one bit in a clock: an access of memory takes
// hundreds of clocks on the bus, so a few clocks more inside the chip
// cost nothing, and a fast shifter or multiplier would cost area.
//
// The array of the dot products (asc_dot.sv) multiplies for dot4, dotv,
// dotm, and learn. Its registers are not in the register file: the array
// keeps the weights and the inputs next to the cells that use them.
//
// A register of the program changes in the WRITE states only, and from
// two places only: alu_q, or the word that the bus unit has read. An
// instruction is through with memory before it writes, so an exception
// finds every register as it was, and the instruction can run again.
//
// The control block below decides, for the state and the instruction,
// what the datapath does in this clock. The blocks after it do it.
// The lines of the instruction cache and the rows of the array of the dot
// products (CPU_IC_LINES and CPU_DOT_ROWS of asc.h); a layout run may try
// other numbers
`ifndef ASC_IC_LINES
`define ASC_IC_LINES 4
`endif
`ifndef ASC_DOT_ROWS
`define ASC_DOT_ROWS 3
`endif

module asc_cpu #(
    parameter int IC_LINES = `ASC_IC_LINES,
    parameter int DOT_ROWS = `ASC_DOT_ROWS
) (
    input  logic         clk,
    input  logic         rst,
    // The bus unit (asc_bus.sv): the CPU holds bus_start and the request
    // until bus_idle goes low, and reads the answer once bus_idle is high
    // again
    output logic         bus_start,
    input  logic         bus_idle,
    output logic [7:0]   bus_hdr,
    output logic [31:0]  bus_addr,
    output logic [31:0]  bus_wdata,
    input  logic [2:0]   bus_status,
    input  logic [31:0]  bus_rdata,
    // The interrupt controller (asc_pic.sv)
    input  logic         irq,
    input  logic [7:0]   irq_vec,
    output logic         irq_ack,
    // The ports of the devices: io_rdata follows io_port, and io_read
    // tells a device that the CPU has taken the byte
    output logic [7:0]   io_port,
    output logic         io_read,
    output logic         io_write,
    output logic [7:0]   io_wdata,
    input  logic [7:0]   io_rdata,
    // While stop is high the CPU waits between two instructions
    input  logic         stop,
    // A clock with cache_flush high empties the instruction cache: the
    // RP2040 has changed memory, or wants to see every fetch again
    input  logic         cache_flush,
    output logic         boundary,
    output logic         retired,
    // For the debug port: double fault, halted, the state, the bits 3 to
    // 0 of cr0, flags, cr5, the instruction, and ip
    output logic [107:0] dbg,
    // For the debug port too: cr4, cr3, cr2, and cr1 as words, above the
    // twelve words of the register file (asc_regs.sv gives their order)
    output logic [511:0] dbg_regs,
    // The kernel has locked the debug port (cr8)
    output logic         dbg_locked,
    // For the debug port as well: the bits A and C of cr0, which are
    // younger than the order of the bits above
    output logic [1:0]   dbg_cr0_high
);
    // Opcodes without bit 7, which selects the immediate form
    localparam logic [6:0] OP_HLT  = 7'h00;
    localparam logic [6:0] OP_NOP  = 7'h01;
    localparam logic [6:0] OP_CLI  = 7'h02;
    localparam logic [6:0] OP_STI  = 7'h03;
    localparam logic [6:0] OP_IRET = 7'h04;
    localparam logic [6:0] OP_INT  = 7'h05;
    localparam logic [6:0] OP_INB  = 7'h06;
    localparam logic [6:0] OP_OUTB = 7'h07;
    localparam logic [6:0] OP_MFC  = 7'h08;
    localparam logic [6:0] OP_MTC  = 7'h09;
    localparam logic [6:0] OP_MOV  = 7'h10;
    localparam logic [6:0] OP_LIH  = 7'h11;
    localparam logic [6:0] OP_PUSH = 7'h12;
    localparam logic [6:0] OP_POP  = 7'h13;
    localparam logic [6:0] OP_SR   = 7'h14;
    localparam logic [6:0] OP_SRH  = 7'h15;
    localparam logic [6:0] OP_SRB  = 7'h16;
    localparam logic [6:0] OP_LR   = 7'h18;
    localparam logic [6:0] OP_LRH  = 7'h19;
    localparam logic [6:0] OP_LRB  = 7'h1a;
    localparam logic [6:0] OP_LRHU = 7'h1d;
    localparam logic [6:0] OP_LRBU = 7'h1e;
    localparam logic [6:0] OP_ADD  = 7'h20;
    localparam logic [6:0] OP_ADC  = 7'h21;
    localparam logic [6:0] OP_SUB  = 7'h22;
    localparam logic [6:0] OP_SBB  = 7'h23;
    localparam logic [6:0] OP_CMP  = 7'h24;
    localparam logic [6:0] OP_AND  = 7'h25;
    localparam logic [6:0] OP_TEST = 7'h26;
    localparam logic [6:0] OP_OR   = 7'h27;
    localparam logic [6:0] OP_XOR  = 7'h28;
    localparam logic [6:0] OP_NOT  = 7'h29;
    localparam logic [6:0] OP_SHL  = 7'h2a;
    localparam logic [6:0] OP_SHR  = 7'h2b;
    localparam logic [6:0] OP_SAR  = 7'h2c;
    localparam logic [6:0] OP_MUL  = 7'h2d;
    localparam logic [6:0] OP_DOT4 = 7'h2e;
    localparam logic [6:0] OP_POPCNT = 7'h2f;
    localparam logic [6:0] OP_JMP  = 7'h30;
    localparam logic [6:0] OP_CALL = 7'h31;
    localparam logic [6:0] OP_RET  = 7'h32;
    localparam logic [6:0] OP_MFA   = 7'h60;
    localparam logic [6:0] OP_MTA   = 7'h61;
    localparam logic [6:0] OP_DOTV  = 7'h62;
    localparam logic [6:0] OP_DOTM  = 7'h63;
    localparam logic [6:0] OP_LEARN = 7'h64;
    localparam logic [6:0] OP_XSH   = 7'h65;
    localparam logic [6:0] OP_SSAT  = 7'h66;
    localparam logic [6:0] OP_USAT  = 7'h67;

    // The conditional jumps are the opcodes 0x40 to 0x49, and the
    // conditional sets 0x50 to 0x59: the low 4 bits select the condition
    localparam logic [2:0] OP_GROUP_JCC = 3'h4;

    // Numbers of registers in an instruction, and the words of the
    // register file that hold the two stack pointers
    localparam logic [3:0] REG_SP    = 4'd9;
    localparam logic [3:0] REG_LR    = 4'd10;
    localparam logic [3:0] REG_IP    = 4'd11;
    localparam logic [3:0] REG_FLAGS = 4'd12;
    localparam logic [3:0] WORD_USP  = 4'd11;

    // Bits of flags
    localparam int FLAG_C = 0;
    localparam int FLAG_Z = 1;
    localparam int FLAG_S = 2;
    localparam int FLAG_O = 3;
    localparam int FLAG_I = 4;
    localparam int FLAG_U = 5;

    // Bits of cr0
    localparam int CR0_P = 0;
    localparam int CR0_S = 1;
    localparam int CR0_F = 2;
    localparam int CR0_T = 3;
    localparam int CR0_C = 4;
    localparam int CR0_A = 5;

    // The value that locks the debug port when it is written to cr8: the
    // letters "LOCK"
    localparam logic [31:0] DBG_LOCK_KEY = 32'h4c4f_434b;

    // Bits of a page table entry
    localparam int PTE_P = 0;
    localparam int PTE_W = 1;
    localparam int PTE_U = 2;

    // Vectors of the exceptions
    localparam logic [7:0] VEC_INVALID    = 8'd0;
    localparam logic [7:0] VEC_PRIVILEGED = 8'd1;
    localparam logic [7:0] VEC_MISALIGNED = 8'd2;
    localparam logic [7:0] VEC_PAGE_FAULT = 8'd3;
    localparam logic [7:0] VEC_TLB_MISS   = 8'd4;
    localparam logic [7:0] VEC_BUS_ERROR  = 8'd5;
    localparam logic [7:0] VEC_INT        = 8'd6;

    localparam logic [31:0] RESET_IP    = 32'h8080_0000;
    localparam logic [5:0]  RESET_FLAGS = 6'b000010;  // Z alone: kernel mode, interrupts off
    localparam logic [5:0]  RESET_CR0   = 6'b000100;  // F alone: no paging, every fetch carries its address, no cache

    // The header of a request of the CPU itself for a word of a page
    // table or of the vector table: a read of 4 bytes in kernel mode
    localparam logic [7:0] HDR_OWN_READ = 8'b0010_0100;

    // The size of an access as the header of a request tells it
    localparam logic [1:0] SIZE_1 = 2'b00;
    localparam logic [1:0] SIZE_2 = 2'b01;
    localparam logic [1:0] SIZE_4 = 2'b10;

    // The operations of the ALU (asc_alu.sv)
    localparam logic [2:0] ALU_ADD = 3'd0;
    localparam logic [2:0] ALU_SUB = 3'd1;
    localparam logic [2:0] ALU_AND = 3'd2;
    localparam logic [2:0] ALU_OR  = 3'd3;
    localparam logic [2:0] ALU_XOR = 3'd4;
    localparam logic [2:0] ALU_LIH = 3'd5;

    typedef enum logic [4:0] {
        S_BOUNDARY,
        S_FETCH,
        S_XLATE,
        S_BUS_START,
        S_BUS_WAIT,
        S_DECODE,
        S_READ_B,
        S_EXEC,
        S_SHIFT,       // one bit of a shift
        S_SHIFT_END,   // alu_q takes the shifted value
        S_MUL,         // one bit of a multiplication
        S_DOT_MUL,     // the array: the cells multiply
        S_DOT_SUM,     // the array: the sums go down the rows
        S_DOT_ADD,     // the array: the sum of a row is added to its register
        S_WRITE_SP,    // pop: the stack pointer
        S_WRITE_LR,    // call: the return address
        S_WRITE_CTRL,  // mov to a control register
        S_WRITE,
        S_RETIRE,
        // The states below are newer than the debug port, which shows the
        // number of the state: the numbers above stay as they were
        S_POP,         // popcnt: one bit is counted
        S_DOT_READ,    // dotv, dotm: b_q takes the register that the sum of a row is for
        S_DOT_STORE    // learn: the weights take what the cells have worked out
    } state_t;

    // The first input of the ALU
    typedef enum logic [2:0] {
        X_B,     // b_q
        X_A,     // a_q
        X_IP,    // ip
        X_ACC2,  // alu_q times 2
        X_ACC,   // alu_q
        X_ZERO
    } x_sel_t;

    // The second input of the ALU
    typedef enum logic [2:0] {
        Y_A,       // a_q
        Y_A_IF_B,  // a_q if the top bit of b_q is set, zero otherwise
        Y_IMM,     // the immediate value
        Y_IMM4,    // the immediate value times 4
        Y_FOUR,
        Y_ONES,
        Y_MISC,    // a value that only one instruction uses (misc below)
        Y_ZERO
    } y_sel_t;

    typedef enum logic [2:0] {
        B_HOLD,
        B_REG,  // takes a register
        B_SHL,  // moves left by one bit
        B_SHR,  // moves right by one bit; a zero enters
        B_SAR   // moves right by one bit; the sign stays
    } b_sel_t;

    // The register that is read
    typedef enum logic [2:0] {
        RD_A,   // the one that the field ra names
        RD_B,   // the one that the field rb names
        RD_D,   // the one that the low bits of imm name (dot4)
        RD_ROW, // the one that takes the sum of a row of the array (dotv, dotm)
        RD_SP,
        RD_LR,
        RD_USP  // the stack pointer of user mode, in any mode
    } rd_sel_t;

    // The register that is written
    typedef enum logic [2:0] {
        WR_B,
        WR_D,
        WR_ROW,
        WR_SP,
        WR_LR,
        WR_IP,
        WR_USP
    } wr_sel_t;

    typedef enum logic [1:0] {
        ACC_FETCH,
        ACC_READ,
        ACC_WRITE
    } acc_t;

    // What the request on the bus is for
    typedef enum logic [1:0] {
        FOR_ACCESS,    // the access itself
        FOR_PTE_TOP,   // the entry of the top page table
        FOR_PTE_LEAF,  // the entry of the second page table
        FOR_VECTOR     // the address of a handler
    } bus_for_t;

    typedef enum logic [1:0] {
        TRAP_EXCPT,  // an exception: the instruction did not finish
        TRAP_INT,    // the instruction int, which finishes as it traps
        TRAP_IRQ     // an interrupt of a device
    } trap_kind_t;

    /* Registers */

    state_t      state_q;
    logic [31:0] ip_q;
    logic [5:0]  flags_q;
    logic [5:0]  cr0_q;
    logic [383:0] regs_dbg;
    logic [31:0] cr1_q;
    logic [31:0] cr2_q;
    logic [31:12] cr3_q;
    logic [5:0]  cr4_q;
    logic [26:0] cr5_q;
    logic        dbg_lock_q;    // cr8
    logic        halted_q;
    logic        double_fault_q;
    logic        fetch_run_q;   // the next fetch may ask for "the next word"
    logic        ip_set_q;      // the instruction has set ip itself, or keeps it

    logic [31:0] ir_q;
    logic [31:0] a_q;
    logic [31:0] b_q;
    logic [31:0] alu_q;
    logic        c_q;           // carry and overflow of the operation, on their way to flags
    logic        o_q;
    logic [4:0]  cnt_q;         // steps left of a shift, of mul, of popcnt, or of the array
    acc_t        acc_q;
    bus_for_t    bus_for_q;
    trap_kind_t  trap_kind_q;
    logic [19:0] walk_pfn_q;    // from the top entry: the page of the second table
    logic        walk_w_q;      // and the two permissions
    logic        walk_u_q;

    /* The instruction */

    logic [6:0]  op;
    logic        imm_form;
    logic [3:0]  rb;
    logic [3:0]  ra;
    logic [15:0] imm;
    logic [31:0] simm;
    logic        dec_valid;
    logic        dec_privileged;
    logic        dec_array;
    logic        cond;
    logic        flag_c;
    logic        flag_z;
    logic        flag_s;
    logic        flag_o;

    /* Control */

    state_t      state_d;
    bus_for_t    bus_for_d;
    rd_sel_t     rd_sel;
    logic        a_we;
    b_sel_t      b_sel;
    x_sel_t      alu_x_sel;
    y_sel_t      alu_y_sel;
    logic [2:0]  alu_op;
    logic        alu_carry_in;
    logic        alu_we;
    logic        co_we;
    logic        cnt_we;
    logic [4:0]  cnt_d;
    logic        wr_en;
    wr_sel_t     wr_sel;
    logic        wb_bus;
    logic        flags_we;
    logic        ir_we;
    logic        ic_take;     // the instruction comes from the cache
    logic        ic_hit;
    logic        ic_fill;
    logic        ic_flush;
    logic [31:0] ic_rdata;
    logic        vector_we;
    logic        vector_fail;
    logic        walk_we;
    logic        tlb_load;
    logic        tlb_flush;
    logic        dot_first;
    logic        dot_step;
    logic [3:1]  dot_take;
    logic        dot_own;     // the cells multiply their own weights and inputs
    logic        dot_learn;
    logic        dot_half;
    logic        dot_load;
    logic        dot_shift;
    logic        dot_store;
    logic [1:0]  dot_row;     // the row that the cells work on
    logic [3:0]  row_code;    // the register that takes the sum of that row

    logic        trap;
    trap_kind_t  trap_kind;
    logic [7:0]  trap_vec;
    logic [7:0]  trap_num;   // the number of an int
    logic        trap_mem;   // an exception of an access: cr2 takes the address
    logic        trap_p;     // the bits of the cause
    logic [1:0]  trap_lvl;
    logic        trap_m;
    logic [2:0]  trap_stat;

    /* Datapath */

    logic [3:0]  rd_code;
    logic [3:0]  regs_raddr;
    logic [31:0] regs_rdata;
    logic [31:0] reg_val;
    logic [3:0]  wr_code;
    logic        regs_we;
    logic [3:0]  regs_waddr;
    logic        wr_ip;
    logic        wr_flags;
    logic [31:0] wb_data;

    logic [31:0] alu_x;
    logic [31:0] alu_y;
    logic [31:0] alu_result;
    logic        alu_carry;
    logic        alu_overflow;
    logic [31:0] misc;
    logic [31:0] ctrl_val;
    logic [17:0] dot_sum;
    logic [31:0] dot_rdata;
    logic        sat_fits;
    logic [31:0] sat_val;

    /* Memory access */

    logic [31:0] va;
    logic [1:0]  size;
    logic        misaligned;
    logic        paged;
    logic        fetch_next;
    logic [18:0] tlb_vpn;
    logic        tlb_hit;
    logic [19:0] tlb_pfn;
    logic        tlb_writable;
    logic        tlb_user;
    logic [19:0] tlb_load_pfn;
    logic        tlb_load_writable;
    logic        tlb_load_user;
    logic        tlb_refused;
    logic        pte_refused;

    asc_decoder #(.DOT_ROWS(DOT_ROWS)) decoder (
        .inst       (ir_q),
        .valid      (dec_valid),
        .privileged (dec_privileged),
        .array      (dec_array)
    );

    asc_regs regs (
        .clk   (clk),
        .rst   (rst),
        .raddr (regs_raddr),
        .rdata (regs_rdata),
        .we    (regs_we),
        .waddr (regs_waddr),
        .wdata (wb_data),
        .dbg   (regs_dbg)
    );

    asc_alu alu (
        .op       (alu_op),
        .x        (alu_x),
        .y        (alu_y),
        .carry_in (alu_carry_in),
        .result   (alu_result),
        .carry    (alu_carry),
        .overflow (alu_overflow)
    );

    // mov to a register of the array names it in the field rb, and mov
    // from one in the field ra
    asc_dot #(.ROWS(DOT_ROWS)) dot (
        .clk     (clk),
        .first   (dot_first),
        .step    (dot_step),
        .take    (dot_take),
        .own     (dot_own),
        .learn   (dot_learn),
        .half    (dot_half),
        .bit_sel (cnt_q[2:0]),
        .a       (a_q),
        .b_top   ({b_q[31], b_q[23], b_q[15], b_q[7]}),
        .err     (b_q[{dot_row, cnt_q[2:0]}]),
        .row     (dot_row),
        .load    (dot_load),
        .shift   (dot_shift),
        .store   (dot_store),
        .code    ((op == OP_MTA) ? rb[2:0] : ra[2:0]),
        .wdata   (a_q),
        .rdata   (dot_rdata),
        .sum     (dot_sum)
    );

    // The cache is empty while cr0.C is clear. It empties whenever the mode
    // or a translation may change: at a trap, at iret, at a write to a
    // control register. A program that writes instructions and runs them
    // must pass one of these in between; any trap does.
    always_comb begin
        ic_fill  = ir_we && !ic_take && cr0_q[CR0_C];
        ic_flush = rst || !cr0_q[CR0_C] || cache_flush || trap ||
                   (state_q == S_WRITE_CTRL) || (state_q == S_EXEC && op == OP_IRET);
    end

    asc_icache #(.LINES(IC_LINES)) icache (
        .clk   (clk),
        .flush (ic_flush),
        .addr  (ip_q),
        .hit   (ic_hit),
        .rdata (ic_rdata),
        .fill  (ic_fill),
        .wdata (bus_rdata)
    );

    asc_tlb tlb (
        .clk           (clk),
        .rst           (rst),
        .flush         (tlb_flush),
        .vpn           (tlb_vpn),
        .hit           (tlb_hit),
        .pfn           (tlb_pfn),
        .writable      (tlb_writable),
        .user          (tlb_user),
        .load          (tlb_load),
        .load_pfn      (tlb_load_pfn),
        .load_writable (tlb_load_writable),
        .load_user     (tlb_load_user)
    );

    /* The fields of the instruction */

    always_comb begin
        op       = ir_q[6:0];
        imm_form = ir_q[7];
        rb       = ir_q[11:8];
        ra       = ir_q[15:12];
        imm      = ir_q[31:16];
        simm     = {{16{imm[15]}}, imm};

        flag_c = flags_q[FLAG_C];
        flag_z = flags_q[FLAG_Z];
        flag_s = flags_q[FLAG_S];
        flag_o = flags_q[FLAG_O];

        // The condition of a conditional jump or set
        case (op[3:0])
            4'd0:    cond = flag_z;                         // equal
            4'd1:    cond = !flag_z;                        // not equal
            4'd2:    cond = (flag_s != flag_o);             // less
            4'd3:    cond = (flag_s == flag_o);             // greater or equal
            4'd4:    cond = flag_z || (flag_s != flag_o);   // less or equal
            4'd5:    cond = !flag_z && (flag_s == flag_o);  // greater
            4'd6:    cond = flag_c;                         // below
            4'd7:    cond = !flag_c;                        // above or equal
            4'd8:    cond = flag_c || flag_z;               // below or equal
            4'd9:    cond = !flag_c && !flag_z;             // above
            default: cond = 1'b0;
        endcase
    end

    /* The address of an access and its checks */

    always_comb begin
        va = (acc_q == ACC_FETCH) ? ip_q : alu_q;

        if (acc_q == ACC_FETCH || op == OP_PUSH || op == OP_POP) begin
            size = SIZE_4;
        end else begin
            // sr, srh, srb, and the loads tell the size in their low 2 bits
            case (op[1:0])
                2'b00:   size = SIZE_4;
                2'b01:   size = SIZE_2;
                default: size = SIZE_1;
            endcase
        end

        misaligned = (size == SIZE_4 && va[1:0] != 2'b00) || (size == SIZE_2 && va[0]);

        // The upper half of the addresses is never translated
        paged = !va[31] && cr0_q[CR0_P];

        tlb_refused = (flags_q[FLAG_U] && !tlb_user) || (acc_q == ACC_WRITE && !tlb_writable);
        pte_refused = (flags_q[FLAG_U] && !bus_rdata[PTE_U]) || (acc_q == ACC_WRITE && !bus_rdata[PTE_W]);

        fetch_next = (acc_q == ACC_FETCH) && fetch_run_q && !cr0_q[CR0_F];

        // A write to cr7 loads a translation for the page of cr2
        if (state_q == S_WRITE_CTRL) begin
            tlb_vpn           = cr2_q[30:12];
            tlb_load_pfn      = alu_q[31:12];
            tlb_load_writable = alu_q[PTE_W];
            tlb_load_user     = alu_q[PTE_U];
        end else begin
            // An access needs the permission in both entries
            tlb_vpn           = va[30:12];
            tlb_load_pfn      = bus_rdata[31:12];
            tlb_load_writable = bus_rdata[PTE_W] && walk_w_q;
            tlb_load_user     = bus_rdata[PTE_U] && walk_u_q;
        end
    end

    /* The request to the bus unit */

    always_comb begin
        bus_wdata = a_q;

        case (bus_for_q)
            FOR_ACCESS: begin
                bus_hdr  = {acc_q == ACC_WRITE, fetch_next, size, acc_q == ACC_FETCH, !flags_q[FLAG_U], 2'b00};
                bus_addr = paged ? {tlb_pfn, va[11:0]} : {1'b0, va[30:0]};
            end
            FOR_PTE_TOP: begin
                bus_hdr  = HDR_OWN_READ;
                bus_addr = {cr3_q, va[31:22], 2'b00};
            end
            FOR_PTE_LEAF: begin
                bus_hdr  = HDR_OWN_READ;
                bus_addr = {walk_pfn_q, va[21:12], 2'b00};
            end
            default: begin
                bus_hdr  = HDR_OWN_READ;
                bus_addr = {22'd0, cr5_q[7:0], 2'b00};
            end
        endcase
    end

    /* Control */

    always_comb begin
        // Nothing happens unless the state says so
        state_d      = state_q;
        bus_for_d    = bus_for_q;
        rd_sel       = RD_A;
        a_we         = 1'b0;
        b_sel        = B_HOLD;
        alu_x_sel    = X_IP;
        alu_y_sel    = Y_ZERO;
        alu_op       = ALU_ADD;
        alu_carry_in = 1'b0;
        alu_we       = 1'b0;
        co_we        = 1'b0;
        cnt_we       = 1'b0;
        cnt_d        = cnt_q - 5'd1;
        wr_en        = 1'b0;
        wr_sel       = WR_B;
        wb_bus       = 1'b0;
        flags_we     = 1'b0;
        ir_we        = 1'b0;
        ic_take      = 1'b0;
        vector_we    = 1'b0;
        vector_fail  = 1'b0;
        walk_we      = 1'b0;
        tlb_load     = 1'b0;
        tlb_flush    = 1'b0;
        dot_first    = 1'b0;
        dot_step     = 1'b0;
        dot_take     = 3'b000;
        dot_half     = 1'b0;
        dot_load     = 1'b0;
        dot_shift    = 1'b0;
        dot_store    = 1'b0;
        bus_start    = 1'b0;
        io_read      = 1'b0;
        io_write     = 1'b0;
        irq_ack      = 1'b0;

        // A state that raises a trap leaves the ALU to the trap: the ALU
        // works out the address to return to, ip or ip + 4
        trap         = 1'b0;
        trap_kind    = TRAP_EXCPT;
        trap_vec     = 8'd0;
        trap_num     = 8'd0;
        trap_mem     = 1'b0;
        trap_p       = 1'b0;
        trap_lvl     = 2'd0;
        trap_m       = 1'b0;
        trap_stat    = 3'd0;

        case (state_q)
            S_BOUNDARY: begin
                // After a double fault only a reset helps
                if (!stop && !double_fault_q) begin
                    if (irq && flags_q[FLAG_I] && !cr0_q[CR0_T]) begin
                        // A halted CPU continues after its hlt
                        alu_y_sel = halted_q ? Y_FOUR : Y_ZERO;
                        trap      = 1'b1;
                        trap_kind = TRAP_IRQ;
                        trap_vec  = irq_vec;
                        irq_ack   = 1'b1;
                    end else if (!halted_q) begin
                        state_d = S_FETCH;
                    end
                end
            end

            S_FETCH: begin
                // A word that the cache holds needs neither a translation
                // nor the bus
                if (ic_hit) begin
                    ir_we   = 1'b1;
                    ic_take = 1'b1;
                    state_d = S_DECODE;
                end else begin
                    state_d = S_XLATE;
                end
            end

            // The checks of an address, in the order of asc.h
            S_XLATE: begin
                if (misaligned) begin
                    trap     = 1'b1;
                    trap_vec = VEC_MISALIGNED;
                    trap_mem = 1'b1;
                end else if (va[31]) begin
                    // The upper half is the lower half of physical memory
                    // as kernel mode sees it
                    if (flags_q[FLAG_U]) begin
                        trap     = 1'b1;
                        trap_vec = VEC_BUS_ERROR;
                        trap_mem = 1'b1;
                    end else begin
                        bus_for_d = FOR_ACCESS;
                        state_d   = S_BUS_START;
                    end
                end else if (!cr0_q[CR0_P]) begin
                    bus_for_d = FOR_ACCESS;
                    state_d   = S_BUS_START;
                end else if (tlb_hit) begin
                    if (tlb_refused) begin
                        trap     = 1'b1;
                        trap_vec = VEC_PAGE_FAULT;
                        trap_mem = 1'b1;
                        trap_p   = 1'b1;
                    end else begin
                        bus_for_d = FOR_ACCESS;
                        state_d   = S_BUS_START;
                    end
                end else if (cr0_q[CR0_S]) begin
                    // The kernel looks the translation up and loads it
                    trap     = 1'b1;
                    trap_vec = VEC_TLB_MISS;
                    trap_mem = 1'b1;
                end else if (cr3_q[31:23] != 9'd0) begin
                    // A page table lies in RAM, the first 8 MB of physical memory
                    trap     = 1'b1;
                    trap_vec = VEC_PAGE_FAULT;
                    trap_mem = 1'b1;
                    trap_lvl = 2'd1;
                    trap_m   = 1'b1;
                end else begin
                    // The CPU looks the translation up itself
                    bus_for_d = FOR_PTE_TOP;
                    state_d   = S_BUS_START;
                end
            end

            S_BUS_START: begin
                bus_start = 1'b1;
                if (!bus_idle) begin
                    state_d = S_BUS_WAIT;
                end
            end

            S_BUS_WAIT: begin
                if (bus_idle) begin
                    case (bus_for_q)
                        FOR_ACCESS: begin
                            if (bus_status != 3'd0) begin
                                trap      = 1'b1;
                                trap_vec  = VEC_BUS_ERROR;
                                trap_mem  = 1'b1;
                                trap_stat = bus_status;
                            end else if (acc_q == ACC_FETCH) begin
                                ir_we   = 1'b1;
                                state_d = S_DECODE;
                            end else if (op == OP_POP) begin
                                // The new stack pointer: b_q + 4
                                alu_x_sel = X_B;
                                alu_y_sel = Y_FOUR;
                                alu_we    = 1'b1;
                                state_d   = S_WRITE_SP;
                            end else if (acc_q == ACC_READ || op == OP_PUSH) begin
                                state_d = S_WRITE;
                            end else begin
                                state_d = S_RETIRE;
                            end
                        end

                        // The entry of the top table names the second table
                        FOR_PTE_TOP: begin
                            trap_vec = VEC_PAGE_FAULT;
                            trap_mem = 1'b1;
                            trap_lvl = 2'd1;
                            if (bus_status != 3'd0) begin
                                trap      = 1'b1;
                                trap_stat = bus_status;
                            end else if (!bus_rdata[PTE_P]) begin
                                trap = 1'b1;
                            end else if (pte_refused) begin
                                trap   = 1'b1;
                                trap_p = 1'b1;
                            end else if (bus_rdata[31:23] != 9'd0) begin
                                trap     = 1'b1;
                                trap_lvl = 2'd2;
                                trap_m   = 1'b1;
                            end else begin
                                walk_we   = 1'b1;
                                bus_for_d = FOR_PTE_LEAF;
                                state_d   = S_BUS_START;
                            end
                        end

                        // The entry of the second table names the page
                        FOR_PTE_LEAF: begin
                            trap_vec = VEC_PAGE_FAULT;
                            trap_mem = 1'b1;
                            trap_lvl = 2'd2;
                            if (bus_status != 3'd0) begin
                                trap      = 1'b1;
                                trap_stat = bus_status;
                            end else if (!bus_rdata[PTE_P]) begin
                                trap = 1'b1;
                            end else if (pte_refused) begin
                                trap   = 1'b1;
                                trap_p = 1'b1;
                            end else begin
                                // The access starts again and finds the translation
                                tlb_load = 1'b1;
                                state_d  = S_XLATE;
                            end
                        end

                        // The address of the handler of a trap
                        default: begin
                            if (bus_status != 3'd0) begin
                                vector_fail = 1'b1;
                                state_d     = S_BOUNDARY;
                            end else begin
                                vector_we = 1'b1;
                                case (trap_kind_q)
                                    TRAP_INT: state_d = S_RETIRE;
                                    TRAP_IRQ: state_d = S_FETCH;
                                    default:  state_d = S_BOUNDARY;
                                endcase
                            end
                        end
                    endcase
                end
            end

            S_DECODE: begin
                if (!dec_valid) begin
                    trap     = 1'b1;
                    trap_vec = VEC_INVALID;
                end else if ((dec_privileged || (dec_array && !cr0_q[CR0_A])) && flags_q[FLAG_U]) begin
                    // The registers of the array are the kernel's until it sets cr0.A
                    trap     = 1'b1;
                    trap_vec = VEC_PRIVILEGED;
                end else begin
                    rd_sel  = RD_A;
                    a_we    = 1'b1;
                    state_d = S_READ_B;
                end
            end

            S_READ_B: begin
                if (op == OP_PUSH || op == OP_POP) begin
                    rd_sel = RD_SP;
                end else if (op == OP_RET) begin
                    rd_sel = RD_LR;
                end else if (op == OP_POPCNT || op == OP_LEARN) begin
                    // b_q, which can shift, takes register A: the bits to
                    // count, or the errors of the rows
                    rd_sel = RD_A;
                end else begin
                    rd_sel = RD_B;
                end
                b_sel   = B_REG;
                state_d = S_EXEC;
            end

            S_EXEC: begin
                case (op)
                    // The block of the small registers below does these four
                    OP_HLT, OP_NOP, OP_CLI, OP_STI: begin
                        state_d = S_RETIRE;
                    end

                    // ip takes cr1; the block below gives flags and cr0 their part
                    OP_IRET: begin
                        alu_x_sel = X_ZERO;
                        alu_y_sel = Y_MISC;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    // The handler returns to the instruction after the int
                    OP_INT: begin
                        alu_y_sel = Y_FOUR;
                        trap      = 1'b1;
                        trap_kind = TRAP_INT;
                        trap_vec  = VEC_INT;
                        trap_num  = imm[7:0];
                    end

                    OP_INB: begin
                        io_read   = 1'b1;
                        alu_x_sel = X_ZERO;
                        alu_y_sel = Y_MISC;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    OP_OUTB: begin
                        io_write = 1'b1;
                        state_d  = S_RETIRE;
                    end

                    // cr6 is a word of the register file
                    OP_MFC: begin
                        rd_sel    = RD_USP;
                        alu_x_sel = X_ZERO;
                        alu_y_sel = Y_MISC;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    OP_MTC: begin
                        alu_x_sel = X_ZERO;
                        alu_y_sel = Y_A;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE_CTRL;
                    end

                    OP_MOV: begin
                        alu_x_sel = X_ZERO;
                        alu_y_sel = Y_A;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    OP_LIH: begin
                        alu_x_sel = X_B;
                        alu_y_sel = Y_IMM;
                        alu_op    = ALU_LIH;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    // The address of the word below the top of the stack
                    OP_PUSH: begin
                        alu_x_sel = X_B;
                        alu_y_sel = Y_FOUR;
                        alu_op    = ALU_SUB;
                        alu_we    = 1'b1;
                        state_d   = S_XLATE;
                    end

                    OP_POP: begin
                        alu_x_sel = X_B;
                        alu_y_sel = Y_ZERO;
                        alu_we    = 1'b1;
                        state_d   = S_XLATE;
                    end

                    // The address is register B plus the immediate value
                    OP_SR, OP_SRH, OP_SRB: begin
                        alu_x_sel = X_B;
                        alu_y_sel = Y_IMM;
                        alu_we    = 1'b1;
                        state_d   = S_XLATE;
                    end

                    // The address is register A plus the immediate value
                    OP_LR, OP_LRH, OP_LRB, OP_LRHU, OP_LRBU: begin
                        alu_x_sel = X_A;
                        alu_y_sel = Y_IMM;
                        alu_we    = 1'b1;
                        state_d   = S_XLATE;
                    end

                    OP_ADD, OP_ADC, OP_SUB, OP_SBB, OP_CMP, OP_AND, OP_TEST, OP_OR, OP_XOR: begin
                        alu_x_sel = X_B;
                        alu_y_sel = Y_A;
                        alu_we    = 1'b1;
                        co_we     = 1'b1;
                        state_d   = S_WRITE;
                        case (op)
                            OP_ADC: begin
                                alu_carry_in = flag_c;
                            end
                            OP_SUB, OP_CMP: begin
                                alu_op = ALU_SUB;
                            end
                            OP_SBB: begin
                                alu_op       = ALU_SUB;
                                alu_carry_in = flag_c;
                            end
                            OP_AND, OP_TEST: begin
                                alu_op = ALU_AND;
                            end
                            OP_OR: begin
                                alu_op = ALU_OR;
                            end
                            OP_XOR: begin
                                alu_op = ALU_XOR;
                            end
                            default: begin
                            end
                        endcase
                    end

                    OP_NOT: begin
                        alu_x_sel = X_B;
                        alu_y_sel = Y_ONES;
                        alu_op    = ALU_XOR;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    // A shift by zero bits writes nothing
                    OP_SHL, OP_SHR, OP_SAR: begin
                        cnt_we  = 1'b1;
                        cnt_d   = a_q[4:0];
                        state_d = (a_q[4:0] == 5'd0) ? S_RETIRE : S_SHIFT;
                    end

                    // The first of 32 steps: the top bit of b_q
                    OP_MUL: begin
                        alu_x_sel = X_ZERO;
                        alu_y_sel = Y_A_IF_B;
                        alu_we    = 1'b1;
                        b_sel     = B_SHL;
                        cnt_we    = 1'b1;
                        cnt_d     = 5'd31;
                        state_d   = S_MUL;
                    end

                    // The first of 32 steps: the top bit of b_q
                    OP_POPCNT: begin
                        alu_x_sel    = X_ZERO;
                        alu_carry_in = b_q[31];
                        alu_we       = 1'b1;
                        b_sel        = B_SHL;
                        cnt_we       = 1'b1;
                        cnt_d        = 5'd31;
                        state_d      = S_POP;
                    end

                    // Eight steps, one for each bit of a factor, from bit 7
                    // down, for the first row. The two top bits of cnt_q
                    // name the row that the cells work on.
                    OP_DOT4, OP_DOTV, OP_DOTM, OP_LEARN: begin
                        cnt_we  = 1'b1;
                        cnt_d   = 5'd7;
                        state_d = S_DOT_MUL;
                    end

                    // A word of the array, or b_q held in the range of a byte
                    OP_MFA, OP_SSAT, OP_USAT: begin
                        alu_x_sel = X_ZERO;
                        alu_y_sel = Y_MISC;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    OP_MTA: begin
                        dot_load = 1'b1;
                        state_d  = S_RETIRE;
                    end

                    OP_XSH: begin
                        dot_shift = 1'b1;
                        state_d   = S_RETIRE;
                    end

                    // The target: a register or, in the immediate form, a
                    // number of instructions from this one
                    OP_JMP: begin
                        alu_x_sel = imm_form ? X_IP : X_ZERO;
                        alu_y_sel = imm_form ? Y_IMM4 : Y_A;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    // The return address first
                    OP_CALL: begin
                        alu_x_sel = X_IP;
                        alu_y_sel = Y_FOUR;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE_LR;
                    end

                    OP_RET: begin
                        alu_x_sel = X_B;
                        alu_y_sel = Y_ZERO;
                        alu_we    = 1'b1;
                        state_d   = S_WRITE;
                    end

                    default: begin
                        if (op[6:4] == OP_GROUP_JCC) begin
                            // A conditional jump
                            alu_x_sel = imm_form ? X_IP : X_ZERO;
                            alu_y_sel = imm_form ? Y_IMM4 : Y_A;
                            alu_we    = 1'b1;
                            state_d   = cond ? S_WRITE : S_RETIRE;
                        end else begin
                            // A conditional set: 1 or 0
                            alu_x_sel = X_ZERO;
                            alu_y_sel = Y_MISC;
                            alu_we    = 1'b1;
                            state_d   = S_WRITE;
                        end
                    end
                endcase
            end

            S_SHIFT: begin
                case (op)
                    OP_SHL:  b_sel = B_SHL;
                    OP_SHR:  b_sel = B_SHR;
                    default: b_sel = B_SAR;
                endcase
                cnt_we = 1'b1;
                if (cnt_q == 5'd1) begin
                    state_d = S_SHIFT_END;
                end
            end

            S_SHIFT_END: begin
                alu_x_sel = X_B;
                alu_y_sel = Y_ZERO;
                alu_we    = 1'b1;
                state_d   = S_WRITE;
            end

            // The sum so far times 2, plus a_q if the next bit of b_q is set
            S_MUL: begin
                alu_x_sel = X_ACC2;
                alu_y_sel = Y_A_IF_B;
                alu_we    = 1'b1;
                b_sel     = B_SHL;
                cnt_we    = 1'b1;
                if (cnt_q == 5'd1) begin
                    state_d = S_WRITE;
                end
            end

            // The count so far, plus 1 if the next bit of b_q is set
            S_POP: begin
                alu_x_sel    = X_ACC;
                alu_carry_in = b_q[31];
                alu_we       = 1'b1;
                b_sel        = B_SHL;
                cnt_we       = 1'b1;
                if (cnt_q == 5'd1) begin
                    state_d = S_WRITE;
                end
            end

            // The cells multiply for the row that the two top bits of cnt_q
            // name; the three low bits count the steps. For dot4 b_q moves
            // left by one bit in each step, and the cells find the bits of
            // its second factor at the tops of its bytes. For learn b_q
            // holds the errors of all rows and stays as it is.
            S_DOT_MUL: begin
                dot_step  = 1'b1;
                dot_first = (cnt_q[2:0] == 3'd7);
                dot_half  = (op == OP_LEARN) && (cnt_q[2:0] == 3'd6);
                b_sel     = (op == OP_DOT4) ? B_SHL : B_HOLD;
                cnt_we    = 1'b1;
                if (cnt_q[2:0] == 3'd0) begin
                    cnt_d   = {cnt_q[4:3], 3'd3};
                    state_d = (op == OP_LEARN) ? S_DOT_STORE : S_DOT_SUM;
                end
            end

            // In the last clock b_q takes the destination register of dot4
            S_DOT_SUM: begin
                dot_take[1] = (cnt_q[2:0] == 3'd3);
                dot_take[2] = (cnt_q[2:0] == 3'd2);
                dot_take[3] = (cnt_q[2:0] == 3'd1);
                cnt_we      = 1'b1;
                if (cnt_q[2:0] == 3'd1) begin
                    if (op == OP_DOT4) begin
                        rd_sel  = RD_D;
                        b_sel   = B_REG;
                        state_d = S_DOT_ADD;
                    end else begin
                        state_d = S_DOT_READ;
                    end
                end
            end

            S_DOT_READ: begin
                rd_sel  = RD_ROW;
                b_sel   = B_REG;
                state_d = S_DOT_ADD;
            end

            S_DOT_ADD: begin
                alu_x_sel = X_B;
                alu_y_sel = Y_MISC;
                alu_we    = 1'b1;
                state_d   = S_WRITE;
            end

            // The weights of the row at work take what the cells have worked
            // out, and the cells go on with the next row
            S_DOT_STORE: begin
                dot_store = 1'b1;
                if (dot_row != 2'(DOT_ROWS - 1)) begin
                    cnt_we  = 1'b1;
                    cnt_d   = {dot_row + 2'd1, 3'd7};
                    state_d = S_DOT_MUL;
                end else begin
                    state_d = S_RETIRE;
                end
            end

            S_WRITE_SP: begin
                wr_en   = 1'b1;
                wr_sel  = WR_SP;
                state_d = S_WRITE;
            end

            // lr takes the return address, and alu_q the target
            S_WRITE_LR: begin
                wr_en     = 1'b1;
                wr_sel    = WR_LR;
                alu_x_sel = imm_form ? X_IP : X_ZERO;
                alu_y_sel = imm_form ? Y_IMM4 : Y_A;
                alu_we    = 1'b1;
                state_d   = S_WRITE;
            end

            // The block of the small registers below writes cr0 to cr5 and cr8
            S_WRITE_CTRL: begin
                case (rb)
                    4'd0: begin
                        // The TLB holds translations made under the old settings
                        tlb_flush = (cr0_q[CR0_P] != alu_q[CR0_P]) || (cr0_q[CR0_S] != alu_q[CR0_S]);
                    end
                    4'd3: begin
                        tlb_flush = 1'b1;
                    end
                    4'd6: begin
                        wr_en  = 1'b1;
                        wr_sel = WR_USP;
                    end
                    4'd7: begin
                        tlb_load = !cr2_q[31] && alu_q[PTE_P];
                    end
                    default: begin
                    end
                endcase
                state_d = S_RETIRE;
            end

            S_WRITE: begin
                wr_en   = 1'b1;
                state_d = S_RETIRE;
                case (op)
                    OP_IRET, OP_JMP, OP_CALL, OP_RET: begin
                        wr_sel = WR_IP;
                    end
                    OP_PUSH: begin
                        wr_sel = WR_SP;
                    end
                    OP_POP, OP_LR, OP_LRH, OP_LRB, OP_LRHU, OP_LRBU: begin
                        wb_bus = 1'b1;
                    end
                    OP_DOT4: begin
                        wr_sel = WR_D;
                    end
                    // The sum of one row, and the cells go on with the next
                    // row; dotv sets the flags by its last sum
                    OP_DOTV, OP_DOTM: begin
                        wr_sel = WR_ROW;
                        if (dot_row != 2'(DOT_ROWS - 1)) begin
                            cnt_we  = 1'b1;
                            cnt_d   = {dot_row + 2'd1, 3'd7};
                            state_d = S_DOT_MUL;
                        end else if (op == OP_DOTV) begin
                            flags_we = 1'b1;
                        end
                    end
                    OP_CMP, OP_TEST: begin
                        wr_en    = 1'b0;
                        flags_we = 1'b1;
                    end
                    OP_ADD, OP_ADC, OP_SUB, OP_SBB, OP_AND, OP_OR, OP_XOR, OP_SHL, OP_SHR, OP_SAR: begin
                        flags_we = 1'b1;
                    end
                    default: begin
                        if (op[6:4] == OP_GROUP_JCC) begin
                            wr_sel = WR_IP;
                        end
                    end
                endcase
            end

            // ip + 4, unless the instruction has set ip itself
            S_RETIRE: begin
                alu_x_sel = X_IP;
                alu_y_sel = Y_FOUR;
                state_d   = S_BOUNDARY;
            end

            default: begin
                state_d = S_BOUNDARY;
            end
        endcase
    end

    /* Datapath: the register file */

    always_comb begin
        dot_own   = (op == OP_DOTV || op == OP_DOTM || op == OP_LEARN);
        dot_learn = (op == OP_LEARN);

        // The two top bits of cnt_q name the row that the cells work on.
        // dot4 has one sum. dotv adds the sum of every row to one register,
        // and dotm the sum of row r to register B + r.
        dot_row  = cnt_q[4:3];
        row_code = (op == OP_DOTM) ? rb + {2'b00, dot_row} : rb;

        case (rd_sel)
            RD_A:    rd_code = ra;
            RD_B:    rd_code = rb;
            RD_D:    rd_code = imm[3:0];
            RD_ROW:  rd_code = row_code;
            RD_LR:   rd_code = REG_LR;
            default: rd_code = REG_SP;
        endcase

        // Every mode has its own stack pointer
        if (rd_code == REG_SP && (flags_q[FLAG_U] || rd_sel == RD_USP)) begin
            regs_raddr = WORD_USP;
        end else begin
            regs_raddr = rd_code;
        end

        case (rd_code)
            REG_IP:    reg_val = ip_q;
            REG_FLAGS: reg_val = {26'd0, flags_q};
            default:   reg_val = regs_rdata;
        endcase

        case (wr_sel)
            WR_B:    wr_code = rb;
            WR_D:    wr_code = imm[3:0];
            WR_ROW:  wr_code = row_code;
            WR_LR:   wr_code = REG_LR;
            WR_IP:   wr_code = REG_IP;
            default: wr_code = REG_SP;
        endcase

        if (wr_code == REG_SP && (flags_q[FLAG_U] || wr_sel == WR_USP)) begin
            regs_waddr = WORD_USP;
        end else begin
            regs_waddr = wr_code;
        end

        regs_we  = wr_en && (wr_code < REG_IP);
        wr_ip    = wr_en && (wr_code == REG_IP);
        wr_flags = wr_en && (wr_code == REG_FLAGS);

        // The bus unit fills the bytes above the size of a read with zeros
        if (!wb_bus) begin
            wb_data = alu_q;
        end else if (op == OP_LRH) begin
            wb_data = {{16{bus_rdata[15]}}, bus_rdata[15:0]};
        end else if (op == OP_LRB) begin
            wb_data = {{24{bus_rdata[7]}}, bus_rdata[7:0]};
        end else begin
            wb_data = bus_rdata;
        end
    end

    /* Datapath: the inputs of the ALU */

    always_comb begin
        // A control register for mov and for iret, which reads cr1
        case ((op == OP_IRET) ? 4'd1 : ra)
            4'd0:    ctrl_val = {26'd0, cr0_q};
            4'd1:    ctrl_val = cr1_q;
            4'd2:    ctrl_val = cr2_q;
            4'd3:    ctrl_val = {cr3_q, 12'd0};
            4'd4:    ctrl_val = {26'd0, cr4_q};
            4'd5:    ctrl_val = {5'd0, cr5_q};
            4'd6:    ctrl_val = regs_rdata;
            4'd8:    ctrl_val = {31'd0, dbg_lock_q};
            default: ctrl_val = 32'd0;
        endcase

        // b_q held in the range of a signed byte (ssat) or between 0 and
        // 127 (usat): a value that fits has nothing but its sign above
        // bit 6, and usat takes no negative value
        sat_fits = (b_q[31:7] == 25'd0) || (op == OP_SSAT && b_q[31:7] == 25'h1ff_ffff);
        if (sat_fits) begin
            sat_val = b_q;
        end else if (b_q[31]) begin
            sat_val = (op == OP_SSAT) ? 32'hffff_ff80 : 32'd0;
        end else begin
            sat_val = 32'h0000_007f;
        end

        case (op)
            OP_INB:                    misc = {24'd0, io_rdata};
            OP_MFC, OP_IRET:           misc = ctrl_val;
            OP_DOT4, OP_DOTV, OP_DOTM: misc = {{14{dot_sum[17]}}, dot_sum};
            OP_MFA:                    misc = dot_rdata;
            OP_SSAT, OP_USAT:          misc = sat_val;
            default:                   misc = {31'd0, cond};
        endcase

        case (alu_x_sel)
            X_B:     alu_x = b_q;
            X_A:     alu_x = a_q;
            X_IP:    alu_x = ip_q;
            X_ACC2:  alu_x = {alu_q[30:0], 1'b0};
            X_ACC:   alu_x = alu_q;
            default: alu_x = 32'd0;
        endcase

        case (alu_y_sel)
            Y_A:      alu_y = a_q;
            Y_A_IF_B: alu_y = b_q[31] ? a_q : 32'd0;
            Y_IMM:    alu_y = simm;
            Y_IMM4:   alu_y = {simm[29:0], 2'b00};
            Y_FOUR:   alu_y = 32'd4;
            Y_ONES:   alu_y = 32'hffff_ffff;
            Y_MISC:   alu_y = misc;
            default:  alu_y = 32'd0;
        endcase

        // inb takes the number of the port from register A, outb from register B
        io_port  = (op == OP_INB) ? a_q[7:0] : b_q[7:0];
        io_wdata = a_q[7:0];
    end

    /* Datapath: the registers that a program cannot see. They need no
       reset: each one is written before it is read. */

    always_ff @(posedge clk) begin
        if (ir_we) begin
            ir_q <= ic_take ? ic_rdata : bus_rdata;
        end
        if (a_we) begin
            a_q <= imm_form ? simm : reg_val;
        end
        case (b_sel)
            B_REG:   b_q <= reg_val;
            B_SHL:   b_q <= {b_q[30:0], 1'b0};
            B_SHR:   b_q <= {1'b0, b_q[31:1]};
            B_SAR:   b_q <= {b_q[31], b_q[31:1]};
            default: begin
            end
        endcase
        if (alu_we) begin
            alu_q <= alu_result;
        end
        if (co_we) begin
            c_q <= alu_carry;
            o_q <= alu_overflow;
        end
        if (cnt_we) begin
            cnt_q <= cnt_d;
        end
        if (walk_we) begin
            walk_pfn_q <= bus_rdata[31:12];
            walk_w_q   <= bus_rdata[PTE_W];
            walk_u_q   <= bus_rdata[PTE_U];
        end

        bus_for_q <= trap ? FOR_VECTOR : bus_for_d;
        if (trap) begin
            trap_kind_q <= trap_kind;
        end

        case (state_q)
            S_FETCH: begin
                acc_q <= ACC_FETCH;
            end
            // shr sets O to the top bit of the value before the shift
            S_READ_B: begin
                o_q <= reg_val[31];
            end
            S_EXEC: begin
                if (op == OP_PUSH || op == OP_SR || op == OP_SRH || op == OP_SRB) begin
                    acc_q <= ACC_WRITE;
                end else begin
                    acc_q <= ACC_READ;
                end
            end
            // C is the last bit that a shift has moved out
            S_SHIFT: begin
                c_q <= (op == OP_SHL) ? b_q[31] : b_q[0];
            end
            // shl sets O if the top bit of the result differs from C; sar clears it
            S_SHIFT_END: begin
                if (op == OP_SHL) begin
                    o_q <= b_q[31] ^ c_q;
                end else if (op == OP_SAR) begin
                    o_q <= 1'b0;
                end
            end
            // dotv clears C and O
            S_DOT_ADD: begin
                c_q <= 1'b0;
                o_q <= 1'b0;
            end
            default: begin
            end
        endcase
    end

    /* The registers that a program can see, the state, and the entry of
       a trap */

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q        <= S_BOUNDARY;
            ip_q           <= RESET_IP;
            flags_q        <= RESET_FLAGS;
            cr0_q          <= RESET_CR0;
            cr1_q          <= 32'd0;
            cr2_q          <= 32'd0;
            cr3_q          <= 20'd0;
            cr4_q          <= 6'd0;
            cr5_q          <= 27'd0;
            dbg_lock_q     <= 1'b0;
            halted_q       <= 1'b0;
            double_fault_q <= 1'b0;
            fetch_run_q    <= 1'b0;
            ip_set_q       <= 1'b0;
        end else if (trap && cr0_q[CR0_T]) begin
            // The record of the last trap is still in use, and a second
            // one would overwrite it: a double fault. Nothing changes,
            // and the CPU stops.
            double_fault_q <= 1'b1;
            state_q        <= S_BOUNDARY;
        end else if (trap) begin
            // The record of the trap: where to return to, the flags, and
            // the cause. The ALU has worked out the address.
            cr1_q <= alu_result;
            cr4_q <= flags_q;
            cr5_q <= {trap_stat, 1'b0, trap_m, trap_lvl,
                      trap_mem && acc_q == ACC_FETCH,
                      trap_mem && flags_q[FLAG_U],
                      trap_mem && acc_q == ACC_WRITE,
                      trap_p, trap_num, trap_vec};
            if (trap_mem) begin
                cr2_q <= va;
            end

            // The handler runs in kernel mode with interrupts off
            flags_q[FLAG_U] <= 1'b0;
            flags_q[FLAG_I] <= 1'b0;
            cr0_q[CR0_T]    <= 1'b1;
            halted_q        <= 1'b0;
            fetch_run_q     <= 1'b0;

            // Its address is in the vector table
            state_q <= S_BUS_START;
        end else begin
            state_q <= state_d;

            // The page after this one may be anywhere in memory
            // The RP2040 has not seen a word that came from the cache, so
            // the fetch after it carries its address
            if (ir_we) begin
                fetch_run_q <= !ic_take && (ip_q[11:0] != 12'hffc);
            end
            // A new translation may have taken the place of the one that
            // the instructions are fetched through
            if (tlb_load) begin
                fetch_run_q <= 1'b0;
            end

            if (vector_we) begin
                ip_q     <= bus_rdata;
                ip_set_q <= 1'b1;
            end
            if (vector_fail) begin
                double_fault_q <= 1'b1;
            end

            case (state_q)
                S_FETCH: begin
                    ip_set_q <= 1'b0;
                end

                S_EXEC: begin
                    case (op)
                        OP_HLT: begin
                            halted_q <= 1'b1;
                            ip_set_q <= 1'b1;
                        end
                        OP_CLI: begin
                            flags_q[FLAG_I] <= 1'b0;
                        end
                        OP_STI: begin
                            flags_q[FLAG_I] <= 1'b1;
                        end
                        // All of flags, so sp may name the other stack pointer from now on
                        OP_IRET: begin
                            flags_q      <= cr4_q;
                            cr0_q[CR0_T] <= 1'b0;
                        end
                        default: begin
                        end
                    endcase
                end

                // A write to any control register ends a run of fetches
                // that carry no address
                S_WRITE_CTRL: begin
                    fetch_run_q <= 1'b0;
                    case (rb)
                        4'd0:    cr0_q <= alu_q[5:0];
                        4'd1:    cr1_q <= alu_q;
                        4'd2:    cr2_q <= alu_q;
                        4'd3:    cr3_q <= alu_q[31:12];
                        4'd4:    cr4_q <= alu_q[5:0];
                        4'd5:    cr5_q <= {alu_q[26:24], 1'b0, alu_q[22:0]};
                        // One value locks the debug port, and only a reset opens it
                        4'd8: begin
                            if (alu_q == DBG_LOCK_KEY) begin
                                dbg_lock_q <= 1'b1;
                            end
                        end
                        default: begin
                        end
                    endcase
                end

                S_RETIRE: begin
                    if (!ip_set_q) begin
                        ip_q <= alu_result;
                    end
                end

                default: begin
                end
            endcase

            // A write to ip is a jump
            if (wr_ip) begin
                ip_q        <= wb_data;
                ip_set_q    <= 1'b1;
                fetch_run_q <= 1'b0;
            end

            // A write to flags changes C, Z, S, and O only, and it wins
            // over the flags of the operation
            if (wr_flags) begin
                flags_q[3:0] <= wb_data[3:0];
            end else if (flags_we) begin
                flags_q[3:0] <= {o_q, alu_q[31], alu_q == 32'd0, c_q};
            end
        end
    end

    always_comb begin
        boundary = (state_q == S_BOUNDARY);
        retired  = (state_q == S_RETIRE);
        dbg      = {double_fault_q, halted_q, state_q, cr0_q[3:0], flags_q, cr5_q, ir_q, ip_q};
        dbg_regs = {26'd0, cr4_q, cr3_q, 12'd0, cr2_q, cr1_q, regs_dbg};

        dbg_locked   = dbg_lock_q;
        dbg_cr0_high = cr0_q[CR0_A:CR0_C];
    end
endmodule
