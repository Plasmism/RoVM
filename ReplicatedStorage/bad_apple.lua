return [[

#include "rovm.h"
#include "stdio.h"

#define CHUNK_SIZE  8192
#define WIDTH       512
#define HEIGHT      384
#define FPS         12

static char buffer[CHUNK_SIZE];

int main(void)
{
    FILE *f;
    int n;

    if (app_window(WIDTH, HEIGHT) < 0) {
        print("bad_apple: app_window failed\n");
        exit(1);
    }
    app_set_title("Bad Apple");

    f = fopen("/usr/src/badapple.bin", "r");
    if (!f) {
        print("bad_apple: cannot open /usr/src/badapple.bin\n");
        exit(1);
    }

    gpu_set_view(0, 0, WIDTH, HEIGHT);
    gpu_set_xy(0, 0);
    gpu_set_color(0);

    for (;;) {
        n = (int)fread(buffer, 1, CHUNK_SIZE, f);
        if (n <= 0)
            break;
        gpu_play_chunk(buffer, n, FPS);
    }

    gpu_draw_rle(WIDTH * HEIGHT);
    flush();

    fclose(f);
    exit(0);
    return 0;
}


]]