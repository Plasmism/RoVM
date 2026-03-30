local python_c = [===[
#include <rovm.h>
#include <string.h>
#include <ctype.h>
#include <stdlib.h>

#define PY_NONE 0
#define PY_INT 1
#define PY_BOOL 2
#define PY_STRING 3

struct PyValue {
    int type;
    int int_value;
    char str_value[192];
};
typedef struct PyValue PyValue;

struct PyVar {
    int used;
    char name[32];
    PyValue value;
};
typedef struct PyVar PyVar;

char py_input_line[256];
char py_program[4096];
int py_program_len;
int py_line_start[192];
int py_line_len[192];
int py_line_indent[192];
int py_line_count;
PyVar py_vars[64];
int py_error;
int py_error_line;
char py_error_text[96];
char py_stmt[256];
char py_expr_buf[256];
char py_saved_expr[256];
char* py_expr_ptr;
int py_expr_pos;
PyValue py_temp_pool[256];
int py_temp_top;
PyValue py_fallback_value;

void py_copy_limit(char* dest, char* src, int max_len) {
    int i;
    i = 0;
    while (src[i] && i < max_len - 1) {
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
    while (src[i] && dlen < max_len - 1) {
        dest[dlen] = src[i];
        dlen++;
        i++;
    }
    dest[dlen] = 0;
}

void py_copy_value(PyValue* dest, PyValue* src) {
    dest->type = src->type;
    dest->int_value = src->int_value;
    py_copy_limit(dest->str_value, src->str_value, 192);
}

void py_set_error(char* text) {
    if (!py_error) {
        py_error = 1;
        py_copy_limit(py_error_text, text, 96);
    }
}

void py_value_none(PyValue* v) {
    v->type = PY_NONE;
    v->int_value = 0;
    v->str_value[0] = 0;
}

void py_value_int(PyValue* v, int n) {
    v->type = PY_INT;
    v->int_value = n;
    v->str_value[0] = 0;
}

void py_value_bool(PyValue* v, int n) {
    v->type = PY_BOOL;
    v->int_value = n ? 1 : 0;
    v->str_value[0] = 0;
}

void py_value_string(PyValue* v, char* text) {
    v->type = PY_STRING;
    v->int_value = 0;
    py_copy_limit(v->str_value, text, 192);
}

PyValue* py_temp_value() {
    PyValue* v;
    if (py_temp_top >= 256) {
        py_set_error("expression too complex");
        v = &py_fallback_value;
    } else {
        v = &py_temp_pool[py_temp_top];
        py_temp_top++;
    }
    py_value_none(v);
    return v;
}

PyValue* py_make_none() {
    return py_temp_value();
}

PyValue* py_make_int(int n) {
    PyValue* v;
    v = py_temp_value();
    py_value_int(v, n);
    return v;
}

PyValue* py_make_bool(int n) {
    PyValue* v;
    v = py_temp_value();
    py_value_bool(v, n);
    return v;
}

PyValue* py_make_string(char* text) {
    PyValue* v;
    v = py_temp_value();
    py_value_string(v, text);
    return v;
}

int py_is_name_start(int c) {
    return isalpha(c) || c == '_';
}

int py_is_name_char(int c) {
    return isalnum(c) || c == '_';
}

int py_is_int_like(PyValue* v) {
    return v->type == PY_INT || v->type == PY_BOOL;
}

int py_truthy(PyValue* v) {
    if (v->type == PY_NONE) return 0;
    if (v->type == PY_STRING) return strlen(v->str_value) > 0;
    return v->int_value != 0;
}

void py_print_value(PyValue* v) {
    if (v->type == PY_STRING) {
        print(v->str_value);
    } else if (v->type == PY_BOOL) {
        if (v->int_value) print("True");
        else print("False");
    } else if (v->type == PY_NONE) {
        print("None");
    } else {
        printint(v->int_value);
    }
}

int py_value_equal(PyValue* left, PyValue* right) {
    if (left->type == PY_NONE || right->type == PY_NONE) {
        return left->type == PY_NONE && right->type == PY_NONE;
    }
    if (left->type == PY_STRING || right->type == PY_STRING) {
        if (left->type != PY_STRING || right->type != PY_STRING) return 0;
        return strcmp(left->str_value, right->str_value) == 0;
    }
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return left->int_value == right->int_value;
    }
    return 0;
}

int py_compare_int_values(int left, int right) {
    int left_bits;
    int right_bits;
    int bit;
    if (left == right) return 0;
    left_bits = left ^ ((int)0x80000000);
    right_bits = right ^ ((int)0x80000000);
    bit = 31;
    while (bit >= 0) {
        int left_bit;
        int right_bit;
        left_bit = (left_bits >> bit) & 1;
        right_bit = (right_bits >> bit) & 1;
        if (left_bit != right_bit) {
            if (left_bit < right_bit) return -1;
            return 1;
        }
        bit--;
    }
    return 0;
}

int py_compare_values(PyValue* left, int op, PyValue* right) {
    int cmp;
    cmp = 0;
    if (left->type == PY_STRING || right->type == PY_STRING) {
        if (left->type != PY_STRING || right->type != PY_STRING) {
            py_set_error("cannot compare these values");
            return 0;
        }
        cmp = strcmp(left->str_value, right->str_value);
    } else if (py_is_int_like(left) && py_is_int_like(right)) {
        cmp = py_compare_int_values(left->int_value, right->int_value);
    } else {
        py_set_error("cannot compare these values");
        return 0;
    }

    if (op == 1) return cmp == -1;
    if (op == 2) return cmp != 1;
    if (op == 3) return cmp == 1;
    if (op == 4) return cmp != -1;
    return 0;
}

int py_find_var(char* name) {
    int i;
    i = 0;
    while (i < 64) {
        if (py_vars[i].used && strcmp(py_vars[i].name, name) == 0) return i;
        i++;
    }
    return -1;
}

int py_ensure_var(char* name) {
    int i;
    int slot;
    slot = py_find_var(name);
    if (slot >= 0) return slot;
    i = 0;
    while (i < 64) {
        if (!py_vars[i].used) {
            py_vars[i].used = 1;
            py_copy_limit(py_vars[i].name, name, 32);
            py_value_none(&py_vars[i].value);
            return i;
        }
        i++;
    }
    py_set_error("too many variables");
    return -1;
}

PyValue* py_get_var(char* name) {
    PyValue* v;
    int idx;
    v = py_make_none();
    idx = py_find_var(name);
    if (idx < 0) {
        py_set_error("unknown variable");
        return v;
    }
    py_copy_value(v, &py_vars[idx].value);
    return v;
}

void py_set_var(char* name, PyValue* value) {
    int idx;
    idx = py_ensure_var(name);
    if (idx < 0) return;
    py_copy_value(&py_vars[idx].value, value);
}

void py_sanitize_line(char* src, char* dest, int max_len) {
    int i;
    int out;
    int in_string;
    int escaped;
    char c;
    i = 0;
    out = 0;
    in_string = 0;
    escaped = 0;
    while (src[i] && out < max_len - 1) {
        c = src[i];
        if (!in_string && c == '#') break;
        if (c == '"' && !escaped) in_string = !in_string;
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
    if (py_program_len + len + 1 >= 4096) {
        py_set_error("program buffer is full");
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
    py_line_count = 0;
    pos = 0;
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
            if (py_line_count >= 192) {
                py_set_error("too many lines");
                return;
            }
            py_line_start[py_line_count] = content_start;
            py_line_len[py_line_count] = line_end - content_start;
            py_line_indent[py_line_count] = indent;
            py_line_count++;
        }
        pos = line_end + 1;
    }
}

void py_copy_line_text(int index) {
    int pos;
    int end;
    int out;
    int in_string;
    int escaped;
    char c;
    pos = py_line_start[index];
    end = py_line_start[index] + py_line_len[index];
    out = 0;
    in_string = 0;
    escaped = 0;
    while (pos < end && out < 255) {
        c = py_program[pos];
        if (!in_string && c == '#') break;
        if (c == '"' && !escaped) in_string = !in_string;
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

void py_copy_trim_range(char* src, int start, int end, char* dest, int max_len) {
    int out;
    out = 0;
    while (start <= end && (src[start] == ' ' || src[start] == '\t')) start++;
    while (end >= start && (src[end] == ' ' || src[end] == '\t')) end--;
    while (start <= end && out < max_len - 1) {
        dest[out] = src[start];
        out++;
        start++;
    }
    dest[out] = 0;
}

int py_stmt_has_keyword(char* stmt, char* keyword) {
    int klen;
    klen = strlen(keyword);
    if (strncmp(stmt, keyword, klen) != 0) return 0;
    if (stmt[klen] == 0) return 1;
    if (stmt[klen] == ' ' || stmt[klen] == '\t' || stmt[klen] == ':' || stmt[klen] == '(') return 1;
    return 0;
}

int py_extract_header_expr(char* keyword, char* out) {
    int klen;
    int len;
    int start;
    int end;
    klen = strlen(keyword);
    len = strlen(py_stmt);
    if (!py_stmt_has_keyword(py_stmt, keyword)) return 0;
    end = len - 1;
    while (end >= 0 && (py_stmt[end] == ' ' || py_stmt[end] == '\t')) end--;
    if (end < 0 || py_stmt[end] != ':') {
        py_set_error("expected ':'");
        return 0;
    }
    start = klen;
    while (py_stmt[start] == ' ' || py_stmt[start] == '\t') start++;
    end--;
    while (end >= start && (py_stmt[end] == ' ' || py_stmt[end] == '\t')) end--;
    if (end < start) {
        py_set_error("expected a condition");
        return 0;
    }
    py_copy_trim_range(py_stmt, start, end, out, 256);
    return 1;
}

int py_parse_identifier(char* text, char* out_name, int* out_pos) {
    int pos;
    int out;
    pos = 0;
    out = 0;
    while (text[pos] == ' ' || text[pos] == '\t') pos++;
    if (!py_is_name_start(text[pos])) return 0;
    while (py_is_name_char(text[pos]) && out < 31) {
        out_name[out] = text[pos];
        out++;
        pos++;
    }
    out_name[out] = 0;
    *out_pos = pos;
    return 1;
}

void py_expr_skip_spaces() {
    while (py_expr_ptr[py_expr_pos] == ' ' || py_expr_ptr[py_expr_pos] == '\t' || py_expr_ptr[py_expr_pos] == '\r') {
        py_expr_pos++;
    }
}

int py_expr_match_char(int ch) {
    py_expr_skip_spaces();
    if (py_expr_ptr[py_expr_pos] == ch) {
        py_expr_pos++;
        return 1;
    }
    return 0;
}

int py_expr_match_op(char* op) {
    int len;
    len = strlen(op);
    py_expr_skip_spaces();
    if (strncmp(py_expr_ptr + py_expr_pos, op, len) == 0) {
        py_expr_pos += len;
        return 1;
    }
    return 0;
}

int py_expr_match_word(char* word) {
    int len;
    len = strlen(word);
    py_expr_skip_spaces();
    if (strncmp(py_expr_ptr + py_expr_pos, word, len) != 0) return 0;
    if (py_is_name_char(py_expr_ptr[py_expr_pos + len])) return 0;
    py_expr_pos += len;
    return 1;
}

int py_expr_read_name(char* out_name) {
    int out;
    py_expr_skip_spaces();
    if (!py_is_name_start(py_expr_ptr[py_expr_pos])) return 0;
    out = 0;
    while (py_is_name_char(py_expr_ptr[py_expr_pos]) && out < 31) {
        out_name[out] = py_expr_ptr[py_expr_pos];
        out++;
        py_expr_pos++;
    }
    out_name[out] = 0;
    return 1;
}

PyValue* py_parse_expression();

PyValue* py_op_plus(PyValue* left, PyValue* right) {
    PyValue* res;
    res = py_make_none();
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return py_make_int(left->int_value + right->int_value);
    }
    if (left->type == PY_STRING && right->type == PY_STRING) {
        py_value_string(res, left->str_value);
        py_append_limit(res->str_value, right->str_value, 192);
        return res;
    }
    py_set_error("unsupported '+' operands");
    return res;
}

PyValue* py_op_minus(PyValue* left, PyValue* right) {
    PyValue* res;
    res = py_make_none();
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return py_make_int(left->int_value - right->int_value);
    }
    py_set_error("unsupported '-' operands");
    return res;
}

PyValue* py_op_mul(PyValue* left, PyValue* right) {
    PyValue* res;
    int count;
    int i;
    res = py_make_none();
    if (py_is_int_like(left) && py_is_int_like(right)) {
        return py_make_int(left->int_value * right->int_value);
    }
    if (left->type == PY_STRING && py_is_int_like(right)) {
        py_value_string(res, "");
        count = right->int_value;
        if (count < 0) count = 0;
        i = 0;
        while (i < count) {
            py_append_limit(res->str_value, left->str_value, 192);
            i++;
        }
        return res;
    }
    if (right->type == PY_STRING && py_is_int_like(left)) {
        py_value_string(res, "");
        count = left->int_value;
        if (count < 0) count = 0;
        i = 0;
        while (i < count) {
            py_append_limit(res->str_value, right->str_value, 192);
            i++;
        }
        return res;
    }
    py_set_error("unsupported '*' operands");
    return res;
}

PyValue* py_op_div(PyValue* left, PyValue* right) {
    PyValue* res;
    res = py_make_none();
    if (py_is_int_like(left) && py_is_int_like(right)) {
        if (right->int_value == 0) {
            py_set_error("division by zero");
            return res;
        }
        return py_make_int(left->int_value / right->int_value);
    }
    py_set_error("unsupported '/' operands");
    return res;
}

PyValue* py_op_mod(PyValue* left, PyValue* right) {
    PyValue* res;
    res = py_make_none();
    if (py_is_int_like(left) && py_is_int_like(right)) {
        if (right->int_value == 0) {
            py_set_error("division by zero");
            return res;
        }
        return py_make_int(left->int_value % right->int_value);
    }
    py_set_error("unsupported '%' operands");
    return res;
}

PyValue* py_parse_primary() {
    PyValue* value;
    char name[32];
    int out;
    int ch;
    int n;
    int escaped;
    value = py_make_none();
    py_expr_skip_spaces();

    if (py_expr_match_char('(')) {
        value = py_parse_expression();
        if (!py_error && !py_expr_match_char(')')) py_set_error("expected ')'");
        return value;
    }

    if (py_expr_ptr[py_expr_pos] == '"') {
        py_expr_pos++;
        out = 0;
        escaped = 0;
        while (py_expr_ptr[py_expr_pos]) {
            ch = py_expr_ptr[py_expr_pos];
            py_expr_pos++;
            if (!escaped && ch == '"') break;
            if (!escaped && ch == '\\') {
                escaped = 1;
                continue;
            }
            if (escaped) {
                if (ch == 'n') ch = '\n';
                else if (ch == 't') ch = '\t';
                escaped = 0;
            }
            if (out < 191) {
                value->str_value[out] = (char)ch;
                out++;
            }
        }
        if (escaped) py_set_error("unfinished escape");
        value->type = PY_STRING;
        value->int_value = 0;
        value->str_value[out] = 0;
        if (py_expr_pos <= 0 || py_expr_ptr[py_expr_pos - 1] != '"') py_set_error("unterminated string");
        return value;
    }

    if (isdigit(py_expr_ptr[py_expr_pos])) {
        n = 0;
        while (isdigit(py_expr_ptr[py_expr_pos])) {
            n = n * 10 + (py_expr_ptr[py_expr_pos] - '0');
            py_expr_pos++;
        }
        return py_make_int(n);
    }

    if (py_expr_match_word("True")) return py_make_bool(1);
    if (py_expr_match_word("False")) return py_make_bool(0);
    if (py_expr_match_word("None")) return py_make_none();

    if (py_expr_read_name(name)) {
        return py_get_var(name);
    }

    py_set_error("invalid expression");
    return value;
}

PyValue* py_parse_unary() {
    PyValue* value;
    value = py_make_none();
    if (py_expr_match_word("not")) {
        value = py_parse_unary();
        if (py_error) return value;
        return py_make_bool(!py_truthy(value));
    }
    if (py_expr_match_char('+')) {
        value = py_parse_unary();
        if (py_error) return value;
        if (!py_is_int_like(value)) {
            py_set_error("bad unary '+'");
            return py_make_none();
        }
        return py_make_int(value->int_value);
    }
    if (py_expr_match_char('-')) {
        value = py_parse_unary();
        if (py_error) return value;
        if (!py_is_int_like(value)) {
            py_set_error("bad unary '-'");
            return py_make_none();
        }
        return py_make_int(-value->int_value);
    }
    return py_parse_primary();
}

PyValue* py_parse_mul() {
    PyValue* left;
    PyValue* right;
    left = py_parse_unary();
    while (!py_error) {
        if (py_expr_match_op("//")) {
            right = py_parse_unary();
            left = py_op_div(left, right);
        } else if (py_expr_match_char('*')) {
            right = py_parse_unary();
            left = py_op_mul(left, right);
        } else if (py_expr_match_char('/')) {
            right = py_parse_unary();
            left = py_op_div(left, right);
        } else if (py_expr_match_char('%')) {
            right = py_parse_unary();
            left = py_op_mod(left, right);
        } else {
            break;
        }
    }
    return left;
}

PyValue* py_parse_add() {
    PyValue* left;
    PyValue* right;
    left = py_parse_mul();
    while (!py_error) {
        if (py_expr_match_char('+')) {
            right = py_parse_mul();
            left = py_op_plus(left, right);
        } else if (py_expr_match_char('-')) {
            right = py_parse_mul();
            left = py_op_minus(left, right);
        } else {
            break;
        }
    }
    return left;
}

PyValue* py_parse_compare() {
    PyValue* left;
    PyValue prev;
    PyValue* right;
    int saw;
    int ok;
    int op;
    left = py_parse_add();
    py_copy_value(&prev, left);
    saw = 0;
    ok = 1;
    while (!py_error) {
        op = 0;
        if (py_expr_match_op("==")) op = 10;
        else if (py_expr_match_op("!=")) op = 11;
        else if (py_expr_match_op("<=")) op = 2;
        else if (py_expr_match_op(">=")) op = 4;
        else if (py_expr_match_char('<')) op = 1;
        else if (py_expr_match_char('>')) op = 3;
        if (!op) break;
        saw = 1;
        right = py_parse_add();
        if (py_error) break;
        if (op == 10) {
            if (!py_value_equal(&prev, right)) ok = 0;
        } else if (op == 11) {
            if (py_value_equal(&prev, right)) ok = 0;
        } else {
            if (!py_compare_values(&prev, op, right)) ok = 0;
            if (py_error) break;
        }
        py_copy_value(&prev, right);
    }
    if (saw) return py_make_bool(ok);
    return left;
}

PyValue* py_parse_and() {
    PyValue* left;
    PyValue* right;
    left = py_parse_compare();
    while (!py_error && py_expr_match_word("and")) {
        right = py_parse_compare();
        if (py_truthy(left)) left = right;
    }
    return left;
}

PyValue* py_parse_or() {
    PyValue* left;
    PyValue* right;
    left = py_parse_and();
    while (!py_error && py_expr_match_word("or")) {
        right = py_parse_and();
        if (!py_truthy(left)) left = right;
    }
    return left;
}

PyValue* py_parse_expression() {
    return py_parse_or();
}

int py_eval_expression_text(char* text, PyValue* out) {
    PyValue* value;
    py_copy_limit(py_expr_buf, text, 256);
    py_expr_ptr = py_expr_buf;
    py_expr_pos = 0;
    py_temp_top = 0;
    value = py_parse_expression();
    if (py_error) return 0;
    py_expr_skip_spaces();
    if (py_expr_ptr[py_expr_pos] != 0) {
        py_set_error("invalid expression");
        return 0;
    }
    py_copy_value(out, value);
    return 1;
}

int py_exec_print_statement(char* stmt) {
    int len;
    int start;
    int end;
    int i;
    int seg_start;
    int depth;
    int in_string;
    int escaped;
    int printed;
    PyValue value;
    len = strlen(stmt);
    if (!py_stmt_has_keyword(stmt, "print")) return 0;
    if (stmt[5] == '(' && stmt[len - 1] == ')') {
        start = 6;
        end = len - 2;
        if (end < start) {
            printchar(10);
            return 1;
        }
        seg_start = start;
        depth = 0;
        in_string = 0;
        escaped = 0;
        printed = 0;
        i = start;
        while (i <= end + 1) {
            if (i <= end) {
                if (stmt[i] == '"' && !escaped) in_string = !in_string;
                if (in_string && stmt[i] == '\\' && !escaped) escaped = 1;
                else escaped = 0;
                if (!in_string) {
                    if (stmt[i] == '(') depth++;
                    else if (stmt[i] == ')') depth--;
                }
            }
            if (i == end + 1 || (!in_string && depth == 0 && stmt[i] == ',')) {
                py_copy_trim_range(stmt, seg_start, i - 1, py_saved_expr, 256);
                if (strlen(py_saved_expr) > 0) {
                    if (!py_eval_expression_text(py_saved_expr, &value)) return 1;
                    if (printed) print(" ");
                    py_print_value(&value);
                    printed = 1;
                }
                seg_start = i + 1;
            }
            i++;
        }
        printchar(10);
        return 1;
    }
    if (stmt[5] == ' ' || stmt[5] == '\t') {
        py_copy_trim_range(stmt, 5, len - 1, py_saved_expr, 256);
        if (!py_eval_expression_text(py_saved_expr, &value)) return 1;
        py_print_value(&value);
        printchar(10);
        return 1;
    }
    py_set_error("bad print statement");
    return 1;
}

int py_apply_assignment(char* name, char* op, PyValue* rhs) {
    PyValue* left;
    PyValue* res;
    if (strcmp(op, "=") == 0) {
        py_set_var(name, rhs);
        return 1;
    }
    left = py_get_var(name);
    if (py_error) return 1;
    if (strcmp(op, "+=") == 0) res = py_op_plus(left, rhs);
    else if (strcmp(op, "-=") == 0) res = py_op_minus(left, rhs);
    else if (strcmp(op, "*=") == 0) res = py_op_mul(left, rhs);
    else if (strcmp(op, "/=") == 0) res = py_op_div(left, rhs);
    else if (strcmp(op, "%=") == 0) res = py_op_mod(left, rhs);
    else {
        py_set_error("bad assignment operator");
        return 1;
    }
    if (py_error) return 1;
    py_set_var(name, res);
    return 1;
}

void py_exec_simple(char* stmt) {
    char name[32];
    char op[3];
    int pos;
    int op_pos;
    int len;
    PyValue value;
    if (strcmp(stmt, "pass") == 0) return;
    if (py_exec_print_statement(stmt)) return;

    if (py_parse_identifier(stmt, name, &pos)) {
        op_pos = pos;
        while (stmt[op_pos] == ' ' || stmt[op_pos] == '\t') op_pos++;
        op[0] = 0;
        if (stmt[op_pos] == '=' && stmt[op_pos + 1] != '=') {
            op[0] = '=';
            op[1] = 0;
        } else if ((stmt[op_pos] == '+' || stmt[op_pos] == '-' || stmt[op_pos] == '*' || stmt[op_pos] == '/' || stmt[op_pos] == '%') &&
                   stmt[op_pos + 1] == '=') {
            op[0] = stmt[op_pos];
            op[1] = '=';
            op[2] = 0;
        }

        if (op[0]) {
            len = strlen(stmt);
            if (op[1] == '=') py_copy_trim_range(stmt, op_pos + 2, len - 1, py_saved_expr, 256);
            else py_copy_trim_range(stmt, op_pos + 1, len - 1, py_saved_expr, 256);
            if (strlen(py_saved_expr) <= 0) {
                py_set_error("missing assignment value");
                return;
            }
            if (!py_eval_expression_text(py_saved_expr, &value)) return;
            py_apply_assignment(name, op, &value);
            return;
        }
    }

    if (!py_eval_expression_text(stmt, &value)) return;
    py_print_value(&value);
        printchar(10);
}

int py_find_suite_end(int start, int parent_indent, int end) {
    int i;
    i = start;
    while (i < end && py_line_indent[i] > parent_indent) i++;
    return i;
}

int py_exec_block(int start, int end, int indent);

int py_exec_if_chain(int index, int end, int indent) {
    int next;
    int body_start;
    int body_end;
    int executed;
    PyValue cond;
    executed = 0;
    next = index;

    while (next < end) {
        py_error_line = next + 1;
        py_copy_line_text(next);
        if (next == index) {
            if (!py_extract_header_expr("if", py_saved_expr)) return end;
            if (!executed) {
                if (!py_eval_expression_text(py_saved_expr, &cond)) return end;
            } else {
                py_value_bool(&cond, 0);
            }
        } else if (py_stmt_has_keyword(py_stmt, "elif")) {
            if (!py_extract_header_expr("elif", py_saved_expr)) return end;
            if (!executed) {
                if (!py_eval_expression_text(py_saved_expr, &cond)) return end;
            } else {
                py_value_bool(&cond, 0);
            }
        } else if (strcmp(py_stmt, "else:") == 0) {
            py_value_bool(&cond, 1);
        } else {
            break;
        }

        body_start = next + 1;
        if (body_start >= end || py_line_indent[body_start] <= indent) {
            py_set_error("expected an indented block");
            return end;
        }
        body_end = py_find_suite_end(body_start, indent, end);
        if (!executed && py_truthy(&cond)) {
            py_exec_block(body_start, body_end, py_line_indent[body_start]);
            if (py_error) return end;
            executed = 1;
        }
        next = body_end;
        if (next >= end || py_line_indent[next] != indent) break;
        py_copy_line_text(next);
        if (!py_stmt_has_keyword(py_stmt, "elif") && strcmp(py_stmt, "else:") != 0) break;
        if (strcmp(py_stmt, "else:") == 0) {
            py_error_line = next + 1;
            body_start = next + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block");
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            if (!executed) {
                py_exec_block(body_start, body_end, py_line_indent[body_start]);
                if (py_error) return end;
            }
            next = body_end;
            break;
        }
    }

    return next;
}

int py_exec_block(int start, int end, int indent) {
    int i;
    int body_start;
    int body_end;
    PyValue cond;
    i = start;
    while (i < end) {
        if (py_line_indent[i] < indent) return i;
        if (py_line_indent[i] > indent) {
            py_error_line = i + 1;
            py_set_error("unexpected indentation");
            return end;
        }

        py_error_line = i + 1;
        py_copy_line_text(i);

        if (py_stmt_has_keyword(py_stmt, "if")) {
            i = py_exec_if_chain(i, end, indent);
            if (py_error) return end;
            continue;
        }

        if (py_stmt_has_keyword(py_stmt, "while")) {
            if (!py_extract_header_expr("while", py_saved_expr)) return end;
            body_start = i + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block");
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            while (!py_error) {
                py_error_line = i + 1;
                if (!py_eval_expression_text(py_saved_expr, &cond)) return end;
                if (!py_truthy(&cond)) break;
                py_exec_block(body_start, body_end, py_line_indent[body_start]);
                if (py_error) return end;
            }
            i = body_end;
            continue;
        }

        if (py_stmt_has_keyword(py_stmt, "elif") || strcmp(py_stmt, "else:") == 0) {
            py_set_error("unexpected block continuation");
            return end;
        }

        py_exec_simple(py_stmt);
        if (py_error) return end;
        i++;
    }
    return i;
}

void py_report_error() {
    print("error");
    if (py_error_line > 0) {
        print(" on line ");
        printint(py_error_line);
    }
    print(": ");
    print(py_error_text);
    printchar(10);
}

void py_run_buffer() {
    py_error = 0;
    py_error_line = 0;
    py_error_text[0] = 0;
    py_prepare_lines();
    if (py_error) {
        py_report_error();
        return;
    }
    if (py_line_count <= 0) return;
    if (py_line_indent[0] != 0) {
        py_error = 1;
        py_error_line = 1;
        py_copy_limit(py_error_text, "unexpected indentation", 96);
        py_report_error();
        return;
    }
    py_exec_block(0, py_line_count, 0);
    if (py_error) py_report_error();
}

void py_print_repl_banner() {
    print("Python 3.11.9 (tags/v3.11.9:de54cf5, Apr  2 2024, 10:12:12) [MSC v.1938 64 bit (AMD64)] on win32\n");
    print("Type \"help\", \"copyright\", \"credits\" or \"license\" for more information.\n");
}

void py_print_help() {
    print("Type help() for interactive help, or help(object) for help about object.\n");
}

void py_print_help_topic(char* topic) {
    if (!topic || !*topic) {
        py_print_help();
        return;
    }
    print("No Python documentation found for '");
    print(topic);
    print("'.\n");
}

void py_print_copyright_notice() {
    print("Copyright (c) 2001-2024 Python Software Foundation.\n");
    print("All Rights Reserved.\n");
    print("This ROVM build provides a small Python-compatible subset.\n");
}

void py_print_credits_notice() {
    print("Thanks to the Python Software Foundation and the CPython community.\n");
    print("This interpreter borrows the look and feel of Python 3.11 where practical.\n");
}

void py_print_license_notice() {
    print("See the Python Software Foundation License for CPython.\n");
    print("Documentation: https://docs.python.org/3/license.html\n");
}

void py_run_help_utility() {
    int len;
    char help_clean[256];
    print("Welcome to Python 3.11's help utility! If this is your first time using\n");
    print("Python, you should definitely check out the tutorial at\n");
    print("https://docs.python.org/3.11/tutorial/.\n\n");
    print("Enter the name of any module, keyword, or topic to get help on writing\n");
    print("Python programs and using Python modules.  To get a list of available\n");
    print("modules, keywords, symbols, or topics, enter \"modules\", \"keywords\",\n");
    print("\"symbols\", or \"topics\".\n\n");
    print("Each module also comes with a one-line summary of what it does; to list\n");
    print("the modules whose name or summary contain a given string such as \"spam\",\n");
    print("enter \"modules spam\".\n\n");
    print("To quit this help utility and return to the interpreter,\n");
    print("enter \"q\" or \"quit\".\n\n");
    while (1) {
        len = py_read_line("help> ", py_input_line, 256);
        if (len < 0) {
            printchar(10);
            return;
        }
        py_sanitize_line(py_input_line, help_clean, 256);
        if (strlen(help_clean) <= 0) continue;
        if (strcmp(help_clean, "q") == 0 || strcmp(help_clean, "quit") == 0) return;
        if (strcmp(help_clean, "modules") == 0) {
            print("No module index is available in this build.\n");
            continue;
        }
        if (strncmp(help_clean, "modules ", 8) == 0) {
            print("No module index is available in this build.\n");
            continue;
        }
        if (strcmp(help_clean, "keywords") == 0) {
            print("Available keywords include: and, break, continue, def, elif,\n");
            print("else, False, for, if, None, not, or, pass, print, True, while.\n");
            continue;
        }
        if (strcmp(help_clean, "symbols") == 0) {
            print("Common symbols include: (), [], {}, :, ,, ., +, -, *, /, %, ==, !=.\n");
            continue;
        }
        if (strcmp(help_clean, "topics") == 0) {
            print("Common topics include: variables, strings, loops, conditionals.\n");
            continue;
        }
        py_print_help_topic(help_clean);
    }
}

int main() {
    int len;
    int collecting;
    char clean[256];
    collecting = 0;
    py_reset_program();
    py_print_repl_banner();
    while (1) {
        len = py_read_line(collecting ? "... " : ">>> ", py_input_line, 256);
        if (len < 0) {
            printchar(10);
            return 0;
        }

        if (len == 0) {
            if (collecting && py_program_len > 0) {
                py_run_buffer();
                py_reset_program();
                collecting = 0;
            }
            continue;
        }

        py_sanitize_line(py_input_line, clean, 256);
        if (strlen(clean) <= 0) {
            if (collecting) continue;
            continue;
        }

        if (!collecting) {
            if (strcmp(clean, "help") == 0) {
                py_print_help();
                continue;
            }
            if (strcmp(clean, "help()") == 0) {
                py_run_help_utility();
                continue;
            }
            if (strncmp(clean, "help(", 5) == 0 && clean[strlen(clean) - 1] == ')') {
                py_copy_trim_range(clean, 5, strlen(clean) - 2, py_stmt, 256);
                if (strlen(py_stmt) <= 0) py_run_help_utility();
                else py_print_help_topic(py_stmt);
                continue;
            }
            if (strcmp(clean, "copyright") == 0) {
                py_print_copyright_notice();
                continue;
            }
            if (strcmp(clean, "credits") == 0) {
                py_print_credits_notice();
                continue;
            }
            if (strcmp(clean, "license") == 0) {
                py_print_license_notice();
                continue;
            }
            if (strcmp(clean, "clear") == 0) {
                syscall(5, 0, 0, 0, 0, 0, 0);
                py_print_repl_banner();
                continue;
            }
            if (strcmp(clean, "exit") == 0 || strcmp(clean, "quit") == 0 ||
                strcmp(clean, "exit()") == 0 || strcmp(clean, "quit()") == 0) {
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

        py_run_buffer();
        py_reset_program();
        collecting = 0;
    }
    return 0;
}
]===]

return python_c