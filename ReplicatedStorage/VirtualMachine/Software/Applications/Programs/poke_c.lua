local poke_c = [[
#include "rovm.h"
#include "string.h"
#include "stdlib.h"

int htoi(char* str) {
    if (str[0] == '0' && (str[1] == 'x' || str[1] == 'X')) str = str + 2;
    int res = 0;
    while (*str) {
        char c = *str;
        int val = 0;
        if (c >= '0' && c <= '9') val = c - '0';
        else if (c >= 'a' && c <= 'f') val = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') val = c - 'A' + 10;
        else break;
        res = (res << 4) | val;
        str++;
    }
    return res;
}

int readln(char* buf, int max) {
    int pos = 0;
    int c = 0;
    while (pos < max - 1) {
        c = getkey();
        if (c == 13 || c == 10) { printchar(10); break; }
        if (c == 8) {
            if (pos > 0) {
                pos--;
                printchar(8); printchar(32); printchar(8);
            }
            continue;
        }
        if (c >= 32 && c < 127) {
            buf[pos] = (char)c;
            pos++;
            printchar(c);
        }
    }
    buf[pos] = 0;
    flush();
    return pos;
}

int main() {
    print("ROVM Physical Memory Poker\n");
    while (1) {
        char buf[32];
        print("Address (hex, or 'q' to quit): ");
        readln(buf, 32);
        if (buf[0] == 'q') break;
        int addr = htoi(buf);
        
        print("Address "); printhex(addr); print(" contains: ");
        int val = syscall(71, addr, 0, 0, 0, 0, 0); // SC_PEEK_PHYS
        if (val == -1 && addr != 0xFFFFFFFF) {
            print("INVALID ADDRESS\n");
            continue;
        }
        printhex(val); printchar(10);
        
        print("New value (hex, or empty to skip): ");
        readln(buf, 32);
        if (buf[0] == 0) continue;
        int new_val = htoi(buf);
        
        int r = syscall(72, addr, new_val, 0, 0, 0, 0); // SC_POKE_PHYS
        if (r == -1) print("WRITE FAILED\n");
        else print("WRITE OK\n");
    }
    return 0;
}
]]

return poke_c