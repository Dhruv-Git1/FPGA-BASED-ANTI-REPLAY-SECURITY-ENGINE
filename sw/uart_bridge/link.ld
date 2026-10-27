/* Run entirely from the Zynq on-chip memory (OCM), mapped at address 0 after
 * the boot ROM. DDR is not needed. */
ENTRY(_start)

MEMORY
{
    ocm (rwx) : ORIGIN = 0x00000000, LENGTH = 0x30000
}

SECTIONS
{
    .text : { *(.text.start) *(.text*) *(.rodata*) } > ocm
    .data : { *(.data*) } > ocm
    .bss  : { *(.bss*) *(COMMON) } > ocm
    _stack_top = ORIGIN(ocm) + LENGTH(ocm) - 16;
}
