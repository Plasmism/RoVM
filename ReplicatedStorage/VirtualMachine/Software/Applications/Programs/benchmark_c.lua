local benchmark_c = [===[
#include <rovm.h>
#include <string.h>

int sysinfo(int sel) { return syscall(73, sel, 0, 0, 0, 0, 0); }

void print_result(char* name, int score) {
    print(name);
    print(": ");
    printint(score);
    print(" iter/sec\n");
}

void print_mips(char* name, int mips_x100) {
    print(name);
    print(": ");
    printint(mips_x100 / 100);
    print(".");
    int frac = mips_x100 % 100;
    if (frac < 10) print("0");
    printint(frac);
    print(" MIPS\n");
}

int main() {
    print("\nStarting ROVM System Benchmark...\n");
    print("---------------------------------\n");
    
    // 1. Integer Arithmetic
    print("Testing CPU Integer Math... ");
    int start = sysinfo(6);
    int ops = 0;
    int a = 0;
    while (sysinfo(6) - start < 1000) {
        for(int i=0; i<10; i++) {
            a = (a + 1) * 3 - 2;
        }
        ops += 10;
    }
    print("Done.\n");
    print_result("Integer Math    ", ops);
    
    // 2. Memory Access
    print("Testing Memory writes...    ");
    char buffer[1024];
    start = sysinfo(6);
    ops = 0;
    while (sysinfo(6) - start < 1000) {
        for(int i=0; i<1024; i++) {
            buffer[i] = (char)i;
        }
        ops++;
    }
    print("Done.\n");
    print_result("Mem Write (1KB) ", ops);

    // 3. Syscall overhead
    print("Testing Syscall speed...    ");
    start = sysinfo(6);
    ops = 0;
    while (sysinfo(6) - start < 1000) {
        for(int i=0; i<10; i++) {
            sysinfo(0); // calling a cheap syscall
        }
        ops += 10;
    }
    print("Done.\n");
    print_result("Syscalls        ", ops);
    print_mips("Reported vCPU   ", sysinfo(8));

    print("---------------------------------\n");
    print("Benchmark complete!\n\n");
    
    return 0;
}
]===]

return benchmark_c