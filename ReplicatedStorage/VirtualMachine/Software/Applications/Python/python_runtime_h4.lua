local python_runtime_h4 = [===[
void py_report_error() {
    if (py_repl_mode) {
        print("line ");
        if (py_error_line > 0) printint(py_error_line);
        else print("0");
        print(": error: ");
        print(py_error_text);
        printchar(10);
        return;
    }
    print(py_active_filename[0] ? py_active_filename : "<stdin>");
    if (py_error_line > 0) {
        print(":");
        printint(py_error_line);
    }
    print(": error: ");
    print(py_error_text);
    printchar(10);
}

int py_run_buffer() {
    PyCode* code;
    PyObject* result;
    py_error = 0;
    py_error_line = 0;
    py_error_text[0] = 0;
    py_prepare_lines();
    if (py_error) {
        py_report_error();
        return 0;
    }
    if (py_line_count <= 0) return 1;
    if (py_line_indent[0] != 0) {
        py_set_error("unexpected indentation", py_line_number[0]);
        py_report_error();
        return 0;
    }
    code = py_compile_code_range((PyCompiler*)0, py_active_filename[0] ? py_active_filename : "<stdin>", 0, py_line_count, 0, 1, py_echo_expressions ? 1 : 0, 0, (char**)0, 0);
    if (py_error || !code) {
        py_report_error();
        return 0;
    }
    result = py_vm_run_code(code, &py_global_scope, &py_global_scope, 0, py_echo_expressions);
    if (py_error) {
        py_report_error();
        return 0;
    }
    if (py_echo_expressions && result && result->type != PY_NONE) {
        py_repr_object(result);
        printchar(10);
    }
    return 1;
}

char* py_get_env_value(char** envp, char* key) {
    int key_len;
    key_len = strlen(key);
    while (envp && *envp) {
        if (strncmp(*envp, key, key_len) == 0 && (*envp)[key_len] == '=') {
            return (*envp) + key_len + 1;
        }
        envp++;
    }
    return (char*)0;
}

void py_resolve_path(char* out, char* path, char* cwd) {
    if (!out) return;
    if (!path || !*path) {
        py_copy_limit(out, cwd && *cwd ? cwd : "/", 256);
        return;
    }
    while (path[0] == '.' && path[1] == '/') {
        path += 2;
    }
    if (path[0] == '/') {
        py_copy_limit(out, path, 256);
        return;
    }
    py_copy_limit(out, cwd && *cwd ? cwd : "/", 256);
    if (strlen(out) <= 0) {
        py_copy_limit(out, "/", 256);
    }
    if (out[strlen(out) - 1] != '/') {
        py_append_limit(out, "/", 256);
    }
    py_append_limit(out, path, 256);
}

int py_load_file(char* path) {
    int fd;
    int n;
    int total;
    int i;
    int want;
    fd = syscall(32, (int)path, 1, 0, 0, 0, 0);
    if (fd < 0) {
        py_set_error("cannot open file", 0);
        return 0;
    }
    total = 0;
    while (total < PY_MAX_PROGRAM - 1) {
        want = PY_MAX_PROGRAM - 1 - total;
        if (want > 128) want = 128;
        n = syscall(33, fd, (int)py_file_chunk, want, 0, 0, 0);
        if (n < 0) {
            syscall(35, fd, 0, 0, 0, 0, 0);
            py_set_error("failed to read file", 0);
            return 0;
        }
        if (n == 0) break;
        i = 0;
        while (i < n) {
            py_program[total + i] = py_file_chunk[i];
            i++;
        }
        total += n;
    }
    syscall(35, fd, 0, 0, 0, 0, 0);
    if (total >= PY_MAX_PROGRAM - 1) {
        py_set_error("file is too large", 0);
        return 0;
    }
    py_program_len = total;
    py_program[py_program_len] = 0;
    return 1;
}

int py_register_module_builtionj(pyobject* module_obj, char* name, int builtin_d) {

 if (!obj) {
 py set_error_9)("module ius not initialized", 0);

int py_register_module_builtin(PyObject* module_obj, char* name, int builtin_id) {
    if (!module_obj) {
        py_set_error("module is not initialized", 0);
        return 0;
    }
    if (!py_module_set_attr(module_obj, name, py_make_builtin(name, builtin_id), 0)) return 0;
    return !py_error;
}

int py_register_module_int(PyObject* module_obj, char* name, int value) {
    if (!module_obj) {
        py_set_error("module is not initialized", 0);
        return 0;
    }
    if (!py_module_set_attr(module_obj, name, py_make_int(value), 0)) return 0;
    return !py_error;
}

int py_populate_math_module(PyObject* module_obj) {
    if (!py_register_module_builtin(module_obj, "abs", PY_BUILTIN_MATH_ABS)) return 0;
    if (!py_register_module_builtin(module_obj, "sqrt", PY_BUILTIN_MATH_SQRT)) return 0;
    if (!py_register_module_builtin(module_obj, "pow", PY_BUILTIN_MATH_POW)) return 0;
    if (!py_register_module_builtin(module_obj, "min", PY_BUILTIN_MATH_MIN)) return 0;
    if (!py_register_module_builtin(module_obj, "max", PY_BUILTIN_MATH_MAX)) return 0;
    return !py_error;
}

int py_populate_rovm_module(PyObject* module_obj) {
    if (!py_register_module_int(module_obj, "RED", RED)) return 0;
    if (!py_register_module_int(module_obj, "GREEN", GREEN)) return 0;
    if (!py_register_module_int(module_obj, "BLUE", BLUE)) return 0;
    if (!py_register_module_int(module_obj, "BLACK", BLACK)) return 0;
    if (!py_register_module_int(module_obj, "WHITE", WHITE)) return 0;
    if (!py_register_module_int(module_obj, "KEY_ENTER", KEY_ENTER)) return 0;
    if (!py_register_module_int(module_obj, "KEY_UP", KEY_UP)) return 0;
    if (!py_register_module_int(module_obj, "KEY_DOWN", KEY_DOWN)) return 0;
    if (!py_register_module_int(module_obj, "KEY_LEFT", KEY_LEFT)) return 0;
    if (!py_register_module_int(module_obj, "KEY_RIGHT", KEY_RIGHT)) return 0;
    if (!py_register_module_int(module_obj, "KEY_ESC", KEY_ESC)) return 0;
    if (!py_register_module_int(module_obj, "KEY_SPACE", KEY_SPACE)) return 0;
    if (!py_register_module_builtin(module_obj, "rgb", PY_BUILTIN_ROVM_RGB)) return 0;
    if (!py_register_module_builtin(module_obj, "window", PY_BUILTIN_ROVM_WINDOW)) return 0;
    if (!py_register_module_builtin(module_obj, "set_title", PY_BUILTIN_ROVM_SET_TITLE)) return 0;
    if (!py_register_module_builtin(module_obj, "clear", PY_BUILTIN_ROVM_CLEAR)) return 0;
    if (!py_register_module_builtin(module_obj, "reboot", PY_BUILTIN_ROVM_REBOOT)) return 0;
    if (!py_register_module_builtin(module_obj, "flush", PY_BUILTIN_ROVM_FLUSH)) return 0;
    if (!py_register_module_builtin(module_obj, "getkey", PY_BUILTIN_ROVM_GETKEY)) return 0;
    if (!py_register_module_builtin(module_obj, "getkey_nowait", PY_BUILTIN_ROVM_GETKEY_NOWAIT)) return 0;
    if (!py_register_module_builtin(module_obj, "key_down", PY_BUILTIN_ROVM_KEY_DOWN)) return 0;
    if (!py_register_module_builtin(module_obj, "key_pressed", PY_BUILTIN_ROVM_KEY_PRESSED)) return 0;
    if (!py_register_module_builtin(module_obj, "vsync", PY_BUILTIN_ROVM_VSYNC)) return 0;
    if (!py_register_module_builtin(module_obj, "getpid", PY_BUILTIN_ROVM_GETPID)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_clear_frame", PY_BUILTIN_ROVM_GPU_CLEAR_FRAME)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_draw_rect", PY_BUILTIN_ROVM_GPU_DRAW_RECT)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_draw_line", PY_BUILTIN_ROVM_GPU_DRAW_LINE)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_cls", PY_BUILTIN_ROVM_GPU_CLS)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_set_view", PY_BUILTIN_ROVM_GPU_SET_VIEW)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_set_xy", PY_BUILTIN_ROVM_GPU_SET_XY)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_set_color", PY_BUILTIN_ROVM_GPU_SET_COLOR)) return 0;
    if (!py_register_module_builtin(module_obj, "gpu_wait_frame", PY_BUILTIN_ROVM_GPU_WAIT_FRAME)) return 0;
    return !py_error;
}

int py_init_math_module() {
    py_math_module_obj = py_make_module("math", 0);
    if (py_error || !py_math_module_obj) return 0;
    return py_populate_math_module(py_math_module_obj);
}

int py_init_rovm_module() {
    py_rovm_module_obj = py_make_module("rovm", 0);
    if (py_error || !py_rovm_module_obj) return 0;
    return py_populate_rovm_module(py_rovm_module_obj);
}

PyObject* py_import_module(char* name, int line_no) {
    if (name && strcmp(name, "math") == 0) {
        if (!py_math_module_obj) py_set_error("math module is unavailable", line_no);
        return py_math_module_obj ? py_math_module_obj : py_make_none();
    }
    if (name && strcmp(name, "rovm") == 0) {
        if (!py_rovm_module_obj) py_set_error("rovm module is unavailable", line_no);
        return py_rovm_module_obj ? py_rovm_module_obj : py_make_none();
    }
    py_set_name_error("unknown module ", name, line_no);
    return py_make_none();
}

void py_runtime_init() {
    PyObject* none_obj;
    PyObject* true_obj;
    PyObject* false_obj;
    py_reset_program();
    py_line_count = 0;
    py_error = 0;
    py_error_line = 0;
    py_error_text[0] = 0;
    py_active_filename[0] = 0;
    py_script_path[0] = 0;
    py_expr_text = (char*)0;
    py_expr_pos = 0;
    py_expr_compiler = (PyCompiler*)0;
    py_expr_line = 0;
    py_repl_mode = 0;
    py_echo_expressions = 0;
    py_math_module_obj = (PyObject*)0;
    py_rovm_module_obj = (PyObject*)0;
    none_obj = &py_none_obj;
    true_obj = &py_true_obj;
    false_obj = &py_false_obj;

    none_obj->type = PY_NONE;
    none_obj->int_value = 0;
    none_obj->str_value = (char*)0;
    none_obj->list_value = (PyList*)0;
    none_obj->func_value = (PyFunction*)0;
    none_obj->code_value = (PyCode*)0;
    none_obj->iter_value = (PyIter*)0;
    none_obj->module_value = (PyModule*)0;

    true_obj->type = PY_BOOL;
    true_obj->int_value = 1;
    true_obj->str_value = (char*)0;
    true_obj->list_value = (PyList*)0;
    true_obj->func_value = (PyFunction*)0;
    true_obj->code_value = (PyCode*)0;
    true_obj->iter_value = (PyIter*)0;
    true_obj->module_value = (PyModule*)0;

    false_obj->type = PY_BOOL;
    false_obj->int_value = 0;
    false_obj->str_value = (char*)0;
    false_obj->list_value = (PyList*)0;
    false_obj->func_value = (PyFunction*)0;
    false_obj->code_value = (PyCode*)0;
    false_obj->iter_value = (PyIter*)0;
    false_obj->module_value = (PyModule*)0;

    py_scope_init(&py_global_scope, (PyScope*)0);
    if (py_error) return;
    py_scope_set(&py_global_scope, "print", py_make_builtin("print", PY_BUILTIN_PRINT), 0);
    py_scope_set(&py_global_scope, "len", py_make_builtin("len", PY_BUILTIN_LEN), 0);
    py_scope_set(&py_global_scope, "range", py_make_builtin("range", PY_BUILTIN_RANGE), 0);
    if (py_error) return;
    py_init_math_module();
    if (py_error) return;
    py_init_rovm_module();
}

void py_bind_argv_repl() {
    py_scope_set(&py_global_scope, "argv", py_make_list(), 0);
}

void py_bind_argv_script(char* script_path, int argc, char** argv) {
    PyObject* argv_list;
    int i;
    argv_list = py_make_list();
    if (py_error) return;
    py_list_append(argv_list, py_make_string(script_path ? script_path : ""), 0);
    if (py_error) return;
    i = 2;
    while (argv && i < argc && !py_error) {
        py_list_append(argv_list, py_make_string(argv[i] ? argv[i] : ""), 0);
        i++;
    }
    if (py_error) return;
    py_scope_set(&py_global_scope, "argv", argv_list, 0);
}
]===]

python_runtime_h4 = python_runtime_h4 .. [===[
void py_print_repl_banner() {
    print("ROVM Python 3 subset (PVM v1)\n");
    print("Type \"help\", \"copyright\", \"credits\" or \"license\" for more information.\n");
}

void py_print_help() {
    print("This build implements a strict Python 3-style subset.\n");
    print("Supported: ints, bools, strings, lists, indexing, if/elif/else,\n");
    print("while, for-in, def, return, pass, import/from-import,\n");
    print("print(), len(), range(), import math, import rovm.\n");
}

void py_print_help_topic(char* topic) {
    if (!topic || !*topic) {
        py_print_help();
        return;
    }
    if (strcmp(topic, "modules") == 0) {
        print("Modules: math, rovm.\n");
        print("math provides integer helpers like sqrt() and pow().\n");
        print("rovm exposes window, keyboard, system, and GPU calls.\n");
        return;
    }
    if (strcmp(topic, "math") == 0) {
        print("math is integer-only in this runtime.\n");
        print("Available: abs(x), sqrt(x), pow(x, y), min(a, b), max(a, b).\n");
        return;
    }
    if (strcmp(topic, "rovm") == 0) {
        print("rovm includes window(), set_title(), clear(), flush(), reboot(),\n");
        print("getkey(), getkey_nowait(), key_down(), key_pressed(), vsync(),\n");
        print("getpid(), rgb(), and GPU helpers like gpu_draw_rect().\n");
        return;
    }
    print("No detailed documentation is bundled for '");
    print(topic);
    print("'.\n");
}

void py_print_copyright_notice() {
    print("ROVM Python subset runtime.\n");
    print("Behavior is inspired by Python, but this is not CPython.\n");
}

void py_print_credits_notice() {
    print("Implemented for the ROVM userspace runtime.\n");
    print("Thanks to the Python language community for the reference model.\n");
}

void py_print_license_notice() {
    print("This runtime is a custom implementation for ROVM.\n");
}

void py_run_help_utility() {
    int len;
    char help_clean[256];
    print("ROVM Python subset help. Enter a topic name, or 'q' to quit.\n");
    while (1) {
        len = py_read_line("help> ", py_input_line, 256);
        if (len < 0) {
            printchar(10);
            return;
        }
        py_sanitize_line(py_input_line, help_clean, 256);
        if (strlen(help_clean) <= 0) continue;
        if (strcmp(help_clean, "q") == 0 || strcmp(help_clean, "quit") == 0) return;
        if (strcmp(help_clean, "keywords") == 0) {
            print("Supported keywords: and, def, elif, else, False, for, from,\n");
            print("if, import, None, not, or, pass, return, True, while.\n");
            continue;
        }
        if (strcmp(help_clean, "topics") == 0) {
            print("Topics: functions, lists, strings, loops, conditionals, modules.\n");
            continue;
        }
        py_print_help_topic(help_clean);
    }
}

int py_main(int argc, char** argv, char** envp) {
    int len;
    int collecting;
    char* cwd;
    char* script_path;

    py_runtime_init();
    if (py_error) {
        py_report_error();
        return 1;
    }

    script_path = py_get_env_value(envp, "PY_SCRIPT");
    if (script_path && *script_path) {
        py_copy_limit(py_script_path, script_path, 256);
        py_copy_limit(py_active_filename, py_script_path, 256);
        py_repl_mode = 0;
        py_bind_argv_script(py_script_path, argc, argv);
        if (py_error) {
            py_report_error();
            return 1;
        }
        if (!py_load_file(py_script_path)) {
            py_report_error();
            return 1;
        }
        py_echo_expressions = 0;
        if (!py_run_buffer()) return 1;
        return 0;
    }

    if (argc >= 2) {
        cwd = py_get_env_value(envp, "PWD");
        py_resolve_path(py_script_path, argv[1], cwd ? cwd : "/");
        py_copy_limit(py_active_filename, py_script_path, 256);
        py_repl_mode = 0;
        py_bind_argv_script(py_script_path, argc, argv);
        if (py_error) {
            py_report_error();
            return 1;
        }
        if (!py_load_file(py_script_path)) {
            py_report_error();
            return 1;
        }
        py_echo_expressions = 0;
        if (!py_run_buffer()) return 1;
        return 0;
    }

    py_repl_mode = 1;
    py_copy_limit(py_active_filename, "<stdin>", 256);
    py_bind_argv_repl();
    if (py_error) {
        py_report_error();
        return 1;
    }

    collecting = 0;
    py_print_repl_banner();

    while (1) {
        len = py_read_line(collecting ? "... " : ">>> ", py_input_line, 256);
        if (len < 0) {
            printchar(10);
            return 0;
        }

        if (len == 0) {
            if (collecting && py_program_len > 0) {
                py_echo_expressions = 0;
                py_run_buffer();
                py_reset_program();
                collecting = 0;
            }
            continue;
        }

        py_sanitize_line(py_input_line, py_clean_line, 256);
        if (strlen(py_clean_line) <= 0) {
            if (collecting) continue;
            continue;
        }

        if (!collecting) {
            if (strcmp(py_clean_line, "help") == 0) {
                py_print_help();
                continue;
            }
            if (strcmp(py_clean_line, "help()") == 0) {
                py_run_help_utility();
                continue;
            }
            if (strncmp(py_clean_line, "help(", 5) == 0 && py_clean_line[strlen(py_clean_line) - 1] == ')') {
                py_copy_trim_range(py_clean_line, 5, strlen(py_clean_line) - 2, py_saved_expr, 256);
                if (strlen(py_saved_expr) <= 0) py_run_help_utility();
                else py_print_help_topic(py_saved_expr);
                continue;
            }
            if (strcmp(py_clean_line, "copyright") == 0) {
                py_print_copyright_notice();
                continue;
            }
            if (strcmp(py_clean_line, "credits") == 0) {
                py_print_credits_notice();
                continue;
            }
            if (strcmp(py_clean_line, "license") == 0) {
                py_print_license_notice();
                continue;
            }
            if (strcmp(py_clean_line, "clear") == 0) {
                syscall(5, 0, 0, 0, 0, 0, 0);
                py_print_repl_banner();
                continue;
            }
            if (strcmp(py_clean_line, "exit") == 0 || strcmp(py_clean_line, "quit") == 0 ||
                strcmp(py_clean_line, "exit()") == 0 || strcmp(py_clean_line, "quit()") == 0) {
                return 0;
            }
        }

        py_append_program_line(py_input_line);
        if (py_error) {
            py_report_error();
            py_error = 0;
            py_error_line = 0;
            py_error_text[0] = 0;
            py_reset_program();
            collecting = 0;
            continue;
        }

        if (collecting || py_line_opens_block(py_input_line)) {
            collecting = 1;
            continue;
        }

        py_echo_expressions = 1;
        py_run_buffer();
        py_reset_program();
        collecting = 0;
    }
    return 0;
}
]===]

return python_runtime_h4
