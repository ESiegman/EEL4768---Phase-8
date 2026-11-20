# LSU interface (proposal)

Owner: Shade. Needs agreement from Eren (issue, ROB, commit, retire) and
Bradly (`cdb_arb`). Nothing here changes `hart.v`, `rat.v` or `cdb_arb.v`;
it is what `lsu.v` expects from them.

Status: implemented in `lsu.v` (lint clean) and unit tested by `lsu_tb.v`
with the real data cache, 5 cache configurations x memory latency 1/4/10.
`run_test.sh` does not list `lsu` yet; until it does, run it by hand:
`iverilog -g2005 -s lsu_tb -o build/lsu_sim lsu_tb.v *.v cache/*.v` (minus
the other `_tb.v` files) and `cd build && vvp lsu_sim`.

The conventions follow what Bowen already merged in `rs.v` and
`reservation_station.v`, so the three schedulers look alike to the hart:

- an operand is `{wait, qtag, value}`: `wait = 1` means "not ready, watch the
  CDB for `qtag`", `wait = 0` means `value` is the operand;
- a result is a held request (`o_result_valid` + payload) that stays up,
  unchanged, until the arbiter's `i_result_grant` (a load may first request
  in the cycle the cache answers it, see "Load completion");
- the unit snoops the CDB on the allocate cycle too, so a producer that
  broadcasts in the same cycle its consumer issues is never lost.

## Summary

| Group | Signals | Notes |
|---|---|---|
| Allocate (issue) | `i_alloc_valid`, `i_alloc_tag`, `i_alloc_store`, `i_alloc_funct3`, `i_alloc_imm`, base `{wait,qtag,value}`, store data `{wait,qtag,value}` | One per cycle, in program order. Only when `!o_full`. |
| Full | `o_full` | Registered state only: does not look at this cycle's allocate or free. |
| CDB snoop | `i_cdb_valid`, `i_cdb_tag`, `i_cdb_value` | Every waiting entry compares every cycle, and so does the entry being allocated. |
| Load result to `cdb_arb` | `o_result_valid`, `o_result_tag`, `o_result_value`, `i_result_grant` | Held until granted, from the cache-ready cycle on. fflags for a load are `5'd0`. |
| ROB head / commit | `i_rob_head`, `i_commit_valid`, `o_head_valid`, `o_head_ready`, `o_head_trap` | Replaces a "done without CDB" pulse; see below. |
| Retire fields for a memory op at the head | `o_head_base`, `o_head_data`, `o_head_dmem_{addr,mask,ren,wen,rdata,wdata}` | Same values the phase 6 hart reported. |
| Main memory | `o_mem_*`, `i_mem_valid`, `i_mem_rd_data` | The data cache is instantiated **inside** `lsu.v`; the hart passes these straight to its ports. |

## Ports

```verilog
module lsu #(
    parameter EVICT_POLICY = 0,
    parameter NUM_WAYS     = 1,
    parameter CACHE_SIZE   = 16,
    parameter BLOCK_SIZE   = 128,
    parameter PREFETCH_EN  = 0
) (
    input  wire        i_clk,
    input  wire        i_rst,

    // ---- allocate, from issue ----
    input  wire        i_alloc_valid,       // a load or store issues this cycle (only when !o_full)
    output wire        o_full,              // 8 entries in use
    input  wire [ 2:0] i_alloc_tag,         // its ROB tag
    input  wire        i_alloc_store,       // 1: sb/sh/sw/fsw   0: lb/lh/lw/lbu/lhu/flw
    input  wire [ 2:0] i_alloc_funct3,      // inst[14:12]; flw/fsw use 3'b010 like lw/sw
    input  wire [31:0] i_alloc_imm,         // sign-extended I (load) or S (store) immediate
    input  wire        i_alloc_base_wait,   // rs1 not ready: wait for i_alloc_base_qtag
    input  wire [ 2:0] i_alloc_base_qtag,
    input  wire [31:0] i_alloc_base_value,  // rs1 when !wait
    input  wire        i_alloc_data_wait,   // store data (x[rs2], or f[rs2] for fsw) not ready
    input  wire [ 2:0] i_alloc_data_qtag,
    input  wire [31:0] i_alloc_data_value,  // ignored for loads

    // ---- CDB snoop ----
    input  wire        i_cdb_valid,
    input  wire [ 2:0] i_cdb_tag,
    input  wire [31:0] i_cdb_value,

    // ---- load result, to cdb_arb ----
    output wire        o_result_valid,      // held until i_result_grant
    input  wire        i_result_grant,      // this cycle's CDB is ours
    output wire [ 2:0] o_result_tag,
    output wire [31:0] o_result_value,      // extended (lb/lh/lbu/lhu), whole word for lw/flw

    // ---- ROB head and commit ----
    input  wire [ 2:0] i_rob_head,          // tag of the ROB head (a register in the ROB)
    input  wire        i_commit_valid,      // the ROB commits its head this cycle
    output wire        o_head_valid,        // the ROB head is a load/store held here
    output wire        o_head_ready,        // ...and it may commit this cycle
    output wire        o_head_trap,         // ...misaligned (valid when o_head_ready)
    output wire [31:0] o_head_base,         // o_retire_rs1_rdata
    output wire [31:0] o_head_data,         // o_retire_rs2_rdata (sb/sh/sw) or frs2_rdata (fsw)
    output wire [31:0] o_head_dmem_addr,    // o_retire_dmem_* for the head
    output wire [ 3:0] o_head_dmem_mask,
    output wire        o_head_dmem_ren,
    output wire        o_head_dmem_wen,
    output wire [31:0] o_head_dmem_rdata,
    output wire [31:0] o_head_dmem_wdata,

    // ---- main memory, behind the data cache inside the LSU ----
    output wire                    o_mem_rd,
    output wire [31:0]             o_mem_rd_addr,
    input  wire                    i_mem_valid,
    input  wire [BLOCK_SIZE*8-1:0] i_mem_rd_data,
    output wire                    o_mem_wr,
    output wire [31:0]             o_mem_wr_addr,
    output wire [BLOCK_SIZE*8-1:0] o_mem_wr_data,
    output wire [BLOCK_SIZE-1:0]   o_mem_wr_be
);
```

`i_mem_ready` stays unused in the hart (the phase 5 cache has no such input).

## Allocate

Issue sends one memory op per cycle with its ROB tag, in program order. For
each of the two operands it sends either the value (`wait = 0`) or the
producer's ROB tag (`wait = 1`). Loads pass `i_alloc_data_wait = 0`.

FP loads and stores need nothing special: the RAT maps `f0`-`f31` to the same
ROB tags as `x1`-`x31`, so `fsw` data is just another `{wait, qtag, value}`
(from the FP register file / FP RAT), and `flw`'s word goes back on the CDB
like any other result. The LSU never needs to know an op is FP: `flw` behaves
exactly like `lw`, `fsw` exactly like `sw`.

`o_full` is `tail == head` with the wrap bits different. It never depends on
this cycle's allocate or this cycle's commit, so there is no combinational
path from issue back to issue.

## Same-cycle CDB rule

If a producer broadcasts in the cycle its consumer allocates, **the LSU
catches it**: the entry being allocated compares `i_alloc_*_qtag` against the
CDB just like a waiting entry does (the same thing `reservation_station.v`
does). Issue may also resolve it as a CDB bypass (PDF 4.8) and send
`wait = 0`; both are safe, so issue doesn't have to.

## Load completion (to `cdb_arb`)

- A load reads the cache when it is the oldest entry that still needs the
  cache. In the cycle the cache raises `o_ready`, the LSU latches `o_rdata`
  (the cache does not hold it).
- `o_result_valid` is high for the **oldest load whose data is latched and
  not yet broadcast**, with its tag and extended value. If there is none, it
  is high for the load the cache answers **this cycle**, with the value taken
  straight from `o_rdata` (PDF 4.10.2: "Load -> o_complete: on cache ready +
  CDB grant"). If that load loses the arbitration, its word is latched as
  usual and it keeps requesting, unchanged, from the next cycle until
  `i_result_grant`. The grant cycle is the broadcast cycle:
  `cdb = {valid: 1, tag: o_result_tag, value: o_result_value, fflags: 5'd0}`.
- `o_result_valid` and the payload depend on LSU registers and the cache's
  `o_ready`/`o_rdata`, which depend only on LSU registers and `i_rob_head`,
  never on a grant, so the grant can be combinational from it without a
  loop.
- The next load does not wait for the previous load's grant: once a load's
  data is latched, the next op may use the cache while the first one waits
  for the CDB.
- Stores and misaligned ops never raise `o_result_valid`.

For `o_complete_pc` and `o_complete_rd`, the hart looks up the ROB entry of
the CDB tag (the ROB keeps pc and rd for retire anyway). The LSU does not
carry them.

## Done without the CDB, and commit

Stores and misaligned ops never go on the CDB. Instead of a done pulse, the
LSU answers one question about the ROB head:

- `o_head_valid`: the ROB head (`i_rob_head`) is a memory op in the LSU. It
  is always the LSU's oldest entry, so this is one tag compare.
- `o_head_ready`: it may commit **this cycle**:
  - load: its CDB grant happened in an earlier cycle;
  - misaligned load: its base is known;
  - misaligned store: base and store data are known (the trap still reports
    `rs2_rdata`, which is checked for stores);
  - aligned store: base and data are known **and the cache accepts the write
    this cycle** (see the next section), or it already did.
- `o_head_trap`: misaligned (`lh/lhu/sh` with `addr[0]`, `lw/sw/flw/fsw` with
  `addr[1:0] != 0`). No cache request is ever made for it and nothing is
  written at commit.

ROB commit rule for its head:

```verilog
wire head_commit = rob_valid[head] &
                   (lsu_head_valid ? lsu_head_ready : rob_done[head]);
```

`i_commit_valid` goes to the LSU (it frees its oldest entry when
`o_head_valid & i_commit_valid`). Each LSU entry lives until its instruction
commits; the LSU and ROB both have 8 entries, so this never costs capacity,
and it is what lets the LSU supply the retire fields.

## Stores: write at commit, no store buffer

When the ROB head is an aligned store with base and data ready, the LSU
drives the cache's `i_wen`, `i_addr`, `i_mask` and `i_wdata` for it. The cache
raises `o_ready` combinationally (same cycle on a hit or a no-allocate miss;
later while a fill or prefetch owns the array), and the store is applied on
that clock edge. `o_head_ready` is high in that cycle, so **the ROB commits
the store in the same cycle the cache takes the write**.

- `i_wen` depends only on `i_rob_head` and LSU registers, never on the ROB's
  commit decision, so `i_rob_head -> i_wen -> o_ready -> o_head_ready ->
  commit` has no loop. The LSU uses `i_commit_valid` only at the clock edge.
- If the ROB commits later than that cycle for some other reason, the LSU
  remembers the write was done and never writes twice.
- A store only writes once it is the ROB head, so nothing younger than an
  `ebreak` (which never commits) can write memory.
- Loads behind a store do not touch the cache until the store has written:
  no load passes a store and there is no store-to-load forwarding.
- The cache request mux gives the committing store priority over a load
  starting in the same cycle (PDF 4.7). A load whose miss is already in
  flight keeps the port until its `o_ready`.

(The alternative, "ROB commits the store first and the LSU writes it later",
also works but needs a committed-not-written state and makes the first younger
load wait a cycle longer. Tell me if you prefer it.)

## Retire fields for a memory op

When `o_head_valid` is high, the ROB reports these for its head (they match
the phase 6 hart, including for trapped accesses):

| Retire port | From |
|---|---|
| `o_retire_rs1_rdata` | `o_head_base` (the base the op actually used) |
| `o_retire_rs2_rdata` | `o_head_data` for `sb/sh/sw`, 0 otherwise |
| `o_retire_frs2_rdata` | `o_head_data` for `fsw` |
| `o_retire_dmem_addr` | `o_head_dmem_addr`: word-aligned effective address (also for traps) |
| `o_retire_dmem_mask` | `o_head_dmem_mask`: byte lanes, `4'b0000` when trapped |
| `o_retire_dmem_ren` / `_wen` | `o_head_dmem_ren` / `_wen`: low when trapped |
| `o_retire_dmem_rdata` | `o_head_dmem_rdata`: the raw cache word a load read |
| `o_retire_dmem_wdata` | `o_head_dmem_wdata`: store data shifted to its lanes |
| `o_retire_trap` | `o_head_trap` |
| `o_retire_rd_wdata` / `frd_wdata` | the ROB's own copy of the CDB value (no write when trapped) |

## Timing

```
cycle      t          t+1                t+2             t+3
issue      lw alloc
LSU                   cache req, hit:
                      o_ready, latch
                      o_rdata
cdb_arb               o_result_valid,
                      grant -> CDB,
                      o_complete
ROB                                      head ready, commit

issue      sw alloc
LSU                   data/base ready
ROB                   ...older ops commit...  head == sw:
                                              i_wen, o_ready -> commit
```

## Instantiation (for `hart.v`)

```verilog
lsu #(
    .EVICT_POLICY(EVICT_POLICY),
    .NUM_WAYS    (NUM_WAYS),
    .CACHE_SIZE  (CACHE_SIZE),
    .BLOCK_SIZE  (BLOCK_SIZE),
    .PREFETCH_EN (PREFETCH_EN)
) lsu_inst (
    .i_clk             (i_clk),
    .i_rst             (i_rst),
    .i_alloc_valid     (issue_fire & issue_is_mem),
    .o_full            (lsu_full),
    .i_alloc_tag       (rob_tail),
    .i_alloc_store     (dec_dmem_wen),
    .i_alloc_funct3    (id_inst[14:12]),
    .i_alloc_imm       (dec_immediate),
    .i_alloc_base_wait (src1_wait),
    .i_alloc_base_qtag (src1_qtag),
    .i_alloc_base_value(src1_value),
    .i_alloc_data_wait (src2_wait),        // f[rs2] operand for fsw
    .i_alloc_data_qtag (src2_qtag),
    .i_alloc_data_value(src2_value),
    .i_cdb_valid       (cdb_valid),
    .i_cdb_tag         (cdb_tag),
    .i_cdb_value       (cdb_value),
    .o_result_valid    (lsu_req),
    .i_result_grant    (grant_lsu),
    .o_result_tag      (lsu_tag),
    .o_result_value    (lsu_value),
    .i_rob_head        (rob_head),
    .i_commit_valid    (rob_commit),
    .o_head_valid      (lsu_head_valid),
    .o_head_ready      (lsu_head_ready),
    .o_head_trap       (lsu_head_trap),
    .o_head_base       (lsu_head_base),
    .o_head_data       (lsu_head_data),
    .o_head_dmem_addr  (lsu_dmem_addr),
    .o_head_dmem_mask  (lsu_dmem_mask),
    .o_head_dmem_ren   (lsu_dmem_ren),
    .o_head_dmem_wen   (lsu_dmem_wen),
    .o_head_dmem_rdata (lsu_dmem_rdata),
    .o_head_dmem_wdata (lsu_dmem_wdata),
    .o_mem_rd          (o_mem_rd),
    .o_mem_rd_addr     (o_mem_rd_addr),
    .i_mem_valid       (i_mem_valid),
    .i_mem_rd_data     (i_mem_rd_data),
    .o_mem_wr          (o_mem_wr),
    .o_mem_wr_addr     (o_mem_wr_addr),
    .o_mem_wr_data     (o_mem_wr_data),
    .o_mem_wr_be       (o_mem_wr_be)
);
```

Issue stalls on `lsu_full` for a memory op. `issue_is_mem` is the decoder's
`o_dmem_ren | o_dmem_wen` on a legal instruction (illegal encodings go to the
ROB only, PDF 4.4).

## Open questions

1. **Eren:** OK to commit a store in the cycle the cache takes its write
   (`o_head_ready`), rather than committing first?
2. **Eren:** OK for the ROB to take load and store retire fields from the
   `o_head_*` ports instead of storing them itself?
3. **Eren:** ROB tags are allocated consecutively mod 8 (tail increments by
   one per issued instruction)? The hart testbenches check consecutive
   retires carry consecutive tags.
4. **Bradly:** the LSU is one requester with `{valid, tag}` for age and
   `{value, fflags = 0}` as payload; `o_result_valid` is held until granted
   and depends only on LSU registers and the cache's same-cycle answer.
