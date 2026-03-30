local python_runtime_h3 = [===[
PyCode* py_alloc_code(char* name, int arg_count, char** arg_names, int single_mode) {
    PyCode* code;
    code = (PyCode*)malloc(sizeof(PyCode));
    if (!code) {
        py_set_error("out of memory", 0);
        return (PyCode*)0;
    }
    code->name = py_strdup_text(name ? name : "<module>");
    if (!code->name) return (PyCode*)0;
    code->arg_count = arg_count;
    code->arg_names = arg_names;
    code->local_count = 0;
    code->local_names = (char**)0;
    code->single_mode = single_mode;
    code->instruction_count = 0;
    code->instruction_cap = 0;
    code->instr_ops = (int*)0;
    code->instr_args = (int*)0;
    code->instr_lines = (int*)0;
    code->const_count = 0;
    code->const_cap = 0;
    code->constants = (PyObject**)0;
    code->name_count = 0;
    code->name_cap = 0;
    code->names = (char**)0;
    return code;
}

int py_code_add_const(PyCode* code, PyObject* value) {
    PyObject** new_values;
    int new_cap;
    if (!code) return -1;
    if (code->const_count >= code->const_cap) {
        new_cap = code->const_cap == 0 ? 8 : code->const_cap * 2;
        new_values = (PyObject**)realloc(code->constants, sizeof(PyObject*) * new_cap);
        if (!new_values) {
            py_set_error("out of memory", 0);
            return -1;
        }
        code->constants = new_values;
        code->const_cap = new_cap;
    }
    code->constants[code->const_count] = value;
    code->const_count++;
    return code->const_count - 1;
}

int py_code_add_name(PyCode* code, char* name) {
    char** new_names;
    int new_cap;
    int i;
    if (!code || !name) return -1;
    i = 0;
    while (i < code->name_count) {
        if (strcmp(code->names[i], name) == 0) return i;
        i++;
    }
    if (code->name_count >= code->name_cap) {
        new_cap = code->name_cap == 0 ? 8 : code->name_cap * 2;
        new_names = (char**)realloc(code->names, sizeof(char*) * new_cap);
        if (!new_names) {
            py_set_error("out of memory", 0);
            return -1;
        }
        code->names = new_names;
        code->name_cap = new_cap;
    }
    code->names[code->name_count] = py_strdup_text(name);
    if (!code->names[code->name_count]) return -1;
    code->name_count++;
    return code->name_count - 1;
}

int py_emit_instruction(PyCode* code, int op, int arg, int line_no) {
    int* new_ops;
    int* new_args;
    int* new_lines;
    int new_cap;
    if (!code) return -1;
    if (code->instruction_count >= code->instruction_cap) {
        new_cap = code->instruction_cap == 0 ? 16 : code->instruction_cap * 2;
        new_ops = (int*)realloc(code->instr_ops, sizeof(int) * new_cap);
        new_args = (int*)realloc(code->instr_args, sizeof(int) * new_cap);
        new_lines = (int*)realloc(code->instr_lines, sizeof(int) * new_cap);
        if (!new_ops || !new_args || !new_lines) {
            py_set_error("out of memory", line_no);
            return -1;
        }
        code->instr_ops = new_ops;
        code->instr_args = new_args;
        code->instr_lines = new_lines;
        code->instruction_cap = new_cap;
    }
    code->instr_ops[code->instruction_count] = op;
    code->instr_args[code->instruction_count] = arg;
    code->instr_lines[code->instruction_count] = line_no;
    code->instruction_count++;
    return code->instruction_count - 1;
}

void py_patch_instruction_arg(PyCode* code, int index, int arg) {
    if (!code) return;
    if (index < 0 || index >= code->instruction_count) return;
    code->instr_args[index] = arg;
}

int py_compiler_has_local(PyCompiler* compiler, char* name) {
    int i;
    if (!compiler || !name) return 0;
    i = 0;
    while (i < compiler->local_count) {
        if (compiler->local_names[i] && strcmp(compiler->local_names[i], name) == 0) {
            return 1;
        }
        i++;
    }
    return 0;
}

int py_compiler_add_local(PyCompiler* compiler, char* name) {
    char** new_names;
    int new_cap;
    if (!compiler || !name || !*name) return 0;
    if (py_compiler_has_local(compiler, name)) return 1;
    if (compiler->local_count >= compiler->local_cap) {
        new_cap = compiler->local_cap == 0 ? 8 : compiler->local_cap * 2;
        new_names = (char**)realloc(compiler->local_names, sizeof(char*) * new_cap);
        if (!new_names) {
            py_set_error("out of memory", 0);
            return 0;
        }
        compiler->local_names = new_names;
        compiler->local_cap = new_cap;
    }
    compiler->local_names[compiler->local_count] = py_strdup_text(name);
    if (!compiler->local_names[compiler->local_count]) return 0;
    compiler->local_count++;
    return 1;
}

int py_compiler_name_in_parent_locals(PyCompiler* compiler, char* name) {
    PyCompiler* parent;
    parent = compiler ? compiler->parent : (PyCompiler*)0;
    while (parent) {
        if (!parent->is_module && py_compiler_has_local(parent, name)) {
            return 1;
        }
        parent = parent->parent;
    }
    return 0;
}

int py_validate_name_load(PyCompiler* compiler, char* name, int line_no) {
    if (!compiler || !name) return 1;
    if (py_compiler_has_local(compiler, name)) return 1;
    if (py_compiler_name_in_parent_locals(compiler, name)) {
        py_set_error("closure capture is not supported", line_no);
        return 0;
    }
    return 1;
}

int py_parse_assignment_stmt(char* out_name, char* out_op, char* out_expr) {
    int pos;
    int op_pos;
    int len;
    if (!py_parse_identifier_at(py_stmt, 0, out_name, &pos)) return 0;
    if (py_is_reserved_keyword_name(out_name)) return 0;
    op_pos = pos;
    while (py_stmt[op_pos] == ' ' || py_stmt[op_pos] == '\t') op_pos++;
    out_op[0] = 0;
    if (py_stmt[op_pos] == '=' && py_stmt[op_pos + 1] != '=') {
        out_op[0] = '=';
        out_op[1] = 0;
        py_copy_trim_range(py_stmt, op_pos + 1, strlen(py_stmt) - 1, out_expr, 256);
        return 1;
    }
    if ((py_stmt[op_pos] == '+' || py_stmt[op_pos] == '-' || py_stmt[op_pos] == '*' || py_stmt[op_pos] == '/' || py_stmt[op_pos] == '%') &&
        py_stmt[op_pos + 1] == '=') {
        out_op[0] = py_stmt[op_pos];
        out_op[1] = '=';
        out_op[2] = 0;
        len = strlen(py_stmt);
        py_copy_trim_range(py_stmt, op_pos + 2, len - 1, out_expr, 256);
        return 1;
    }
    return 0;
}

int py_stmt_skip_spaces(int pos) {
    while (py_stmt[pos] == ' ' || py_stmt[pos] == '\t') pos++;
    return pos;
}

int py_collect_import_locals(PyCompiler* compiler, int line_no) {
    int pos;
    if (py_stmt_has_keyword("import")) {
        pos = 6;
        while (!py_error) {
            py_name_attr[0] = 0;
            if (!py_parse_identifier_at(py_stmt, pos, py_name_parse, &pos) || py_is_reserved_keyword_name(py_name_parse)) {
                py_set_error("expected module name", line_no);
                return 1;
            }
            py_copy_limit(py_name_attr, py_name_parse, PY_MAX_NAME);
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == 'a' && py_stmt[pos + 1] == 's' && !py_is_name_char(py_stmt[pos + 2])) {
                pos += 2;
                if (!py_parse_identifier_at(py_stmt, pos, py_name_attr, &pos) || py_is_reserved_keyword_name(py_name_attr)) {
                    py_set_error("expected alias name", line_no);
                    return 1;
                }
            }
            if (!py_compiler_add_local(compiler, py_name_attr)) return 1;
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == ',') {
                pos++;
                continue;
            }
            if (py_stmt[pos] == 0) return 1;
            py_set_error("expected ',' or end of import", line_no);
            return 1;
        }
        return 1;
    }
    if (py_stmt_has_keyword("from")) {
        pos = 4;
        if (!py_parse_identifier_at(py_stmt, pos, py_name_parse, &pos) || py_is_reserved_keyword_name(py_name_parse)) {
            py_set_error("expected module name", line_no);
            return 1;
        }
        pos = py_stmt_skip_spaces(pos);
        if (py_stmt[pos] != 'i' || py_stmt[pos + 1] != 'm' || py_stmt[pos + 2] != 'p' ||
            py_stmt[pos + 3] != 'o' || py_stmt[pos + 4] != 'r' || py_stmt[pos + 5] != 't' ||
            py_is_name_char(py_stmt[pos + 6])) {
            py_set_error("expected 'import'", line_no);
            return 1;
        }
        pos += 6;
        while (!py_error) {
            py_name_attr[0] = 0;
            if (!py_parse_identifier_at(py_stmt, pos, py_name_def, &pos) || py_is_reserved_keyword_name(py_name_def)) {
                py_set_error("expected imported name", line_no);
                return 1;
            }
            py_copy_limit(py_name_attr, py_name_def, PY_MAX_NAME);
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == 'a' && py_stmt[pos + 1] == 's' && !py_is_name_char(py_stmt[pos + 2])) {
                pos += 2;
                if (!py_parse_identifier_at(py_stmt, pos, py_name_attr, &pos) || py_is_reserved_keyword_name(py_name_attr)) {
                    py_set_error("expected alias name", line_no);
                    return 1;
                }
            }
            if (!py_compiler_add_local(compiler, py_name_attr)) return 1;
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == ',') {
                pos++;
                continue;
            }
            if (py_stmt[pos] == 0) return 1;
            py_set_error("expected ',' or end of import", line_no);
            return 1;
        }
        return 1;
    }
    return 0;
}

int py_compile_import_statement(PyCompiler* compiler, int line_no) {
    int pos;
    int module_name_index;
    int alias_name_index;
    int attr_name_index;
    if (py_stmt_has_keyword("import")) {
        pos = 6;
        while (!py_error) {
            py_name_attr[0] = 0;
            if (!py_parse_identifier_at(py_stmt, pos, py_name_parse, &pos) || py_is_reserved_keyword_name(py_name_parse)) {
                py_set_error("expected module name", line_no);
                return 1;
            }
            py_copy_limit(py_name_attr, py_name_parse, PY_MAX_NAME);
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == 'a' && py_stmt[pos + 1] == 's' && !py_is_name_char(py_stmt[pos + 2])) {
                pos += 2;
                if (!py_parse_identifier_at(py_stmt, pos, py_name_attr, &pos) || py_is_reserved_keyword_name(py_name_attr)) {
                    py_set_error("expected alias name", line_no);
                    return 1;
                }
            }
            module_name_index = py_code_add_name(compiler->code, py_name_parse);
            if (module_name_index < 0) return 1;
            if (py_emit_instruction(compiler->code, PY_OP_IMPORT_NAME, module_name_index, line_no) < 0) return 1;
            alias_name_index = py_code_add_name(compiler->code, py_name_attr);
            if (alias_name_index < 0) return 1;
            if (py_emit_instruction(compiler->code, PY_OP_STORE_NAME, alias_name_index, line_no) < 0) return 1;
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == ',') {
                pos++;
                continue;
            }
            if (py_stmt[pos] == 0) return 1;
            py_set_error("expected ',' or end of import", line_no);
            return 1;
        }
        return 1;
    }
    if (py_stmt_has_keyword("from")) {
        pos = 4;
        if (!py_parse_identifier_at(py_stmt, pos, py_name_parse, &pos) || py_is_reserved_keyword_name(py_name_parse)) {
            py_set_error("expected module name", line_no);
            return 1;
        }
        pos = py_stmt_skip_spaces(pos);
        if (py_stmt[pos] != 'i' || py_stmt[pos + 1] != 'm' || py_stmt[pos + 2] != 'p' ||
            py_stmt[pos + 3] != 'o' || py_stmt[pos + 4] != 'r' || py_stmt[pos + 5] != 't' ||
            py_is_name_char(py_stmt[pos + 6])) {
            py_set_error("expected 'import'", line_no);
            return 1;
        }
        pos += 6;
        module_name_index = py_code_add_name(compiler->code, py_name_parse);
        if (module_name_index < 0) return 1;
        while (!py_error) {
            py_name_attr[0] = 0;
            if (!py_parse_identifier_at(py_stmt, pos, py_name_def, &pos) || py_is_reserved_keyword_name(py_name_def)) {
                py_set_error("expected imported name", line_no);
                return 1;
            }
            py_copy_limit(py_name_attr, py_name_def, PY_MAX_NAME);
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == 'a' && py_stmt[pos + 1] == 's' && !py_is_name_char(py_stmt[pos + 2])) {
                pos += 2;
                if (!py_parse_identifier_at(py_stmt, pos, py_name_attr, &pos) || py_is_reserved_keyword_name(py_name_attr)) {
                    py_set_error("expected alias name", line_no);
                    return 1;
                }
            }
            if (py_emit_instruction(compiler->code, PY_OP_IMPORT_NAME, module_name_index, line_no) < 0) return 1;
            attr_name_index = py_code_add_name(compiler->code, py_name_def);
            if (attr_name_index < 0) return 1;
            if (py_emit_instruction(compiler->code, PY_OP_LOAD_ATTR, attr_name_index, line_no) < 0) return 1;
            alias_name_index = py_code_add_name(compiler->code, py_name_attr);
            if (alias_name_index < 0) return 1;
            if (py_emit_instruction(compiler->code, PY_OP_STORE_NAME, alias_name_index, line_no) < 0) return 1;
            pos = py_stmt_skip_spaces(pos);
            if (py_stmt[pos] == ',') {
                pos++;
                continue;
            }
            if (py_stmt[pos] == 0) return 1;
            py_set_error("expected ',' or end of import", line_no);
            return 1;
        }
        return 1;
    }
    return 0;
}

int py_collect_locals(PyCompiler* compiler, int start, int end, int indent);

int py_collect_if_chain_locals(PyCompiler* compiler, int index, int end, int indent) {
    int next;
    int body_start;
    int body_end;
    int line_no;
    next = index;
    while (next < end && !py_error) {
        line_no = py_line_number[next];
        if (py_line_indent[next] != indent) return next;
        py_copy_line_text(next);
        if (next == index) {
            if (!py_stmt_has_keyword("if")) return next;
        } else if (!py_stmt_has_keyword("elif") && strcmp(py_stmt, "else:") != 0) {
            return next;
        }
        body_start = next + 1;
        if (body_start >= end || py_line_indent[body_start] <= indent) {
            py_set_error("expected an indented block", line_no);
            return end;
        }
        body_end = py_find_suite_end(body_start, indent, end);
        py_collect_locals(compiler, body_start, body_end, py_line_indent[body_start]);
        if (py_error) return end;
        if (strcmp(py_stmt, "else:") == 0) return body_end;
        next = body_end;
        if (next >= end || py_line_indent[next] != indent) return next;
        py_copy_line_text(next);
        if (!py_stmt_has_keyword("elif") && strcmp(py_stmt, "else:") != 0) return next;
    }
    return next;
}

int py_collect_locals(PyCompiler* compiler, int start, int end, int indent) {
    int i;
    i = start;
    while (i < end && !py_error) {
        int line_no;
        int body_start;
        int body_end;
        int pos;
        line_no = py_line_number[i];
        if (py_line_indent[i] < indent) return i;
        if (py_line_indent[i] > indent) {
            py_set_error("unexpected indentation", line_no);
            return end;
        }
        py_copy_line_text(i);

        if (py_stmt_has_keyword("if")) {
            i = py_collect_if_chain_locals(compiler, i, end, indent);
            continue;
        }

        if (py_stmt_has_keyword("while")) {
            body_start = i + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block", line_no);
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            py_collect_locals(compiler, body_start, body_end, py_line_indent[body_start]);
            if (py_error) return end;
            i = body_end;
            continue;
        }

        if (py_stmt_has_keyword("for")) {
            if (py_parse_for_header(py_name_loop, py_saved_expr, line_no)) {
                if (!py_compiler_add_local(compiler, py_name_loop)) return end;
            }
            body_start = i + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block", line_no);
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            py_collect_locals(compiler, body_start, body_end, py_line_indent[body_start]);
            if (py_error) return end;
            i = body_end;
            continue;
        }

        if (py_stmt_has_keyword("def")) {
            if (py_parse_identifier_at(py_stmt, 3, py_name_def, &pos) && !py_is_reserved_keyword_name(py_name_def)) {
                if (!py_compiler_add_local(compiler, py_name_def)) return end;
            }
            body_start = i + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block", line_no);
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            i = body_end;
            continue;
        }

        if (py_collect_import_locals(compiler, line_no)) {
            if (py_error) return end;
            i++;
            continue;
        }

        if (py_parse_assignment_stmt(py_name_assign, py_assign_op, py_saved_expr)) {
            if (!py_compiler_add_local(compiler, py_name_assign)) return end;
        }
        i++;
    }
    return i;
}

int py_compile_block(PyCompiler* compiler, int start, int end, int indent);

int py_compile_simple(PyCompiler* compiler, int line_no) {
    if (strcmp(py_stmt, "pass") == 0) return 1;

    if (py_parse_assignment_stmt(py_name_assign, py_assign_op, py_saved_expr)) {
        if (strlen(py_saved_expr) <= 0) {
            py_set_error("missing assignment value", line_no);
            return 0;
        }
        if (!py_compiler_add_local(compiler, py_name_assign)) return 0;
        if (strcmp(py_assign_op, "=") != 0) {
            if (!py_emit_name_value(compiler, PY_OP_LOAD_NAME, py_name_assign, line_no)) return 0;
        }
        if (!py_compile_expression_text(compiler, py_saved_expr, line_no)) return 0;
        if (strcmp(py_assign_op, "+=") == 0) {
            if (py_emit_instruction(compiler->code, PY_OP_BINARY_ADD, 0, line_no) < 0) return 0;
        } else if (strcmp(py_assign_op, "-=") == 0) {
            if (py_emit_instruction(compiler->code, PY_OP_BINARY_SUB, 0, line_no) < 0) return 0;
        } else if (strcmp(py_assign_op, "*=") == 0) {
            if (py_emit_instruction(compiler->code, PY_OP_BINARY_MUL, 0, line_no) < 0) return 0;
        } else if (strcmp(py_assign_op, "/=") == 0) {
            if (py_emit_instruction(compiler->code, PY_OP_BINARY_DIV, 0, line_no) < 0) return 0;
        } else if (strcmp(py_assign_op, "%=") == 0) {
            if (py_emit_instruction(compiler->code, PY_OP_BINARY_MOD, 0, line_no) < 0) return 0;
        } else if (strcmp(py_assign_op, "=") != 0) {
            py_set_error("bad assignment operator", line_no);
            return 0;
        }
        if (!py_emit_name_value(compiler, PY_OP_STORE_NAME, py_name_assign, line_no)) return 0;
        return 1;
    }

    if (!py_compile_expression_text(compiler, py_stmt, line_no)) return 0;
    if (compiler->is_module && compiler->single_mode) {
        if (py_emit_instruction(compiler->code, PY_OP_RETURN_VALUE, 0, line_no) < 0) return 0;
    } else {
        if (py_emit_instruction(compiler->code, PY_OP_POP_TOP, 0, line_no) < 0) return 0;
    }
    return 1;
}
]===]

python_runtime_h3 = python_runtime_h3 .. [===[
int py_compile_if_chain(PyCompiler* compiler, int index, int end, int indent) {
    int next;
    int body_start;
    int body_end;
    int line_no;
    int false_jump;
    int end_jumps[64];
    int end_jump_count;
    int is_else;
    next = index;
    end_jump_count = 0;
    while (next < end && !py_error) {
        line_no = py_line_number[next];
        if (py_line_indent[next] != indent) break;
        py_copy_line_text(next);
        false_jump = -1;
        is_else = 0;
        if (next == index) {
            if (!py_extract_header_expr("if", py_saved_expr, line_no)) return end;
            if (!py_compile_expression_text(compiler, py_saved_expr, line_no)) return end;
            false_jump = py_emit_instruction(compiler->code, PY_OP_POP_JUMP_IF_FALSE, 0, line_no);
            if (false_jump < 0) return end;
        } else if (py_stmt_has_keyword("elif")) {
            if (!py_extract_header_expr("elif", py_saved_expr, line_no)) return end;
            if (!py_compile_expression_text(compiler, py_saved_expr, line_no)) return end;
            false_jump = py_emit_instruction(compiler->code, PY_OP_POP_JUMP_IF_FALSE, 0, line_no);
            if (false_jump < 0) return end;
        } else if (strcmp(py_stmt, "else:") == 0) {
            is_else = 1;
        } else {
            break;
        }

        body_start = next + 1;
        if (body_start >= end || py_line_indent[body_start] <= indent) {
            py_set_error("expected an indented block", line_no);
            return end;
        }
        body_end = py_find_suite_end(body_start, indent, end);
        py_compile_block(compiler, body_start, body_end, py_line_indent[body_start]);
        if (py_error) return end;

        if (!is_else) {
            if (end_jump_count >= 64) {
                py_set_error("if statement is too large", line_no);
                return end;
            }
            end_jumps[end_jump_count] = py_emit_instruction(compiler->code, PY_OP_JUMP, 0, line_no);
            if (end_jumps[end_jump_count] < 0) return end;
            end_jump_count++;
            py_patch_instruction_arg(compiler->code, false_jump, compiler->code->instruction_count);
        }

        next = body_end;
        if (is_else) break;
        if (next >= end || py_line_indent[next] != indent) break;
        py_copy_line_text(next);
        if (!py_stmt_has_keyword("elif") && strcmp(py_stmt, "else:") != 0) break;
    }

    while (end_jump_count > 0) {
        end_jump_count--;
        py_patch_instruction_arg(compiler->code, end_jumps[end_jump_count], compiler->code->instruction_count);
    }
    return next;
}

int py_compile_block(PyCompiler* compiler, int start, int end, int indent) {
    int i;
    i = start;
    while (i < end && !py_error) {
        int line_no;
        int body_start;
        int body_end;
        PyCode* child_code;
        char** arg_names;
        int arg_count;
        line_no = py_line_number[i];
        if (py_line_indent[i] < indent) return i;
        if (py_line_indent[i] > indent) {
            py_set_error("unexpected indentation", line_no);
            return end;
        }

        py_copy_line_text(i);

        if (py_stmt_has_keyword("if")) {
            i = py_compile_if_chain(compiler, i, end, indent);
            continue;
        }

        if (py_stmt_has_keyword("while")) {
            int loop_start;
            int exit_jump;
            if (!py_extract_header_expr("while", py_saved_expr, line_no)) return end;
            body_start = i + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block", line_no);
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            loop_start = compiler->code->instruction_count;
            if (!py_compile_expression_text(compiler, py_saved_expr, line_no)) return end;
            exit_jump = py_emit_instruction(compiler->code, PY_OP_POP_JUMP_IF_FALSE, 0, line_no);
            if (exit_jump < 0) return end;
            py_compile_block(compiler, body_start, body_end, py_line_indent[body_start]);
            if (py_error) return end;
            if (py_emit_instruction(compiler->code, PY_OP_JUMP, loop_start, line_no) < 0) return end;
            py_patch_instruction_arg(compiler->code, exit_jump, compiler->code->instruction_count);
            i = body_end;
            continue;
        }

        if (py_stmt_has_keyword("for")) {
            int loop_start;
            int for_iter_index;
            if (!py_parse_for_header(py_name_loop, py_saved_expr, line_no)) return end;
            body_start = i + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block", line_no);
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            if (!py_compiler_add_local(compiler, py_name_loop)) return end;
            if (!py_compile_expression_text(compiler, py_saved_expr, line_no)) return end;
            if (py_emit_instruction(compiler->code, PY_OP_GET_ITER, 0, line_no) < 0) return end;
            loop_start = compiler->code->instruction_count;
            for_iter_index = py_emit_instruction(compiler->code, PY_OP_FOR_ITER, 0, line_no);
            if (for_iter_index < 0) return end;
            if (!py_emit_name_value(compiler, PY_OP_STORE_NAME, py_name_loop, line_no)) return end;
            py_compile_block(compiler, body_start, body_end, py_line_indent[body_start]);
            if (py_error) return end;
            if (py_emit_instruction(compiler->code, PY_OP_JUMP, loop_start, line_no) < 0) return end;
            py_patch_instruction_arg(compiler->code, for_iter_index, compiler->code->instruction_count);
            i = body_end;
            continue;
        }

        if (py_stmt_has_keyword("def")) {
            if (!py_parse_def_header(py_name_def, &arg_names, &arg_count, line_no)) return end;
            body_start = i + 1;
            if (body_start >= end || py_line_indent[body_start] <= indent) {
                py_set_error("expected an indented block", line_no);
                return end;
            }
            body_end = py_find_suite_end(body_start, indent, end);
            child_code = py_compile_code_range(compiler, py_name_def, body_start, body_end, py_line_indent[body_start], 0, 0, 1, arg_names, arg_count);
            if (py_error || !child_code) return end;
            if (!py_emit_const_value(compiler, py_make_code_object(child_code), line_no)) return end;
            if (py_emit_instruction(compiler->code, PY_OP_MAKE_FUNCTION, 0, line_no) < 0) return end;
            if (!py_emit_name_value(compiler, PY_OP_STORE_NAME, py_name_def, line_no)) return end;
            i = body_end;
            continue;
        }

        if (py_stmt_has_keyword("return")) {
            if (!compiler->allow_return) {
                py_set_error("return outside function", line_no);
                return end;
            }
            if (strcmp(py_stmt, "return") == 0) {
                if (!py_emit_const_value(compiler, py_make_none(), line_no)) return end;
            } else {
                py_copy_trim_range(py_stmt, 6, strlen(py_stmt) - 1, py_saved_expr, 256);
                if (strlen(py_saved_expr) <= 0) {
                    if (!py_emit_const_value(compiler, py_make_none(), line_no)) return end;
                } else {
                    if (!py_compile_expression_text(compiler, py_saved_expr, line_no)) return end;
                }
            }
            if (py_emit_instruction(compiler->code, PY_OP_RETURN_VALUE, 0, line_no) < 0) return end;
            i++;
            continue;
        }

        if (py_compile_import_statement(compiler, line_no)) {
            if (py_error) return end;
            i++;
            continue;
        }

        if (py_stmt_has_keyword("elif") || strcmp(py_stmt, "else:") == 0) {
            py_set_error("unexpected block continuation", line_no);
            return end;
        }

        if (py_stmt_has_keyword("break") || py_stmt_has_keyword("continue") ||
            py_stmt_has_keyword("import") || py_stmt_has_keyword("class") ||
            py_stmt_has_keyword("try") || py_stmt_has_keyword("except") ||
            py_stmt_has_keyword("raise") || py_stmt_has_keyword("with") ||
            py_stmt_has_keyword("global") || py_stmt_has_keyword("nonlocal") ||
            py_stmt_has_keyword("del") || py_stmt_has_keyword("assert") ||
            py_stmt_has_keyword("from")) {
            py_set_error("unsupported statement", line_no);
            return end;
        }

        if (!py_compile_simple(compiler, line_no)) return end;
        i++;
    }
    return i;
}

PyCode* py_compile_code_range(PyCompiler* parent, char* name, int start, int end, int indent, int is_module, int single_mode, int allow_return, char** arg_names, int arg_count) {
    PyCode* code;
    PyCompiler compiler;
    int i;
    int line_no;
    code = py_alloc_code(name, arg_count, arg_names, single_mode);
    if (!code) return (PyCode*)0;

    compiler.parent = parent;
    compiler.code = code;
    compiler.is_module = is_module;
    compiler.single_mode = single_mode;
    compiler.allow_return = allow_return;
    compiler.local_count = 0;
    compiler.local_cap = 0;
    compiler.local_names = (char**)0;

    i = 0;
    while (i < arg_count) {
        if (!py_compiler_add_local(&compiler, arg_names[i])) return (PyCode*)0;
        i++;
    }

    py_collect_locals(&compiler, start, end, indent);
    if (py_error) return (PyCode*)0;
    py_compile_block(&compiler, start, end, indent);
    if (py_error) return (PyCode*)0;

    code->local_count = compiler.local_count;
    code->local_names = compiler.local_names;

    line_no = start < end ? py_line_number[end - 1] : 0;
    if (!py_emit_const_value(&compiler, py_make_none(), line_no)) return (PyCode*)0;
    if (py_emit_instruction(code, PY_OP_RETURN_VALUE, 0, line_no) < 0) return (PyCode*)0;
    return code;
}

PyObject* py_builtin_print(PyObject** args, int arg_count, int line_no) {
    int i;
    i = 0;
    while (i < arg_count) {
        if (i > 0) print(" ");
        py_display_object(args[i]);
        i++;
    }
    printchar(10);
    return py_make_none();
}

PyObject* py_builtin_len(PyObject** args, int arg_count, int line_no) {
    if (arg_count != 1) {
        py_set_error("len() takes exactly one argument", line_no);
        return py_make_none();
    }
    if (args[0]->type == PY_STRING) {
        return py_make_int(strlen(args[0]->str_value ? args[0]->str_value : ""));
    }
    if (args[0]->type == PY_LIST) {
        return py_make_int(args[0]->list_value ? args[0]->list_value->count : 0);
    }
    py_set_error("len() expects a string or list", line_no);
    return py_make_none();
}

PyObject* py_builtin_range(PyObject** args, int arg_count, int line_no) {
    int start;
    int stop;
    int step;
    int value;
    PyObject* list;
    list = py_make_list();
    if (py_error) return py_make_none();
    if (arg_count == 1) {
        if (!py_expect_int(args[0], line_no, &stop)) return py_make_none();
        start = 0;
        step = 1;
    } else if (arg_count == 2) {
        if (!py_expect_int(args[0], line_no, &start)) return py_make_none();
        if (!py_expect_int(args[1], line_no, &stop)) return py_make_none();
        step = 1;
    } else if (arg_count == 3) {
        if (!py_expect_int(args[0], line_no, &start)) return py_make_none();
        if (!py_expect_int(args[1], line_no, &stop)) return py_make_none();
        if (!py_expect_int(args[2], line_no, &step)) return py_make_none();
    } else {
        py_set_error("range() takes 1 to 3 integer arguments", line_no);
        return py_make_none();
    }
    if (step == 0) {
        py_set_error("range() step cannot be zero", line_no);
        return py_make_none();
    }
    value = start;
    if (step > 0) {
        while (value < stop && !py_error) {
            if (!py_list_append(list, py_make_int(value), line_no)) return py_make_none();
            value += step;
        }
    } else {
        while (value > stop && !py_error) {
            if (!py_list_append(list, py_make_int(value), line_no)) return py_make_none();
            value += step;
        }
    }
    return list;
}

int py_expect_string_arg(PyObject* obj, int line_no, char** out) {
    if (!obj || obj->type != PY_STRING) {
        py_set_error("expected a string", line_no);
        return 0;
    }
    *out = obj->str_value ? obj->str_value : "";
    return 1;
}

int py_int_sqrt_floor(int value) {
    int x;
    int y;
    if (value <= 0) return 0;
    x = value;
    y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + (value / x)) / 2;
    }
    return x;
}

int py_int_pow_nonneg(int base, int exp) {
    int result;
    result = 1;
    while (exp > 0) {
        result *= base;
        exp--;
    }
    return result;
}

PyObject* py_call_builtin_dispatch(int builtin_id, PyObject** args, int arg_count, int line_no) {
    int a;
    int b;
    int c;
    int d;
    int e;
    char* text;
    if (builtin_id == PY_BUILTIN_PRINT) return py_builtin_print(args, arg_count, line_no);
    if (builtin_id == PY_BUILTIN_LEN) return py_builtin_len(args, arg_count, line_no);
    if (builtin_id == PY_BUILTIN_RANGE) return py_builtin_range(args, arg_count, line_no);

    if (builtin_id == PY_BUILTIN_MATH_ABS) {
        if (arg_count != 1 || !py_expect_int(args[0], line_no, &a)) return py_make_none();
        if (a < 0) a = -a;
        return py_make_int(a);
    }
    if (builtin_id == PY_BUILTIN_MATH_SQRT) {
        if (arg_count != 1 || !py_expect_int(args[0], line_no, &a)) return py_make_none();
        if (a < 0) {
            py_set_error("sqrt() expects a non-negative integer", line_no);
            return py_make_none();
        }
        return py_make_int(py_int_sqrt_floor(a));
    }
    if (builtin_id == PY_BUILTIN_MATH_POW) {
        if (arg_count != 2 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b)) return py_make_none();
        if (b < 0) {
            py_set_error("pow() expects a non-negative exponent", line_no);
            return py_make_none();
        }
        return py_make_int(py_int_pow_nonneg(a, b));
    }
    if (builtin_id == PY_BUILTIN_MATH_MIN) {
        if (arg_count != 2 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b)) return py_make_none();
        return py_make_int(a < b ? a : b);
    }
    if (builtin_id == PY_BUILTIN_MATH_MAX) {
        if (arg_count != 2 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b)) return py_make_none();
        return py_make_int(a > b ? a : b);
    }

    if (builtin_id == PY_BUILTIN_ROVM_RGB) {
        if (arg_count != 3 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b) || !py_expect_int(args[2], line_no, &c)) return py_make_none();
        return py_make_int(((a & 255) << 16) | ((b & 255) << 8) | (c & 255));
    }
    if (builtin_id == PY_BUILTIN_ROVM_WINDOW) {
        if (arg_count != 2 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b)) return py_make_none();
        return py_make_int(app_window(a, b));
    }
    if (builtin_id == PY_BUILTIN_ROVM_SET_TITLE) {
        if (arg_count != 1 || !py_expect_string_arg(args[0], line_no, &text)) return py_make_none();
        app_set_title(text);
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_CLEAR) {
        if (arg_count != 0) {
            py_set_error("clear() takes no arguments", line_no);
            return py_make_none();
        }
        syscall(5, 0, 0, 0, 0, 0, 0);
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_REBOOT) {
        if (arg_count != 0) {
            py_set_error("reboot() takes no arguments", line_no);
            return py_make_none();
        }
        reboot();
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_FORMAT) {
        if (arg_count != 0) {
            py_set_error("format() takes no arguments", line_no);
            return py_make_none();
        }
        format();
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_FLUSH) {
        if (arg_count != 0) {
            py_set_error("flush() takes no arguments", line_no);
            return py_make_none();
        }
        flush();
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GETKEY) {
        if (arg_count != 0) {
            py_set_error("getkey() takes no arguments", line_no);
            return py_make_none();
        }
        return py_make_int(getkey());
    }
    if (builtin_id == PY_BUILTIN_ROVM_GETKEY_NOWAIT) {
        if (arg_count != 0) {
            py_set_error("getkey_nowait() takes no arguments", line_no);
            return py_make_none();
        }
        return py_make_int(getkey_nowait());
    }
    if (builtin_id == PY_BUILTIN_ROVM_KEY_DOWN) {
        if (arg_count != 1 || !py_expect_int(args[0], line_no, &a)) return py_make_none();
        return py_make_int(key_down(a));
    }
    if (builtin_id == PY_BUILTIN_ROVM_KEY_PRESSED) {
        if (arg_count != 1 || !py_expect_int(args[0], line_no, &a)) return py_make_none();
        return py_make_int(key_pressed(a));
    }
    if (builtin_id == PY_BUILTIN_ROVM_VSYNC) {
        if (arg_count != 1 || !py_expect_int(args[0], line_no, &a)) return py_make_none();
        return py_make_int(vsync(a));
    }
    if (builtin_id == PY_BUILTIN_ROVM_GETPID) {
        if (arg_count != 0) {
            py_set_error("getpid() takes no arguments", line_no);
            return py_make_none();
        }
        return py_make_int(getpid());
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_CLEAR_FRAME) {
        if (arg_count != 0) {
            py_set_error("gpu_clear_frame() takes no arguments", line_no);
            return py_make_none();
        }
        gpu_clear_frame();
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_DRAW_RECT) {
        if (arg_count != 5 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b) ||
            !py_expect_int(args[2], line_no, &c) || !py_expect_int(args[3], line_no, &d) ||
            !py_expect_int(args[4], line_no, &e)) return py_make_none();
        gpu_draw_rect(a, b, c, d, e);
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_DRAW_LINE) {
        if (arg_count != 5 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b) ||
            !py_expect_int(args[2], line_no, &c) || !py_expect_int(args[3], line_no, &d) || !py_expect_int(args[4], line_no, &e)) return py_make_none();
        gpu_draw_line(a, b, c, d, e);
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_CLS) {
        if (arg_count != 0) {
            py_set_error("gpu_cls() takes no arguments", line_no);
            return py_make_none();
        }
        gpu_cls();
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_SET_VIEW) {
        if (arg_count != 4 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b) ||
            !py_expect_int(args[2], line_no, &c) || !py_expect_int(args[3], line_no, &d)) return py_make_none();
        gpu_set_view(a, b, c, d);
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_SET_XY) {
        if (arg_count != 2 || !py_expect_int(args[0], line_no, &a) || !py_expect_int(args[1], line_no, &b)) return py_make_none();
        gpu_set_xy(a, b);
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_SET_COLOR) {
        if (arg_count != 1 || !py_expect_int(args[0], line_no, &a)) return py_make_none();
        gpu_set_color(a);
        return py_make_none();
    }
    if (builtin_id == PY_BUILTIN_ROVM_GPU_WAIT_FRAME) {
        if (arg_count != 0) {
            py_set_error("gpu_wait_frame() takes no arguments", line_no);
            return py_make_none();
        }
        return py_make_int(gpu_wait_frame());
    }

    py_set_error("unsupported builtin", line_no);
    return py_make_none();
}

PyObject* py_call_object(PyObject* callable, PyObject** args, int arg_count, int line_no) {
    PyFunction* fn;
    PyScope local_scope;
    PyObject* result;
    int i;
    if (!callable || callable->type != PY_FUNCTION || !callable->func_value) {
        py_set_error("object is not callable", line_no);
        return py_make_none();
    }
    fn = callable->func_value;
    if (fn->builtin_id != PY_BUILTIN_NONE) return py_call_builtin_dispatch(fn->builtin_id, args, arg_count, line_no);

    if (!fn->code) {
        py_set_error("invalid function object", line_no);
        return py_make_none();
    }
    if (arg_count != fn->arg_count) {
        py_set_error("wrong number of arguments", line_no);
        return py_make_none();
    }

    py_scope_init(&local_scope, (PyScope*)0);
    if (py_error) return py_make_none();
    i = 0;
    while (i < fn->arg_count) {
        py_scope_set(&local_scope, fn->arg_names[i], args[i], line_no);
        if (py_error) {
            py_scope_release(&local_scope);
            return py_make_none();
        }
        i++;
    }

    result = py_vm_run_code(fn->code, &local_scope, fn->globals ? fn->globals : &py_global_scope, 1, 0);
    py_scope_release(&local_scope);
    return result;
}
]===]

python_runtime_h3 = python_runtime_h3 .. [===[
int py_code_has_local_name(PyCode* code, char* name) {
    int i;
    if (!code || !name) return 0;
    i = 0;
    while (i < code->local_count) {
        if (code->local_names[i] && strcmp(code->local_names[i], name) == 0) return 1;
        i++;
    }
    return 0;
}

int py_frame_push(PyExecFrame* frame, PyObject* value, int line_no) {
    PyObject** new_items;
    int new_cap;
    if (!frame) return 0;
    if (frame->stack_top >= frame->stack_cap) {
        new_cap = frame->stack_cap == 0 ? 16 : frame->stack_cap * 2;
        new_items = (PyObject**)realloc(frame->stack, sizeof(PyObject*) * new_cap);
        if (!new_items) {
            py_set_error("out of memory", line_no);
            return 0;
        }
        frame->stack = new_items;
        frame->stack_cap = new_cap;
    }
    frame->stack[frame->stack_top] = value;
    frame->stack_top++;
    return 1;
}

PyObject* py_frame_pop(PyExecFrame* frame, int line_no) {
    if (!frame || frame->stack_top <= 0) {
        py_set_error("stack underflow", line_no);
        return py_make_none();
    }
    frame->stack_top--;
    return frame->stack[frame->stack_top];
}

PyObject* py_frame_peek(PyExecFrame* frame, int line_no) {
    if (!frame || frame->stack_top <= 0) {
        py_set_error("stack underflow", line_no);
        return py_make_none();
    }
    return frame->stack[frame->stack_top - 1];
}

PyObject* py_vm_load_name(PyExecFrame* frame, char* name, int line_no) {
    int slot;
    if (!frame || !name) return py_make_none();

    if (frame->locals && frame->globals && frame->locals != frame->globals && py_code_has_local_name(frame->code, name)) {
        slot = py_scope_find_local_index(frame->locals, name);
        if (slot >= 0) return frame->locals->values[slot];
        py_set_name_error("local variable referenced before assignment ", name, line_no);
        return py_make_none();
    }

    if (frame->locals) {
        slot = py_scope_find_local_index(frame->locals, name);
        if (slot >= 0) return frame->locals->values[slot];
    }

    if (frame->globals && frame->globals != frame->locals) {
        slot = py_scope_find_local_index(frame->globals, name);
        if (slot >= 0) return frame->globals->values[slot];
    }

    if (frame->globals == &py_global_scope && frame->locals != &py_global_scope) {
        slot = py_scope_find_local_index(&py_global_scope, name);
        if (slot >= 0) return py_global_scope.values[slot];
    }

    py_set_name_error("unknown variable ", name, line_no);
    return py_make_none();
}

int py_vm_store_name(PyExecFrame* frame, char* name, PyObject* value, int line_no) {
    PyScope* target;
    if (!frame || !name) return 0;
    target = frame->locals ? frame->locals : frame->globals;
    py_scope_set(target, name, value, line_no);
    return !py_error;
}

PyObject* py_vm_unary_positive(PyObject* value, int line_no) {
    if (!py_is_int_like(value)) {
        py_set_error("bad operand for unary +", line_no);
        return py_make_none();
    }
    return py_make_int(value->int_value);
}

PyObject* py_vm_unary_negative(PyObject* value, int line_no) {
    if (!py_is_int_like(value)) {
        py_set_error("bad operand for unary -", line_no);
        return py_make_none();
    }
    return py_make_int(-value->int_value);
}

PyObject* py_vm_compare(PyObject* left, int op, PyObject* right, int line_no) {
    if (op == PY_CMP_EQ) return py_make_bool(py_value_equal(left, right));
    if (op == PY_CMP_NE) return py_make_bool(!py_value_equal(left, right));
    return py_make_bool(py_compare_values(left, op, right, line_no));
}

PyObject* py_vm_binary_subscr(PyObject* target, PyObject* index_obj, int line_no) {
    int index;
    int count;
    if (!py_expect_int(index_obj, line_no, &index)) return py_make_none();
    if (target->type == PY_LIST) {
        count = target->list_value ? target->list_value->count : 0;
        if (index < 0) index += count;
        if (index < 0 || index >= count) {
            py_set_error("index out of range", line_no);
            return py_make_none();
        }
        return target->list_value->items[index];
    }
    if (target->type == PY_STRING) {
        count = strlen(target->str_value ? target->str_value : "");
        if (index < 0) index += count;
        if (index < 0 || index >= count) {
            py_set_error("index out of range", line_no);
            return py_make_none();
        }
        return py_make_string_len(target->str_value + index, 1);
    }
    py_set_error("object is not subscriptable", line_no);
    return py_make_none();
}

PyObject* py_vm_run_code(PyCode* code, PyScope* locals, PyScope* globals, int allow_return, int echo_expression) {
    PyExecFrame frame;
    PyObject* result;
    if (!code) {
        py_set_error("invalid code object", 0);
        return py_make_none();
    }

    frame.parent = (PyExecFrame*)0;
    frame.code = code;
    frame.locals = locals ? locals : globals;
    frame.globals = globals ? globals : locals;
    frame.stack = (PyObject**)0;
    frame.stack_top = 0;
    frame.stack_cap = 0;
    frame.ip = 0;
    frame.allow_return = allow_return;
    frame.echo_expression = echo_expression;

    while (!py_error && frame.ip < code->instruction_count) {
        int op;
        int arg;
        int line_no;
        op = code->instr_ops[frame.ip];
        arg = code->instr_args[frame.ip];
        line_no = code->instr_lines[frame.ip];
        frame.ip++;

        if (op == PY_OP_LOAD_CONST) {
            if (arg < 0 || arg >= code->const_count) {
                py_set_error("bad constant index", line_no);
                break;
            }
            if (!py_frame_push(&frame, code->constants[arg], line_no)) break;
            continue;
        }

        if (op == PY_OP_LOAD_NAME) {
            if (arg < 0 || arg >= code->name_count) {
                py_set_error("bad name index", line_no);
                break;
            }
            result = py_vm_load_name(&frame, code->names[arg], line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_IMPORT_NAME) {
            if (arg < 0 || arg >= code->name_count) {
                py_set_error("bad name index", line_no);
                break;
            }
            result = py_import_module(code->names[arg], line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_LOAD_ATTR) {
            PyObject* owner;
            if (arg < 0 || arg >= code->name_count) {
                py_set_error("bad name index", line_no);
                break;
            }
            owner = py_frame_pop(&frame, line_no);
            if (py_error) break;
            result = py_module_get_attr(owner, code->names[arg], line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_STORE_NAME) {
            PyObject* value;
            if (arg < 0 || arg >= code->name_count) {
                py_set_error("bad name index", line_no);
                break;
            }
            value = py_frame_pop(&frame, line_no);
            if (py_error) break;
            if (!py_vm_store_name(&frame, code->names[arg], value, line_no)) break;
            continue;
        }

        if (op == PY_OP_POP_TOP) {
            py_frame_pop(&frame, line_no);
            if (py_error) break;
            continue;
        }

        if (op == PY_OP_UNARY_POSITIVE) {
            PyObject* value;
            value = py_frame_pop(&frame, line_no);
            if (py_error) break;
            result = py_vm_unary_positive(value, line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_UNARY_NEGATIVE) {
            PyObject* value;
            value = py_frame_pop(&frame, line_no);
            if (py_error) break;
            result = py_vm_unary_negative(value, line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_UNARY_NOT) {
            PyObject* value;
            value = py_frame_pop(&frame, line_no);
            if (py_error) break;
            result = py_make_bool(!py_truthy(value));
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_BINARY_ADD || op == PY_OP_BINARY_SUB ||
            op == PY_OP_BINARY_MUL || op == PY_OP_BINARY_DIV ||
            op == PY_OP_BINARY_MOD) {
            PyObject* right;
            PyObject* left;
            right = py_frame_pop(&frame, line_no);
            if (py_error) break;
            left = py_frame_pop(&frame, line_no);
            if (py_error) break;
            if (op == PY_OP_BINARY_ADD) result = py_op_plus(left, right, line_no);
            else if (op == PY_OP_BINARY_SUB) result = py_op_minus(left, right, line_no);
            else if (op == PY_OP_BINARY_MUL) result = py_op_mul(left, right, line_no);
            else if (op == PY_OP_BINARY_DIV) result = py_op_div(left, right, line_no);
            else result = py_op_mod(left, right, line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_COMPARE_OP) {
            PyObject* right;
            PyObject* left;
            right = py_frame_pop(&frame, line_no);
            if (py_error) break;
            left = py_frame_pop(&frame, line_no);
            if (py_error) break;
            result = py_vm_compare(left, arg, right, line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_JUMP) {
            frame.ip = arg;
            continue;
        }

        if (op == PY_OP_POP_JUMP_IF_FALSE) {
            PyObject* value;
            value = py_frame_pop(&frame, line_no);
            if (py_error) break;
            if (!py_truthy(value)) {
                frame.ip = arg;
            }
            continue;
        }

        if (op == PY_OP_JUMP_IF_FALSE_OR_POP) {
            PyObject* value;
            value = py_frame_peek(&frame, line_no);
            if (py_error) break;
            if (!py_truthy(value)) {
                frame.ip = arg;
            } else {
                py_frame_pop(&frame, line_no);
                if (py_error) break;
            }
            continue;
        }

        if (op == PY_OP_JUMP_IF_TRUE_OR_POP) {
            PyObject* value;
            value = py_frame_peek(&frame, line_no);
            if (py_error) break;
            if (py_truthy(value)) {
                frame.ip = arg;
            } else {
                py_frame_pop(&frame, line_no);
                if (py_error) break;
            }
            continue;
        }
]===]

python_runtime_h3 = python_runtime_h3 .. [===[
        if (op == PY_OP_BUILD_LIST) {
            PyObject* list;
            PyObject** items;
            int i;
            items = (PyObject**)0;
            if (arg < 0) {
                py_set_error("bad list size", line_no);
                break;
            }
            if (arg > 0) {
                items = (PyObject**)malloc(sizeof(PyObject*) * arg);
                if (!items) {
                    py_set_error("out of memory", line_no);
                    break;
                }
            }
            i = arg - 1;
            while (i >= 0) {
                items[i] = py_frame_pop(&frame, line_no);
                if (py_error) break;
                i--;
            }
            if (py_error) {
                if (items) free(items);
                break;
            }
            list = py_make_list();
            if (py_error) {
                if (items) free(items);
                break;
            }
            i = 0;
            while (i < arg && !py_error) {
                py_list_append(list, items[i], line_no);
                i++;
            }
            if (items) free(items);
            if (py_error) break;
            if (!py_frame_push(&frame, list, line_no)) break;
            continue;
        }

        if (op == PY_OP_BINARY_SUBSCR) {
            PyObject* index_obj;
            PyObject* target;
            index_obj = py_frame_pop(&frame, line_no);
            if (py_error) break;
            target = py_frame_pop(&frame, line_no);
            if (py_error) break;
            result = py_vm_binary_subscr(target, index_obj, line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_CALL) {
            PyObject* callable;
            PyObject** args;
            int i;
            args = (PyObject**)0;
            if (arg < 0) {
                py_set_error("bad call arity", line_no);
                break;
            }
            if (arg > 0) {
                args = (PyObject**)malloc(sizeof(PyObject*) * arg);
                if (!args) {
                    py_set_error("out of memory", line_no);
                    break;
                }
            }
            i = arg - 1;
            while (i >= 0) {
                args[i] = py_frame_pop(&frame, line_no);
                if (py_error) break;
                i--;
            }
            if (py_error) {
                if (args) free(args);
                break;
            }
            callable = py_frame_pop(&frame, line_no);
            if (py_error) {
                if (args) free(args);
                break;
            }
            result = py_call_object(callable, args, arg, line_no);
            if (args) free(args);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_RETURN_VALUE) {
            if (frame.stack_top > 0) result = py_frame_pop(&frame, line_no);
            else result = py_make_none();
            if (frame.stack) free(frame.stack);
            return result;
        }

        if (op == PY_OP_MAKE_FUNCTION) {
            PyObject* code_obj;
            if (!frame.globals) {
                py_set_error("missing globals scope", line_no);
                break;
            }
            code_obj = py_frame_pop(&frame, line_no);
            if (py_error) break;
            if (!code_obj || code_obj->type != PY_CODE || !code_obj->code_value) {
                py_set_error("expected code object", line_no);
                break;
            }
            result = py_make_user_function(code_obj->code_value, frame.globals);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_GET_ITER) {
            PyObject* source;
            source = py_frame_pop(&frame, line_no);
            if (py_error) break;
            result = py_make_iter_object(source, line_no);
            if (py_error) break;
            if (!py_frame_push(&frame, result, line_no)) break;
            continue;
        }

        if (op == PY_OP_FOR_ITER) {
            PyObject* iter_obj;
            int has_item;
            iter_obj = py_frame_peek(&frame, line_no);
            if (py_error) break;
            result = py_iter_next(iter_obj, line_no, &has_item);
            if (py_error) break;
            if (!has_item) {
                py_frame_pop(&frame, line_no);
                if (py_error) break;
                frame.ip = arg;
            } else {
                if (!py_frame_push(&frame, result, line_no)) break;
            }
            continue;
        }

        py_set_error("unsupported opcode", line_no);
        break;
    }

    if (frame.stack) free(frame.stack);
    if (py_error) return py_make_none();
    return py_make_none();
}
]===]

return python_runtime_h3
