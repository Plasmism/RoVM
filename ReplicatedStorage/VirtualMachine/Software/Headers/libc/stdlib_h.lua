local stdlib_h = [[
#ifndef STDLIB_H
#define STDLIB_H
#include "rovm.h"
#include "string.h"
int abs(int j) { return j < 0 ? -j : j; }
int atoi(char* str) {
    int res = 0; int sign = 1; int i = 0;
    if (str[0] == 45) { sign = -1; i++; }
    while (str[i] >= 48 && str[i] <= 57) {
        res = res * 10 + (str[i] - 48);
        i++;
    }
    return sign * res;
}

int __heap_base = 0;
int __heap_limit = 0;
int __free_list = 0;
int __heap_inited = 0;

int __heap_block_valid(int hdr) {
    int bsz;
    if (hdr < __heap_base || hdr + 8 > __heap_limit) return 0;
    if ((hdr & 3) != 0) return 0;
    bsz = *((int*)hdr);
    if (bsz < 8 || (bsz & 3) != 0) return 0;
    if (hdr + bsz > __heap_limit) return 0;
    return 1;
}

int __heap_grow(int need) {
    int grow;
    int prev;
    if (need < 65536) grow = 65536;
    else grow = need;
    grow = (grow + 4095) & (~4095);
    prev = sbrk(grow);
    if (prev < 0) return 0;
    *((int*)prev) = grow;
    *((int*)(prev + 4)) = __free_list;
    __free_list = prev;
    __heap_limit = prev + grow;
    return 1;
}

void __heap_init() {
    if (__heap_inited) return;
    __heap_inited = 1;
    __heap_base = sbrk(0);
    if (__heap_base < 0) { __heap_base = 0; __heap_limit = 0; __free_list = 0; return; }
    __heap_limit = __heap_base;
    if (!__heap_grow(262144)) { __heap_base = 0; __heap_limit = 0; __free_list = 0; return; }
}

void* malloc(int size) {
    int need;
    int scans;
    __heap_init();
    if (size <= 0) return (void*)0;
    size = (size + 3) & (~3);
    need = size + 8;
    while (1) {
        int prev = 0;
        int curr = __free_list;
        if (!curr) {
            if (!__heap_grow(need)) return (void*)0;
            curr = __free_list;
        }
        scans = 0;
        while (curr) {
            int bsz;
            int next;
            if (!__heap_block_valid(curr) || scans > 8192) {
                __free_list = 0;
                break;
            }
            bsz = *((int*)curr);
            next = *((int*)(curr + 4));
            if (bsz >= need) {
                if (bsz >= need + 16) {
                    int nb = curr + need;
                    *((int*)nb) = bsz - need;
                    *((int*)(nb + 4)) = next;
                    *((int*)curr) = need;
                    if (prev) *((int*)(prev + 4)) = nb;
                    else __free_list = nb;
                } else {
                    if (prev) *((int*)(prev + 4)) = next;
                    else __free_list = next;
                }
                return (void*)(curr + 8);
            }
            prev = curr;
            curr = next;
            scans++;
        }
        if (!__heap_grow(need)) return (void*)0;
    }
}

void free(void* ptr) {
    int hdr;
    int scan;
    int scans;
    if (!ptr) return;
    if (!__heap_inited) return;
    hdr = (int)ptr - 8;
    if (!__heap_block_valid(hdr)) return;
    scan = __free_list;
    scans = 0;
    while (scan) {
        if (!__heap_block_valid(scan) || scans > 8192) {
            __free_list = 0;
            break;
        }
        if (scan == hdr) return;
        scan = *((int*)(scan + 4));
        scans++;
    }
    *((int*)(hdr + 4)) = __free_list;
    __free_list = hdr;
}

void* calloc(int nmemb, int size) {
    int total = nmemb * size;
    void* p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void* realloc(void* ptr, int size) {
    if (!ptr) return malloc(size);
    if (size == 0) { free(ptr); return (void*)0; }
    int oldhdr = (int)ptr - 8;
    int oldsize = *((int*)oldhdr) - 8;
    void* newp = malloc(size);
    if (!newp) return (void*)0;
    int copylen = oldsize < size ? oldsize : size;
    memcpy(newp, ptr, copylen);
    free(ptr);
    return newp;
}

int __rand_seed = 12345;
int rand() {
    __rand_seed = __rand_seed * 1103515245 + 12345;
    return (__rand_seed >> 16) & 32767;
}
void srand(int seed) { __rand_seed = seed; }

void __swap_bytes(char* a, char* b, int size) {
    int i = 0;
    while (i < size) {
        char tmp = a[i];
        a[i] = b[i];
        b[i] = tmp;
        i++;
    }
}
void qsort(void* base, int nmemb, int size, int (*cmp)(void*, void*)) {
    if (nmemb <= 1) return;
    char* arr = (char*)base;
    char* pivot = arr + (nmemb - 1) * size;
    int store = 0;
    int i = 0;
    while (i < nmemb - 1) {
        if (cmp(arr + i * size, pivot) <= 0) {
            __swap_bytes(arr + i * size, arr + store * size, size);
            store++;
        }
        i++;
    }
    __swap_bytes(arr + store * size, pivot, size);
    qsort(arr, store, size, cmp);
    qsort(arr + (store + 1) * size, nmemb - store - 1, size, cmp);
}
void* bsearch(void* key, void* base, int nmemb, int size, int (*cmp)(void*, void*)) {
    int lo = 0; int hi = nmemb - 1;
    char* arr = (char*)base;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        int r = cmp(key, arr + mid * size);
        if (r == 0) return (void*)(arr + mid * size);
        if (r < 0) hi = mid - 1;
        else lo = mid + 1;
    }
    return (void*)0;
}
#endif
]]

return stdlib_h