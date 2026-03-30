local string_h = [[
#ifndef STRING_H
#define STRING_H
int strlen(char* s) { int l = 0; while (s[l]) l++; return l; }
int strcmp(char* s1, char* s2) {
    while (*s1 && (*s1 == *s2)) { s1++; s2++; }
    return *s1 - *s2;
}
int strncmp(char* s1, char* s2, int n) {
    while (n > 0 && *s1 && (*s1 == *s2)) { s1++; s2++; n--; }
    if (n == 0) return 0;
    return *s1 - *s2;
}
char* strcpy(char* dest, char* src) {
    char* d = dest;
    while (*src) { *d = *src; d++; src++; }
    *d = 0; return dest;
}
char* strncpy(char* dest, char* src, int n) {
    char* d = dest;
    while (n > 0 && *src) { *d = *src; d++; src++; n--; }
    while (n > 0) { *d = 0; d++; n--; }
    return dest;
}
char* strcat(char* dest, char* src) {
    char* d = dest;
    while (*d) d++;
    while (*src) { *d = *src; d++; src++; }
    *d = 0; return dest;
}
char* strncat(char* dest, char* src, int n) {
    char* d = dest;
    while (*d) d++;
    while (n > 0 && *src) { *d = *src; d++; src++; n--; }
    *d = 0; return dest;
}
char* strchr(char* s, int c) {
    while (*s) { if (*s == c) return s; s++; }
    if (c == 0) return s;
    return (char*)0;
}
char* strrchr(char* s, int c) {
    char* last = (char*)0;
    while (*s) { if (*s == c) last = s; s++; }
    if (c == 0) return s;
    return last;
}
char* strstr(char* hay, char* needle) {
    if (!*needle) return hay;
    while (*hay) {
        char* h = hay; char* n = needle;
        while (*h && *n && *h == *n) { h++; n++; }
        if (!*n) return hay;
        hay++;
    }
    return (char*)0;
}
void* memset(void* s, int c, int n) {
    char* p = (char*)s;
    while (n > 0) { *p = (char)c; p++; n--; }
    return s;
}
void* memcpy(void* dest, void* src, int n) {
    char* d = (char*)dest; char* s = (char*)src;
    while (n > 0) { *d = *s; d++; s++; n--; }
    return dest;
}
void* memmove(void* dest, void* src, int n) {
    char* d = (char*)dest; char* s = (char*)src;
    if (d < s) {
        while (n > 0) { *d = *s; d++; s++; n--; }
    } else {
        d = d + n - 1; s = s + n - 1;
        while (n > 0) { *d = *s; d--; s--; n--; }
    }
    return dest;
}
int memcmp(void* s1, void* s2, int n) {
    char* a = (char*)s1; char* b = (char*)s2;
    while (n > 0) {
        if (*a != *b) return *a - *b;
        a++; b++; n--;
    }
    return 0;
}
#endif
]]

return string_h
