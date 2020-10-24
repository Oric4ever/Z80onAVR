#include <avr/io.h>

#define regZero r7
#define Operand r19
#define tmp     r24

#if UART==0
#define UCSRA UCSR0A
#define UDR   UDR0
#define RXC   RXC0
#define UDRE  UDRE0
#else
#define UCSRA UCSR1A
#define UDR   UDR1
#define RXC   RXC1
#define UDRE  UDRE1
#endif

.section .text

input_table:
    rjmp con_status /* 0 */
    rjmp con_input  /* 1 */
    ret             /* 2 */
    ret             /* 3 */
    ret             /* 4 */
    ret             /* 5 */
    ret             /* 6 */
    ret             /* 7 */
    ret             /* 8 */
    ret             /* 9 */
    rjmp get_drive  /* 10 */
    rjmp get_track  /* 11 */
    rjmp get_sector /* 12 */
    rjmp get_command/* 13 */
    rjmp get_status /* 14 */
    rjmp get_addrl  /* 15 */
    rjmp get_addrh  /* 16 */
    
output_table:
    ret             /* 0 */
    rjmp con_output /* 1 */
    ret             /* 2 */
    ret             /* 3 */
    ret             /* 4 */
    ret             /* 5 */
    ret             /* 6 */
    ret             /* 7 */
    ret             /* 8 */
    ret             /* 9 */
    rjmp set_drive  /* 10 */
    rjmp set_track  /* 11 */
    rjmp set_sector /* 12 */
    rjmp set_command/* 13 */
    ret             /* 14 */
    rjmp set_addrl  /* 15 */
    rjmp set_addrh  /* 16 */
    

con_status: /* returns 0xff if input available, 0 otherwise */
    call  kbd_is_empty /* tmp==1 if kbd buffer empty, 0 otherwise */
    dec   tmp
    ret
con_input:
    call  kbd_is_empty
    tst   tmp
    brne  con_input
    call  kbd_dequeue
    ret
get_drive:
    lds  tmp,disk
    ret
get_track:
    lds  tmp,track
    ret
get_sector:
    lds  tmp,sector
    ret
get_command:
    clr  tmp
    ret
get_status:
    lds  tmp,status
    ret
get_addrl:
    lds  tmp,dma_addr
    ret
get_addrh:
    lds  tmp,dma_addr+1
    ret

con_output:
    mov r16,tmp
    rjmp uart_send
set_drive:
    sts  disk,tmp
    ret
set_track:
    sts  track,tmp
    ret
set_sector:
    sts  sector,tmp
    ret
set_command:
    sts  command,tmp
    rjmp rw_sector
set_addrl:
    sts  dma_addr,tmp
    ret
set_addrh:
    sts  dma_addr+1,tmp
    ret

.global input
input:
    push  ZH
    push  ZL
    ldi   ZH,hi8(pm(input_table))
    ldi   ZL,lo8(pm(input_table))
    rjmp  input_output

.global output
output:
    push  ZH
    push  ZL
    ldi   ZH,hi8(pm(output_table))
    ldi   ZL,lo8(pm(output_table))
input_output:
    cpi   Operand,17
    brcs  do_io
    pop   ZL
    pop   ZH
    ret

do_io:
    push  r29
    push  r28
    push  r27
    push  r26
    push  r25
    push  r24
    push  r23
    push  r22
    push  r21
    push  r20
    push  r19
    push  r18
    push  r17
    push  r16
    push  r15
    push  r14
    push  r13
    push  r12
    push  r11
    push  r10
    push  r9
    push  r8
    push  r7
    push  r6
    push  r5
    push  r4
    push  r3
    push  r2
    push  r1
    push  r0
    clr   r1    /* r1 must be 0 for C language */
    rcall io_jump
    pop   r0
    pop   r1
    pop   r2
    pop   r3
    pop   r4
    pop   r5
    pop   r6
    pop   r7
    pop   r8
    pop   r9
    pop   r10
    pop   r11
    pop   r12
    pop   r13
    pop   r14
    pop   r15
    pop   r16
    pop   r17
    pop   r18
    pop   r19
    pop   r20
    pop   r21
    pop   r22
    pop   r23
    pop   r25   /* result is returned in tmp */
    pop   r25
    pop   r26
    pop   r27
    pop   r28
    pop   r29
    pop   r30
    pop   r31
    ret

io_jump:
    add   ZL,Operand
    adc   ZH,regZero
    ijmp


.global send_hex
send_hex:
    push  r16
    swap  r16
    rcall send_hexbyte
    pop   r16
send_hexbyte:
    andi  r16,0x0f
    cpi   r16,10
    brlo  1f
    subi  r16,-7
1:  subi  r16,-48
    rjmp  uart_send

.global send_newline
send_newline:
    ldi   r16,'\r'
    rcall uart_send
    ldi   r16,'\n'
    rjmp  uart_send
.global send_space
send_space:
    ldi   r16,' '
.global uart_send
uart_send:
    sbis  _SFR_IO_ADDR(UCSRA),UDRE
    rjmp  uart_send
    out   _SFR_IO_ADDR(UDR),r16
uart_wait:
    sbis  _SFR_IO_ADDR(UCSRA),UDRE
    rjmp  uart_wait
    ret


