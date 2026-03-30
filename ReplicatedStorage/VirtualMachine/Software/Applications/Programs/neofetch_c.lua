local neofetch_c = [===[
#include <rovm.h>
#include <string.h>

void set_fg(int color) { syscall(8, color, 0, 0, 0, 0, 0); }
void set_bg(int color) { syscall(9, color, 0, 0, 0, 0, 0); }
int sysinfo(int sel) { return syscall(73, sel, 0, 0, 0, 0, 0); }

void color_reset() {
    set_fg(RGB(255, 255, 255));
    set_bg(RGB(0, 0, 0));
}

void print_bold(char* str) {
    set_fg(RGB(255, 255, 255));
    print(str);
    color_reset();
}

void print_label(char* label, char* value) {
    set_fg(RGB(230, 50, 50));
    print(label);
    color_reset();
    print(value);
    printchar(10);
}

void print_label_int(char* label, int val, char* suffix) {
    set_fg(RGB(230, 50, 50));
    print(label);
    color_reset();
    printint(val);
    if (suffix) print(suffix);
    printchar(10);
}

void print_color_block(int r, int g, int b) {
    set_bg(RGB(r, g, b));
    print("   ");
    set_bg(RGB(0, 0, 0));
}

int main() {
char* logo[] = {
"      ######..                  ",
"     .##########.###.           ",
"     #####################..    ",
"    .###########################",
"    ############################",
"   .###########################.",
"   ############################ ",
"  .########### #.#.###########. ",
"  ############    ############  ",
" .#############.. ###########.  ",
" ############################   ",
" ###########################.   ",
"############################    ",
"###########################.    ",
"   ..###.##################     ",
"           ###.###########.     ",
"                  .#######      "
};

    int uptime_sec = sysinfo(0);
    int heap_break = sysinfo(1);
    int num_procs  = sysinfo(2);
    int total_mem  = sysinfo(3);
    int scr_w      = sysinfo(4);
    int scr_h      = sysinfo(5);
    int mips_x100  = sysinfo(8);

    int heap_kb = heap_break / 1024;
    int total_kb = total_mem / 1024;
    int up_min = uptime_sec / 60;
    int up_sec = uptime_sec % 60;

    int info_count = 18;

    printchar(10);

    for (int i = 0; i < info_count; i++) {
        set_fg(RGB(230, 50, 50));
        char* line = logo[i];
        int j = 0;
        while (line[j]) {
            if (line[j] == '#') {
                set_bg(RGB(230, 50, 50));
                printchar(' ');
                set_bg(RGB(0, 0, 0));
            } else if (line[j] == '.') {
                set_bg(RGB(140, 30, 30));
                printchar(' ');
                set_bg(RGB(0, 0, 0));
            } else {
                printchar(' ');
            }
            j++;
        }
        print("   ");

        if (i == 0) {
            set_fg(RGB(230, 50, 50));
            print_bold("root");
            set_fg(RGB(200, 200, 200));
            print("@");
            print_bold("bloxos");
        } else if (i == 1) {
            set_fg(RGB(230, 50, 50));
            print("-----------------");
            color_reset();
        } else if (i == 2) {
            print_label("OS: ", "BloxOS 2026");
        } else if (i == 3) {
            print_label("Host: ", "Roblox");
        } else if (i == 4) {
            print_label("Kernel: ", "BloxOS-Kernel 3.3.0 STABLE");
        } else if (i == 5) {
            set_fg(RGB(230, 50, 50));
            print("Uptime: ");
            color_reset();
            printint(up_min);
            print(" min, ");
            printint(up_sec);
            print(" sec\n");
        } else if (i == 6) {
            print_label("Shell: ", "BloxOS Shell 2.3");
        } else if (i == 7) {
            set_fg(RGB(230, 50, 50));
            print("Resolution: ");
            color_reset();
            printint(scr_w);
            print("x");
            printint(scr_h);
            printchar(10);
        } else if (i == 8) {
            print_label("DE: ", "None");
        } else if (i == 9) {
            print_label("WM: ", "BloxOS-WM");
        } else if (i == 10) {
            print_label("Terminal: ", "RoVM TTY");
        } else if (i == 11) {
            set_fg(RGB(230, 50, 50));
            print("CPU: ");
            color_reset();
            print("RoVM vCPU @ ");
            printint(mips_x100 / 100);
            print(".");
            int mips_frac = mips_x100 % 100;
            if (mips_frac < 10) print("0");
            printint(mips_frac);
            print(" MIPS\n");
        } else if (i == 12) {
            print_label("GPU: ", "RoVM vGPU");
        } else if (i == 13) {
            set_fg(RGB(230, 50, 50));
            print("Memory: ");
            color_reset();
            printint(heap_kb);
            print(" KB / ");
            printint(total_kb);
            print(" KB\n");
        } else if (i == 14) {
            print_label_int("Processes: ", num_procs, NULL);
        } else if (i == 15) {
            print("   ");
            print_color_block(40, 40, 40);
            print_color_block(230, 50, 50);
            print_color_block(50, 200, 50);
            print_color_block(230, 200, 50);
            print_color_block(60, 100, 220);
            print_color_block(180, 60, 200);
            print_color_block(60, 200, 200);
            print_color_block(200, 200, 200);
        } else if (i == 16) {
            print("   ");
            print_color_block(100, 100, 100);
            print_color_block(255, 100, 100);
            print_color_block(100, 255, 100);
            print_color_block(255, 255, 100);
            print_color_block(100, 150, 255);
            print_color_block(220, 120, 255);
            print_color_block(100, 255, 255);
            print_color_block(255, 255, 255);
        }

        printchar(10);
    }

    color_reset();
    printchar(10);
    return 0;
}
]===]

return neofetch_c