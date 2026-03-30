local python_runtime_h2 = [===[
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

int py_stmt_has_keyword(char* keyword) {
    int klen;
    klen = strlen(keyword);
    if (strncmp(py_stmt, keyword, klen) != 0) return 0;
    if (py_stmt[klen] == 0) return 1;
    if (py_stmt[klen] == ' ' || py_stmt[klen] == '\t' || py_stmt[klen] == ':' || py_stmt[klen] == '(') return 1;
    return 0;
}

int py_parse_identifier_at(char* text, int start, char* out_name, int* out_pos) {
    int pos;
    int out;
    pos = start;
    out = 0;
    while (text[pos] == ' ' || text[pos] == '\t') pos++;
    if (!py_is_name_start(text[pos])) return 0;
    while (py_is_name_char(text[pos]) && out < PY_MAX_NAME - 1) {
        out_name[out] = text[pos];
        out++;
        pos++;
    }
    out_name[out] = 0;
    *out_pos = pos;
    return 1;
}

int py_extract_header_expr(char* keyword, char* out, int line_no) {
    int klen;
    int len;
    int start;
    int end;
    klen = strlen(keyword);
    len = strlen(py_stmt);
    if (!py_stmt_has_keyword(keyword)) return 0;
    end = len - 1;
    while (end >= 0 && (py_stmt[end] == ' ' || py_stmt[end] == '\t')) end--;
    if (end < 0 || py_stmt[end] != ':') {
        py_set_error("expected ':'", line_no);
        return 0;
    }
    start = klen;
    while (py_stmt[start] == ' ' || py_stmt[start] == '\t') start++;
    end--;
    while (end >= start && (py_stmt[end] == ' ' || py_stmt[end] == '\t')) end--;
    if (end < start) {
        py_set_error("expected an expression", line_no);
        return 0;
    }
    py_copy_trim_range(py_stmt, start, end, out, 256);
    return 1;
}

int py_parse_for_header(char* out_name, char* out_expr, int line_no) {
    int len;
    int pos;
    int expr_start;
    int end;
    len = strlen(py_stmt);
    end = len - 1;
    while (end >= 0 && (py_stmt[end] == ' ' || py_stmt[end] == '\t')) end--;
    if (end < 0 || py_stmt[end] != ':') {
        py_set_error("expected ':'", line_no);
        return 0;
    }
    pos = 3;
    if (!py_parse_identifier_at(py_stmt, pos, out_name, &pos) || py_is_reserved_keyword_name(out_name)) {
        py_set_error("expected loop variable", line_no);
        return 0;
    }
    while (py_stmt[pos] == ' ' || py_stmt[pos] == '\t') pos++;
    if (py_stmt[pos] != 'i' || py_stmt[pos + 1] != 'n' || py_is_name_char(py_stmt[pos + 2])) {
        py_set_error("expected 'in'", line_no);
        return 0;
    }
    pos += 2;
    expr_start = pos;
    while (py_stmt[expr_start] == ' ' || py_stmt[expr_start] == '\t') expr_start++;
    end--;
    while (end >= expr_start && (py_stmt[end] == ' ' || py_stmt[end] == '\t')) end--;
    if (end < expr_start) {
        py_set_error("expected iterable expression", line_no);
        return 0;
    }
    py_copy_trim_range(py_stmt, expr_start, end, out_expr, 256);
    return 1;
}

int py_parse_def_header(char* out_name, char*** out_arg_names, int* out_arg_count, int line_no) {
    int len;
    int pos;
    int argc;
    char* temp_args[PY_MAX_ARGS];
    int i;
    len = strlen(py_stmt);
    if (len <= 0 || py_stmt[len - 1] != ':') {
        py_set_error("expected ':'", line_no);
        return 0;
    }
    pos = 3;
    if (!py_parse_identifier_at(py_stmt, pos, out_name, &pos) || py_is_reserved_keyword_name(out_name)) {
        py_set_error("expected function name", line_no);
        return 0;
    }
    while (py_stmt[pos] == ' ' || py_stmt[pos] == '\t') pos++;
    if (py_stmt[pos] != '(') {
        py_set_error("expected '('", line_no);
        return 0;
    }
    pos++;
    argc = 0;
    while (1) {
        while (py_stmt[pos] == ' ' || py_stmt[pos] == '\t') pos++;
        if (py_stmt[pos] == ')') {
            pos++;
            break;
        }
        if (argc >= PY_MAX_ARGS) {
            py_set_error("too many function arguments", line_no);
            return 0;
        }
        if (!py_parse_identifier_at(py_stmt, pos, py_name_arg, &pos) || py_is_reserved_keyword_name(py_name_arg)) {
            py_set_error("expected argument name", line_no);
            return 0;
        }
        temp_args[argc] = py_strdup_text(py_name_arg);
        if (!temp_args[argc]) return 0;
        argc++;
        while (py_stmt[pos] == ' ' || py_stmt[pos] == '\t') pos++;
        if (py_stmt[pos] == ',') {
            pos++;
            continue;
        }
        if (py_stmt[pos] == ')') {
            pos++;
            break;
        }
        py_set_error("expected ',' or ')'", line_no);
        return 0;
    }
    while (py_stmt[pos] == ' ' || py_stmt[pos] == '\t') pos++;
    if (py_stmt[pos] != ':') {
        py_set_error("expected ':'", line_no);
        return 0;
    }
    if (argc > 0) {
        *out_arg_names = (char**)malloc(sizeof(char*) * argc);
        if (!*out_arg_names) {
            py_set_error("out of memory", line_no);
            return 0;
        }
        i = 0;
        while (i < argc) {
            (*out_arg_names)[i] = temp_args[i];
            i++;
        }
    } else {
        *out_arg_names = (char**)0;
    }
    *out_arg_count = argc;
    return 1;
}

int py_find_suite_end(int start, int parent_indent, int end) {
    int i;
    i = start;
    while (i < end && py_line_indent[i] > parent_indent) i++;
    return i;
}

void py_parser_skip_spaces(PyParser* parser) {
    while (py_expr_text[py_expr_pos] == ' ' || py_expr_text[py_expr_pos] == '\t' || py_expr_text[py_expr_pos] == '\r') {
        py_expr_pos++;
    }
}

int py_parser_match_char(PyParser* parser, int ch) {
    py_parser_skip_spaces(parser);
    if (py_expr_text[py_expr_pos] == ch) {
        py_expr_pos++;
        return 1;
    }
    return 0;
}

int py_parser_match_op(PyParser* parser, char* op) {
    int len;
    len = strlen(op);
    py_parser_skip_spaces(parser);
    if (strncmp(py_expr_text + py_expr_pos, op, len) == 0) {
        py_expr_pos += len;
        return 1;
    }
    return 0;
}

int py_parser_match_word(PyParser* parser, char* word) {
    int len;
    len = strlen(word);
    py_parser_skip_spaces(parser);
    if (strncmp(py_expr_text + py_expr_pos, word, len) != 0) return 0;
    if (py_is_name_char(py_expr_text[py_expr_pos + len])) return 0;
    py_expr_pos += len;
    return 1;
}

int py_parser_read_name(PyParser* parser, char* out_name) {
    int out;
    py_parser_skip_spaces(parser);
    if (!py_is_name_start(py_expr_text[py_expr_pos])) return 0;
    out = 0;
    while (py_is_name_char(py_expr_text[py_expr_pos]) && out < PY_MAX_NAME - 1) {
        out_name[out] = py_expr_text[py_expr_pos];
        out++;
        py_expr_pos++;
    }
    out_name[out] = 0;
    return 1;
}

int py_is_reserved_keyword_name(char* name) {
    if (!name || !*name) return 0;
    if (strcmp(name, "and") == 0) return 1;
    if (strcmp(name, "as") == 0) return 1;
    if (strcmp(name, "assert") == 0) return 1;
    if (strcmp(name, "break") == 0) return 1;
    if (strcmp(name, "class") == 0) return 1;
    if (strcmp(name, "continue") == 0) return 1;
    if (strcmp(name, "def") == 0) return 1;
    if (strcmp(name, "del") == 0) return 1;
    if (strcmp(name, "elif") == 0) return 1;
    if (strcmp(name, "else") == 0) return 1;
    if (strcmp(name, "except") == 0) return 1;
    if (strcmp(name, "False") == 0) return 1;
    if (strcmp(name, "for") == 0) return 1;
    if (strcmp(name, "from") == 0) return 1;
    if (strcmp(name, "global") == 0) return 1;
    if (strcmp(name, "if") == 0) return 1;
    if (strcmp(name, "import") == 0) return 1;
    if (strcmp(name, "in") == 0) return 1;
    if (strcmp(name, "is") == 0) return 1;
    if (strcmp(name, "lambda") == 0) return 1;
    if (strcmp(name, "None") == 0) return 1;
    if (strcmp(name, "nonlocal") == 0) return 1;
    if (strcmp(name, "not") == 0) return 1;
    if (strcmp(name, "or") == 0) return 1;
    if (strcmp(name, "pass") == 0) return 1;
    if (strcmp(name, "raise") == 0) return 1;
    if (strcmp(name, "return") == 0) return 1;
    if (strcmp(name, "True") == 0) return 1;
    if (strcmp(name, "try") == 0) return 1;
    if (strcmp(name, "while") == 0) return 1;
    if (strcmp(name, "with") == 0) return 1;
    return 0;
}

int py_emit_const_value(PyCompiler* compiler, PyObject* value, int line_no) {
    int index;
    index = py_code_add_const(compiler->code, value);
    if (index < 0) return 0;
    if (py_emit_instruction(compiler->code, PY_OP_LOAD_CONST, index, line_no) < 0) return 0;
    return 1;
}

int py_emit_name_value(PyCompiler* compiler, int op, char* name, int line_no) {
    int index;
    if (op == PY_OP_LOAD_NAME && !py_validate_name_load(compiler, name, line_no)) {
        return 0;
    }
    index = py_code_add_name(compiler->code, name);
    if (index < 0) return 0;
    if (py_emit_instruction(compiler->code, op, index, line_no) < 0) return 0;
    return 1;
}

int py_compile_expression(PyParser* parser);

int py_compile_primary(PyParser* parser) {
    int out;
    int ch;
    int escaped;
    int quote;
    int n;

    py_parser_skip_spaces(parser);

    if (py_parser_match_char(parser, '(')) {
        if (!py_compile_expression(parser)) return 0;
        if (!py_error && !py_parser_match_char(parser, ')')) {
            py_set_error("expected ')'", py_expr_line);
            return 0;
        }
    } else if (py_expr_text[py_expr_pos] == '"' || py_expr_text[py_expr_pos] == '\'') {
        quote = py_expr_text[py_expr_pos];
        py_expr_pos++;
        out = 0;
        escaped = 0;
        while (py_expr_text[py_expr_pos]) {
            ch = py_expr_text[py_expr_pos];
            py_expr_pos++;
            if (!escaped && ch == quote) break;
            if (!escaped && ch == '\\') {
                escaped = 1;
                continue;
            }
            if (escaped) {
                if (ch == 'n') ch = '\n';
                else if (ch == 't') ch = '\t';
                else if (ch == 'r') ch = '\r';
                escaped = 0;
            }
            if (out >= 255) {
                py_set_error("string literal too long", py_expr_line);
                return 0;
            }
            py_string_temp[out] = (char)ch;
            out++;
        }
        if (escaped) {
            py_set_error("unfinished escape", py_expr_line);
            return 0;
        }
        if (py_expr_pos <= 0 || py_expr_text[py_expr_pos - 1] != quote) {
            py_set_error("unterminated string", py_expr_line);
            return 0;
        }
        py_string_temp[out] = 0;
        if (!py_emit_const_value(py_expr_compiler, py_make_string(py_string_temp), py_expr_line)) return 0;
    } else if (py_parser_match_char(parser, '[')) {
        int item_count;
        item_count = 0;
        py_parser_skip_spaces(parser);
        if (!py_parser_match_char(parser, ']')) {
            while (!py_error) {
                if (!py_compile_expression(parser)) return 0;
                item_count++;
                py_parser_skip_spaces(parser);
                if (py_parser_match_char(parser, ']')) break;
                if (!py_parser_match_char(parser, ',')) {
                    py_set_error("expected ',' or ']'", py_expr_line);
                    return 0;
                }
            }
        }
        if (py_emit_instruction(py_expr_compiler->code, PY_OP_BUILD_LIST, item_count, py_expr_line) < 0) return 0;
    } else if (isdigit(py_expr_text[py_expr_pos])) {
        n = 0;
        while (isdigit(py_expr_text[py_expr_pos])) {
            n = n * 10 + (py_expr_text[py_expr_pos] - '0');
            py_expr_pos++;
        }
        if (!py_emit_const_value(py_expr_compiler, py_make_int(n), py_expr_line)) return 0;
    } else if (py_parser_match_word(parser, "True")) {
        if (!py_emit_const_value(py_expr_compiler, py_make_bool(1), py_expr_line)) return 0;
    } else if (py_parser_match_word(parser, "False")) {
        if (!py_emit_const_value(py_expr_compiler, py_make_bool(0), py_expr_line)) return 0;
    } else if (py_parser_match_word(parser, "None")) {
        if (!py_emit_const_value(py_expr_compiler, py_make_none(), py_expr_line)) return 0;
    } else if (py_parser_read_name(parser, py_name_parse)) {
        if (py_is_reserved_keyword_name(py_name_parse)) {
            py_set_error("syntax error", py_expr_line);
            return 0;
        }
        if (!py_emit_name_value(py_expr_compiler, PY_OP_LOAD_NAME, py_name_parse, py_expr_line)) return 0;
    } else {
        py_set_error("syntax error", py_expr_line);
        return 0;
    }

    while (!py_error) {
        py_parser_skip_spaces(parser);
        if (py_parser_match_char(parser, '.')) {
            int attr_index;
            if (!py_parser_read_name(parser, py_name_attr)) {
                py_set_error("expected attribute name", py_expr_line);
                return 0;
            }
            attr_index = py_code_add_name(py_expr_compiler->code, py_name_attr);
            if (attr_index < 0) return 0;
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_LOAD_ATTR, attr_index, py_expr_line) < 0) return 0;
        } else if (py_parser_match_char(parser, '(')) {
            int arg_count;
            arg_count = 0;
            py_parser_skip_spaces(parser);
            if (!py_parser_match_char(parser, ')')) {
                while (!py_error) {
                    if (arg_count >= PY_MAX_ARGS) {
                        py_set_error("too many call arguments", py_expr_line);
                        return 0;
                    }
                    if (!py_compile_expression(parser)) return 0;
                    arg_count++;
                    py_parser_skip_spaces(parser);
                    if (py_parser_match_char(parser, ')')) break;
                    if (!py_parser_match_char(parser, ',')) {
                        py_set_error("expected ',' or ')'", py_expr_line);
                        return 0;
                    }
                }
            }
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_CALL, arg_count, py_expr_line) < 0) return 0;
        } else if (py_parser_match_char(parser, '[')) {
            if (!py_compile_expression(parser)) return 0;
            if (!py_parser_match_char(parser, ']')) {
                py_set_error("expected ']'", py_expr_line);
                return 0;
            }
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_BINARY_SUBSCR, 0, py_expr_line) < 0) return 0;
        } else {
            break;
        }
    }

    return !py_error;
}

int py_compile_unary(PyParser* parser) {
    if (py_parser_match_word(parser, "not")) {
        if (!py_compile_unary(parser)) return 0;
        if (py_emit_instruction(py_expr_compiler->code, PY_OP_UNARY_NOT, 0, py_expr_line) < 0) return 0;
        return 1;
    }
    if (py_parser_match_char(parser, '+')) {
        if (!py_compile_unary(parser)) return 0;
        if (py_emit_instruction(py_expr_compiler->code, PY_OP_UNARY_POSITIVE, 0, py_expr_line) < 0) return 0;
        return 1;
    }
    if (py_parser_match_char(parser, '-')) {
        if (!py_compile_unary(parser)) return 0;
        if (py_emit_instruction(py_expr_compiler->code, PY_OP_UNARY_NEGATIVE, 0, py_expr_line) < 0) return 0;
        return 1;
    }
    return py_compile_primary(parser);
}

int py_compile_mul(PyParser* parser) {
    if (!py_compile_unary(parser)) return 0;
    while (!py_error) {
        if (py_parser_match_op(parser, "//")) {
            if (!py_compile_unary(parser)) return 0;
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_BINARY_DIV, 0, py_expr_line) < 0) return 0;
        } else if (py_parser_match_char(parser, '*')) {
            if (!py_compile_unary(parser)) return 0;
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_BINARY_MUL, 0, py_expr_line) < 0) return 0;
        } else if (py_parser_match_char(parser, '/')) {
            if (!py_compile_unary(parser)) return 0;
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_BINARY_DIV, 0, py_expr_line) < 0) return 0;
        } else if (py_parser_match_char(parser, '%')) {
            if (!py_compile_unary(parser)) return 0;
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_BINARY_MOD, 0, py_expr_line) < 0) return 0;
        } else {
            break;
        }
    }
    return !py_error;
}

int py_compile_add(PyParser* parser) {
    if (!py_compile_mul(parser)) return 0;
    while (!py_error) {
        if (py_parser_match_char(parser, '+')) {
            if (!py_compile_mul(parser)) return 0;
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_BINARY_ADD, 0, py_expr_line) < 0) return 0;
        } else if (py_parser_match_char(parser, '-')) {
            if (!py_compile_mul(parser)) return 0;
            if (py_emit_instruction(py_expr_compiler->code, PY_OP_BINARY_SUB, 0, py_expr_line) < 0) return 0;
        } else {
            break;
        }
    }
    return !py_error;
}

int py_compile_compare(PyParser* parser) {
    int op;
    if (!py_compile_add(parser)) return 0;
    op = 0;
    while (!py_error) {
        if (py_parser_match_op(parser, "==")) op = PY_CMP_EQ;
        else if (py_parser_match_op(parser, "!=")) op = PY_CMP_NE;
        else if (py_parser_match_op(parser, "<=")) op = PY_CMP_LE;
        else if (py_parser_match_op(parser, ">=")) op = PY_CMP_GE;
        else if (py_parser_match_char(parser, '<')) op = PY_CMP_LT;
        else if (py_parser_match_char(parser, '>')) op = PY_CMP_GT;
        else break;

        if (!py_compile_add(parser)) return 0;
        if (py_emit_instruction(py_expr_compiler->code, PY_OP_COMPARE_OP, op, py_expr_line) < 0) return 0;

        py_parser_skip_spaces(parser);
        if (strncmp(py_expr_text + py_expr_pos, "==", 2) == 0 ||
            strncmp(py_expr_text + py_expr_pos, "!=", 2) == 0 ||
            strncmp(py_expr_text + py_expr_pos, "<=", 2) == 0 ||
            strncmp(py_expr_text + py_expr_pos, ">=", 2) == 0 ||
            py_expr_text[py_expr_pos] == '<' ||
            py_expr_text[py_expr_pos] == '>') {
            py_set_error("comparison chaining is not supported", py_expr_line);
            return 0;
        }
    }
    return !py_error;
}

int py_compile_and(PyParser* parser) {
    int patch_count;
    int patches[64];
    if (!py_compile_compare(parser)) return 0;
    patch_count = 0;
    while (!py_error && py_parser_match_word(parser, "and")) {
        if (patch_count >= 64) {
            py_set_error("expression too complex", py_expr_line);
            return 0;
        }
        patches[patch_count] = py_emit_instruction(py_expr_compiler->code, PY_OP_JUMP_IF_FALSE_OR_POP, 0, py_expr_line);
        if (patches[patch_count] < 0) return 0;
        patch_count++;
        if (!py_compile_compare(parser)) return 0;
    }
    while (patch_count > 0) {
        patch_count--;
        py_patch_instruction_arg(py_expr_compiler->code, patches[patch_count], py_expr_compiler->code->instruction_count);
    }
    return !py_error;
}

int py_compile_or(PyParser* parser) {
    int patch_count;
    int patches[64];
    if (!py_compile_and(parser)) return 0;
    patch_count = 0;
    while (!py_error && py_parser_match_word(parser, "or")) {
        if (patch_count >= 64) {
            py_set_error("expression too complex", py_expr_line);
            return 0;
        }
        patches[patch_count] = py_emit_instruction(py_expr_compiler->code, PY_OP_JUMP_IF_TRUE_OR_POP, 0, py_expr_line);
        if (patches[patch_count] < 0) return 0;
        patch_count++;
        if (!py_compile_and(parser)) return 0;
    }
    while (patch_count > 0) {
        patch_count--;
        py_patch_instruction_arg(py_expr_compiler->code, patches[patch_count], py_expr_compiler->code->instruction_count);
    }
    return !py_error;
}

int py_compile_expression(PyParser* parser) {
    return py_compile_or(parser);
}

int py_compile_expression_text(PyCompiler* compiler, char* text, int line_no) {
    py_expr_text = text;
    py_expr_pos = 0;
    py_expr_compiler = compiler;
    py_expr_line = line_no;
    if (!py_compile_expression((PyParser*)0)) return 0;
    if (py_error) return 0;
    py_parser_skip_spaces((PyParser*)0);
    if (py_expr_text[py_expr_pos] != 0) {
        py_set_error("syntax error", line_no);
        return 0;
    }
    return 1;
}
]===]

return python_runtime_h2
