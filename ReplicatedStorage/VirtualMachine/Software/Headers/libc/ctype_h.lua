local ctype_h = [[
#ifndef CTYPE_H
#define CTYPE_H
int isdigit(int c) { return c >= 48 && c <= 57; }
int isxdigit(int c) { return (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102); }
int isalpha(int c) { return (c >= 65 && c <= 90) || (c >= 97 && c <= 122); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isspace(int c) { return c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12; }
int isprint(int c) { return c >= 32 && c <= 126; }
int isupper(int c) { return c >= 65 && c <= 90; }
int islower(int c) { return c >= 97 && c <= 122; }
int toupper(int c) { return (c >= 97 && c <= 122) ? c - 32 : c; }
int tolower(int c) { return (c >= 65 && c <= 90) ? c + 32 : c; }
#endif
]]
return ctype_h