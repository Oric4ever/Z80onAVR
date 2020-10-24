# Z80onAVR

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
