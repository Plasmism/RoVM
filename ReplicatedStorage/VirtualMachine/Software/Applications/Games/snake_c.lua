local snake_c = [===[
#include <rovm.h>
#include <stdlib.h>

#define gpu_draw_rect gpu_batch_rect

#define GRID_W 20
#define GRID_H 20
#define CELL 24
#define PAD 20
#define HUD_H 80
#define SCREEN_W (GRID_W * CELL + PAD * 2)
#define SCREEN_H (GRID_H * CELL + PAD * 2 + HUD_H)
#define MAX_SNAKE 256
#define STEP_FRAMES 5

int snake_x[MAX_SNAKE];
int snake_y[MAX_SNAKE];
int snake_len;
int snake_dir;
int snake_next_dir;
int food_x;
int food_y;
int score;
int best_score;
int game_over;
int paused;
int tick_counter;

void set_title_running() { app_set_title("Snake"); }
void set_title_paused() { app_set_title("Snake"); }
void set_title_game_over() { app_set_title("Snake"); }

int snake_contains(int x, int y) {
    int i = 0;
    while (i < snake_len) {
        if (snake_x[i] == x && snake_y[i] == y) return 1;
        i++;
    }
    return 0;
}

void spawn_food() {
    int tries = 0;
    while (tries < 512) {
        int x = rand() % GRID_W;
        int y = rand() % GRID_H;
        if (!snake_contains(x, y)) {
            food_x = x;
            food_y = y;
            return;
        }
        tries++;
    }
    food_x = 0;
    food_y = 0;
}

void reset_game() {
    snake_len = 4;
    snake_x[0] = GRID_W / 2;
    snake_y[0] = GRID_H / 2;
    snake_x[1] = snake_x[0] - 1;
    snake_y[1] = snake_y[0];
    snake_x[2] = snake_x[1] - 1;
    snake_y[2] = snake_y[1];
    snake_x[3] = snake_x[2] - 1;
    snake_y[3] = snake_y[2];
    snake_dir = 1;
    snake_next_dir = 1;
    score = 0;
    game_over = 0;
    paused = 0;
    tick_counter = 0;
    spawn_food();
    set_title_running();
}

void draw_cell(int gx, int gy, int color) {
    int px = PAD + gx * CELL;
    int py = PAD + gy * CELL + HUD_H;
    gpu_draw_rect(px + 2, py + 2, CELL - 4, CELL - 4, color);
}

void draw_frame() {
    int i;
    gpu_batch_begin();
    gpu_draw_rect(0, 0, SCREEN_W, SCREEN_H, RGB(10, 12, 14));
    gpu_draw_rect(PAD - 4, PAD + HUD_H - 4, GRID_W * CELL + 8, GRID_H * CELL + 8, RGB(60, 72, 82));
    gpu_draw_rect(PAD, PAD + HUD_H, GRID_W * CELL, GRID_H * CELL, RGB(18, 24, 28));
    for (i = 0; i < snake_len; i++) {
        int color = (i == 0) ? RGB(140, 255, 140) : RGB(55, 190, 75);
        draw_cell(snake_x[i], snake_y[i], color);
    }
    draw_cell(food_x, food_y, RGB(255, 90, 90));
    if (paused || game_over) {
        gpu_draw_rect(PAD + 36, PAD + HUD_H + 180, GRID_W * CELL - 72, 92, RGB(24, 26, 30));
        gpu_draw_rect(PAD + 44, PAD + HUD_H + 188, GRID_W * CELL - 88, 76, paused ? RGB(60, 110, 160) : RGB(150, 55, 55));
    }
    gpu_batch_flush();
    flush();
}

void handle_input() {
    if (key_pressed(113)) exit(0);
    if (key_pressed(KEY_SPACE)) {
        if (game_over) reset_game();
        else {
            paused = !paused;
            if (paused) set_title_paused();
            else set_title_running();
        }
    }
    if (game_over || paused) return;
    if ((key_pressed(119) || key_pressed(KEY_UP)) && snake_dir != 2) snake_next_dir = 0;
    else if ((key_pressed(100) || key_pressed(KEY_RIGHT)) && snake_dir != 3) snake_next_dir = 1;
    else if ((key_pressed(115) || key_pressed(KEY_DOWN)) && snake_dir != 0) snake_next_dir = 2;
    else if ((key_pressed(97) || key_pressed(KEY_LEFT)) && snake_dir != 1) snake_next_dir = 3;
}

void advance_snake() {
    int nx;
    int ny;
    int i;
    int grow = 0;
    if (game_over || paused) return;
    tick_counter++;
    if (tick_counter < STEP_FRAMES) return;
    tick_counter = 0;
    snake_dir = snake_next_dir;
    nx = snake_x[0];
    ny = snake_y[0];
    if (snake_dir == 0) ny--;
    else if (snake_dir == 1) nx++;
    else if (snake_dir == 2) ny++;
    else nx--;
    if (nx < 0 || nx >= GRID_W || ny < 0 || ny >= GRID_H) {
        game_over = 1;
        if (score > best_score) best_score = score;
        set_title_game_over();
        return;
    }
    if (nx == food_x && ny == food_y) grow = 1;
    i = 0;
    while (i < snake_len - (grow ? 0 : 1)) {
        if (snake_x[i] == nx && snake_y[i] == ny) {
            game_over = 1;
            if (score > best_score) best_score = score;
            set_title_game_over();
            return;
        }
        i++;
    }
    if (grow && snake_len < MAX_SNAKE) snake_len++;
    i = snake_len - 1;
    while (i > 0) {
        snake_x[i] = snake_x[i - 1];
        snake_y[i] = snake_y[i - 1];
        i--;
    }
    snake_x[0] = nx;
    snake_y[0] = ny;
    if (grow) {
        score++;
        if (score > best_score) best_score = score;
        spawn_food();
    }
}

int main() {
    app_window(SCREEN_W, SCREEN_H);
    srand(syscall(73, 6, 0, 0, 0, 0, 0));
    reset_game();
    while (1) {
        handle_input();
        advance_snake();
        draw_frame();
        vsync(30);
    }
    return 0;
}
]===]

return snake_c