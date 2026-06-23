; =============================================================================
; engine.asm — inner interpreter and startup routines
; =============================================================================

; =============================================================================
; FORTH_NEXT — inner interpreter
;
; IP is stored in memory (FORTH_IP), NOT in BC. This frees BC for CODE words.
; HL = TOS is preserved across dispatch using push/ex(sp)/ret.
;
; On entry to handler: HL = TOS, DE = CFA+1
; FORTH_IP (the in-memory IP) now lives in the RAM scratch page (ts2068.inc).
; =============================================================================
FORTH_NEXT:
    push hl             ; save TOS on param stack
    ld  hl, (FORTH_IP)
    ld  e, (hl)
    inc hl
    ld  d, (hl)         ; DE = CFA address
    inc hl
    ld  (FORTH_IP), hl  ; IP += 2
    ex  de, hl          ; HL = CFA, DE = updated IP... no, we want DE=CFA+1
    ; HL = CFA. Read handler.
    ld  e, (hl)
    inc hl
    ld  d, (hl)         ; DE = handler address, HL = CFA+1
    ex  de, hl          ; HL = handler, DE = CFA+1
    ex  (sp), hl        ; swap: (SP) = handler, HL = TOS (restored!)
    ret                 ; pop handler, jump to it. HL = TOS, DE = CFA+1.

; =============================================================================
; FORTH_DOCOL — colon word entry
; HL = TOS, DE = CFA+1 on entry. Sets IP to PFA.
; =============================================================================
FORTH_DOCOL:
    ; Push current IP onto return stack, set IP = PFA
    push hl             ; save TOS
    push de             ; save CFA+1 (RPUSH_HL destroys DE!)
    ld  hl, (FORTH_IP)
    RPUSH_HL            ; push IP to return stack
    pop  de             ; restore CFA+1
    pop  hl             ; restore TOS
    inc de              ; DE = PFA = CFA+2
    ld  (FORTH_IP), de  ; set new IP
    jp  FORTH_NEXT

; =============================================================================
; FORTH_SEMIS — ;S exit from colon word
; HL = TOS (preserved). Pops IP from return stack.
; =============================================================================
FORTH_SEMIS:
    push hl             ; save TOS
    RPOP_HL             ; pop IP from return stack (uses DE as scratch)
    ld  (FORTH_IP), hl  ; restore IP
    pop  hl             ; restore TOS
    jp  FORTH_NEXT

; =============================================================================
; FORTH_DOVAR — VARIABLE runtime: push PFA address
; =============================================================================
FORTH_DOVAR:
    PUSH_TOS            ; push old TOS
    ex  de, hl          ; HL = CFA+1
    inc hl              ; HL = PFA = new TOS
    jp  FORTH_NEXT

; =============================================================================
; FORTH_DOCON — CONSTANT runtime: push value at PFA
; =============================================================================
FORTH_DOCON:
    PUSH_TOS            ; push old TOS
    ex  de, hl          ; HL = CFA+1
    inc hl              ; HL = PFA
    ld  e, (hl)
    inc hl
    ld  d, (hl)
    ex  de, hl          ; HL = constant value = new TOS
    jp  FORTH_NEXT

; =============================================================================
; FORTH_DOUSER — USER variable runtime: push USER_START + offset
; =============================================================================
FORTH_DOUSER:
    PUSH_TOS            ; push old TOS
    ex  de, hl          ; HL = CFA+1
    inc hl              ; HL = PFA
    ld  e, (hl)
    inc hl
    ld  d, (hl)         ; DE = offset
    ld  hl, USER_START
    add hl, de          ; HL = USER_START + offset = new TOS
    jp  FORTH_NEXT

; =============================================================================
; FORTH_DODOES — DOES> runtime
; =============================================================================
FORTH_DODOES:
    ; Entered via a `CALL FORTH_DODOES` that DOES> compiled into the parent
    ; (defining) word, just after (;CODE). On entry: HL = TOS, DE = child CFA+1,
    ; and the machine-stack top = the does-thread address (the return the CALL
    ; pushed). We push the child PFA as the new TOS and thread into the does-code,
    ; having saved the current IP so the does-code's trailing ;S returns to the
    ; child word's caller.
    pop  bc             ; BC = does-thread address (from the CALL)
    PUSH_TOS            ; push old TOS onto param stack
    inc  de             ; DE = CFA+2 = child PFA (becomes new TOS)
    push de             ; save PFA
    push bc             ; save does-thread
    ld   hl, (FORTH_IP)
    RPUSH_HL            ; push current IP to return stack (destroys DE)
    pop  bc             ; does-thread
    pop  hl             ; PFA = new TOS
    ld   (FORTH_IP), bc ; IP = does-thread
    jp   FORTH_NEXT

; =============================================================================
; FORTH_COLD
; =============================================================================
FORTH_COLD:
    di
    ld  sp, PS_TOP
    ld  hl, RS_TOP
    ld  (USER_START + U_RS_PTR), hl
    ld  hl, _COLD_INIT_TABLE
    ld  de, USER_START
    ld  bc, _COLD_INIT_SIZE
    ldir
    ld  hl, RS_TOP
    ld  (USER_START + U_RS_PTR), hl
    ; Copy RAM dict image
    ld  hl, _RAM_DICT_ROM
    ld  de, DICT_RAM_START
    ld  bc, _RAM_DICT_SIZE
    ld  a, b
    or  c
    jr  z, .no_dict
    ldir
.no_dict:
    ; Zero the RAM scratch sysvar page (interpreter scratch cells — relocated
    ; out of ROM). Defensive: most cells are written before read, but FORTH_IP
    ; and the counters benefit from a clean start.
    ld  hl, SCRATCH_START
    ld  de, SCRATCH_START + 1
    ld  bc, SCRATCH_END - SCRATCH_START - 1
    ld  (hl), 0
    ldir
    ; Zero the entire dictionary RAM ($C000-$EFFF = 12K), grows up from here
    ld  hl, DICT_RAM_START
    ld  de, DICT_RAM_START + 1
    ld  bc, DICT_RAM_END - DICT_RAM_START
    ld  (hl), 0
    ldir
    ; Initialize FORTH vocabulary head cell at DICT_RAM_START
    ld  hl, LAST_WORD_NFA      ; NFA of last word in ROM dictionary
    ld  (DICT_RAM_START), hl   ; vocab head = NFA of most recent word
    ; Zero buffers
    ld  hl, BUF_START
    ld  de, BUF_START + 1
    ld  bc, BUF_END - BUF_START - 1
    ld  (hl), 0
    ldir
    ; Copy the EXROM tape bank-switch stub into RAM (it must run from RAM —
    ; enabling the EXROM can page out the cartridge ROM mid-call)
    ld  hl, _TAPE_STUB_ROM
    ld  de, TAPE_STUB
    ld  bc, TS_LEN
    ldir
    ei

; === FORTH_WARM ===
FORTH_WARM:
    di
    ld  sp, PS_TOP
    ld  hl, RS_TOP
    ld  (USER_START + U_RS_PTR), hl
    ld  hl, 0
    ld  (USER_START + U_BLK),   hl
    ld  (USER_START + U_IN),    hl
    ld  (USER_START + U_STATE), hl
    ld  (USER_START + U_OUT),   hl
    ei
    ld  hl, _STR_BANNER
    call _PRINT_STR
    ; Print free dictionary bytes = (DICT_RAM_END+1) - DP. DICT_RAM_END=$FFFF, so
    ; compute $FFFF-DP then +1 (avoids the $10000 16-bit-truncation warning).
    ld  hl, DICT_RAM_END
    ld  de, (USER_START + U_DP)
    or  a
    sbc hl, de
    inc hl                  ; HL = free bytes
    call _PRINT_DECIMAL
    ld  hl, _STR_FREE
    call _PRINT_STR

; === FORTH_ABORT ===
FORTH_ABORT:
    ld  sp, PS_TOP
    ld  hl, RS_TOP
    ld  (USER_START + U_RS_PTR), hl
    ld  hl, 0
    ld  (USER_START + U_STATE), hl
    ld  (USER_START + U_BLK),   hl

; === FORTH_QUIT (machine code outer interpreter) ===
FORTH_QUIT_MC:
_QUIT_LOOP:
    call _DO_QUERY          ; read line into TIB (safe: no Forth stack ops)
    jp  _DO_INTERPRET       ; interpret all tokens; jumps to _QUIT_CONTINUE
_QUIT_CONTINUE:
    ld  hl, _STR_OK
    call _PRINT_STR
    jr  _QUIT_LOOP

; --- Input: read line into TIB -----------------------------------------------
_DO_QUERY:
    ld  hl, TIB_START
.ql:
    ; Show cursor
    push hl
    ld  a, '_' : rst 0x10
    ld  a, 8   : rst 0x10       ; backspace over cursor
    pop  hl
.ql_wait:
    push hl
    halt                        ; wait for interrupt (keyboard scan)
    call _GET_KEY
    pop  hl
    or  a
    jr  z, .ql_wait
    ; Hide cursor (overwrite with space, backspace)
    push hl : push af
    ld  a, 32 : rst 0x10       ; overwrite cursor with space
    ld  a, 8  : rst 0x10       ; backspace back
    pop  af : pop  hl
    ; Process key
    cp  13 : jr  z, .qdone     ; CR = done
    cp  12 : jr  z, .qbs       ; DELETE (TS2068)
    cp  8  : jr  z, .qbs       ; BACKSPACE (just in case)
    cp  32 : jr  c, .ql        ; ignore other control chars
    ; Echo original character, store uppercase
    push hl : push af
    rst 0x10                   ; echo original (lowercase) char
    pop  af : pop  hl
    ; Convert to uppercase for storage
    cp  'a'
    jr  c, .ql_store
    cp  'z'+1
    jr  nc, .ql_store
    sub 32                      ; 'a'-'z' -> 'A'-'Z'
.ql_store:
    ld  (hl), a
    inc hl
    jr  .ql
.qbs:
    ld  a, l
    cp  TIB_START & 0xFF
    jr  z, .ql                 ; at start, nothing to delete
    dec hl
    push hl
    ld  a, 8  : rst 0x10
    ld  a, 32 : rst 0x10
    ld  a, 8  : rst 0x10
    pop  hl
    jr  .ql
.qdone:
    ld  (hl), 0                ; null-terminate input
    push hl
    ld  a, 13 : rst 0x10
    pop  hl
    ld  hl, 0
    ld  (USER_START + U_IN), hl
    ret

_GET_KEY:
    xor a
    ld  hl, SYSVAR_FLAGS
    bit 5, (hl)
    ret z
    res 5, (hl)
    ld  a, (SYSVAR_LASTK)
    ret

; --- Outer interpreter (called from QUIT loop) --------------------------------
; Processes all tokens in TIB until end of input.
; Uses machine code for parsing/searching; trampolines into threaded mode
; for executing found words.
_DO_INTERPRET:
_INTERP_LOOP:
    ; 1. Parse next token: WORD with BL delimiter
    ld  hl, 32              ; delimiter = space
    call _MC_WORD           ; HL = HERE (counted string)
    ; 2. Check for empty word (end of input)
    ld  a, (hl)
    and 0x1F
    jp  z, _QUIT_CONTINUE   ; empty word = end of input, print ok
    ; Save HERE for potential error message
    ld  (INTERP_TOKEN), hl
    ; 3. Search dictionary
    ld  (MF_HERE), hl       ; set up for search (reuse -FIND's scratch)
    ld  hl, (USER_START + U_CONTEXT)
    ld  e, (hl) : inc hl : ld  d, (hl)
    ; DE = NFA of most recent word
    call _DICT_SEARCH       ; Z flag set if not found
                            ; If found: HL=CFA, A=count byte (with flags)
    jp  z, _INTERP_NUMBER
    ; 4. Found in dictionary. A=count byte, HL=CFA.
    ld  b, a                ; save count byte
    ; Check STATE
    ld  de, (USER_START + U_STATE)
    ld  a, d : or  e
    jr  z, _INTERP_EXEC     ; STATE=0: execute
    ; STATE != 0: compile mode
    bit 6, b                ; F_IMM = 0x40 — immediate?
    jr  nz, _INTERP_EXEC   ; IMMEDIATE words execute even in compile mode
    ; Compile: store CFA at HERE, advance DP
    ld  de, (USER_START + U_DP)
    ld  a, l : ld  (de), a : inc de
    ld  a, h : ld  (de), a : inc de
    ld  (USER_START + U_DP), de
    jr  _INTERP_LOOP

_INTERP_EXEC:
    ; Execute word at CFA (HL).
    ; Build a mini 2-word thread: [CFA] [INTERP_RESUME]
    ; Set FORTH_IP to it and enter FORTH_NEXT.
    ld  (INTERP_THREAD), hl
    ld  hl, INTERP_RESUME
    ld  (INTERP_THREAD + 2), hl
    ld  hl, INTERP_THREAD
    ld  (FORTH_IP), hl      ; IP = address of mini-thread
    ; Pop TOS from param stack — executed word needs it in HL
    pop  hl                 ; HL = TOS (correct Forth stack state)
    jp  FORTH_NEXT           ; enter threaded execution

; This CODE word is reached when the executed word finishes.
; BC (IP) may have been destroyed by the executed word.
; We don't need BC anymore (we're leaving threaded mode), so just
; push TOS and return to the machine-code interpreter loop.
INTERP_RESUME:
    dw  INTERP_RESUME_CODE
INTERP_RESUME_CODE:
    push hl
    jr  _INTERP_LOOP

_INTERP_NUMBER:
    ; 5. Not in dictionary — try parsing as a number
    ld  hl, (INTERP_TOKEN)  ; HL = HERE (counted string)
    ld  a, (hl)
    and 0x1F
    ld  c, a                ; C = name length
    inc hl                  ; HL = first char
    ; Check for leading minus
    ld  b, 0                ; B = negative flag
    ld  a, (hl)
    cp  '-'
    jr  nz, _INTERP_NONEG
    ld  b, 1
    inc hl
    dec c
    jr  z, _INTERP_ERROR    ; just "-" with no digits
_INTERP_NONEG:
    ; Save sign flag
    ld  a, b
    ld  (INTERP_NEG), a
    ; Strip high bit on last char (set by WORD)
    push hl                 ; save start
    ld  d, 0 : ld  e, c
    add hl, de
    dec hl                  ; HL = last char
    ld  a, (hl)
    and 0x7F
    ld  (hl), a             ; strip high bit
    pop  hl                 ; HL = first digit char
    ; Set up double accumulator d = 0 via scratch variables
    ld  (PN_ADDR), hl
    ld  hl, 0
    ld  (PN_DLO), hl
    ld  (PN_DHI), hl
    ; Call (NUMBER) loop directly — jumps into .pnum_loop
    ; On exit: PN_DLO/PN_DHI have result, PN_ADDR has addr past digits
    call _PNUMBER_LOOP
    ; Check: did (NUMBER) consume all chars?
    ld  hl, (PN_ADDR)
    ld  a, (hl)
    cp  32 : jr  z, _INTERP_NUMOK
    or  a  : jr  z, _INTERP_NUMOK
    cp  13 : jr  z, _INTERP_NUMOK
    ; Not all consumed -> error
    jr  _INTERP_ERRCLN

_INTERP_NUMOK:
    ; Got a valid number. Read d from scratch variables.
    ld  de, (PN_DHI)        ; DE = d_high
    ld  hl, (PN_DLO)        ; HL = d_low
    ; Apply sign
    ld  a, (INTERP_NEG)
    or  a
    jr  z, _INTERP_NOSIGN
    ; Negate double
    ld  a, l : cpl : ld  l, a : ld  a, h : cpl : ld  h, a : inc hl
    ld  a, e : cpl : ld  e, a : ld  a, d : cpl : ld  d, a
    jr  nc, _INTERP_NOSIGN
    inc de
_INTERP_NOSIGN:
    ; Check STATE
    ld  bc, (USER_START + U_STATE)
    ld  a, b : or  c
    jr  z, _INTERP_EXECNUM
    ; Compile mode: compile LIT + value
    push hl                 ; save d_low
    ld  bc, (USER_START + U_DP)
    ld  a, LIT & 0xFF : ld  (bc), a : inc bc
    ld  a, LIT >> 8   : ld  (bc), a : inc bc
    pop  hl                 ; HL = d_low
    ld  a, l : ld  (bc), a : inc bc
    ld  a, h : ld  (bc), a : inc bc
    ld  (USER_START + U_DP), bc
    jp  _INTERP_LOOP

_INTERP_EXECNUM:
    ; Interpret mode: leave number on parameter stack
    push hl                 ; push d_low as value on param stack
    jp  _INTERP_LOOP

_INTERP_ERRCLN:
    ; d is in scratch vars (PN_DLO/PN_DHI), not on stack — no cleanup needed
_INTERP_ERROR:
    ; Print the word that failed, then " ?"
    ld  hl, (INTERP_TOKEN)
    ld  a, (hl)
    and 0x1F
    ld  b, a
    inc hl
_INTERP_ERRPRT:
    ld  a, (hl)
    and 0x7F
    rst 0x10
    inc hl
    djnz _INTERP_ERRPRT
    ld  hl, _STR_ERR
    call _PRINT_STR
    jp  FORTH_ABORT

; --- Dictionary search subroutine ---
; Input:  (MF_HERE) = counted string to find
;         DE = NFA of first word to check
; Output: Z set = not found
;         Z clear = found, HL = CFA, A = count byte (with flags)
_DICT_SEARCH:
.ds_loop:
    ld  a, d : or  e
    ret z                   ; NFA=0 -> not found (Z set)
    ; Check smudge
    ld  a, (de)
    bit 5, a
    jr  nz, .ds_advance
    ; Compare lengths
    and 0x1F
    ld  b, a                ; B = dict name length
    ld  hl, (MF_HERE)
    ld  a, (hl)
    and 0x1F
    cp  b
    jr  nz, .ds_advance
    ; Compare characters
    ld  c, b                ; C = count
    push de                 ; save NFA
    inc hl : inc de         ; past count bytes
.ds_cmp:
    ld  a, (de)
    and 0x7F                ; strip high bit
    ld  b, a
    ld  a, (hl)
    and 0x7F
    cp  b
    jr  nz, .ds_no
    inc hl : inc de
    dec c
    jr  nz, .ds_cmp
    ; MATCH
    pop  de                 ; DE = NFA of found word
    ld  a, (de)             ; A = count byte (with flags)
    ld  b, a
    and 0x1F                ; A = name length
    ld  c, a
    ld  h, d : ld  l, e    ; HL = NFA
    inc hl                  ; HL = past count byte
    ld  d, 0 : ld  e, c
    add hl, de              ; HL = NFA + 1 + name_length = CFA
    ld  a, b                ; A = count byte (with flags)
    or  1                   ; ensure Z flag clear (found)
    ret

.ds_no:
    pop  de                 ; DE = NFA
.ds_advance:
    ; Follow LFA chain
    dec de : dec de         ; DE = LFA address
    ex  de, hl
    ld  e, (hl) : inc hl : ld  d, (hl)
    ; DE = previous LFA value
    ld  a, d : or  e
    ret z                   ; LFA=0 -> end of chain (Z set)
    inc de : inc de         ; DE = previous NFA
    jr  .ds_loop

; --- Print null-terminated string at HL ---------------------------------------
_PRINT_STR:
.lp:
    ld  a, (hl)
    or  a
    ret z
    rst 0x10
    inc hl
    jr  .lp

; =============================================================================
; USER variable defaults
; =============================================================================
_COLD_INIT_TABLE:
    dw  PS_TOP              ; U_SP0
    dw  RS_TOP              ; U_R0
    dw  TIB_START           ; U_TIB
    dw  31                  ; U_WIDTH
    dw  1                   ; U_WARNING
    dw  DICT_RAM_START      ; U_FENCE
    dw  DICT_RAM_START + 256 ; U_DP (first 256 bytes: vocab head + guard space)
    dw  0                   ; U_VOC_LINK
    dw  0                   ; U_BLK
    dw  0                   ; U_IN
    dw  0                   ; U_OUT
    dw  0                   ; U_SCR
    dw  0                   ; U_OFFSET
    dw  DICT_RAM_START      ; U_CONTEXT -> vocab head cell
    dw  DICT_RAM_START      ; U_CURRENT -> vocab head cell
    dw  0                   ; U_STATE
    dw  10                  ; U_BASE
    dw  0xFFFF              ; U_DPL
    dw  0                   ; U_FLD
    dw  PS_TOP              ; U_CSP
    dw  0                   ; U_R_HASH
    dw  PAD_START           ; U_HLD
    dw  RS_TOP              ; U_RS_PTR
    dw  0                   ; U_DRIVE
    dw  0                   ; U_DENSITY
    dw  18                  ; U_SEC_BLK
    dw  4                   ; U_N_BUFF
    dw  BUF_START           ; U_USE
    dw  BUF_START           ; U_PREV
    dw  0                   ; U_DISK_ERR
    dw  0                   ; U_CAPS
    dw  0                   ; U_PRINTER
_COLD_INIT_SIZE EQU $ - _COLD_INIT_TABLE

_STR_BANNER:
    db  13, "TS2068 fig-FORTH  v0.9", 13, 0
_STR_FREE:
    db  " bytes free", 13, 0
_STR_OK:
    db  " ok", 13, 0
_STR_ERR:
    db  " ?", 13, 0

; Print HL as unsigned decimal (for boot message)
_PRINT_DECIMAL:
    ; Convert HL to decimal digits on stack, then print
    ld  de, 0               ; digit count
.pd_div:
    push de
    ld  de, 10
    call _PD_DIVMOD
    pop  de
    add a, '0'
    push af
    inc de
    ld  a, h : or  l
    jr  nz, .pd_div
.pd_print:
    pop  af
    rst 0x10
    dec de
    ld  a, d : or  e
    jr  nz, .pd_print
    ret
; HL = HL / DE, A = remainder
_PD_DIVMOD:
    ld  bc, 0
    or  a
.pd_loop:
    sbc hl, de
    jr  c, .pd_done
    inc bc
    jr  .pd_loop
.pd_done:
    add hl, de
    ld  a, l
    ld  h, b : ld  l, c
    ret

; RAM dictionary image placeholder (filled by dictionary.asm)
_RAM_DICT_ROM:
_RAM_DICT_SIZE EQU 0
