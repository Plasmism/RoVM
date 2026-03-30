local welcome_c = [===[
/*
================================================================================
   Welcome to the BloxOS C development environment!
================================================================================

   This is a complete, working C development environment running inside Roblox!
   You are looking at `welcome.c`, a simple program to get you started.

   -- HOW TO NAVIGATE THE UI --
   * Type 'ls' to list files in the current directory.
   * Type 'cd /path' to change directories.
   * Type 'cat filename' to print a file's contents.
   * Type 'edit filename' to open the built-in text editor.
     -> Inside the editor: Press 'I' to enter Insert mode.
     -> Press 'Ctrl + C' to return to Command mode.
     -> In Command mode, type ':wq' and press ENTER to save and quit.

   -- HOW TO RUN PROGRAMS --
   This OS comes with a built-in C compiler. To run this exact file,
   type the following command in the terminal:

       cc welcome.c
       run welcome.rov

   -- COOL DEMOS --
   We have several pre-compiled demos you can run by just typing their names:
   * 'neofetch'  -> Displays system information
   * 'benchmark' -> Runs a CPU and Memory stress test
   * 'calculator' -> Integer calculator REPL
   * 'python'    -> Python REPL (also available as 'py')
   * 'snake'     -> Classic arcade snake
   * 'tetris'    -> Classic block game
   * 'pong'      -> Classic arcade Pong
   * 'space_defenders' -> Classic alien shooter
   * 'doom'      -> Classic raycaster shooter
   * 'cube'      -> Spinning 3d wireframe cube
   * 'bad_apple' -> Plays the Bad Apple music video

================================================================================
*/

#include <rovm.h>
#include <string.h>

int main() {
    // syscall(8) sets the foreground text color (R, G, B)
    syscall(8, RGB(50, 255, 50), 0, 0, 0, 0, 0);
    print("\nSUCCESS: You compiled and ran your first ROVM C program!\n\n");
    
    syscall(8, RGB(255, 255, 255), 0, 0, 0, 0, 0); // Reset to white (always remember to do this!)
    print("This VM supports many standard C features:\n");
    print(" - Functions, loops, arrays, and pointers\n");
    print(" - <string.h> (strcpy, strlen, strcmp, etc.)\n");
    print(" - <stdlib.h> (malloc, free, rand, atoi)\n");
    print(" - <math.h> (sin, cos, atan2, sqrt, fixed-point)\n\n");
    
    print("It also has hardware-accelerated graphics! Check out '/usr/src/doom.c'\n");
    print("to see how to use `gpu_draw_rect` to build a 3D engine.\n\n");
    
    return 0;
}
]===]

return welcome_c