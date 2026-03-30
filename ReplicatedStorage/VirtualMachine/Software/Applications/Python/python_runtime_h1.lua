local python_runtime_h1 = [===[
#ifndef PYTHON_RUNTIME_H
#define PYTHON_RUNTIME_H

#include <rovm.h>
#include <string.h>
#include <ctype.h>
#include <stdlib.h>
#include <stdio.h>

#define PY_NONE 0
#define PY_INT 1
#define PY_BOOL 2
#define PY_STRING 3
#define PY_LIST 4
#define PY_FUNCTION 5
#define PY_CODE 6
#define PY_ITER 7
#define PY_MODULE 8

#define PY_BUILTIN_NONE 0
#define PY_BUILTIN_PRINT 1
#define PY_BUILTIN_LEN 2
#define PY_BUILTIN_RANGE 3
#define PY_BUILTIN_MATH_ABS 10
#define PY_BUILTIN_MATH_SQRT 11
#define PY_BUILTIN_MATH_POW 12
#define PY_BUILTIN_MATH_MIN 13
#define PY_BUILTIN_MATH_MAX 14
#define PY_BUILTIN_ROVM_RGB 30
#define PY_BUILTIN_ROVM_WINDOW 31
#define PY_BUILTIN_ROVM_SET_TITLE 32
#define PY_BUILTIN_ROVM_CLEAR 33
#define PY_BUILTIN_ROVM_REBOOT 34
#define PY_BUILTIN_ROVM_FORMAT 35
#define PY_BUILTIN_ROVM_FLUSH 36
#define PY_BUILTIN_ROVM_GETKEY 37
#define PY_BUILTIN_ROVM_GETKEY_NOWAIT 38
#define PY_BUILTIN_ROVM_KEY_DOWN 39
#define PY_BUILTIN_ROVM_KEY_PRESSED 40
#define PY_BUILTIN_ROVM_VSYNC 41
#define PY_BUILTIN_ROVM_GETPID 42
#define PY_BUILTIN_ROVM_GPU_CLEAR_FRAME 43
#define PY_BUILTIN_ROVM_GPU_DRAW_RECT 44
#define PY_BUILTIN_ROVM_GPU_DRAW_LINE 45
#define PY_BUILTIN_ROVM_GPU_CLS 46
#define PY_BUILTIN_ROVM_GPU_SET_VIEW 47
#define PY_BUILTIN_ROVM_GPU_SET_XY 48
#define PY_BUILTIN_ROVM_GPU_SET_COLOR 49
#define PY_BUILTIN_ROVM_GPU_WAIT_FRAME 50

#define PY_OP_LOAD_CONST 1
#define PY_OP_LOAD_NAME 2
#define PY_OP_STORE_NAME 3
#define PY_OP_POP_TOP 4
#define PY_OP_UNARY_POSITIVE 5
#define PY_OP_UNARY_NEGATIVE 6
#define PY_OP_UNARY_NOT 7
#define PY_OP_BINARY_ADD 8
#define PY_OP_BINARY_SUB 9
#define PY_OP_BINARY_MUL 10
#define PY_OP_BINARY_DIV 11
#define PY_OP_BINARY_MOD 12
#define PY_OP_COMPARE_OP 13
#define PY_OP_JUMP 14
#define PY_OP_POP_JUMP_IF_FALSE 15
#define PY_OP_JUMP_IF_FALSE_OR_POP 16
#define PY_OP_JUMP_IF_TRUE_OR_POP 17
#define PY_OP_BUILD_LIST 18
#define PY_OP_BINARY_SUBSCR 19
#define PY_OP_CALL 20
#define PY_OP_RETURN_VALUE 21
#define PY_OP_MAKE_FUNCTION 22
#define PY_OP_GET_ITER 23
#define PY_OP_FOR_ITER 24
#define PY_OP_IMPORT_NAME 25
#define PY_OP_LOAD_ATTR 26

#define PY_CMP_LT 1
#define PY_CMP_LE 2
#define PY_CMP_GT 3
#define PY_CMP_GE 4
#define PY_CMP_EQ 10
#define PY_CMP_NE 11

#define PY_MAX_PROGRAM 16384
#define PY_MAX_LINES 512
#define PY_MAX_VARS 96
#define PY_MAX_NAME 32
#define PY_MAX_ERROR 160
#define PY_MAX_ARGS 16

struct PyObject;
typedef struct PyObject PyObject;

struct PyCode;
typedef struct PyCode PyCode;

struct PyCompiler;
typedef struct PyCompiler PyCompiler;

struct PyModule;
typedef struct PyModule PyModule;

struct PyList {
    int count;
    int cap;
    PyObject** items;
};
typedef struct PyList PyList;

struct PyInstr {
    int op;
    int arg;
    int line_no;
};
typedef struct PyInstr PyInstr;

struct PyFunction {
    int builtin_id;
    char* name;
    PyCode* code;
    struct PyScope* globals;
    int arg_count;
    char** arg_names;
};
typedef struct PyFunction PyFunction;

struct PyIter {
    PyObject* source;
    int index;
};
typedef struct PyIter PyIter;

struct PyObject {
    int type;
    int int_value;
    char* str_value;
    PyList* list_value;
    PyFunction* func_value;
    PyCode* code_value;
    PyIter* iter_value;
    PyModule* module_value;
};

struct PyVar {
    int used;
    char* name;
    PyObject* value;
};
typedef struct PyVar PyVar;

struct PyScope {
    struct PyScope* parent;
    int used[PY_MAX_VARS];
    char* names[PY_MAX_VARS];
    PyObject* values[PY_MAX_VARS];
};
typedef struct PyScope PyScope;

struct PyParser {
    char* text;
    int pos;
    int line_no;
};
typedef struct PyParser PyParser;

struct PyModule {
    char* name;
    PyScope scope;
};
typedef struct PyModule PyModule;

struct PyCode {
    char* name;
    int arg_count;
    char** arg_names;
    int local_count;
    char** local_names;
    int single_mode;
    int instruction_count;
    int instruction_cap;
    int* instr_ops;
    int* instr_args;
    int* instr_lines;
    int const_count;
    int const_cap;
    PyObject** constants;
    int name_count;
    int name_cap;
    char** names;
};
typedef struct PyCode PyCode;

struct PyCompiler {
    struct PyCompiler* parent;
    PyCode* code;
    int is_module;
    int single_mode;
    int allow_return;
    int local_count;
    int local_cap;
    char** local_names;
};
typedef struct PyCompiler PyCompiler;

struct PyExecFrame {
    struct PyExecFrame* parent;
    PyCode* code;
    PyScope* locals;
    PyScope* globals;
    PyObject** stack;
    int stack_top;
    int stack_cap;
    int ip;
    int allow_return;
    int echo_expression;
};
typedef struct PyExecFrame PyExecFrame;

char py_input_line[256];
char py_program[PY_MAX_PROGRAM];
int py_program_len;
int py_line_start[PY_MAX_LINES];
int py_line_len[PY_MAX_LINES];
int py_line_indent[PY_MAX_LINES];
int py_line_number[PY_MAX_LINES];
int py_line_count;
char py_stmt[256];
char py_saved_expr[256];
char py_error_text[PY_MAX_ERROR];
char py_active_filename[256];
char py_clean_line[256];
char py_script_path[256];
char py_file_chunk[128];
char py_name_parse[PY_MAX_NAME];
char py_name_assign[PY_MAX_NAME];
char py_name_loop[PY_MAX_NAME];
char py_name_def[PY_MAX_NAME];
char py_name_arg[PY_MAX_NAME];
char py_name_attr[PY_MAX_NAME];
char py_assign_op[3];
char py_string_temp[256];
char* py_expr_text;
int py_expr_pos;
PyCompiler* py_expr_compiler;
int py_expr_line;
int py_error;
int py_error_line;
int py_repl_mode;
int py_echo_expressions;
PyScope py_global_scope;
PyObject py_none_obj;
PyObject py_true_obj;
PyObject py_false_obj;
PyObject* py_math_module_obj;
PyObject* py_rovm_module_obj;

int py_is_name_start(int c);
int py_is_name_char(int c);
void py_set_error(char* text, int line_no);
void py_set_name_error(char* prefix, char* name, int line_no);
void py_copy_limit(char* dest, char* src, int max_len);
void py_append_limit(char* dest, char* src, int max_len);
void py_copy_trim_range(char* src, int start, int end, char* dest, int max_len);
int py_scope_find_local_index(PyScope* scope, char* name);
void py_scope_init(PyScope* scope, PyScope* parent);
void py_scope_set(PyScope* scope, char* name, PyObject* value, int line_no);
PyObject* py_scope_get(PyScope* scope, char* name, int line_no);
PyObject* py_make_code_object(PyCode* code);
PyObject* py_make_user_function(PyCode* code, PyScope* globals);
PyObject* py_make_iter_object(PyObject* source, int line_no);
PyObject* py_make_module(char* name, int line_no);
int py_module_set_attr(PyObject* module_obj, char* name, PyObject* value, int line_no);
PyObject* py_module_get_attr(PyObject* module_obj, char* name, int line_no);
PyObject* py_import_module(char* name, int line_no);
PyObject* py_iter_next(PyObject* iter_obj, int line_no, int* has_item);
PyCode* py_alloc_code(char* name, int arg_count, char** arg_names, int single_mode);
int py_code_add_const(PyCode* code, PyObject* value);
int py_code_add_name(PyCode* code, char* name);
int py_emit_instruction(PyCode* code, int op, int arg, int line_no);
void py_patch_instruction_arg(PyCode* code, int index, int arg);
int py_compiler_add_local(PyCompiler* compiler, char* name);
int py_compiler_has_local(PyCompiler* compiler, char* name);
int py_compiler_name_in_parent_locals(PyCompiler* compiler, char* name);
int py_validate_name_load(PyCompiler* compiler, char* name, int line_no);
int py_is_reserved_keyword_name(char* name);
int py_compile_expression_text(PyCompiler* compiler, char* text, int line_no);
PyCode* py_compile_code_range(PyCompiler* parent, char* name, int start, int end, int indent, int is_module, int single_mode, int allow_return, char** arg_names, int arg_count);
PyObject* py_vm_run_code(PyCode* code, PyScope* locals, PyScope* globals, int allow_return, int echo_expression);

void py_copy_limit(char* dest, char* src, int max_len) {
    int i;
    i = 0;
    while (src && src[i] && i < max_len - 1) {
        dest[i] = src[i];
        i++;
    }
    dest[i] = 0;
}

void py_append_limit(char* dest, char* src, int max_len) {
    int i;
    int dlen;
    dlen = strlen(dest);
    i = 0;
    while (src && src[i] && dlen < max_len - 1) {
        dest[dlen] = src[i];
        dlen++;
        i++;
    }
    dest[dlen] = 0;
}

int py_is_name_start(int c) {
    return isalpha(c) || c == '_';
}

int py_is_name_char(int c) {
    return isalnum(c) || c == '_';
}

void py_set_error(char* text, int line_no) {
    if (!py_error) {
        py_error = 1;
        py_error_line = line_no;
        py_copy_limit(py_error_text, text, PY_MAX_ERROR);
    }
}

void py_set_name_error(char* prefix, char* name, int line_no) {
    if (!py_error) {
        py_error = 1;
        py_error_line = line_no;
        py_error_text[0] = 0;
        py_append_limit(py_error_text, prefix ? prefix : "", PY_MAX_ERROR);
        if (name && *name) {
            py_append_limit(py_error_text, "'", PY_MAX_ERROR);
            py_append_limit(py_error_text, name, PY_MAX_ERROR);
            py_append_limit(py_error_text, "'", PY_MAX_ERROR);
        }
    }
}

char* py_strdup_text(char* src) {
    int len;
    char* out;
    if (!src) return (char*)0;
    len = strlen(src);
    out = (char*)malloc(len + 1);
    if (!out) {
        py_set_error("out of memory", 0);
        return (char*)0;
    }
    memcpy(out, src, len);
    out[len] = 0;
    return out;
}

char* py_strdup_len(char* src, int len) {
    char* out;
    out = (char*)malloc(len + 1);
    if (!out) {
        py_set_error("out of memory", 0);
        return (char*)0;
    }
    if (len > 0) memcpy(out, src, len);
    out[len] = 0;
    return out;
}

PyObject* py_alloc_object(int type) {
    PyObject* obj;
    obj = (PyObject*)malloc(sizeof(PyObject));
    if (!obj) {
        py_set_error("out of memory", 0);
        return &py_none_obj;
    }
    obj->type = type;
    obj->int_value = 0;
    obj->str_value = (char*)0;
    obj->list_value = (PyList*)0;
    obj->func_value = (PyFunction*)0;
    obj->code_value = (PyCode*)0;
    obj->iter_value = (PyIter*)0;
    obj->module_value = (PyModule*)0;
    return obj;
}

PyObject* py_make_none() {
    return &py_none_obj;
}

PyObject* py_make_bool(int value) {
    if (value) return &py_true_obj;
    return &py_false_obj;
}

PyObject* py_make_int(int value) {
    PyObject* obj;
    obj = py_alloc_object(PY_INT);
    if (obj == &py_none_obj) return obj;
    obj->int_value = value;
    return obj;
}

PyObject* py_make_string(char* text) {
    PyObject* obj;
    obj = py_alloc_object(PY_STRING);
    if (obj == &py_none_obj) return obj;
    obj->str_value = py_strdup_text(text ? text : "");
    if (!obj->str_value) return &py_none_obj;
    return obj;
}

PyObject* py_make_string_len(char* text, int len) {
    PyObject* obj;
    obj = py_alloc_object(PY_STRING);
    if (obj == &py_none_obj) return obj;
    obj->str_value = py_strdup_len(text, len);
    if (!obj->str_value) return &py_none_obj;
    return obj;
}

PyObject* py_make_list() {
    PyObject* obj;
    PyList* list;
    obj = py_alloc_object(PY_LIST);
    if (obj == &py_none_obj) return obj;
    list = (PyList*)malloc(sizeof(PyList));
    if (!list) {
        py_set_error("out of memory", 0);
        return &py_none_obj;
    }
    list->count = 0;
    list->cap = 0;
    list->items = (PyObject**)0;
    obj->list_value = list;
    return obj;
}

PyFunction* py_alloc_function() {
    PyFunction* fn;
    fn = (PyFunction*)malloc(sizeof(PyFunction));
    if (!fn) {
        py_set_error("out of memory", 0);
        return (PyFunction*)0;
    }
    fn->builtin_id = PY_BUILTIN_NONE;
    fn->name = (char*)0;
    fn->code = (PyCode*)0;
    fn->globals = (PyScope*)0;
    fn->arg_count = 0;
    fn->arg_names = (char**)0;
    return fn;
}

PyObject* py_make_function_object(PyFunction* fn) {
    PyObject* obj;
    obj = py_alloc_object(PY_FUNCTION);
    if (obj == &py_none_obj) return obj;
    obj->func_value = fn;
    return obj;
}

PyObject* py_make_builtin(char* name, int builtin_id) {
    PyFunction* fn;
    fn = py_alloc_function();
    if (!fn) return &py_none_obj;
    fn->builtin_id = builtin_id;
    fn->name = py_strdup_text(name);
    fn->globals = &py_global_scope;
    return py_make_function_object(fn);
}

PyObject* py_make_code_object(PyCode* code) {
    PyObject* obj;
    obj = py_alloc_object(PY_CODE);
    if (obj == &py_none_obj) return obj;
    obj->code_value = code;
    return obj;
}

PyObject* py_make_user_function(PyCode* code, PyScope* globals) {
    PyFunction* fn;
    if (!code) {
        py_set_error("invalid function body", 0);
        return py_make_none();
    }
    fn = py_alloc_function();
    if (!fn) return py_make_none();
    fn->name = py_strdup_text(code->name ? code->name : "<function>");
    fn->code = code;
    fn->globals = globals ? globals : &py_global_scope;
    fn->arg_count = code->arg_count;
    fn->arg_names = code->arg_names;
    return py_make_function_object(fn);
}

PyObject* py_make_iter_object(PyObject* source, int line_no) {
    PyObject* obj;
    PyIter* iter;
    if (!source || (source->type != PY_LIST && source->type != PY_STRING)) {
        py_set_error("object is not iterable", line_no);
        return py_make_none();
    }
    iter = (PyIter*)malloc(sizeof(PyIter));
    if (!iter) {
        py_set_error("out of memory", line_no);
        return py_make_none();
    }
    iter->source = source;
    iter->index = 0;
    obj = py_alloc_object(PY_ITER);
    if (obj == &py_none_obj) return obj;
    obj->iter_value = iter;
    return obj;
}

PyObject* py_make_module(char* name, int line_no) {
    PyObject* obj;
    PyModule* module;
    obj = py_alloc_object(PY_MODULE);
    if (obj == &py_none_obj) return obj;
    module = (PyModule*)malloc(sizeof(PyModule));
    if (!module) {
        py_set_error("out of memory", line_no);
        return py_make_none();
    }
    module->name = py_strdup_text(name ? name : "module");
    if (!module->name) return py_make_none();
    py_scope_init(&module->scope, (PyScope*)0);
    if (py_error) return py_make_none();
    obj->module_value = module;
    return obj;
}

int py_module_set_attr(PyObject* module_obj, char* name, PyObject* value, int line_no) {
    if (!module_obj || module_obj->type != PY_MODULE || !module_obj->module_value) {
        py_set_error("expected a module", line_no);
        return 0;
    }
    py_scope_set(&module_obj->module_value->scope, name, value, line_no);
    return !py_error;
}

PyObject* py_make_builtin_module_attr(char* name, int builtin_id) {
    return py_make_builtin(name, builtin_id);
}

PyObject* py_make_math_module_attr(char* name) {
    if (!name) return (PyObject*)0;
    if (strcmp(name, "abs") == 0) return py_make_builtin_module_attr("abs", PY_BUILTIN_MATH_ABS);
    if (strcmp(name, "sqrt") == 0) return py_make_builtin_module_attr("sqrt", PY_BUILTIN_MATH_SQRT);
    if (strcmp(name, "pow") == 0) return py_make_builtin_module_attr("pow", PY_BUILTIN_MATH_POW);
    if (strcmp(name, "min") == 0) return py_make_builtin_module_attr("min", PY_BUILTIN_MATH_MIN);
    if (strcmp(name, "max") == 0) return py_make_builtin_module_attr("max", PY_BUILTIN_MATH_MAX);
    return (PyObject*)0;
}

PyObject* py_make_rovm_module_attr(char* name) {
    if (!name) return (PyObject*)0;
    if (strcmp(name, "RED") == 0) return py_make_int(RED);
    if (strcmp(name, "GREEN") == 0) return py_make_int(GREEN);
    if (strcmp(name, "BLUE") == 0) return py_make_int(BLUE);
    if (strcmp(name, "BLACK") == 0) return py_make_int(BLACK);
    if (strcmp(name, "WHITE") == 0) return py_make_int(WHITE);
    if (strcmp(name, "KEY_ENTER") == 0) return py_make_int(KEY_ENTER);
    if (strcmp(name, "KEY_UP") == 0) return py_make_int(KEY_UP);
    if (strcmp(name, "KEY_DOWN") == 0) return py_make_int(KEY_DOWN);
    if (strcmp(name, "KEY_LEFT") == 0) return py_make_int(KEY_LEFT);
    if (strcmp(name, "KEY_RIGHT") == 0) return py_make_int(KEY_RIGHT);
    if (strcmp(name, "KEY_ESC") == 0) return py_make_int(KEY_ESC);
    if (strcmp(name, "KEY_SPACE") == 0) return py_make_int(KEY_SPACE);
    if (strcmp(name, "rgb") == 0) return py_make_builtin_module_attr("rgb", PY_BUILTIN_ROVM_RGB);
    if (strcmp(name, "window") == 0) return py_make_builtin_module_attr("window", PY_BUILTIN_ROVM_WINDOW);
    if (strcmp(name, "set_title") == 0) return py_make_builtin_module_attr("set_title", PY_BUILTIN_ROVM_SET_TITLE);
    if (strcmp(name, "clear") == 0) return py_make_builtin_module_attr("clear", PY_BUILTIN_ROVM_CLEAR);
    if (strcmp(name, "reboot") == 0) return py_make_builtin_module_attr("reboot", PY_BUILTIN_ROVM_REBOOT);
    if (strcmp(name, "flush") == 0) return py_make_builtin_module_attr("flush", PY_BUILTIN_ROVM_FLUSH);
    if (strcmp(name, "getkey") == 0) return py_make_builtin_module_attr("getkey", PY_BUILTIN_ROVM_GETKEY);
    if (strcmp(name, "getkey_nowait") == 0) return py_make_builtin_module_attr("getkey_nowait", PY_BUILTIN_ROVM_GETKEY_NOWAIT);
    if (strcmp(name, "key_down") == 0) return py_make_builtin_module_attr("key_down", PY_BUILTIN_ROVM_KEY_DOWN);
    if (strcmp(name, "key_pressed") == 0) return py_make_builtin_module_attr("key_pressed", PY_BUILTIN_ROVM_KEY_PRESSED);
    if (strcmp(name, "vsync") == 0) return py_make_builtin_module_attr("vsync", PY_BUILTIN_ROVM_VSYNC);
    if (strcmp(name, "getpid") == 0) return py_make_builtin_module_attr("getpid", PY_BUILTIN_ROVM_GETPID);
    if (strcmp(name, "gpu_clear_frame") == 0) return py_make_builtin_module_attr("gpu_clear_frame", PY_BUILTIN_ROVM_GPU_CLEAR_FRAME);
    if (strcmp(name, "gpu_draw_rect") == 0) return py_make_builtin_module_attr("gpu_draw_rect", PY_BUILTIN_ROVM_GPU_DRAW_RECT);
    if (strcmp(name, "gpu_draw_line") == 0) return py_make_builtin_module_attr("gpu_draw_line", PY_BUILTIN_ROVM_GPU_DRAW_LINE);
    if (strcmp(name, "gpu_cls") == 0) return py_make_builtin_module_attr("gpu_cls", PY_BUILTIN_ROVM_GPU_CLS);
    if (strcmp(name, "gpu_set_view") == 0) return py_make_builtin_module_attr("gpu_set_view", PY_BUILTIN_ROVM_GPU_SET_VIEW);
    if (strcmp(name, "gpu_set_xy") == 0) return py_make_builtin_module_attr("gpu_set_xy", PY_BUILTIN_ROVM_GPU_SET_XY);
    if (strcmp(name, "gpu_set_color") == 0) return py_make_builtin_module_attr("gpu_set_color", PY_BUILTIN_ROVM_GPU_SET_COLOR);
    if (strcmp(name, "gpu_wait_frame") == 0) return py_make_builtin_module_attr("gpu_wait_frame", PY_BUILTIN_ROVM_GPU_WAIT_FRAME);
    return (PyObject*)0;
}

PyObject* py_module_get_attr(PyObject* module_obj, char* name, int line_no) {
    int slot;
    PyScope* scope;
    PyObject* value;
    if (!module_obj || module_obj->type != PY_MODULE || !module_obj->module_value) {
        py_set_error("object has no attributes", line_no);
        return py_make_none();
    }
    scope = &module_obj->module_value->scope;
    slot = py_scope_find_local_index(scope, name);
    if (slot >= 0) return scope->values[slot];
    value = (PyObject*)0;
    if (module_obj == py_math_module_obj) {
        value = py_make_math_module_attr(name);
    } else if (module_obj == py_rovm_module_obj) {
        value = py_make_rovm_module_attr(name);
    } else if (module_obj->module_value->name && strcmp(module_obj->module_value->name, "math") == 0) {
        value = py_make_math_module_attr(name);
    } else if (module_obj->module_value->name && strcmp(module_obj->module_value->name, "rovm") == 0) {
        value = py_make_rovm_module_attr(name);
    }
    if (value) {
        py_module_set_attr(module_obj, name, value, line_no);
        if (py_error) return py_make_none();
        return value;
    }
    py_set_name_error("module has no attribute ", name, line_no);
    return py_make_none();
}

PyObject* py_iter_next(PyObject* iter_obj, int line_no, int* has_item) {
    PyIter* iter;
    if (has_item) *has_item = 0;
    if (!iter_obj || iter_obj->type != PY_ITER || !iter_obj->iter_value) {
        py_set_error("invalid iterator", line_no);
        return py_make_none();
    }
    iter = iter_obj->iter_value;
    if (!iter->source) {
        if (has_item) *has_item = 0;
        return py_make_none();
    }
    if (iter->source->type == PY_LIST) {
        if (!iter->source->list_value || iter->index >= iter->source->list_value->count) {
            if (has_item) *has_item = 0;
            return py_make_none();
        }
        if (has_item) *has_item = 1;
        return iter->source->list_value->items[iter->index++];
    }
    if (iter->source->type == PY_STRING) {
        int len;
        len = strlen(iter->source->str_value ? iter->source->str_value : "");
        if (iter->index >= len) {
            if (has_item) *has_item = 0;
            return py_make_none();
        }
        if (has_item) *has_item = 1;
        return py_make_string_len(iter->source->str_value + iter->index++, 1);
    }
    py_set_error("object is not iterable", line_no);
    return py_make_none();
}

int py_is_int_like(PyObject* obj) {
    return obj->type == PY_INT || obj->type == PY_BOOL;
}

void py_print_plain_string(char* text) {
    int i;
    if (!text) return;
    i = 0;
    while (text[i] && i < 1024) {
        printchar(text[i]);
        i++;
    }
    if (i >= 1024 && text[i]) print("...");
}

int py_try_print_string_literal(char* text) {
    int len;
    int i;
    int escaped;
    int quote;
    char c;
    if (!text) return 0;
    len = strlen(text);
    if (len < 2) return 0;
    quote = text[0];
    if (quote != '"' && quote != '\'') return 0;
    i = 1;
    escaped = 0;
    while (i < len) {
        c = text[i];
        if (!escaped && c == '\\') {
            escaped = 1;
            i++;
            continue;
        }
        if (!escaped && c == quote) break;
        escaped = 0;
        i++;
    }
    if (i != len - 1) return 0;
    i = 1;
    escaped = 0;
    while (i < len - 1) {
        c = text[i];
        if (!escaped && c == '\\') {
            escaped = 1;
            i++;
            continue;
        }
        if (escaped) {
            if (c == 'n') c = '\n';
            else if (c == 't') c = '\t';
            else if (c == 'r') c = '\r';
            escaped = 0;
        }
        printchar(c);
        i++;
    }
    printchar(10);
    return 1;
}

int py_truthy(PyObject* obj) {
    if (obj == &py_none_obj || obj->type == PY_NONE) return 0;
    if (obj == &py_false_obj) return 0;
    if (obj == &py_true_obj) return 1;
    if (obj->type == PY_STRING) return obj->str_value && obj->str_value[0] != 0;
    if (obj->type == PY_LIST) return obj->list_value && obj->list_value->count > 0;
    if (obj->type == PY_FUNCTION || obj->type == PY_CODE || obj->type == PY_ITER || obj->type == PY_MODULE) return 1;
    return obj->int_value != 0;
}

int py_expect_int(PyObject* obj, int line_no, int* out) {
    if (!py_is_int_like(obj)) {
        py_set_error("expected an integer", line_no);
        return 0;
    }
    *out = obj->int_value;
    return 1;
}

int py_list_append(PyObject* list_obj, PyObject* item, int line_no) {
    PyList* list;
    PyObject** new_items;
    int new_cap;
    if (!list_obj || list_obj->type != PY_LIST || !list_obj->list_value) {
        py_set_error("expected a list", line_no);
        return 0;
    }
    list = list_obj->list_value;
    if (list->count >= list->cap) {
        new_cap = list->cap == 0 ? 4 : list->cap * 2;
        new_items = (PyObject**)realloc(list->items, sizeof(PyObject*) * new_cap);
        if (!new_items) {
            py_set_error("out of memory", line_no);
            return 0;
        }
        list->items = new_items;
        list->cap = new_cap;
    }
    list->items[list->count] = item;
    list->count++;
    return 1;
}

int py_value_equal(PyObject* left, PyObject* right) {
    if (left->type == PY_NONE || right->type == PY_NONE) {
        return left->type == PY_NONE && right->type == PY_NONE;
    }
    if (left->type == PY_STRING || right->type == PY_STRING) {
        if (left->type != PY_STRING || right->type != PY_STRING) return 0;
        return strcmp(left->str_value, right->str_value) == 0;
    }
    if (left->type == PY_LIST || right->type == PY_LIST ||
        left->type == PY_FUNCTION || right->type == PY_FUNCTION ||
        left->type == PY_CODE || right->type == PY_CODE ||
        left->type == PY_ITER || right->type == PY_ITER ||
        left->type == PY_MODULE || right->type == PY_MODULE) {
        return left == right;
    }
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return left->int_value == right->int_value;
    }
    return 0;
}

int py_compare_values(PyObject* left, int op, PyObject* right, int line_no) {
    int cmp;
    cmp = 0;
    if (left->type == PY_STRING || right->type == PY_STRING) {
        if (left->type != PY_STRING || right->type != PY_STRING) {
            py_set_error("cannot compare these values", line_no);
            return 0;
        }
        cmp = strcmp(left->str_value, right->str_value);
    } else if (py_is_int_like(left) && py_is_int_like(right)) {
        int left_bits;
        int right_bits;
        int bit;
        left_bits = left->int_value;
        right_bits = right->int_value;
        if (left_bits != right_bits) {
            left_bits = left_bits ^ ((int)0x80000000);
            right_bits = right_bits ^ ((int)0x80000000);
            cmp = 0;
            bit = 31;
            while (bit >= 0) {
                int left_bit;
                int right_bit;
                left_bit = (left_bits >> bit) & 1;
                right_bit = (right_bits >> bit) & 1;
                if (left_bit != right_bit) {
                    if (left_bit < right_bit) cmp = -1;
                    else cmp = 1;
                    break;
                }
                bit--;
            }
        }
    } else {
        py_set_error("cannot compare these values", line_no);
        return 0;
    }

    if (op == 1) return cmp == -1;
    if (op == 2) return cmp != 1;
    if (op == 3) return cmp == 1;
    if (op == 4) return cmp != -1;
    return 0;
}

PyObject* py_concat_lists(PyObject* left, PyObject* right, int line_no) {
    PyObject* out;
    int i;
    out = py_make_list();
    if (py_error) return py_make_none();
    i = 0;
    while (i < left->list_value->count) {
        if (!py_list_append(out, left->list_value->items[i], line_no)) return py_make_none();
        i++;
    }
    i = 0;
    while (i < right->list_value->count) {
        if (!py_list_append(out, right->list_value->items[i], line_no)) return py_make_none();
        i++;
    }
    return out;
}

PyObject* py_op_plus(PyObject* left, PyObject* right, int line_no) {
    char* buf;
    int llen;
    int rlen;
    PyObject* out;
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return py_make_int(left->int_value + right->int_value);
    }
    if (left->type == PY_STRING && right->type == PY_STRING) {
        llen = strlen(left->str_value);
        rlen = strlen(right->str_value);
        buf = (char*)malloc(llen + rlen + 1);
        if (!buf) {
            py_set_error("out of memory", line_no);
            return py_make_none();
        }
        memcpy(buf, left->str_value, llen);
        memcpy(buf + llen, right->str_value, rlen);
        buf[llen + rlen] = 0;
        out = py_alloc_object(PY_STRING);
        if (out == &py_none_obj) return out;
        out->str_value = buf;
        return out;
    }
    if (left->type == PY_LIST && right->type == PY_LIST) {
        return py_concat_lists(left, right, line_no);
    }
    py_set_error("unsupported '+' operands", line_no);
    return py_make_none();
}

PyObject* py_op_minus(PyObject* left, PyObject* right, int line_no) {
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return py_make_int(left->int_value - right->int_value);
    }
    py_set_error("unsupported '-' operands", line_no);
    return py_make_none();
}

PyObject* py_op_mul(PyObject* left, PyObject* right, int line_no) {
    int count;
    int i;
    PyObject* out;
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return py_make_int(left->int_value * right->int_value);
    }
    if (left->type == PY_STRING && py_is_int_like(right)) {
        count = right->int_value;
        if (count < 0) count = 0;
        out = py_make_string("");
        i = 0;
        while (i < count && !py_error) {
            out = py_op_plus(out, left, line_no);
            i++;
        }
        return out;
    }
    if (right->type == PY_STRING && py_is_int_like(left)) {
        count = left->int_value;
        if (count < 0) count = 0;
        out = py_make_string("");
        i = 0;
        while (i < count && !py_error) {
            out = py_op_plus(out, right, line_no);
            i++;
        }
        return out;
    }
    py_set_error("unsupported '*' operands", line_no);
    return py_make_none();
}

PyObject* py_op_div(PyObject* left, PyObject* right, int line_no) {
    if (py_is_int_like(left) && py_is_int_like(right)) {
        if (right->int_value == 0) {
            py_set_error("division by zero", line_no);
            return py_make_none();
        }
        return py_make_int(left->int_value / right->int_value);
    }
    py_set_error("unsupported '/' operands", line_no);
    return py_make_none();
}

PyObject* py_op_mod(PyObject* left, PyObject* right, int line_no) {
    if (py_is_int_like(left) && py_is_int_like(right)) {
        if (right->int_value == 0) {
            py_set_error("division by zero", line_no);
            return py_make_none();
        }
        return py_make_int(left->int_value % right->int_value);
    }
    py_set_error("unsupported '%' operands", line_no);
    return py_make_none();
}

int py_scope_find_local_index(PyScope* scope, char* name) {
    int i;
    if (!scope) return -1;
    i = 0;
    while (i < PY_MAX_VARS) {
        if (scope->used[i] && scope->names[i] && strcmp(scope->names[i], name) == 0) {
            return i;
        }
        i++;
    }
    return -1;
}

int py_scope_ensure_local_index(PyScope* scope, char* name, int line_no) {
    int i;
    int slot;
    if (!scope) {
        py_set_error("scope is not initialized", line_no);
        return -1;
    }
    slot = py_scope_find_local_index(scope, name);
    if (slot >= 0) return slot;
    i = 0;
    while (i < PY_MAX_VARS) {
        if (!scope->used[i]) {
            scope->used[i] = 1;
            scope->names[i] = py_strdup_text(name);
            scope->values[i] = py_make_none();
            if (!scope->names[i]) return -1;
            return i;
        }
        i++;
    }
    py_set_error("too many variables", line_no);
    return -1;
}

void py_scope_init(PyScope* scope, PyScope* parent) {
    int i;
    scope->parent = parent;
    i = 0;
    while (i < PY_MAX_VARS) {
        scope->used[i] = 0;
        scope->names[i] = (char*)0;
        scope->values[i] = py_make_none();
        i++;
    }
}

void py_scope_release(PyScope* scope) {
    int i;
    if (!scope) return;
    i = 0;
    while (i < PY_MAX_VARS) {
        if (scope->names[i]) free(scope->names[i]);
        scope->names[i] = (char*)0;
        scope->used[i] = 0;
        scope->values[i] = py_make_none();
        i++;
    }
}

void py_scope_set(PyScope* scope, char* name, PyObject* value, int line_no) {
    int slot;
    slot = py_scope_ensure_local_index(scope, name, line_no);
    if (slot < 0) return;
    scope->values[slot] = value;
}

PyObject* py_scope_get(PyScope* scope, char* name, int line_no) {
    PyScope* cur;
    int slot;
    cur = scope;
    while (cur) {
        slot = py_scope_find_local_index(cur, name);
        if (slot >= 0) return cur->values[slot];
        cur = cur->parent;
    }
    py_set_name_error("unknown variable ", name, line_no);
    return py_make_none();
}

void py_print_string_repr(char* text) {
    int i;
    char c;
    printchar(39);
    i = 0;
    while (text && text[i] && i < 1024) {
        c = text[i];
        if (c == 10) { printchar(92); printchar(110); }
        else if (c == 9) { printchar(92); printchar(116); }
        else if (c == 13) { printchar(92); printchar(114); }
        else if (c == '\\') { printchar(92); printchar(92); }
        else if (c == '\'') { printchar(92); printchar(39); }
        else printchar(c);
        i++;
    }
    if (text && text[i]) { printchar(46); printchar(46); printchar(46); }
    printchar(39);
}

void py_repr_object(PyObject* obj);

void py_display_object(PyObject* obj) {
    if (obj->type == PY_STRING) {
        py_print_plain_string(obj->str_value);
    } else {
        py_repr_object(obj);
    }
}

void py_repr_object(PyObject* obj) {
    int i;
    if (obj->type == PY_STRING) {
        py_print_string_repr(obj->str_value ? obj->str_value : "");
        return;
    }
    if (obj->type == PY_BOOL) {
        if (obj->int_value) print("True");
        else print("False");
        return;
    }
    if (obj->type == PY_NONE) {
        print("None");
        return;
    }
    if (obj->type == PY_INT) {
        printint(obj->int_value);
        return;
    }
    if (obj->type == PY_LIST) {
        printchar(91);
        i = 0;
        while (obj->list_value && i < obj->list_value->count) {
            if (i > 0) {
                printchar(44);
                printchar(32);
            }
            py_repr_object(obj->list_value->items[i]);
            i++;
        }
        printchar(93);
        return;
    }
    if (obj->type == PY_FUNCTION) {
        printchar(60);
        print("function ");
        if (obj->func_value && obj->func_value->name) print(obj->func_value->name);
        else print("anonymous");
        printchar(62);
        return;
    }
    if (obj->type == PY_CODE) {
        printchar(60);
        print("code ");
        if (obj->code_value && obj->code_value->name) print(obj->code_value->name);
        else print("anonymous");
        printchar(62);
        return;
    }
    if (obj->type == PY_ITER) {
        print("<iterator>");
        return;
    }
    if (obj->type == PY_MODULE) {
        printchar(60);
        print("module ");
        if (obj->module_value && obj->module_value->name) print(obj->module_value->name);
        else print("anonymous");
        printchar(62);
        return;
    }
    print("None");
}

void py_sanitize_line(char* src, char* dest, int max_len) {
    int i;
    int out;
    int in_string;
    int escaped;
    int quote;
    char c;
    i = 0;
    out = 0;
    in_string = 0;
    escaped = 0;
    quote = 0;
    while (src[i] && out < max_len - 1) {
        c = src[i];
        if (!in_string && c == '#') break;
        if ((c == '"' || c == '\'') && !escaped) {
            if (!in_string) {
                in_string = 1;
                quote = c;
            } else if (quote == c) {
                in_string = 0;
                quote = 0;
            }
        }
        if (in_string && c == '\\' && !escaped) escaped = 1;
        else escaped = 0;
        dest[out] = c;
        out++;
        i++;
    }
    while (out > 0 && (dest[out - 1] == ' ' || dest[out - 1] == '\t' || dest[out - 1] == '\r')) {
        out--;
    }
    dest[out] = 0;
}

int py_line_opens_block(char* line) {
    int len;
    py_sanitize_line(line, py_stmt, 256);
    len = strlen(py_stmt);
    if (len <= 0) return 0;
    return py_stmt[len - 1] == ':';
}

void py_append_program_line(char* line) {
    int len;
    py_sanitize_line(line, py_stmt, 256);
    len = strlen(py_stmt);
    if (len <= 0) return;
    if (py_program_len + len + 1 >= PY_MAX_PROGRAM) {
        py_set_error("program buffer is full", 0);
        return;
    }
    memcpy(py_program + py_program_len, py_stmt, len);
    py_program_len += len;
    py_program[py_program_len] = '\n';
    py_program_len++;
    py_program[py_program_len] = 0;
}

void py_reset_program() {
    py_program_len = 0;
    py_program[0] = 0;
}

int py_read_line(char* prompt, char* out, int max_len) {
    int pos;
    int c;
    pos = 0;
    print(prompt);
    flush();
    while (pos < max_len - 1) {
        c = getkey();
        if (c == KEY_ESC) return -1;
        if (c == 13 || c == 10) {
            printchar(10);
            break;
        }
        if (c == 8 || c == 127) {
            if (pos > 0) {
                pos--;
                printchar(8);
                printchar(' ');
                printchar(8);
            }
            continue;
        }
        if (c >= 32 && c <= 126) {
            out[pos] = (char)c;
            pos++;
            printchar(c);
        }
    }
    out[pos] = 0;
    return pos;
}

void py_prepare_lines() {
    int pos;
    int line_end;
    int content_start;
    int indent;
    int raw_line;
    py_line_count = 0;
    pos = 0;
    raw_line = 1;
    while (pos < py_program_len) {
        line_end = pos;
        while (line_end < py_program_len && py_program[line_end] != '\n') line_end++;
        content_start = pos;
        indent = 0;
        while (content_start < line_end && (py_program[content_start] == ' ' || py_program[content_start] == '\t')) {
            if (py_program[content_start] == '\t') indent += 4;
            else indent++;
            content_start++;
        }
        if (content_start < line_end && py_program[content_start] != '#') {
            if (py_line_count >= PY_MAX_LINES) {
                py_set_error("too many lines", raw_line);
                return;
            }
            py_line_start[py_line_count] = content_start;
            py_line_len[py_line_count] = line_end - content_start;
            py_line_indent[py_line_count] = indent;
            py_line_number[py_line_count] = raw_line;
            py_line_count++;
        }
        pos = line_end + 1;
        raw_line++;
    }
}

void py_copy_line_text(int index) {
    int pos;
    int end;
    int out;
    int clear;
    int in_string;
    int escaped;
    int quote;
    char c;
    pos = py_line_start[index];
    end = py_line_start[index] + py_line_len[index];
    out = 0;
    clear = 0;
    while (clear < 256) {
        py_stmt[clear] = 0;
        clear++;
    }
    in_string = 0;
    escaped = 0;
    quote = 0;
    while (pos < end && out < 255) {
        c = py_program[pos];
        if (!in_string && c == '#') break;
        if ((c == '"' || c == '\'') && !escaped) {
            if (!in_string) {
                in_string = 1;
                quote = c;
            } else if (quote == c) {
                in_string = 0;
                quote = 0;
            }
        }
        if (in_string && c == '\\' && !escaped) escaped = 1;
        else escaped = 0;
        py_stmt[out] = c;
        out++;
        pos++;
    }
    while (out > 0 && (py_stmt[out - 1] == ' ' || py_stmt[out - 1] == '\t' || py_stmt[out - 1] == '\r')) {
        out--;
    }
    py_stmt[out] = 0;
}
]===]

return python_runtime_h1
