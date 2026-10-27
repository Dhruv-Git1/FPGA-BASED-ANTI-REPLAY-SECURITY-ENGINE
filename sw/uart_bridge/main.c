/*
 * Bare-metal byte relay for the "ps" build variant, running on ARM core 0.
 *
 *   UART1 (MIO 48/49, J14 USB-UART, the PC)  <-->  UART0 (EMIO, the FPGA logic)
 *
 * Every byte received on one UART is sent out of the other, unchanged. The
 * program never looks inside packets. Authentication and replay checks are
 * done only by the FPGA logic. Both UARTs run at 115200 baud, 8-N-1, so bytes
 * leave as fast as they arrive and the 64-byte FIFOs never overflow.
 *
 * Register map: Zynq-7000 TRM (UG585), Appendix B, UART Controller.
 */
#include <stdint.h>

#define UART0_BASE 0xE0000000u
#define UART1_BASE 0xE0001000u

#define REG(base, off) (*(volatile uint32_t *)((base) + (off)))
#define CR(b)      REG(b, 0x00)  /* control */
#define MR(b)      REG(b, 0x04)  /* mode */
#define BAUDGEN(b) REG(b, 0x18)  /* baud rate generator */
#define SR(b)      REG(b, 0x2C)  /* channel status */
#define FIFO(b)    REG(b, 0x30)  /* transmit and receive FIFO */
#define BAUDDIV(b) REG(b, 0x34)  /* baud rate divider */

#define CR_RXRST  (1u << 0)
#define CR_TXRST  (1u << 1)
#define CR_RXEN   (1u << 2)
#define CR_RXDIS  (1u << 3)
#define CR_TXEN   (1u << 4)
#define CR_TXDIS  (1u << 5)
#define MR_8N1    (0x4u << 3)    /* 8 data bits, no parity, 1 stop bit */
#define SR_RXEMPTY (1u << 1)
#define SR_TXFULL  (1u << 4)

/* The ZedBoard preset clocks both UARTs from a 100 MHz reference.
 * 100 MHz / (124 * (6 + 1)) = 115207 baud, 0.006 % from 115200. */
#define BAUD_CD  124u
#define BAUD_DIV 6u

static void uart_init(uint32_t base)
{
    CR(base) = CR_RXDIS | CR_TXDIS;
    MR(base) = MR_8N1;
    BAUDGEN(base) = BAUD_CD;
    BAUDDIV(base) = BAUD_DIV;
    CR(base) = CR_RXRST | CR_TXRST;
    while (CR(base) & (CR_RXRST | CR_TXRST))
        ;
    CR(base) = CR_RXEN | CR_TXEN;
}

static void relay_one(uint32_t from, uint32_t to)
{
    if (!(SR(from) & SR_RXEMPTY)) {
        uint32_t byte = FIFO(from);
        while (SR(to) & SR_TXFULL)
            ;
        FIFO(to) = byte;
    }
}

int main(void)
{
    uart_init(UART0_BASE);
    uart_init(UART1_BASE);
    for (;;) {
        relay_one(UART1_BASE, UART0_BASE);  /* PC to FPGA logic */
        relay_one(UART0_BASE, UART1_BASE);  /* FPGA logic to PC */
    }
}
