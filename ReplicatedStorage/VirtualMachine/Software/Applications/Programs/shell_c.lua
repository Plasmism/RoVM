local shell_c = [[
#include "rovm.h"
#include "string.h"
#include "stdlib.h"
#include "ctype.h"
#include "stdio.h"

#define MAX_CMD 256
#define MAX_ARGS 16

char cwd[256] = "/";
char run_path[256];
char* run_argv[MAX_ARGS + 1];
char run_argbuf[MAX_ARGS][MAX_CMD];
char* run_envp[2];
char run_envbuf[320];

void resolve_path(char* out, char* path) {
    char temp[256];
    if (path[0] == '/') {
        strcpy(temp, path);
    } else {
        strcpy(temp, cwd);
        if (temp[strlen(temp)-1] != '/') strcat(temp, "/");
        strcat(temp, path);
    }
    
    char* parts[32];
    int depth = 0;
    
    // Tokenize by slash
    char* p = temp;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        
        char* start = p;
        while (*p && *p != '/') p++;
        
        if (*p) {
            *p = 0;
            p++;
        }
        
        if (strcmp(start, ".") == 0) {
            // ignore
        } else if (strcmp(start, "..") == 0) {
            if (depth > 0) depth--;
        } else {
            parts[depth++] = start;
        }
    }
    
    // Reconstruct
    out[0] = '/'; out[1] = 0;
    for (int i = 0; i < depth; i++) {
        if (i > 0) strcat(out, "/");
        strcat(out, parts[i]);
    }
}

void cmd_reboot() {
    print("Rebooting system...\n");
    syscall(4, 0, 0, 0);
}

void cmd_format() {
    print("WARNING: This will wipe ALL files and reset the system to factory defaults.\n");
    print("Are you sure? (y/n): ");
    int c = syscall(1, 0, 0, 0);
    printchar(c); printchar(10);
    if (c == 'y' || c == 'Y') {
        print("Formatting...\n");
        syscall(69, 0, 0, 0);
    }
}
void cmd_crash() {
    print("Crashing system...\n");
    syscall(70, 0, 0, 0); // SC_CRASH
}

void cmd_help() {
    print("BloxOS Shell Commands:\n");
    print("  help            - show this message\n");
    print("  clear           - clear screen\n");
    print("  echo <text>     - print text\n");
    print("  cd <dir>        - change directory\n");
    print("  cat <file>      - display file contents\n");
    print("  ls [dir]        - list directory\n");
    print("  mkdir <dir>     - create directory\n");
    print("  rm <file>       - remove file\n");
    print("  run <file> [args] - execute binary (GUI apps use app_window() for a window)\n");
    print("  as <file> [out] - assemble file\n");
    print("  cc <file> [out] - compile and assemble C file\n");
    print("  touch <file>    - create empty file\n");
    print("  write <f> <txt> - write text to file\n");
    print("  edit <file>     - open editor\n");
    print("Apps in PATH: neofetch, benchmark, calculator, python, py, snake, tetris, pong, space_defenders, doom, cube, bad_apple\n");
    print("  crash           - crash the system until reboot\n");
    print("  format          - wipe all files and reset to factory defaults\n");
    print("  reboot          - reboot system\n");
}

void print_banner() {
    print("BloxOS Shell v2.3 (C)\n");
    print("Type 'help' for commands.\n\n");
}

void cmd_clear() {
    syscall(5, 0, 0, 0);
    print_banner();
    flush();
}

void cmd_echo(char* text) {
    print(text);
    printchar(10);
}

void cmd_cat(char* _path) {
    char path[256]; resolve_path(path, _path);
    int fd = syscall(32, (int)path, 1, 0);
    if (fd < 0) { print("cat: file not found\n"); return; }
    char buf[128];
    int n;
    while (1) {
        n = syscall(33, fd, (int)buf, 127);
        if (n <= 0) break;
        buf[n] = 0;
        print(buf);
    }
    syscall(35, fd, 0, 0);
    printchar(10);
}

void cmd_cd(char* _path) {
    if (!_path || !*_path) return;
    char target[256]; resolve_path(target, _path);
    
    // Verify it's a directory by trying to open/stat it
    char buf[16];
    int r = syscall(41, (int)target, (int)buf, 0); // SC_STAT
    if (r < 0) {
        print("cd: no such file or directory\n");
        return;
    }
    int type = *((int*)(buf + 4));
    if (type != 2) { // TYPE_DIR
        print("cd: not a directory\n");
        return;
    }
    
    strcpy(cwd, target);
}

void cmd_ls(char* _path) {
    char path[256];
    if (!_path || !*_path) strcpy(path, cwd);
    else resolve_path(path, _path);
    char buf[1024];
    int n = syscall(40, (int)path, (int)buf, 1024);
    if (n < 0) { print("ls: cannot open directory\n"); return; }
    print(buf);
}

void cmd_mkdir(char* _path) {
    char path[256]; resolve_path(path, _path);
    int r = syscall(38, (int)path, 0, 0);
    if (r < 0) print("mkdir: error\n");
}

void cmd_rm(char* _path) {
    char path[256]; resolve_path(path, _path);
    int r = syscall(37, (int)path, 0, 0);
    if (r < 0) print("rm: error\n");
}

char* skip_spaces(char* s);
char* next_token(char* s, char* tok, int max);

int build_argv(char* exec_path, char* rest) {
    int argc;
    char* p;
    argc = 0;
    run_argv[argc] = exec_path;
    argc++;
    p = skip_spaces(rest);
    while (*p && argc < MAX_ARGS) {
        p = next_token(p, run_argbuf[argc - 1], MAX_CMD);
        run_argv[argc] = run_argbuf[argc - 1];
        argc++;
        p = skip_spaces(p);
    }
    run_argv[argc] = (char*)0;
    return argc;
}

void build_envp() {
    strcpy(run_envbuf, "PWD=");
    strcat(run_envbuf, cwd);
    run_envp[0] = run_envbuf;
    run_envp[1] = (char*)0;
}

void cmd_run(char* _path, char* rest) {
    int argc;
    if (!_path || !*_path) {
        print("run: missing file\n");
        return;
    }
    resolve_path(run_path, _path);
    argc = build_argv(run_path, rest);
    build_envp();
    int pid = fork();
    if (pid < 0) {
        print("run: fork failed\n");
    } else if (pid == 0) {
        // Child
        int r = exec(run_path, run_argv, run_envp);
        if (r < 0) {
            print("run: failed to execute "); print(run_path); printchar(10);
            exit(1);
        }
    } else {
        // Parent
        wait();
    }
}

void cmd_as(char* _src, char* _out) {
    char src[256]; resolve_path(src, _src);
    char out[256];
    char* pout = NULL;
    if (_out && *_out) { resolve_path(out, _out); pout = out; }
    int r;
    if (pout) r = syscall(42, (int)src, (int)pout, 0);
    else r = syscall(42, (int)src, 0, 0);
    if (r < 0) print("as: assembly failed\n");
    else print("assembled OK\n");
}

void cmd_cc(char* _src, char* _out) {
    char src[256]; resolve_path(src, _src);
    
    char asm_path[256];
    strcpy(asm_path, src);
    int slen = strlen(asm_path);
    if (slen > 2 && asm_path[slen-2] == '.' && asm_path[slen-1] == 'c') {
        asm_path[slen-2] = 0;
    }
    strcat(asm_path, ".asm");

    char out_path[256];
    if (_out && *_out) {
        resolve_path(out_path, _out);
    } else {
        strcpy(out_path, src);
        int olen = strlen(out_path);
        if (olen > 2 && out_path[olen-2] == '.' && out_path[olen-1] == 'c') {
            out_path[olen-2] = 0;
        }
        strcat(out_path, ".rov");
    }

    print("compiling "); print(src); print("...\n");
    int r = syscall(43, (int)src, (int)asm_path, 0);
    if (r < 0) {
        return;
    }

    print("assembling "); print(asm_path); print("...\n");
    r = syscall(42, (int)asm_path, (int)out_path, 0);
    if (r < 0) {
        print("cc: assembly failed\n");
        return;
    }
    print("done: "); print(out_path); printchar(10);
}

void cmd_edit(char* _path) {
    char path[256]; resolve_path(path, _path);
    syscall(44, (int)path, 0, 0);
    print_banner();
}

void cmd_touch(char* _path) {
    char path[256]; resolve_path(path, _path);
    int fd = syscall(32, (int)path, 10, 0);
    if (fd < 0) { print("touch: error\n"); return; }
    syscall(35, fd, 0, 0);
}

void cmd_write(char* _path, char* text) {
    char path[256]; resolve_path(path, _path);
    int fd = syscall(32, (int)path, 10, 0);
    if (fd < 0) { print("write: cannot open file\n"); return; }
    int len = 0;
    char* t = text;
    while (*t) { len++; t++; }
    syscall(34, fd, (int)text, len);
    syscall(35, fd, 0, 0);
    print("wrote "); printint(len); print(" bytes\n");
}

char* skip_spaces(char* s) {
    while (*s == 32) s++;
    return s;
}

char* next_token(char* s, char* tok, int max) {
    int i = 0;
    while (*s && *s != 32 && i < max - 1) {
        tok[i] = *s; i++; s++;
    }
    tok[i] = 0;
    return s;
}

int readln(char* buf, int max) {
    int pos = 0;
    int c = 0;
    int blink = 0;
    int blink_state = 0;
    int* io_avail = (int*)0x30000A;
    int* io_read  = (int*)0x30000B;
    
    while (pos < max - 1) {
        if (*io_avail > 0) {
            c = *io_read;
            if (blink_state) { printchar(8); printchar(' '); printchar(8); blink_state = 0; flush(); }
            
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
        } else {
            vsync(60);
            blink++;
            if (blink >= 30) {
                blink = 0;
                if (blink_state) {
                    printchar(8); printchar(' '); printchar(8);
                    blink_state = 0;
                } else {
                    printchar('_');
                    blink_state = 1;
                }
                flush();
            }
        }
    }
    if (blink_state) { printchar(8); printchar(' '); printchar(8); }
    buf[pos] = 0;
    flush();
    return pos;
}

int main() {
    strcpy(cwd, "/");
    cmd_clear();

    char cmd[MAX_CMD];
    char tok[MAX_CMD];

    while (1) {
        print("user:"); print(cwd); print("> ");
        flush();

        int len = readln(cmd, MAX_CMD);
        if (len == 0) continue;

        char* p = skip_spaces(cmd);
        if (!*p) continue;

        p = next_token(p, tok, MAX_CMD);

        if (strcmp(tok, "help") == 0) cmd_help();
        else if (strcmp(tok, "clear") == 0) cmd_clear();
        else if (strcmp(tok, "reboot") == 0) reboot();
        else if (strcmp(tok, "echo") == 0) {
            p = skip_spaces(p);
            cmd_echo(p);
        } else if (strcmp(tok, "cd") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            cmd_cd(arg);
        } else if (strcmp(tok, "cat") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            cmd_cat(arg);
        } else if (strcmp(tok, "ls") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            cmd_ls(arg);
        } else if (strcmp(tok, "mkdir") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            cmd_mkdir(arg);
        } else if (strcmp(tok, "rm") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            cmd_rm(arg);
        } else if (strcmp(tok, "run") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            p = skip_spaces(p);
            cmd_run(arg, p);
        } else if (strcmp(tok, "as") == 0) {
            p = skip_spaces(p);
            char src[MAX_CMD]; p = next_token(p, src, MAX_CMD);
            p = skip_spaces(p);
            char out[MAX_CMD]; next_token(p, out, MAX_CMD);
            cmd_as(src, out);
        } else if (strcmp(tok, "cc") == 0) {
            p = skip_spaces(p);
            char src[MAX_CMD]; p = next_token(p, src, MAX_CMD);
            p = skip_spaces(p);
            char out[MAX_CMD]; next_token(p, out, MAX_CMD);
            cmd_cc(src, out);
        } else if (strcmp(tok, "edit") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            cmd_edit(arg);
        } else if (strcmp(tok, "crash") == 0) {
            cmd_crash();
        } else if (strcmp(tok, "touch") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            cmd_touch(arg);
        } else if (strcmp(tok, "write") == 0) {
            p = skip_spaces(p);
            char arg[MAX_CMD]; p = next_token(p, arg, MAX_CMD);
            p = skip_spaces(p);
            cmd_write(arg, p);
        } else if (strcmp(tok, "format") == 0) {
            cmd_format();
        } else if (strcmp(tok, "reboot") == 0) {
            cmd_reboot();
        } else {
            char bin_path[256];
            strcpy(bin_path, "/usr/bin/");
            strcat(bin_path, tok);
            strcat(bin_path, ".rov");
            int fd = syscall(32, (int)bin_path, 0, 0);
            if (fd >= 0) {
                syscall(35, fd, 0, 0);
                p = skip_spaces(p);
                cmd_run(bin_path, p);
            } else {
                print("unknown command: ");
                print(tok);
                printchar(10);
            }
        }
    }
    return 0;
}
]]

return shell_c
