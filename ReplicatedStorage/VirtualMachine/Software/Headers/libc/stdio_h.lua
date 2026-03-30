local stdio_h = [[
#ifndef STDIO_H
#define STDIO_H
#include "rovm.h"
#include "string.h"
#include "stdlib.h"

struct __file { int fd; int mode; int pos; int eof; int error; };
typedef struct __file FILE;

struct __file __stdin_s  = {-1, 1, 0, 0, 0};
struct __file __stdout_s = {-2, 2, 0, 0, 0};
struct __file __stderr_s = {-3, 2, 0, 0, 0};
FILE* stdin  = &__stdin_s;
FILE* stdout = &__stdout_s;
FILE* stderr = &__stderr_s;

#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

void putchar(int c) { printchar(c); }
void puts(char* s) {
    int len = strlen(s);
    if (len > 0) syscall(34, -2, (int)s, len);
    printchar(10);
}

int fputc(int c, FILE* f) {
    char buf = (char)c;
    int r = syscall(34, f->fd, (int)&buf, 1);
    if (r <= 0) { f->error = 1; return -1; }
    f->pos = f->pos + 1;
    return c;
}

int fputs(char* s, FILE* f) {
    int len = strlen(s);
    int r = syscall(34, f->fd, (int)s, len);
    if (r < 0) { f->error = 1; return -1; }
    f->pos = f->pos + r;
    return 0;
}

int fgetc(FILE* f) {
    if (f->eof) return -1;
    if (f->fd == -1) {
        int c = syscall(1, 0, 0, 0);
        if (c < 0) { f->eof = 1; return -1; }
        return c;
    }
    char buf = 0;
    int r = syscall(33, f->fd, (int)&buf, 1);
    if (r <= 0) { f->eof = 1; return -1; }
    f->pos = f->pos + 1;
    return buf;
}

char* fgets(char* s, int size, FILE* f) {
    int i = 0;
    while (i < size - 1) {
        int c = fgetc(f);
        if (c == -1) { if (i == 0) return (char*)0; break; }
        s[i] = (char)c; i++;
        if (c == 10) break;
    }
    s[i] = 0;
    return s;
}

int fread(void* ptr, int size, int nmemb, FILE* f) {
    int total = size * nmemb;
    if (f->fd == -1) {
        char* p = (char*)ptr; int i = 0;
        while (i < total) { int c = fgetc(f); if (c == -1) break; p[i] = (char)c; i++; }
        return i / size;
    }
    int r = syscall(33, f->fd, (int)ptr, total);
    if (r < 0) { f->error = 1; return 0; }
    f->pos = f->pos + r;
    if (r < total) f->eof = 1;
    return r / size;
}

int fwrite(void* ptr, int size, int nmemb, FILE* f) {
    int total = size * nmemb;
    int r = syscall(34, f->fd, (int)ptr, total);
    if (r < 0) { f->error = 1; return 0; }
    f->pos = f->pos + r;
    return r / size;
}

FILE* fopen(char* path, char* mode) {
    int m = 0;
    if (mode[0] == 114) m = 1;
    else if (mode[0] == 119) m = 2 | 8;
    else if (mode[0] == 97) m = 2 | 4 | 8;
    if (mode[1] == 43) m = m | 1 | 2;
    int fd = syscall(32, (int)path, m, 0);
    if (fd < 0) return (FILE*)0;
    FILE* f = (FILE*)malloc(sizeof(FILE));
    if (!f) { syscall(35, fd, 0, 0); return (FILE*)0; }
    f->fd = fd; f->mode = m; f->pos = 0; f->eof = 0; f->error = 0;
    return f;
}

int fclose(FILE* f) {
    if (!f) return -1;
    int r = 0;
    if (f->fd >= 0) r = syscall(35, f->fd, 0, 0);
    free(f);
    return r;
}

int fseek(FILE* f, int offset, int whence) {
    if (f->fd < 0) return -1;
    int r = syscall(36, f->fd, offset, whence);
    if (r < 0) return -1;
    f->pos = r; f->eof = 0;
    return 0;
}

int ftell(FILE* f) { return f->pos; }
int feof(FILE* f) { return f->eof; }
int ferror(FILE* f) { return f->error; }
void clearerr(FILE* f) { f->eof = 0; f->error = 0; }

void __print_hex(int n) {
    char hex[] = "0123456789abcdef";
    int i = 28; int started = 0;
    while (i >= 0) {
        int d = (n >> i) & 0xF;
        if (d || started || i == 0) { printchar(hex[d]); started = 1; }
        i = i - 4;
    }
}

void printf(char* fmt, int a1, int a2, int a3, int a4) {
    int ai = 0;
    while (*fmt) {
        if (*fmt == 37) {
            fmt++;
            int val;
            if (ai == 0) val = a1;
            else if (ai == 1) val = a2;
            else if (ai == 2) val = a3;
            else val = a4;
            int pad = 0; int zero = 0;
            if (*fmt == 48) { zero = 1; fmt++; }
            while (*fmt >= 48 && *fmt <= 57) { pad = pad * 10 + (*fmt - 48); fmt++; }
            if (*fmt == 108) fmt++;
            if (*fmt == 100 || *fmt == 105) {
                if (val < 0) { printchar(45); val = -val; }
                char buf[12]; int len = 0;
                if (val == 0) { buf[0] = 48; len = 1; }
                else { while (val > 0) { buf[len] = 48 + (val % 10); len++; val = val / 10; } }
                while (pad > len) { printchar(zero ? 48 : 32); pad--; }
                while (len > 0) { len--; printchar(buf[len]); }
                ai++;
            } else if (*fmt == 117) {
                char buf[12]; int len = 0;
                if (val == 0) { buf[0] = 48; len = 1; }
                else { while (val) { buf[len] = 48 + (val % 10); len++; val = val / 10; } }
                while (pad > len) { printchar(zero ? 48 : 32); pad--; }
                while (len > 0) { len--; printchar(buf[len]); }
                ai++;
            } else if (*fmt == 120) {
                __print_hex(val); ai++;
            } else if (*fmt == 115) { print((char*)val); ai++; }
            else if (*fmt == 99) { printchar(val); ai++; }
            else if (*fmt == 112) {
                print("0x"); __print_hex(val); ai++;
            } else if (*fmt == 37) { printchar(37); }
        } else { printchar(*fmt); }
        fmt++;
    }
}

int sprintf(char* buf, char* fmt, int a1, int a2, int a3) {
    int bi = 0; int ai = 0;
    while (*fmt) {
        if (*fmt == 37) {
            fmt++;
            int val;
            if (ai == 0) val = a1;
            else if (ai == 1) val = a2;
            else val = a3;
            if (*fmt == 100 || *fmt == 105) {
                if (val < 0) { buf[bi] = 45; bi++; val = -val; }
                char tmp[12]; int len = 0;
                if (val == 0) { tmp[0] = 48; len = 1; }
                else { while (val > 0) { tmp[len] = 48 + (val % 10); len++; val = val / 10; } }
                while (len > 0) { len--; buf[bi] = tmp[len]; bi++; }
                ai++;
            } else if (*fmt == 115) {
                char* s = (char*)val;
                while (*s) { buf[bi] = *s; bi++; s++; }
                ai++;
            } else if (*fmt == 99) { buf[bi] = (char)val; bi++; ai++; }
            else if (*fmt == 37) { buf[bi] = 37; bi++; }
        } else { buf[bi] = *fmt; bi++; }
        fmt++;
    }
    buf[bi] = 0;
    return bi;
}

int fprintf(FILE* f, char* fmt, int a1, int a2, int a3) {
    char buf[256];
    int n = sprintf(buf, fmt, a1, a2, a3);
    fputs(buf, f);
    return n;
}
#endif
]]

return stdio_h