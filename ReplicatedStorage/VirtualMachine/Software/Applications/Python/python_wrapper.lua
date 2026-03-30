local python_wrapper_c = [===[

int main(int argc, char** argv, char** envp) {
    return py_main(argc, argv, envp);
}
]===]

return python_wrapper_c