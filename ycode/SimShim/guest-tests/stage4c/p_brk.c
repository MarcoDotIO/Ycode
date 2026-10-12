/* Ycode stage-4c probe: a BRK abort with a message pointer in x1 and an
 * errno-like value (-105) in x0, to check the VMM's fault report (it prints
 * the string at x1 and ignores x0). Original Ycode code. Ends with BRK #1. */
int main(void)
{
    static const char message[] = "p_brk: deliberate abort message";
    __asm__ volatile("mov x0, #-105\n\tmov x1, %0\n\tbrk #1" : : "r"(message) : "x0", "x1");
    return 0;
}
