#include <stdio.h>
#include <stdbool.h>
#include <avr/io.h>
#include <util/delay.h>
#include <string.h>
#include "../pff/diskio.h"
#include "../pff/pff.h"

extern void uart_init(void);
extern void kbd_init(void);
extern void startZ80();

FATFS Fatfs;		/* Petit-FatFs work area */

/*
bool read_cpm(void)
{
    if (pf_open("CPM.BIN") != FR_OK) return false;

    // Load CPM at address dc00+0500 instead of dc00
	UINT br;	// Bytes read
	pf_read((void *)(0xdc00+0x0500), 0x1A00, &br);

    // install a jmp f200
    *(BYTE *)0x0500 = 0xc3;
    *(WORD *)0x0501 = 0xf200;
    return true;
}
*/

unsigned char sector_buffer[512];
unsigned char sector=1, track=0, disk=0, command=0, status;
DWORD last_lba=-1;
unsigned int dma_addr=0;

void rw_sector(void)
{
    unsigned int FLOPPY_SIZE = (26 * 77 +3) / 4; // # of 512-bytes sectors
    unsigned int HARDDSK_SIZE = (128 * 255 +3) /4; // (+3 for rounding up)
    unsigned int CLUSTER_MASK = ~(Fatfs.csize - 1);
    // round number of sectors to cluster size
    FLOPPY_SIZE = (FLOPPY_SIZE + Fatfs.csize - 1) & CLUSTER_MASK;
    HARDDSK_SIZE = (HARDDSK_SIZE + Fatfs.csize - 1) & CLUSTER_MASK;
    DWORD lba = Fatfs.database + Fatfs.csize; // cluster #2 not used !?
    unsigned int sectors;
    switch (disk) {
        case 0: sectors = 26; break;
        case 1: sectors = 26; lba += FLOPPY_SIZE; break;
        case 2:
        case 8: sectors =128; lba += 2*FLOPPY_SIZE; break;
        default: sectors=128; lba += 2*FLOPPY_SIZE+HARDDSK_SIZE; break;
    }
    int linear_sector = (track*sectors) + sector - 1;
    lba += linear_sector>>2;
    status = 0;
    if (lba != last_lba) // read only if not already in buffer
        status = disk_readp(sector_buffer, lba, 0, 512);
    last_lba = lba;
    if (status) return;

    char * buf = (char *)(dma_addr+0x500);
    int offset = (linear_sector & 3) << 7;
    if (command==1) {
//printf("Write ");
        for (int i=0; i<128; i++) sector_buffer[offset + i] = buf[i];
        status = disk_write(sector_buffer, lba);
    } else {
//printf("Read  ");
        for (int i=0; i<128; i++) buf[i] = sector_buffer[offset + i];
    }
//printf("DSK%d TRK%d SCT%d:\n",disk,track,sector);
//for (int i=0;i<128; i++) {
//    if ((i&0x0F)==0) printf("\n\t");
//    printf("%02x ",(unsigned char)buf[i]);
//}
//printf("\n");
}

int main(void)
{
    _delay_ms(5000);
    kbd_init();

    /* Initialize UART0 to 38400 Baud, 8N1 */
    UCSR0A = 0;
    UCSR0B = _BV(TXEN0) | _BV(RXEN0);
    UCSR0C = _BV(URSEL0) | _BV(UCSZ01) | _BV(UCSZ00); // 8 bit data
    UBRR0H = 0;
    UBRR0L = 25;  // 38400 baud at 16 MHz

    /* Disable JTAG: it conflicts with address bus */
    uint8_t tmp = MCUCSR | _BV(JTD);
    MCUCSR = tmp; // write twice in less than 4 cycles
    MCUCSR = tmp; // to override protection

    /* Init external sram */
    MCUCR |= _BV(SRE); // external SRAM enable
    
    /* Put PD4 in a defined state, it is connected to SRAM's A16 */
    PORTD |= _BV(PORTD4);

	pf_mount(&Fatfs);	/* Initialize file system */
    rw_sector();        /* read boot sector */
    startZ80();
}

