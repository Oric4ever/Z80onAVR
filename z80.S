/*
  Z80 and CP/M emulator by F.Frances, (C) 2019.

  This targets ATmega processors with external SRAM
  such as ATmega161/162/640/1280/2560/1281/2561...
    
  However, for speed efficiency, the emulator does not try to access the
  part of the external SRAM that is overlayed by the internal ram nor the
  first page reserved for the ATmega's I/Os. So the memory map accessible
  by the emulated Z80 is 0000-FAFF (mapped to the ATmega's 0500-FFFF).

  The 1KB internal ram of the ATmega162 is used for a sector buffer (512 bytes),
  a few variables, and the AVR stack (used when calling a few C routines).

  Caveats:
    - I first wrote a 8080 emulator and added the Z80 instructions afterwards,
      so the mnemonics are those of the Intel 8080.
    - a few opcodes are not implemented, I didn't encountered them when
      running programs on CP/M (eg. Z80 extended IO instructions, not used due
      to hardware abstraction given by CP/M's BIOS)
    - N flag not implemented (memorizes if last operation was an addition or
      subtraction, for correct adjustement in DAA): DAA will always assume
      last operation was an addition...
    - BCD handling not tested, and two extended BCD instructions (RLD,RRD) are
      not implemented...
    - when accessing memory from AVR code, beware that the Z80 address space
      is translated: every page #n of the Z80 is mapped to the physical page
      #n+5.

  Speed: 
    It depends on the Z80 instructions that are executed, but roughly I have
    observed that a 16 MHz ATmega162 gives a ~ 7 or 8 MHz Z80...

  Examples of instructions timing in AVR cycles (all memory accesses considered
  in external mem):

    nop             =>   5 cycles
    ld  a,b         =>   6 cycles
    ld  e,10        =>   8 cycles
    ld  b,(hl)      =>  11 cycles
    ld  (hl),c      =>  11 cycles
    ld  d,(ix+2)    =>  24 cycles
    add b           =>   7 cycles
    adc c           =>   8 cycles
    and d           =>  16 cycles
    inc bc          =>   7 cycles
    inc c           =>   8 cycles
    inc (hl)        =>  14 cycles
    inc (iy-3)      =>  30 cycles
    rar             =>   8 cycles
    jp  addr        =>  14 cycles
    jp  (hl)        =>   7 cycles
    jr  disp        =>  12 cycles
    jr  z,disp      =>  10/15 cycles
    djnz disp       =>  10/15 cycles
    call addr       =>  21 cycles
    ret             =>  12 cycles
    ldir            =>  10 cycles per byte
*/

#define TRACE 0

/* least used variables that couldn't find a room in registers... */
    .section .data
IntFlipFlop:.byte 0
traceFlag:  .byte 0

    .section .text

/***************************************************************************
 ******** Register usage ***************************************************
 ***************************************************************************/

#define regBC   r0
#define regBCL  r0
#define regBCH  r1
#define regC    r0
#define regB    r1

#define regDE   r2
#define regDEL  r2
#define regDEH  r3
#define regE    r2
#define regD    r3

#define regHL   r4
#define regHLL  r4
#define regHLH  r5
#define regL    r4
#define regH    r5

#define regA    r6
#define regZero r7

#define regBC2  r8
#define regC2   r8
#define regB2   r9
#define regDE2  r10
#define regE2   r10
#define regD2   r11
#define regHL2  r12
#define regL2   r12
#define regH2   r13
#define regPSW2 r14
#define regA2   r15

#define regPSW  r16
#define Flags   r17
#define regOne  r18
#define Operand r19
#define regIX   r20
#define regIXL  r20
#define regIXH  r21
#define regIY   r22
#define regIYL  r22
#define regIYH  r23
#define tmp     r24
#define tmpL    r24
#define tmpH    r25

#define regPC   X
#define regPCL  XL
#define regPCH  XH
#define regSP   Y
#define regSPL  YL
#define regSPH  YH
#define EAddr   Z
#define EAddrL  ZL
#define EAddrH  ZH

#define SREG    0x3f

/***************************************************************************
 **************************** FETCH Macro **********************************
 ***************************************************************************/

#if TRACE
#define QFETCH  $  call fetch_and_trace  $  ijmp
#else
#define QFETCH  $  ld ZL,regPC+  $  ijmp
#endif

#define FETCH   $  ldi ZH,hi8(pm(OpcodeTable))  QFETCH
#define JFETCH   $  rjmp fetch

/***************************************************************************
 **************************** Addressing Modes Macros **********************
 ***************************************************************************/

#define Imm             ld Operand,regPC+  $
#define LoadImmW(reg)   ld reg##L,regPC+   $  ld reg##H,regPC+
#define Addr            LoadImmW(EAddr)  $  subi EAddrH,-5  $

#define Relative        ld tmp,regPC+  $
#define AddRel(reg)     add reg##L,tmp  $  adc reg##H,regZero  $  sbrc tmp,7  $  dec reg##H

#define MemHL           EAddrHL   ld Operand,EAddr  $
#define MemIXd          EAddrIXd  ld Operand,EAddr  $
#define MemIYd          EAddrIYd  ld Operand,EAddr  $
#define EAddrHL         movw EAddr,regHL  $  subi EAddrH,-5  $
#define EAddrIXd        Indexed(regIX)  $  subi EAddrH,-5  $
#define EAddrIYd        Indexed(regIY)  $  subi EAddrH,-5  $
#define Indexed(index)  Relative  movw EAddr,index  $  AddRel(EAddr)

/*****************************************************************************
 ************************ ALU flags Macros ***********************************
 *****************************************************************************/

/* Z80 Flags : SZ1A1P1C
    => P/V : shared Parity/Overflow Flag
    => Sign, Zero, Carry : normal use
    => Auxiliary Carry : Half Carry for DAA 
*/
#define bitI    7
#define bitT    6
#define bitH    5
#define bitPV   3
#define bitN    2
#define bitZ    1
#define bitC    0

#define SaveFlags       in Flags,SREG
#define RestoreFlags    out SREG,Flags
#define UpdateCarry     in tmp,SREG  $  bst tmp,bitC  $  bld  Flags,bitC
#define UpdateSZV       bst Flags,bitC  $  SaveFlags  $  bld  Flags,bitC
#define CopyZtoV        bst Flags,bitZ  $  bld Flags,bitPV

#define Parity(reg)  mov ZL,reg  $  ldi ZH,hi8(ParityTable)  $  lpm tmp,Z  $  bst tmp,0  $  bld Flags,bitPV
#define SaveAllFlags(r) SaveFlags  $  Parity(r)

#define CompressPSW \
    bst  Flags,bitH  $  bld  regPSW,4   /* A flag */ $\
    bst  Flags,bitN  $  bld  regPSW,7   /* S flag */ $\
    bst  Flags,bitZ  $  bld  regPSW,6   /* Z flag */ $\
    bst  Flags,bitC  $  bld  regPSW,0   /* C flag */ $\
    bst  Flags,bitPV $  bld  regPSW,2   /* P/V flag */

#define UncompressPSW  \
    bst  regPSW,4  $  bld  Flags,bitH  $\
    bst  regPSW,7  $  bld  Flags,bitN  $\
    bst  regPSW,6  $  bld  Flags,bitZ  $\
    bst  regPSW,0  $  bld  Flags,bitC  $\
    bst  regPSW,2  $  bld  Flags,bitPV

/*****************************************************************************
 ********** transfer instructions ********************************************
 *****************************************************************************/

#define Op_MOV(dst,src) mov dst,src

#define Op_LD_M(reg)    ld reg,EAddr
#define Op_ST_M(reg)    st EAddr,reg

#define Op_MVI(dst)     ld dst,regPC+

#define Op_LXI(reg)     ld reg##L,regPC+  $  ld reg##H,regPC+
#define Op_LXI_SP       Op_LXI(regSP)  $  subi regSPH,-5

#define Op_LDA          ld regA,EAddr
#define Op_STA          st EAddr,regA

#define Op_LHLD(reg)    ld reg##L,EAddr+  $  ld reg##H,EAddr
#define Op_SHLD(reg)    st EAddr+,reg##L  $  st EAddr,reg##H

#define Op_LDAX(reg)    mov EAddrH,reg##H  $  mov EAddrL,reg##L  $  subi EAddrH,-5  $  ld regA,EAddr
#define Op_STAX(reg)    mov EAddrH,reg##H  $  mov EAddrL,reg##L  $  subi EAddrH,-5  $  st EAddr,regA
#define Op_XCHG         movw tmp,regDE     $  movw regDE,regHL   $  movw regHL,tmp

#define Op_PCHL(reg)    movw regPC,reg  $  subi regPCH,-5
#define Op_SPHL(reg)    movw regSP,reg  $  subi regSPH,-5

/*****************************************************************************
 ********************** Arithmetic and logic Macros **************************
 *****************************************************************************/

#define Op_ADD(src)     add regA,src  $  SaveFlags
#define Op_SUB(src)     sub regA,src  $  SaveFlags
#define Op_ANA(src)     and regA,src  $  clc  $  SaveFlags  $  Parity(regA)
#define Op_ORA(src)     or  regA,src  $  clc  $  SaveFlags  $  Parity(regA)
#define Op_ADC(src)     RestoreFlags  $  adc regA,src  $  SaveFlags
#define Op_SBB(src)     RestoreFlags  $  sez  $  sbc regA,src  $  SaveFlags  /* CAVEAT: sbc's Z flag */
#define Op_XRA(src)     eor regA,src  $  clc  $  SaveFlags  $  Parity(regA)
#define Op_CMP(src)     mov tmp,regA  $  sub tmp,src  $  SaveFlags

#define Op_INX(reg)     add reg##L,regOne  $  adc reg##H,regZero
#define Op_DCX(reg)     sub reg##L,regOne  $  sbc reg##H,regZero

#define Op_DAD(dst,src) add dst##L,src##L  $  adc dst##H,src##H  $  UpdateCarry
#define Op_DAD_SP(dst)  mov tmpH,regSPH  $  subi tmpH,5  $  add dst##L,regSPL  $  adc dst##H,tmpH $  UpdateCarry

/*****************************************************************************
 ********************** Rotations, Inc/Dec  **********************************
 *****************************************************************************/

#define Op_RLC          mov tmp,regA  $  lsl tmp   $  rol regA  $  UpdateCarry
#define Op_RRC          mov tmp,regA  $  lsr tmp   $  ror regA  $  UpdateCarry
#define Op_RAL          RestoreFlags  $  rol regA  $  UpdateCarry
#define Op_RAR          RestoreFlags  $  ror regA  $  UpdateCarry
#define Op_INR(reg)     RestoreFlags  $  inc reg   $  SaveFlags /* Carry not modified */
#define Op_DCR(reg)     RestoreFlags  $  dec reg   $  SaveFlags

#define Op_INC_M        ld tmp,EAddr  $  Op_INR(tmp)  $  st EAddr,tmp
#define Op_DEC_M        ld tmp,EAddr  $  Op_DCR(tmp)  $  st EAddr,tmp

/********************************************************************
 ************ Decimal Adjust for Addition : from AVR App Note 0938 **
 ********************************************************************/
#define Op_DAA                                                   \
    ldi  tmp,6        /* value to be added later */             $\
    RestoreFlags                                                $\
    brhs add_1        /* if half carry not set */               $\
    add  regA,tmp     /*     add 6 to LSD */                    $\
    brhs add_2        /*     if half carry not set (LSD <= 9) */$\
    sub  regA,tmp     /*         restore value */               $\
    rjmp add_2        /* else */                                $\
add_1:                                                          $\
    add  regA,tmp     /*     add 6 to LSD */                    $\
add_2:                                                          $\
    brcc add_2a                                                 $\
    sbr  Flags,1      /* set BCD carry */                       $\
add_2a:                                                         $\
    swap tmp          /* now 6 in high nibble */                $\
    add  regA,tmp     /* add 6 to MSD */                        $\
    brcs add_4        /* if carry not set (MSD <= 9) */         $\
    sbrs Flags,bitC   /*     if previous carry not set */       $\
    sub  regA,tmp     /*         restore value */               $\
    rjmp add_5                                                  $\
add_4:                                                          $\
    sbr  Flags,1      /* set BCD carry */                       $\
add_5:


#define Op_NOP
#define Op_HLT  sleep

#define Op_STC  sbr Flags,1
#define Op_CMA  com regA
#define Op_CMC  eor Flags,regOne
#define Op_EI   sts IntFlipFlop,regOne
#define Op_DI   sts IntFlipFlop,regZero
#define Op_IN   call input  $  mov regA,tmp
#define Op_OUT  mov tmp,regA  $  call output


/*****************************************************************************
 ********************** Stack operations Macros ******************************
 *****************************************************************************/

#define Op_XTHL(reg)ld  tmp,regSP    $  st  regSP,reg##L    $  mov reg##L,tmp  $\
                    ldd tmp,regSP+1  $  std regSP+1,reg##H  $  mov reg##H,tmp
#define Op_POP(reg) ld reg##L,regSP+  $  ld reg##H,regSP+
#define Op_POP_PSW  ld regPSW,regSP+  $  ld regA,regSP+    $  UncompressPSW

#define Op_PUSH(reg)st -regSP,reg##H  $  st -regSP,reg##L
#define Op_PUSH_PSW CompressPSW       $  st -regSP,regA    $  st -regSP,regPSW

#define PushPC      subi regPCH,5     $  st -regSP,regPCH  $  st -regSP,regPCL
#define PopPC       ld regPCL,regSP+  $  ld regPCH,regSP+  $  subi regPCH,-5

#define Op_RST(n)   PushPC  $  ldi regPCL,8*n  $  ldi regPCH,5

#define Op_CALL     Do_CALL: PushPC  $  movw regPC,EAddr
#define Op_CNZ      RestoreFlags  $  brne Do_CALL
#define Op_CZ       RestoreFlags  $  breq Do_CALL
#define Op_CNC      RestoreFlags  $  brcc Do_CALL
#define Op_CC       RestoreFlags  $  brcs Do_CALL
#define Op_CPO      RestoreFlags  $  brvc Do_CALL
#define Op_CPE      RestoreFlags  $  brvs Do_CALL
#define Op_CP       RestoreFlags  $  brpl Do_CALL
#define Op_CM       RestoreFlags  $  brmi Do_CALL

#define Op_RET      Do_RET: PopPC
#define Op_RNZ      RestoreFlags  $  brne Do_RET
#define Op_RZ       RestoreFlags  $  breq Do_RET
#define Op_RNC      RestoreFlags  $  brcc Do_RET
#define Op_RC       RestoreFlags  $  brcs Do_RET
#define Op_RPO      RestoreFlags  $  brvc Do_RET
#define Op_RPE      RestoreFlags  $  brvs Do_RET
#define Op_RP       RestoreFlags  $  brpl Do_RET
#define Op_RM       RestoreFlags  $  brmi Do_RET

/*****************************************************************************
 ********************** Branch operations Macros *****************************
 *****************************************************************************/

#define Op_JMP      movw regPC,EAddr
#define Op_JNZ      sbrs Flags,bitZ  $  movw regPC,EAddr
#define Op_JZ       sbrc Flags,bitZ  $  movw regPC,EAddr
#define Op_JNC      sbrs Flags,bitC  $  movw regPC,EAddr
#define Op_JC       sbrc Flags,bitC  $  movw regPC,EAddr
#define Op_JPO      sbrs Flags,bitPV $  movw regPC,EAddr
#define Op_JPE      sbrc Flags,bitPV $  movw regPC,EAddr
#define Op_JP       sbrs Flags,bitN  $  movw regPC,EAddr
#define Op_JM       sbrc Flags,bitN  $  movw regPC,EAddr
    
/*****************************************************************************
 ****************** Extended opcodes *****************************************
 *****************************************************************************/

/* BIT: Carry not modified, S and Z reflect AND operation, V = Z */
#define Op_BIT(bit)  \
    movw EAddr,tmp  $\
    ld   tmp,EAddr  $\
    RestoreFlags    $\
    andi tmp,1<<bit $\
    SaveFlags       $\
    CopyZtoV

#define Op_RES(bit) movw EAddr,tmp  $  ld tmp,EAddr  $  cbr tmp,1<<bit  $  st EAddr,tmp
#define Op_SET(bit) movw EAddr,tmp  $  ld tmp,EAddr  $  sbr tmp,1<<bit  $  st EAddr,tmp

#define NOT_IMPLEMENTED     call trap
#define Op_IN_C(reg)        NOT_IMPLEMENTED
#define Op_OUT_C(reg)       NOT_IMPLEMENTED
#define Op_RLD              NOT_IMPLEMENTED /* BCD left rotation */
#define Op_RRD              NOT_IMPLEMENTED /* BCD right rotation */
#define Op_IM(mode)         NOT_IMPLEMENTED /* set interrupt mode */
#define Op_RETI             NOT_IMPLEMENTED /* return from maskable interrupt */
#define Op_RETN             NOT_IMPLEMENTED /* return from non-maskable interrupt */
#define Op_LDIA             NOT_IMPLEMENTED /* move reg A to I */
#define Op_LDRA             NOT_IMPLEMENTED /* move reg A to R */
#define Op_LDAR             NOT_IMPLEMENTED /* move reg R to A */
#define Op_INI              NOT_IMPLEMENTED
#define Op_OUTI             NOT_IMPLEMENTED
#define Op_IND              NOT_IMPLEMENTED
#define Op_OUTD             NOT_IMPLEMENTED
#define Op_INIR             NOT_IMPLEMENTED
#define Op_OTIR             NOT_IMPLEMENTED
#define Op_INDR             NOT_IMPLEMENTED
#define Op_OTDR             NOT_IMPLEMENTED

/* register I not implemented, but get interrupt state */
#define Op_LDAI           \
    RestoreFlags         $\
    clr regA             $\
    SaveFlags            $\
    lds tmp,IntFlipFlop  $\
    bst tmp,0            $\
    bld Flags,bitPV

#define Exchg(reg1,reg2)    mov  tmp,reg1  $  mov  reg1,reg2  $  mov  reg2,tmp
#define ExchW(reg1,reg2)    movw tmp,reg1  $  movw reg1,reg2  $  movw reg2,tmp

#define Op_EXX      ExchW(regBC,regBC2)  $  ExchW(regDE,regDE2)  $  ExchW(regHL,regHL2)
#define Op_EXAF     Exchg(regA, regA2)   $  CompressPSW  $  Exchg(regPSW,regPSW2)  $  UncompressPSW

#define Op_SBCHL(reg)   RestoreFlags  $  sez  $  sbc regL,reg##L  $  sbc regH,reg##H  $  SaveFlags
#define Op_ADCHL(reg)         \
    RestoreFlags             $\
    adc  regL,reg##L         $\
    adc  regH,reg##H         $\
    clz                      $\
    SaveFlags                $\
    mov  tmp,regL            $\
    or   tmp,regH            $\
    brne 1f                  $\
    sbr  Flags,1<<bitZ       $\
1:

#define Op_NEG          neg  regA  $  SaveFlags
#define Op_SBCHLSP      movw tmp,regSP  $  subi tmpH,5  $  Op_SBCHL(tmp)
#define Op_ADCHLSP      movw tmp,regSP  $  subi tmpH,5  $  Op_ADCHL(tmp)

#define Op_STORE2(reg)  st EAddr+,reg##L  $  st EAddr,reg##H
#define Op_LOAD2(reg)   ld reg##L,EAddr+  $  ld reg##H,EAddr
#define Op_STORESP      st EAddr+,regSPL  $  mov tmpH,regSPH  $  subi tmpH,5  $  st EAddr,tmpH
#define Op_LOADSP       ld regSPL,EAddr+  $  ld regSPH,EAddr  $  subi regSPH,-5


#define LdMemHL         movw EAddr,regHL  $  subi EAddrH,-5  $  ld Operand,EAddr
#define StMemDE         movw EAddr,regDE  $  subi EAddrH,-5  $  st EAddr,Operand
#define Incr(idx)       add idx##L,regOne     $  adc idx##H,regZero
#define Decr(idx)       sub idx##L,regOne     $  sbc idx##H,regZero

#define TestBC      cbr Flags,1<<bitPV $ mov tmp,regB $ or tmp,regC $ breq 1f $ sbr Flags,1<<bitPV $1:

#define Op_LDI      LdMemHL $ StMemDE  $  Incr(regHL)  $ Incr(regDE) $ Decr(regBC) $ TestBC
#define Op_LDD      LdMemHL $ StMemDE  $  Decr(regHL)  $ Decr(regDE) $ Decr(regBC) $ TestBC
#define Op_CPI      LdMemHL $ cp regA,Operand  $  UpdateSZV $ Incr(regHL) $ Decr(regBC) $ TestBC
#define Op_CPD      LdMemHL $ cp regA,Operand  $  UpdateSZV $ Decr(regHL) $ Decr(regBC) $ TestBC
    
#define InitIR      push XH $ push XL $ movw X,regHL $ movw Z,regDE $ subi XH,-5 $ subi ZH,-5 $
#define InitDR      InitIR Incr(X) $ Incr(Z) $
#define EndIR       $ subi XH,5 $ subi ZH,5 $ movw regHL,X $ movw regDE,Z $ pop XL $ pop XH
#define EndDR       $ Decr(X) $ Decr(Z) EndIR

#define Op_LDIR     InitIR 1: ld tmp,X+ $ st Z+,tmp $ Decr(regBC) $ brne 1b $ cbr Flags,1<<bitPV EndIR
#define Op_LDDR     InitDR 1: ld tmp,-X $ st -Z,tmp $ Decr(regBC) $ brne 1b $ cbr Flags,1<<bitPV EndDR
#define Op_CPIR     cpir_loop: Op_CPI  $  sbrs Flags,bitZ  $  brne cpir_loop
#define Op_CPDR     cpdr_loop: Op_CPD  $  sbrs Flags,bitZ  $  brne cpdr_loop

/*****************************************************************************
 ****************** Relative jumps *******************************************
 *****************************************************************************/

#define Op_JR       Do_JR: AddRel(regPC)
#define Op_JRZ      RestoreFlags  $  breq Do_JR
#define Op_JRNZ     RestoreFlags  $  brne Do_JR
#define Op_JRC      RestoreFlags  $  brcs Do_JR
#define Op_JRNC     RestoreFlags  $  brcc Do_JR
#define Op_DJNZ     dec regB      $  brne Do_JR
 
/*****************************************************************************
 ****************** Initialization and debugging *****************************
 *****************************************************************************/


    .global startZ80
startZ80:
    clr  regZero
    ldi  regOne,1
    clr  regIXL         ; registers should not be initialized,
    clr  regIXH         ; but this helps compare correct execution
    clr  regIYL
    clr  regIYH
    clr  regB2
    clr  regC2
    clr  regD2
    clr  regE2
    clr  regH2
    clr  regL2
    sei
    SaveFlags
resetZ80:
    clr  regPCL
    clr  regPCH
    subi regPCH,-5
    FETCH


trap:
    sbiw  regPC,1
    rcall trace
1:  rjmp 1b

fetch_and_trace:
    cpi  regPCL,0
    brne 1f
    cpi  regPCH,1+5
    breq start_trace
1:
    cpi  regPCL,0x9A
    brne 1f
    cpi  regPCH,0xF1+5
    breq restore_trace
1:
    cpi  regPCL,0x05
    brne 1f
    cpi  regPCH,0+5
    breq save_trace
    rjmp 1f
start_trace:
    ldi  tmp,0xFF
    sts  traceFlag,tmp
    rjmp 1f
save_trace:
    lds  tmp,traceFlag
    lsr  tmp
    sts  traceFlag,tmp
    rjmp 1f
restore_trace:
    lds  tmp,traceFlag
    lsl  tmp
    sts  traceFlag,tmp

1:
    ld   ZL,regPC+
    lds  tmp,traceFlag
    sbrs tmp,7
    ret

#define write_space             call send_space
#define write(char)             ldi r16,char $  call uart_send
#define write_flag(char,bit)    ldi r16,'-'  $  sbrc r17,bit  $  write(char)
#define write_hex(reg)          mov r16,reg  $  call send_hex
#define write_addr(reg)         mov r16,reg##H  $  subi r16,5  $  call send_hex  $  write_hex(reg##L)

trace:
    push r17
    push r16
    write_space  $  write_space  $  write_space  $  write_space  $  write_space  $  write_space
 
/*
    write_hex(EAddrH)  $  write_hex(EAddrL)  $  write('=')
    ld   r16,Z  $  call send_hex
    write_space
*/

    write('A')  $  write('=')  $  write_hex(regA)
    write_space
    write('B')  $  write('C')  $  write('=')  $  write_hex(regB)  $  write_hex(regC)
    write_space
    write('D')  $  write('E')  $  write('=')  $  write_hex(regD)  $  write_hex(regE)
    write_space
    write('H')  $  write('L')  $  write('=')  $  write_hex(regH)  $  write_hex(regL)
    write_space
/*
    write('I')  $  write('X')  $  write('=')  $  write_hex(regIXH)  $  write_hex(regIXL)
    write_space
    write('I')  $  write('Y')  $  write('=')  $  write(regIYH)  $  write(regIYL)
    write_space
*/

    write_flag('S',bitN)
    write_flag('Z',bitZ)
    write('1')
    write('x') /*  write_flag('A',bitH)  */
    write('1')
    write_flag('V',bitPV)
    write('1')
    write_flag('C',bitC)

    write_space
    write('S')  $  write('P')  $  write('=')  $  write_addr(regSP)
    call send_newline

    sbiw regPC,1
    write_addr(regPC)
    write_space
    ld   r16,regPC  $  call send_hex
    write_space
    adiw regPC,1

    ld   r16,regPC  $  call send_hex
    call send_newline

    pop  r16
    pop  r17
    ret

/*****************************************************************************
 ****************** Opcodes 00 to 3f *****************************************
 *****************************************************************************/

Op_00:              Op_NOP              QFETCH
Op_10: Relative     Op_DJNZ             QFETCH
Op_20: Relative     Op_JRNZ             QFETCH
Op_30: Relative     Op_JRNC             QFETCH
Op_08:              Op_EXAF             QFETCH
Op_18: Relative     Op_JR               QFETCH
Op_28: Relative     Op_JRZ              QFETCH
Op_38: Relative     Op_JRC              QFETCH

Op_01:              Op_LXI(regBC)       QFETCH
Op_11:              Op_LXI(regDE)       QFETCH
Op_21:              Op_LXI(regHL)       QFETCH
Op_31:              Op_LXI_SP           QFETCH
Op_09:              Op_DAD(regHL,regBC) QFETCH
Op_19:              Op_DAD(regHL,regDE) QFETCH
Op_29:              Op_DAD(regHL,regHL) QFETCH
Op_39:              Op_DAD_SP(regHL)    QFETCH

Op_02:              Op_STAX(regBC)       FETCH
Op_12:              Op_STAX(regDE)       FETCH
Op_22: Addr         Op_SHLD(regHL)       FETCH
Op_32: Addr         Op_STA               FETCH
Op_0a:              Op_LDAX(regBC)       FETCH
Op_1a:              Op_LDAX(regDE)       FETCH
Op_2a: Addr         Op_LHLD(regHL)       FETCH
Op_3a: Addr         Op_LDA               FETCH

Op_03:              Op_INX(regBC)       QFETCH
Op_13:              Op_INX(regDE)       QFETCH
Op_23:              Op_INX(regHL)       QFETCH
Op_33:              Op_INX(regSP)       QFETCH
Op_0b:              Op_DCX(regBC)       QFETCH
Op_1b:              Op_DCX(regDE)       QFETCH
Op_2b:              Op_DCX(regHL)       QFETCH
Op_3b:              Op_DCX(regSP)       QFETCH

Op_04:              Op_INR(regB)        QFETCH
Op_14:              Op_INR(regD)        QFETCH
Op_24:              Op_INR(regH)        QFETCH
Op_34: EAddrHL      Op_INC_M             FETCH
Op_0c:              Op_INR(regC)        QFETCH
Op_1c:              Op_INR(regE)        QFETCH
Op_2c:              Op_INR(regL)        QFETCH
Op_3c:              Op_INR(regA)        QFETCH

Op_05:              Op_DCR(regB)        QFETCH
Op_15:              Op_DCR(regD)        QFETCH
Op_25:              Op_DCR(regH)        QFETCH
Op_35: EAddrHL      Op_DEC_M             FETCH
Op_0d:              Op_DCR(regC)        QFETCH
Op_1d:              Op_DCR(regE)        QFETCH
Op_2d:              Op_DCR(regL)        QFETCH
Op_3d:              Op_DCR(regA)        QFETCH

Op_06:              Op_MVI(regB)        QFETCH
Op_16:              Op_MVI(regD)        QFETCH
Op_26:              Op_MVI(regH)        QFETCH
Op_36: EAddrHL Imm  Op_ST_M(Operand)     FETCH
Op_0e:              Op_MVI(regC)        QFETCH
Op_1e:              Op_MVI(regE)        QFETCH
Op_2e:              Op_MVI(regL)        QFETCH
Op_3e:              Op_MVI(regA)        QFETCH

Op_07:              Op_RLC              QFETCH
Op_17:              Op_RAL              QFETCH
Op_27:              Op_DAA              QFETCH
Op_37:              Op_STC              QFETCH
Op_0f:              Op_RRC              QFETCH
Op_1f:              Op_RAR              QFETCH
Op_2f:              Op_CMA              QFETCH
Op_3f:              Op_CMC              QFETCH

/*****************************************************************************
 ****************** Opcodes 40 to 7f *****************************************
 *****************************************************************************/

Op_40:              Op_MOV(regB,regB)   QFETCH
Op_41:              Op_MOV(regB,regC)   QFETCH
Op_42:              Op_MOV(regB,regD)   QFETCH
Op_43:              Op_MOV(regB,regE)   QFETCH
Op_44:              Op_MOV(regB,regH)   QFETCH
Op_45:              Op_MOV(regB,regL)   QFETCH
Op_46: EAddrHL      Op_LD_M(regB)        FETCH
Op_47:              Op_MOV(regB,regA)   QFETCH
Op_48:              Op_MOV(regC,regB)   QFETCH
Op_49:              Op_MOV(regC,regC)   QFETCH
Op_4a:              Op_MOV(regC,regD)   QFETCH
Op_4b:              Op_MOV(regC,regE)   QFETCH
Op_4c:              Op_MOV(regC,regH)   QFETCH
Op_4d:              Op_MOV(regC,regL)   QFETCH
Op_4e: EAddrHL      Op_LD_M(regC)        FETCH
Op_4f:              Op_MOV(regC,regA)   QFETCH
Op_50:              Op_MOV(regD,regB)   QFETCH
Op_51:              Op_MOV(regD,regC)   QFETCH
Op_52:              Op_MOV(regD,regD)   QFETCH
Op_53:              Op_MOV(regD,regE)   QFETCH
Op_54:              Op_MOV(regD,regH)   QFETCH
Op_55:              Op_MOV(regD,regL)   QFETCH
Op_56: EAddrHL      Op_LD_M(regD)        FETCH
Op_57:              Op_MOV(regD,regA)   QFETCH
Op_58:              Op_MOV(regE,regB)   QFETCH
Op_59:              Op_MOV(regE,regC)   QFETCH
Op_5a:              Op_MOV(regE,regD)   QFETCH
Op_5b:              Op_MOV(regE,regE)   QFETCH
Op_5c:              Op_MOV(regE,regH)   QFETCH
Op_5d:              Op_MOV(regE,regL)   QFETCH
Op_5e: EAddrHL      Op_LD_M(regE)        FETCH
Op_5f:              Op_MOV(regE,regA)   QFETCH
Op_60:              Op_MOV(regH,regB)   QFETCH
Op_61:              Op_MOV(regH,regC)   QFETCH
Op_62:              Op_MOV(regH,regD)   QFETCH
Op_63:              Op_MOV(regH,regE)   QFETCH
Op_64:              Op_MOV(regH,regH)   QFETCH
Op_65:              Op_MOV(regH,regL)   QFETCH
Op_66: EAddrHL      Op_LD_M(regH)        FETCH
Op_67:              Op_MOV(regH,regA)   QFETCH
Op_68:              Op_MOV(regL,regB)   QFETCH
Op_69:              Op_MOV(regL,regC)   QFETCH
Op_6a:              Op_MOV(regL,regD)   QFETCH
Op_6b:              Op_MOV(regL,regE)   QFETCH
Op_6c:              Op_MOV(regL,regH)   QFETCH
Op_6d:              Op_MOV(regL,regL)   QFETCH
Op_6e: EAddrHL      Op_LD_M(regL)        FETCH
Op_6f:              Op_MOV(regL,regA)   QFETCH
Op_70: EAddrHL      Op_ST_M(regB)        FETCH
Op_71: EAddrHL      Op_ST_M(regC)        FETCH
Op_72: EAddrHL      Op_ST_M(regD)        FETCH
Op_73: EAddrHL      Op_ST_M(regE)        FETCH
Op_74: EAddrHL      Op_ST_M(regH)        FETCH
Op_75: EAddrHL      Op_ST_M(regL)        FETCH
Op_76:              Op_HLT              QFETCH
Op_77: EAddrHL      Op_ST_M(regA)        FETCH
Op_78:              Op_MOV(regA,regB)   QFETCH
Op_79:              Op_MOV(regA,regC)   QFETCH
Op_7a:              Op_MOV(regA,regD)   QFETCH
Op_7b:              Op_MOV(regA,regE)   QFETCH
Op_7c:              Op_MOV(regA,regH)   QFETCH
Op_7d:              Op_MOV(regA,regL)   QFETCH
Op_7e: EAddrHL      Op_LD_M(regA)        FETCH
Op_7f:              Op_MOV(regA,regA)   QFETCH

/*****************************************************************************
 ****************** Opcodes 80 to bf *****************************************
 *****************************************************************************/

Op_80:              Op_ADD(regB)        QFETCH
Op_81:              Op_ADD(regC)        QFETCH
Op_82:              Op_ADD(regD)        QFETCH
Op_83:              Op_ADD(regE)        QFETCH
Op_84:              Op_ADD(regH)        QFETCH
Op_85:              Op_ADD(regL)        QFETCH
Op_86: MemHL        Op_ADD(Operand)      FETCH
Op_87:              Op_ADD(regA)        QFETCH

Op_88:              Op_ADC(regB)        QFETCH
Op_89:              Op_ADC(regC)        QFETCH
Op_8a:              Op_ADC(regD)        QFETCH
Op_8b:              Op_ADC(regE)        QFETCH
Op_8c:              Op_ADC(regH)        QFETCH
Op_8d:              Op_ADC(regL)        QFETCH
Op_8e: MemHL        Op_ADC(Operand)      FETCH
Op_8f:              Op_ADC(regA)        QFETCH

Op_90:              Op_SUB(regB)        QFETCH
Op_91:              Op_SUB(regC)        QFETCH
Op_92:              Op_SUB(regD)        QFETCH
Op_93:              Op_SUB(regE)        QFETCH
Op_94:              Op_SUB(regH)        QFETCH
Op_95:              Op_SUB(regL)        QFETCH
Op_96: MemHL        Op_SUB(Operand)      FETCH
Op_97:              Op_SUB(regA)        QFETCH

Op_98:              Op_SBB(regB)        QFETCH
Op_99:              Op_SBB(regC)        QFETCH
Op_9a:              Op_SBB(regD)        QFETCH
Op_9b:              Op_SBB(regE)        QFETCH
Op_9c:              Op_SBB(regH)        QFETCH
Op_9d:              Op_SBB(regL)        QFETCH
Op_9e: MemHL        Op_SBB(Operand)      FETCH
Op_9f:              Op_SBB(regA)        QFETCH

Op_a0:              Op_ANA(regB)         FETCH
Op_a1:              Op_ANA(regC)         FETCH
Op_a2:              Op_ANA(regD)         FETCH
Op_a3:              Op_ANA(regE)         FETCH
Op_a4:              Op_ANA(regH)         FETCH
Op_a5:              Op_ANA(regL)         FETCH
Op_a6: MemHL        Op_ANA(Operand)      FETCH
Op_a7:              Op_ANA(regA)         FETCH

Op_a8:              Op_XRA(regB)         FETCH
Op_a9:              Op_XRA(regC)         FETCH
Op_aa:              Op_XRA(regD)         FETCH
Op_ab:              Op_XRA(regE)         FETCH
Op_ac:              Op_XRA(regH)         FETCH
Op_ad:              Op_XRA(regL)         FETCH
Op_ae: MemHL        Op_XRA(Operand)      FETCH
Op_af:              Op_XRA(regA)         FETCH

Op_b0:              Op_ORA(regB)         FETCH
Op_b1:              Op_ORA(regC)         FETCH
Op_b2:              Op_ORA(regD)         FETCH
Op_b3:              Op_ORA(regE)         FETCH
Op_b4:              Op_ORA(regH)         FETCH
Op_b5:              Op_ORA(regL)         FETCH
Op_b6: MemHL        Op_ORA(Operand)      FETCH
Op_b7:              Op_ORA(regA)         FETCH

Op_b8:              Op_CMP(regB)        QFETCH
Op_b9:              Op_CMP(regC)        QFETCH
Op_ba:              Op_CMP(regD)        QFETCH
Op_bb:              Op_CMP(regE)        QFETCH
Op_bc:              Op_CMP(regH)        QFETCH
Op_bd:              Op_CMP(regL)        QFETCH
Op_be: MemHL        Op_CMP(Operand)      FETCH
Op_bf:              Op_CMP(regA)        QFETCH

/*****************************************************************************
 ****************** Opcodes c0 to ff *****************************************
 *****************************************************************************/

Op_c0:              Op_RNZ              QFETCH
Op_d0:              Op_RNC              QFETCH
Op_e0:              Op_RPO              QFETCH
Op_f0:              Op_RP               QFETCH
Op_c8:              Op_RZ               QFETCH
Op_d8:              Op_RC               QFETCH
Op_e8:              Op_RPE              QFETCH
Op_f8:              Op_RM               QFETCH

Op_c9:              Op_RET              QFETCH
Op_d9:              Op_EXX              QFETCH
Op_e9:              Op_PCHL(regHL)      QFETCH
Op_f9:              Op_SPHL(regHL)      QFETCH

Op_c2: Addr         Op_JNZ               FETCH
Op_d2: Addr         Op_JNC               FETCH
Op_e2: Addr         Op_JPO               FETCH
Op_f2: Addr         Op_JP                FETCH
Op_ca: Addr         Op_JZ                FETCH
Op_da: Addr         Op_JC                FETCH
Op_ea: Addr         Op_JPE               FETCH
Op_fa: Addr         Op_JM                FETCH

Op_c4: Addr         Op_CNZ               FETCH
Op_d4: Addr         Op_CNC               FETCH
Op_e4: Addr         Op_CPO               FETCH
Op_f4: Addr         Op_CP                FETCH

Op_cd: Addr         Op_CALL              FETCH

Op_cc: Addr         Op_CZ                FETCH
Op_dc: Addr         Op_CC                FETCH
Op_ec: Addr         Op_CPE               FETCH
Op_fc: Addr         Op_CM                FETCH

Op_c6: Imm          Op_ADD(Operand)     QFETCH
Op_d6: Imm          Op_SUB(Operand)     QFETCH
Op_e6: Imm          Op_ANA(Operand)      FETCH
Op_f6: Imm          Op_ORA(Operand)      FETCH
Op_ce: Imm          Op_ADC(Operand)     QFETCH
Op_de: Imm          Op_SBB(Operand)     QFETCH
Op_ee: Imm          Op_XRA(Operand)      FETCH
Op_fe: Imm          Op_CMP(Operand)     QFETCH

Op_c1:              Op_POP(regBC)       QFETCH
Op_d1:              Op_POP(regDE)       QFETCH
Op_e1:              Op_POP(regHL)       QFETCH
Op_f1:              Op_POP_PSW          QFETCH

Op_c5:              Op_PUSH(regBC)      QFETCH
Op_d5:              Op_PUSH(regDE)      QFETCH
Op_e5:              Op_PUSH(regHL)      QFETCH
Op_f5:              Op_PUSH_PSW         QFETCH

Op_c3: Addr         Op_JMP               FETCH
Op_d3: Imm          Op_OUT              QFETCH
Op_e3:              Op_XTHL(regHL)      QFETCH
Op_f3:              Op_DI               QFETCH

Op_db: Imm          Op_IN               QFETCH
Op_eb:              Op_XCHG             QFETCH
Op_fb:              Op_EI               QFETCH

Op_c7:              Op_RST(0)           QFETCH
Op_d7:              Op_RST(2)           QFETCH
Op_e7:              Op_RST(4)           QFETCH
Op_f7:              Op_RST(6)           QFETCH
Op_cf:              Op_RST(1)           QFETCH
Op_df:              Op_RST(3)           QFETCH
Op_ef:              Op_RST(5)           QFETCH
Op_ff:              Op_RST(7)           QFETCH

/*****************************************************************************
 ****************** Prefixes CB, DD, ED, FD **********************************
 *****************************************************************************/

IX_dd:
IY_dd:
Op_dd:  /* IX index prefix */
    ldi  ZH,hi8(pm(IXOpcodeTable)) 
    ld   ZL,regPC+
    ijmp

IX_fd:
IY_fd:
Op_fd:  /* IY index prefix */
    ldi  ZH,hi8(pm(IYOpcodeTable)) 
    ld   ZL,regPC+
    ijmp

IX_ed:
IY_ed:
Op_ed:  /* Extended opcodes */
    ldi  ZH,hi8(pm(ExtOpcodeTable)) 
    ld   ZL,regPC+
    subi ZL,-0x40       /* shift opcodes to second half (80-ff) */
    ijmp

Op_cb:  /* CB prefix: partial decode to save space */
    ld   ZL,regPC+      /* get opcode */
    mov  tmp,ZL
    andi tmp,7          /* compute address of register */
    eor  tmp,regOne     /* reverse register order in pair */
    clr  tmpH
    cpi  tmp,7
    brne 3f
                        /* compute address contained in HL */
    mov  tmpH,regH
    mov  tmp,regL
    subi tmpH,-5        /* tmp is address of operand */

3:  lsr  ZL
    lsr  ZL
    lsr  ZL
    ori  ZL,0xC0    /* inside ExtOpcodeTable */
    ldi  ZH,hi8(pm(ExtOpcodeTable))
    ijmp

No_op: FETCH 

/*****************************************************************************/
/* Opcode table in the middle so that relative jumps can reach every opcode  */
    .align 9        ; 2^9 to be sure the OpcodeTable starts on a code page boundary

#define RelJumps0_7(name) \
    rjmp name##0  $  rjmp name##1  $  rjmp name##2  $  rjmp name##3  $\
    rjmp name##4  $  rjmp name##5  $  rjmp name##6  $  rjmp name##7 
#define RelJumps(name) RelJumps0_7(name)  $\
    rjmp name##8  $  rjmp name##9  $  rjmp name##a  $  rjmp name##b  $\
    rjmp name##c  $  rjmp name##d  $  rjmp name##e  $  rjmp name##f

OpcodeTable:
    RelJumps(Op_0)
    RelJumps(Op_1)
    RelJumps(Op_2)
    RelJumps(Op_3)
    RelJumps(Op_4)
    RelJumps(Op_5)
    RelJumps(Op_6)
    RelJumps(Op_7)
    RelJumps(Op_8)
    RelJumps(Op_9)
    RelJumps(Op_a)
    RelJumps(Op_b)
    RelJumps(Op_c)
    RelJumps(Op_d)
    RelJumps(Op_e)
    RelJumps(Op_f)

#define _           rjmp trap2 $
#define X(code)     rjmp IX_##code $
#define Y(code)     rjmp IY_##code $

IXOpcodeTable:
   _     _     _     _     _     _     _     _     _   X(09)   _     _     _     _     _     _  
   _     _     _     _     _     _     _     _     _   X(19)   _     _     _     _     _     _  
   _   X(21) X(22) X(23)   _     _     _     _     _   X(29) X(2a) X(2b)   _     _     _     _  
   _     _     _     _   X(34) X(35) X(36)   _     _   X(39)   _     _     _     _     _     _  
   _     _     _     _     _     _   X(46)   _     _     _     _     _     _     _   X(4e)   _     
   _     _     _     _     _     _   X(56)   _     _     _     _     _     _     _   X(5e)   _     
   _     _     _     _     _     _   X(66)   _     _     _     _     _     _     _   X(6e)   _     
 X(70) X(71) X(72) X(73) X(74) X(75)   _   X(77)   _     _     _     _     _     _   X(7e)   _  
   _     _     _     _     _     _   X(86)   _     _     _     _     _     _     _   X(8e)   _     
   _     _     _     _     _     _   X(96)   _     _     _     _     _     _     _   X(9e)   _     
   _     _     _     _     _     _   X(a6)   _     _     _     _     _     _     _   X(ae)   _     
   _     _     _     _     _     _   X(b6)   _     _     _     _     _     _     _   X(be)   _     
   _     _     _     _     _     _     _     _     _     _     _   X(cb)   _     _     _     _  
   _     _     _     _     _     _     _     _     _     _     _     _     _   X(dd)   _     _  
   _   X(e1)   _   X(e3)   _   X(e5)   _     _     _   X(e9)   _     _     _   X(ed)   _     _  
   _     _     _     _     _     _     _     _     _   X(f9)   _     _     _   X(fd)   _     _  

IYOpcodeTable:
   _     _     _     _     _     _     _     _     _   Y(09)   _     _     _     _     _     _  
   _     _     _     _     _     _     _     _     _   Y(19)   _     _     _     _     _     _  
   _   Y(21) Y(22) Y(23)   _     _     _     _     _   Y(29) Y(2a) Y(2b)   _     _     _     _  
   _     _     _     _   Y(34) Y(35) Y(36)   _     _   Y(39)   _     _     _     _     _     _  
   _     _     _     _     _     _   Y(46)   _     _     _     _     _     _     _   Y(4e)   _     
   _     _     _     _     _     _   Y(56)   _     _     _     _     _     _     _   Y(5e)   _     
   _     _     _     _     _     _   Y(66)   _     _     _     _     _     _     _   Y(6e)   _     
 Y(70) Y(71) Y(72) Y(73) Y(74) Y(75)   _   Y(77)   _     _     _     _     _     _   Y(7e)   _  
   _     _     _     _     _     _   Y(86)   _     _     _     _     _     _     _   Y(8e)   _     
   _     _     _     _     _     _   Y(96)   _     _     _     _     _     _     _   Y(9e)   _     
   _     _     _     _     _     _   Y(a6)   _     _     _     _     _     _     _   Y(ae)   _     
   _     _     _     _     _     _   Y(b6)   _     _     _     _     _     _     _   Y(be)   _     
   _     _     _     _     _     _     _     _     _     _     _   Y(cb)   _     _     _     _  
   _     _     _     _     _     _     _     _     _     _     _     _     _   Y(dd)   _     _  
   _   Y(e1)   _   Y(e3)   _   Y(e5)   _     _     _   Y(e9)   _     _     _   Y(ed)   _     _  
   _     _     _     _     _     _     _     _     _   Y(f9)   _     _     _   Y(fd)   _     _  


ExtOpcodeTable: 
ParityTable:    /* first 128 opcodes replaced by 256 parity bytes */
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1

/* extended (ED) opcodes 40-7f moved to index 0x80 in ExtOpcodeTable */
    RelJumps(Ext_4)
    RelJumps(Ext_5)
    RelJumps(Ext_6)
    RelJumps(Ext_7)

/* Bit (CB) opcodes divided by 8 and moved to index 0xC0-0xDF in ExtOpcodeTable */
    rjmp Ext_RLC       
    rjmp Ext_RRC
    rjmp Ext_RL
    rjmp Ext_RR
    rjmp Ext_SLA
    rjmp Ext_SRA
    rjmp Ext_SLL
    rjmp Ext_SRL

    RelJumps0_7(Ext_BIT)
    RelJumps0_7(Ext_RES)
    RelJumps0_7(Ext_SET)

/* extended (ED) opcodes a0-bf moved to index 0xE0-0xFF in ExtOpcodeTable */
    RelJumps(Ext_a)
    RelJumps(Ext_b)

/*****************************************************************************
 ****************** IX instructions ******************************************
 *****************************************************************************/
trap2:              jmp trap

IX_09:              Op_DAD(regIX,regBC)     FETCH
IX_19:              Op_DAD(regIX,regDE)     FETCH
IX_29:              Op_DAD(regIX,regIX)     FETCH
IX_39:              Op_DAD_SP(regIX)        FETCH

IX_21:              Op_LXI(regIX)           FETCH
IX_22: Addr         Op_SHLD(regIX)          FETCH
IX_2a: Addr         Op_LHLD(regIX)          FETCH

IX_23:              Op_INX(regIX)           FETCH
IX_2b:              Op_DCX(regIX)           FETCH

IX_34: EAddrIXd     Op_INC_M                FETCH
IX_35: EAddrIXd     Op_DEC_M                FETCH
IX_36: EAddrIXd Imm Op_ST_M(Operand)        FETCH

IX_46: EAddrIXd     Op_LD_M(regB)           FETCH
IX_4e: EAddrIXd     Op_LD_M(regC)           FETCH
IX_56: EAddrIXd     Op_LD_M(regD)           FETCH
IX_5e: EAddrIXd     Op_LD_M(regE)           FETCH
IX_66: EAddrIXd     Op_LD_M(regH)           FETCH
IX_6e: EAddrIXd     Op_LD_M(regL)           FETCH
IX_7e: EAddrIXd     Op_LD_M(regA)           FETCH

IX_70: EAddrIXd     Op_ST_M(regB)           FETCH
IX_71: EAddrIXd     Op_ST_M(regC)           FETCH
IX_72: EAddrIXd     Op_ST_M(regD)           FETCH
IX_73: EAddrIXd     Op_ST_M(regE)           FETCH
IX_74: EAddrIXd     Op_ST_M(regH)           FETCH
IX_75: EAddrIXd     Op_ST_M(regL)           FETCH
IX_77: EAddrIXd     Op_ST_M(regA)           FETCH

IX_86: MemIXd       Op_ADD(Operand)         FETCH
IX_8e: MemIXd       Op_ADC(Operand)         FETCH
IX_96: MemIXd       Op_SUB(Operand)         FETCH
IX_9e: MemIXd       Op_SBB(Operand)         FETCH
IX_a6: MemIXd       Op_ANA(Operand)         FETCH
IX_ae: MemIXd       Op_XRA(Operand)         FETCH
IX_b6: MemIXd       Op_ORA(Operand)         FETCH
IX_be: MemIXd       Op_CMP(Operand)         FETCH

IX_e1:              Op_POP(regIX)           FETCH
IX_e3:              Op_XTHL(regIX)          FETCH
IX_e5:              Op_PUSH(regIX)          FETCH
IX_e9:              Op_PCHL(regIX)          FETCH
IX_f9:              Op_SPHL(regIX)          FETCH

IX_cb: /* DD CB prefix: partial decode to save space */
    ld   Operand,regPC+ /* displacement stands first !! */
    ld   ZL,regPC+      /* and opcode comes next */
    movw tmp,regIX
    add  tmp,Operand    /* add displacement */
    adc  tmpH,regZero
    sbrc Operand,7  
    dec  tmpH
    subi tmpH,-5        /* tmp is now address of operand */
    lsr  ZL             /* divide opcode by 8 */
    lsr  ZL
    lsr  ZL
    ori  ZL,0xC0        /* 0xC0-0xDF inside ExtOpcodeTable */
    ldi  ZH,hi8(pm(ExtOpcodeTable))
    ijmp

/*****************************************************************************
 ****************** IY instructions ******************************************
 *****************************************************************************/
IY_09:              Op_DAD(regIY,regBC)     FETCH
IY_19:              Op_DAD(regIY,regDE)     FETCH
IY_29:              Op_DAD(regIY,regIY)     FETCH
IY_39:              Op_DAD_SP(regIY)        FETCH

IY_21:              Op_LXI(regIY)           FETCH
IY_22: Addr         Op_SHLD(regIY)          FETCH
IY_2a: Addr         Op_LHLD(regIY)          FETCH

IY_23:              Op_INX(regIY)           FETCH
IY_2b:              Op_DCX(regIY)           FETCH

IY_34: EAddrIYd     Op_INC_M                FETCH
IY_35: EAddrIYd     Op_DEC_M                FETCH
IY_36: EAddrIYd Imm Op_ST_M(Operand)        FETCH

IY_46: EAddrIYd     Op_LD_M(regB)           FETCH
IY_4e: EAddrIYd     Op_LD_M(regC)           FETCH
IY_56: EAddrIYd     Op_LD_M(regD)           FETCH
IY_5e: EAddrIYd     Op_LD_M(regE)           FETCH
IY_66: EAddrIYd     Op_LD_M(regH)           FETCH
IY_6e: EAddrIYd     Op_LD_M(regL)           FETCH
IY_7e: EAddrIYd     Op_LD_M(regA)           FETCH

IY_70: EAddrIYd     Op_ST_M(regB)           FETCH
IY_71: EAddrIYd     Op_ST_M(regC)           FETCH
IY_72: EAddrIYd     Op_ST_M(regD)           FETCH
IY_73: EAddrIYd     Op_ST_M(regE)           FETCH
IY_74: EAddrIYd     Op_ST_M(regH)           FETCH
IY_75: EAddrIYd     Op_ST_M(regL)           FETCH
IY_77: EAddrIYd     Op_ST_M(regA)           FETCH

IY_86: MemIYd       Op_ADD(Operand)         FETCH
IY_8e: MemIYd       Op_ADC(Operand)         FETCH
IY_96: MemIYd       Op_SUB(Operand)         FETCH
IY_9e: MemIYd       Op_SBB(Operand)         FETCH
IY_a6: MemIYd       Op_ANA(Operand)         FETCH
IY_ae: MemIYd       Op_XRA(Operand)         FETCH
IY_b6: MemIYd       Op_ORA(Operand)         FETCH
IY_be: MemIYd       Op_CMP(Operand)         FETCH

IY_e1:              Op_POP(regIY)           FETCH
IY_e3:              Op_XTHL(regIY)          FETCH
IY_e5:              Op_PUSH(regIY)          FETCH
IY_e9:              Op_PCHL(regIY)          FETCH
IY_f9:              Op_SPHL(regIY)          FETCH

IY_cb: /* DD CB prefix: partial decode to save space */
    ld   Operand,regPC+ /* displacement stands first !! */
    ld   ZL,regPC+      /* and opcode comes next */
    movw tmp,regIY
    add  tmp,Operand    /* add displacement */
    adc  tmpH,regZero
    sbrc Operand,7  
    dec  tmpH
    subi tmpH,-5        /* tmp is now address of operand */
    lsr  ZL             /* divide opcode by 8 */
    lsr  ZL
    lsr  ZL
    ori  ZL,0xC0        /* 0xC0-0xDF inside ExtOpcodeTable */
    ldi  ZH,hi8(pm(ExtOpcodeTable))
    ijmp

/*****************************************************************************
 ****************** Extended (ED) instructions 40-7f *************************
 *****************************************************************************/
Ext_40:             Op_IN_C(regB)        FETCH
Ext_41:             Op_OUT_C(regB)       FETCH
Ext_42:             Op_SBCHL(regBC)      FETCH
Ext_43: Addr        Op_STORE2(regBC)     FETCH
Ext_44:             Op_NEG               FETCH
Ext_45:             Op_RETN              FETCH
Ext_46:             Op_IM(0)             FETCH
Ext_47:             Op_LDIA              FETCH
Ext_48:             Op_IN_C(regC)        FETCH
Ext_49:             Op_OUT_C(regC)       FETCH
Ext_4a:             Op_ADCHL(regBC)      FETCH
Ext_4b: Addr        Op_LOAD2(regBC)      FETCH
Ext_4c:             Op_NEG               FETCH
Ext_4d:             Op_RETI              FETCH
Ext_4e:             Op_IM(0)             FETCH
Ext_4f:             Op_LDRA              FETCH

Ext_50:             Op_IN_C(regD)        FETCH
Ext_51:             Op_OUT_C(regD)       FETCH
Ext_52:             Op_SBCHL(regDE)      FETCH
Ext_53: Addr        Op_STORE2(regDE)     FETCH
Ext_54:             Op_NEG               FETCH
Ext_55:             Op_RETN              FETCH
Ext_56:             Op_IM(1)             FETCH
Ext_57:             Op_LDAI              FETCH
Ext_58:             Op_IN_C(regE)        FETCH
Ext_59:             Op_OUT_C(regE)       FETCH
Ext_5a:             Op_ADCHL(regDE)      FETCH
Ext_5b: Addr        Op_LOAD2(regDE)      FETCH
Ext_5c:             Op_NEG               FETCH
Ext_5d:             Op_RETN              FETCH
Ext_5e:             Op_IM(2)             FETCH
Ext_5f:             Op_LDAR              FETCH
 
Ext_60:             Op_IN_C(regH)        FETCH
Ext_61:             Op_OUT_C(regH)       FETCH
Ext_62:             Op_SBCHL(regHL)      FETCH
Ext_63: Addr        Op_STORE2(regHL)     FETCH
Ext_64:             Op_NEG               FETCH
Ext_65:             Op_RETN              FETCH
Ext_66:             Op_IM(0)             FETCH
Ext_67:             Op_RRD               FETCH
Ext_68:             Op_IN_C(regL)        FETCH
Ext_69:             Op_OUT_C(regL)       FETCH
Ext_6a:             Op_ADCHL(regHL)      FETCH
Ext_6b: Addr        Op_LOAD2(regHL)      FETCH
Ext_6c:             Op_NEG               FETCH
Ext_6d:             Op_RETN              FETCH
Ext_6e:             Op_IM(0)             FETCH
Ext_6f:             Op_RLD

Ext_70:
Ext_71:                                  FETCH
Ext_72:             Op_SBCHLSP           FETCH
Ext_73: Addr        Op_STORESP           FETCH
Ext_74:             Op_NEG               FETCH
Ext_75:             Op_RETN              FETCH
Ext_76:             Op_IM(1)
Ext_77:                                  FETCH
Ext_78:             Op_IN_C(regA)        FETCH
Ext_79:             Op_OUT_C(regA)       FETCH
Ext_7a:             Op_ADCHLSP           FETCH
Ext_7b: Addr        Op_LOADSP            FETCH
Ext_7c:             Op_NEG               FETCH
Ext_7d:             Op_RETN              FETCH
Ext_7e:             Op_IM(2)
Ext_7f:                                  FETCH

/*****************************************************************************
 ****************** Bit instructions *****************************************
 *****************************************************************************/
Ext_RLC:
    movw EAddr,tmp
    ld   tmp,EAddr
    mov  Operand,tmp
    lsl  Operand
    rol  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_RRC:
    movw EAddr,tmp
    ld   tmp,EAddr
    mov  Operand,tmp
    lsr  Operand
    ror  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH
    
Ext_SLL: /* unofficial opcode: shift left and enter a 1 */
    sbr  Flags,1<<bitC
Ext_RL:
    movw EAddr,tmp
    ld   tmp,EAddr
    RestoreFlags
    rol  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_RR:
    movw EAddr,tmp
    ld   tmp,EAddr
    RestoreFlags
    ror  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_SLA:
    movw EAddr,tmp
    ld   tmp,EAddr
    lsl  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_SRA:
    movw EAddr,tmp
    ld   tmp,EAddr
    asr  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_SRL:
    movw EAddr,tmp
    ld   tmp,EAddr
    lsr  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_BIT0:           Op_BIT(0)            FETCH
Ext_BIT1:           Op_BIT(1)            FETCH
Ext_BIT2:           Op_BIT(2)            FETCH
Ext_BIT3:           Op_BIT(3)            FETCH
Ext_BIT4:           Op_BIT(4)            FETCH
Ext_BIT5:           Op_BIT(5)            FETCH
Ext_BIT6:           Op_BIT(6)            FETCH
Ext_BIT7:           Op_BIT(7)            FETCH

Ext_RES0:           Op_RES(0)            FETCH
Ext_RES1:           Op_RES(1)            FETCH
Ext_RES2:           Op_RES(2)            FETCH
Ext_RES3:           Op_RES(3)            FETCH
Ext_RES4:           Op_RES(4)            FETCH
Ext_RES5:           Op_RES(5)            FETCH
Ext_RES6:           Op_RES(6)            FETCH
Ext_RES7:           Op_RES(7)            FETCH

Ext_SET0:           Op_SET(0)            FETCH
Ext_SET1:           Op_SET(1)            FETCH
Ext_SET2:           Op_SET(2)            FETCH
Ext_SET3:           Op_SET(3)            FETCH
Ext_SET4:           Op_SET(4)            FETCH
Ext_SET5:           Op_SET(5)            FETCH
Ext_SET6:           Op_SET(6)            FETCH
Ext_SET7:           Op_SET(7)            FETCH

/*****************************************************************************
 ****************** Extended (ED) instructions a0-bf *************************
 *****************************************************************************/
Ext_a0:             Op_LDI               FETCH
Ext_a1:             Op_CPI               FETCH
Ext_a2:             Op_INI               FETCH
Ext_a3:             Op_OUTI              FETCH
Ext_a4:
Ext_a5:
Ext_a6:
Ext_a7:                                  FETCH
Ext_a8:             Op_LDD               FETCH
Ext_a9:             Op_CPD               FETCH
Ext_aa:             Op_IND               FETCH
Ext_ab:             Op_OUTD              FETCH
Ext_ac:
Ext_ad:
Ext_ae:
Ext_af:                                  FETCH

Ext_b0:             Op_LDIR              FETCH
Ext_b1:             Op_CPIR              FETCH
Ext_b2:             Op_INIR              FETCH
Ext_b3:             Op_OTIR              FETCH
Ext_b4:
Ext_b5:
Ext_b6:
Ext_b7:                                  FETCH
Ext_b8:             Op_LDDR              FETCH
Ext_b9:             Op_CPDR              FETCH
Ext_ba:             Op_INDR              FETCH
Ext_bb:             Op_OTDR              FETCH
Ext_bc:
Ext_bd:
Ext_be:
Ext_bf:                                  FETCH
