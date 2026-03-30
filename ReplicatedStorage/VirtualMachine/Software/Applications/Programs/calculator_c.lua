local calculator_c = [===[
#include <rovm.h>
#include <string.h>
#include <ctype.h>

char calc_line[128];
int calc_vals[64];
int calc_ops[64];
int calc_val_top;
int calc_op_top;
int calc_err;
int calc_value;

int calc_prec(int op) {
    if (op == '+' || op == '-') return 1;
    if (op == '*' || op == '/' || op == '%') return 2;
    return 0;
}

void calc_reduce_once() {
    int op;
    int rhs;
    int lhs;
    int value;
    if (calc_op_top <= 0 || calc_val_top < 2) {
        calc_err = 1;
        return;
    }
    calc_op_top--;
    op = calc_ops[calc_op_top];
    calc_val_top--;
    rhs = calc_vals[calc_val_top];
    calc_val_top--;
    lhs = calc_vals[calc_val_top];
    if ((op == '/' || op == '%') && rhs == 0) {
        calc_err = 2;
        return;
    }
    if (op == '+') value = lhs + rhs;
    else if (op == '-') value = lhs - rhs;
    else if (op == '*') value = lhs * rhs;
    else if (op == '/') value = lhs / rhs;
    else if (op == '%') value = lhs % rhs;
    else {
        calc_err = 1;
        return;
    }
    calc_vals[calc_val_top] = value;
    calc_val_top++;
}

int eval_expr() {
    int i = 0;
    int expect_value = 1;
    int c;
    int sign;
    int value;
    calc_err = 0;
    calc_value = 0;
    calc_val_top = 0;
    calc_op_top = 0;

    while (calc_line[i] != 0 && !calc_err) {
        c = calc_line[i];

        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            i++;
            continue;
        }

        if (expect_value) {
            if (c == '(') {
                calc_ops[calc_op_top] = c;
                calc_op_top++;
                i++;
                continue;
            }

            if (c == '+' || c == '-') {
                sign = 1;
                while (calc_line[i] == '+' || calc_line[i] == '-') {
                    if (calc_line[i] == '-') sign = -sign;
                    i++;
                    while (calc_line[i] == ' ' || calc_line[i] == '\t' || calc_line[i] == '\r') i++;
                }
                if (calc_line[i] == '(') {
                    calc_vals[calc_val_top] = 0;
                    calc_val_top++;
                    if (sign > 0) calc_ops[calc_op_top] = '+';
                    else calc_ops[calc_op_top] = '-';
                    calc_op_top++;
                    continue;
                }
                if (!isdigit(calc_line[i])) {
                    calc_err = 1;
                    break;
                }
                value = 0;
                while (isdigit(calc_line[i])) {
                    value = value * 10 + (calc_line[i] - '0');
                    i++;
                }
                calc_vals[calc_val_top] = value * sign;
                calc_val_top++;
                expect_value = 0;
                continue;
            }

            if (isdigit(c)) {
                value = 0;
                while (isdigit(calc_line[i])) {
                    value = value * 10 + (calc_line[i] - '0');
                    i++;
                }
                calc_vals[calc_val_top] = value;
                calc_val_top++;
                expect_value = 0;
                continue;
            }

            calc_err = 1;
            break;
        }

        if (c == ')') {
            while (calc_op_top > 0 && calc_ops[calc_op_top - 1] != '(' && !calc_err) {
                calc_reduce_once();
            }
            if (calc_err) break;
            if (calc_op_top <= 0 || calc_ops[calc_op_top - 1] != '(') {
                calc_err = 1;
                break;
            }
            calc_op_top--;
            i++;
            continue;
        }

        if (c == '+' || c == '-' || c == '*' || c == '/' || c == '%') {
            while (calc_op_top > 0 &&
                   calc_ops[calc_op_top - 1] != '(' &&
                   calc_prec(calc_ops[calc_op_top - 1]) >= calc_prec(c) &&
                   !calc_err) {
                calc_reduce_once();
            }
            if (calc_err) break;
            calc_ops[calc_op_top] = c;
            calc_op_top++;
            i++;
            expect_value = 1;
            continue;
        }

        calc_err = 1;
    }

    if (!calc_err && expect_value) calc_err = 1;
    while (calc_op_top > 0 && !calc_err) {
        if (calc_ops[calc_op_top - 1] == '(') {
            calc_err = 1;
            break;
        }
        calc_reduce_once();
    }
    if (!calc_err) {
        if (calc_val_top != 1) calc_err = 1;
        else calc_value = calc_vals[0];
    }
    return calc_err;
}

int read_line() {
    int pos = 0;
    while (pos < 127) {
        int c = getkey();
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
            calc_line[pos] = (char)c;
            pos++;
            printchar(c);
        }
    }
    calc_line[pos] = 0;
    return pos;
}

int main() {
    int len;
    print("ROVM Calculator\n");
    print("Type integer expressions with + - * / % and parentheses.\n");
    print("Type 'help' for tips, 'clear' to clear, 'quit' to exit.\n\n");
    while (1) {
        print("calc> ");
        len = read_line();
        if (len < 0) {
            printchar(10);
            return 0;
        }
        if (len == 0) continue;
        if (strcmp(calc_line, "quit") == 0 || strcmp(calc_line, "exit") == 0) return 0;
        if (strcmp(calc_line, "help") == 0) {
            print("Examples:\n");
            print("  (2 + 3) * 4\n");
            print("  18 / 3 + 7\n");
            print("  9 % 4\n\n");
            continue;
        }
        if (strcmp(calc_line, "clear") == 0) {
            syscall(5, 0, 0, 0, 0, 0, 0);
            continue;
        }
        if (eval_expr() == 0) {
            print("= ");
            printint(calc_value);
            printchar(10);
        } else if (calc_err == 2) {
            print("error: division by zero\n");
        } else {
            print("error: invalid expression\n");
        }
    }
    return 0;
}
]===]

return calculator_c