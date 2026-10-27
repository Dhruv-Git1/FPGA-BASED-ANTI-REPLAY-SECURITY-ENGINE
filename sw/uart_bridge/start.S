/* Minimal start-up for the bridge program. The debugger loads the program into
 * on-chip memory and starts at _start, so there is no boot loader. Caches and
 * the MMU stay off, which is fine for a polling loop over device registers. */
    .section .text.start, "ax"
    .global _start
    .arm
_start:
    ldr sp, =_stack_top
    bl  main
1:  b   1b
