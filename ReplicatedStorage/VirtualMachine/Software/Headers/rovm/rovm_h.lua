local rovm_h = [[
#ifndef ROVM_H
#define ROVM_H
#define NULL ((void*)0)
int syscall(int n, int a, int b, int c, int d, int e, int f);

void exit(int code) { syscall(3, code, 0, 0, 0, 0, 0); }
void reboot() { syscall(4, 0, 0, 0, 0, 0, 0); }
void flush() { syscall(2, 0, 0, 0, 0, 0, 0); }
int fork() { return syscall(16, 0, 0, 0, 0, 0, 0); }
int exec(char* path, char** argv, char** envp) { return syscall(17, (int)path, (int)argv, (int)envp, 0, 0, 0); }
int wait() { return syscall(18, 0, 0, 0, 0, 0, 0); }
int getpid() { return syscall(19, 0, 0, 0, 0, 0, 0); }

void printchar(int c) { syscall(0, c, 0, 0); }
int __rovm_strlen(char* str) {
    int len = 0;
    while (str[len]) len++;
    return len;
}
void print(char* str) {
    int i = 0;
    while (str[i]) {
        printchar(str[i]);
        i++;
    }
}

void print_int(int n) {
    char* hex = "0123456789ABCDEF";
    for (int i = 7; i >= 0; i--) {
        printchar(hex[(n >> (i * 4)) & 0xF]);
    }
}
void printint(int n) {
    if (n < 0) { printchar(45); n = -n; }
    if (n == 0) { printchar(48); return; }
    int rev = 0; int count = 0;
    while (n > 0) { rev = (rev * 10) + (n % 10); n = n / 10; count++; }
    while (count > 0) { printchar(48 + (rev % 10)); rev = rev / 10; count--; }
}
void printhex(int n) {
    char hex[] = "0123456789ABCDEF";
    printchar(48); printchar(120);
    int i = 28;
    while (i >= 0) {
        printchar(hex[(n >> i) & 0xF]);
        i = i - 4;
    }
}

int getkey() { return syscall(1, 0, 0, 0, 0, 0, 0); }
int getkey_nowait() { return syscall(77, 0, 0, 0, 0, 0, 0); }
int key_down(int key) { return syscall(75, key, 0, 0, 0, 0, 0); }
int key_pressed(int key) { return syscall(76, key, 0, 0, 0, 0, 0); }
int vsync(int fps) { return syscall(48, fps, 0, 0, 0, 0, 0); }
int sbrk(int increment) { return syscall(65, increment, 0, 0, 0, 0, 0); }
void gpu_clear_frame(void) { syscall(60, 0, 0, 0, 0, 0, 0); }
void gpu_draw_rect(int x, int y, int w, int h, int color) {
    syscall(21, x, y, (w << 16) | (h & 0xFFFF), color, 0, 0);
}
/* Batched rect drawing: accumulate rects, flush with one syscall */
int _gpu_batch_buf[5120]; /* 1024 rects * 5 ints each */
int _gpu_batch_count = 0;
void gpu_batch_begin() { _gpu_batch_count = 0; }
void gpu_batch_rect(int x, int y, int w, int h, int color) {
    if (_gpu_batch_count >= 1024) return;
    int off = _gpu_batch_count * 5;
    _gpu_batch_buf[off] = x;
    _gpu_batch_buf[off + 1] = y;
    _gpu_batch_buf[off + 2] = w;
    _gpu_batch_buf[off + 3] = h;
    _gpu_batch_buf[off + 4] = color;
    _gpu_batch_count++;
}
void gpu_batch_flush() {
    if (_gpu_batch_count > 0)
        syscall(74, (int)_gpu_batch_buf, _gpu_batch_count, 0, 0, 0, 0);
    _gpu_batch_count = 0;
}
void gpu_draw_line(int x0, int y0, int x1, int y1, int color) {
    syscall(57, color, 0, 0, 0, 0, 0); // SC_GPU_SET_COLOR
    syscall(22, x0, y0, x1, y1, 0, 0);
}
void gpu_cls() { gpu_draw_rect(0, 0, 1280, 720, 0); }
void gpu_set_view(int ox, int oy, int wrap_w, int wrap_h) { syscall(55, ox, oy, (wrap_w << 16) | (wrap_h & 0xFFFF)); }
void gpu_set_xy(int lx, int ly) { syscall(56, lx, ly, 0, 0); }
void gpu_set_color(int c) { syscall(57, c, 0, 0); }
void gpu_draw_buffer(void* buf, int len) { syscall(58, (int)buf, len, 0); }
int gpu_wait_frame(void) { return syscall(59, 0, 0, 0); }
void gpu_draw_rle(int length) { syscall(61, length, 0, 0); }
int gpu_get_remaining_len(void) { return syscall(62, 0, 0, 0); }
int gpu_get_buffer_addr(void) { return syscall(63, 0, 0, 0); }
void gpu_play_chunk(void* buf, int len, int fps) { syscall(66, (int)buf, len, fps); }
/* GUI apps: call app_window(width, height) at startup to run in a bordered window
   with title bar and close button; the shell stays full-screen until a program
   requests a window. Use app_set_title("...") to set the window title. */
int app_window(int width, int height) { return syscall(67, width, height, 0, 0, 0, 0); }
void app_set_title(char* title) { syscall(68, (int)title, 0, 0, 0, 0, 0); }
void format() { syscall(69, 0, 0, 0, 0, 0, 0); }
#define RGB(r,g,b) (((r)<<16)|((g)<<8)|(b))
#define BLACK RGB(0,0,0)
#define WHITE RGB(255,255,255)
#define RED   RGB(255,0,0)
#define GREEN RGB(0,255,0)
#define BLUE  RGB(0,0,255)
#define KEY_ENTER 13
#define KEY_UP 17
#define KEY_DOWN 18
#define KEY_LEFT 19
#define KEY_RIGHT 20
#define KEY_ESC 27
#define KEY_SPACE 32
#endif
]]

return rovm_h
