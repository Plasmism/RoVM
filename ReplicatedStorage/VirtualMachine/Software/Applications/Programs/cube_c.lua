local cube_c = [===[
#include <rovm.h>
#include <math.h>

#define SCREEN_W 1280
#define SCREEN_H 720

int main() {
    app_window(SCREEN_W, SCREEN_H);
    app_set_title("3D Cube");

    int points[24]; // 8 points * 3 coords
    points[0] = -100; points[1] = -100; points[2] = -100;
    points[3] =  100; points[4] = -100; points[5] = -100;
    points[6] =  100; points[7] =  100; points[8] = -100;
    points[9] = -100; points[10] =  100; points[11] = -100;
    points[12] = -100; points[13] = -100; points[14] =  100;
    points[15] =  100; points[16] = -100; points[17] =  100;
    points[18] =  100; points[19] =  100; points[20] =  100;
    points[21] = -100; points[22] =  100; points[23] =  100;

    int edges[24]; // 12 edges * 2 indices
    edges[0] = 0; edges[1] = 1;
    edges[2] = 1; edges[3] = 2;
    edges[4] = 2; edges[5] = 3;
    edges[6] = 3; edges[7] = 0;
    edges[8] = 4; edges[9] = 5;
    edges[10] = 5; edges[11] = 6;
    edges[12] = 6; edges[13] = 7;
    edges[14] = 7; edges[15] = 4;
    edges[16] = 0; edges[17] = 4;
    edges[18] = 1; edges[19] = 5;
    edges[20] = 2; edges[21] = 6;
    edges[22] = 3; edges[23] = 7;

    int angle = 0;
    while (1) {
        gpu_cls();
        int s = fix_sin(angle);
        int c = fix_cos(angle);
        
        int proj_x[8];
        int proj_y[8];
        for (int i = 0; i < 8; i++) {
            int x = points[i*3 + 0];
            int y = points[i*3 + 1];
            int z = points[i*3 + 2];

            // Rotate Y
            int nx = fix_to_int(fix_mul(fix_from_int(x), c) - fix_mul(fix_from_int(z), s));
            int nz = fix_to_int(fix_mul(fix_from_int(x), s) + fix_mul(fix_from_int(z), c));
            x = nx; z = nz;

            // Rotate X
            int ny = fix_to_int(fix_mul(fix_from_int(y), c) - fix_mul(fix_from_int(z), s));
            nz = fix_to_int(fix_mul(fix_from_int(y), s) + fix_mul(fix_from_int(z), c));
            y = ny; z = nz;

            // Project
            int pz = z + 400;
            proj_x[i] = SCREEN_W/2 + (x * 400) / pz;
            proj_y[i] = SCREEN_H/2 + (y * 400) / pz;
        }

        for (int i = 0; i < 12; i++) {
            int e0 = edges[i*2 + 0];
            int e1 = edges[i*2 + 1];
            gpu_draw_line(proj_x[e0], proj_y[e0], proj_x[e1], proj_y[e1], GREEN);
        }

        flush();
        vsync(60);
        angle += 1000;
    }
    return 0;
}
]===]

return cube_c