local space_defenders_c = [===[
#include <rovm.h>
#include <stdlib.h>

#define gpu_draw_rect gpu_batch_rect

#define SCREEN_W 820
#define SCREEN_H 620
#define PLAYER_W 56
#define PLAYER_H 18
#define PLAYER_SPEED 7
#define PLAYER_Y (SCREEN_H - 58)
#define PLAYER_COOLDOWN 10
#define SHOT_W 4
#define SHOT_H 14
#define SHOT_SPEED 9
#define ENEMY_BULLETS 3
#define ENEMY_SHOT_W 4
#define ENEMY_SHOT_H 12
#define ENEMY_SHOT_SPEED 7
#define ALIEN_COLS 8
#define ALIEN_ROWS 4
#define ALIEN_TOTAL (ALIEN_COLS * ALIEN_ROWS)
#define ALIEN_W 34
#define ALIEN_H 18
#define ALIEN_GAP_X 16
#define ALIEN_GAP_Y 14
#define ALIEN_START_X 106
#define ALIEN_START_Y 92
#define ALIEN_EDGE 44
#define ALIEN_STEP_X 10
#define ALIEN_STEP_Y 18
#define HUD_H 54
#define ALIEN_ROW_MASK ((1 << ALIEN_COLS) - 1)

int player_x;
int player_lives;
int player_cooldown;
int player_shot_active;
int player_shot_x;
int player_shot_y;
int enemy_shot_active[ENEMY_BULLETS];
int enemy_shot_x[ENEMY_BULLETS];
int enemy_shot_y[ENEMY_BULLETS];
int alien_mask[ALIEN_ROWS];
int alien_origin_x;
int alien_origin_y;
int alien_dir;
int alien_move_tick;
int alien_fire_tick;
int alien_alive_count;
int score;
int wave;
int game_state;

int clamp_int(int value, int low, int high) {
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

void set_running_title() {
    app_set_title("Space Defenders");
}

void set_game_over_title() {
    app_set_title("Space Defenders");
}

void clear_enemy_shots() {
    int i = 0;
    while (i < ENEMY_BULLETS) {
        enemy_shot_active[i] = 0;
        enemy_shot_x[i] = 0;
        enemy_shot_y[i] = 0;
        i++;
    }
}

void seed_wave() {
    int i = 0;
    alien_origin_x = ALIEN_START_X;
    alien_origin_y = ALIEN_START_Y;
    alien_dir = 1;
    alien_move_tick = 18;
    alien_fire_tick = 28;
    alien_alive_count = ALIEN_TOTAL;
    while (i < ALIEN_ROWS) {
        alien_mask[i] = ALIEN_ROW_MASK;
        i++;
    }
    clear_enemy_shots();
    player_shot_active = 0;
    player_cooldown = 0;
    player_x = SCREEN_W / 2 - PLAYER_W / 2;
}

void reset_game() {
    player_lives = 3;
    player_cooldown = 0;
    score = 0;
    wave = 1;
    game_state = 0;
    set_running_title();
    seed_wave();
}

int alien_left_edge() {
    int row = 0;
    int col;
    int bit;
    while (row < ALIEN_ROWS) {
        col = 0;
        while (col < ALIEN_COLS) {
            bit = 1 << col;
            if (alien_mask[row] & bit) return alien_origin_x + col * (ALIEN_W + ALIEN_GAP_X);
            col++;
        }
        row++;
    }
    return alien_origin_x;
}

int alien_right_edge() {
    int row = 0;
    int col;
    int bit;
    while (row < ALIEN_ROWS) {
        col = ALIEN_COLS - 1;
        while (col >= 0) {
            bit = 1 << col;
            if (alien_mask[row] & bit) return alien_origin_x + col * (ALIEN_W + ALIEN_GAP_X) + ALIEN_W;
            col--;
        }
        row++;
    }
    return alien_origin_x + ALIEN_W;
}

int alien_bottom_edge() {
    int row = ALIEN_ROWS - 1;
    int col;
    int bit;
    while (row >= 0) {
        col = 0;
        while (col < ALIEN_COLS) {
            bit = 1 << col;
            if (alien_mask[row] & bit) return alien_origin_y + row * (ALIEN_H + ALIEN_GAP_Y) + ALIEN_H;
            col++;
        }
        row--;
    }
    return alien_origin_y;
}

void respawn_player() {
    player_x = SCREEN_W / 2 - PLAYER_W / 2;
    player_shot_active = 0;
    clear_enemy_shots();
    player_cooldown = PLAYER_COOLDOWN;
}

void lose_life() {
    player_lives--;
    if (player_lives <= 0) {
        game_state = 1;
        set_game_over_title();
        clear_enemy_shots();
        player_shot_active = 0;
        return;
    }
    respawn_player();
}

void move_player() {
    if (key_down(97) || key_down(KEY_LEFT)) player_x -= PLAYER_SPEED;
    if (key_down(100) || key_down(KEY_RIGHT)) player_x += PLAYER_SPEED;
    player_x = clamp_int(player_x, 24, SCREEN_W - 24 - PLAYER_W);
    if (player_cooldown > 0) player_cooldown--;
}

void fire_player_shot() {
    if (player_shot_active) return;
    if (player_cooldown > 0) return;
    player_shot_active = 1;
    player_shot_x = player_x + PLAYER_W / 2 - SHOT_W / 2;
    player_shot_y = PLAYER_Y - SHOT_H;
    player_cooldown = PLAYER_COOLDOWN;
}

void advance_wave() {
    wave++;
    if (wave > 9) wave = 9;
    seed_wave();
}

void update_player_shot() {
    int row;
    int col;
    int ax;
    int ay;
    int i;
    int old_y;
    int sweep_y;
    int sweep_h;
    int shot_left;
    int shot_right;
    int shot_top;
    int shot_bottom;
    int enemy_left;
    int enemy_right;
    int enemy_top;
    int enemy_bottom;
    int bit;

    if (!player_shot_active) return;
    old_y = player_shot_y;
    player_shot_y -= SHOT_SPEED;
    if (player_shot_y + SHOT_H < HUD_H) {
        player_shot_active = 0;
        return;
    }
    sweep_y = player_shot_y;
    sweep_h = (old_y - player_shot_y) + SHOT_H;

    i = 0;
    while (i < ENEMY_BULLETS) {
        if (enemy_shot_active[i]) {
            shot_left = player_shot_x - 1;
            shot_right = shot_left + SHOT_W + 2;
            shot_top = sweep_y;
            shot_bottom = shot_top + sweep_h;
            enemy_left = enemy_shot_x[i];
            enemy_right = enemy_left + ENEMY_SHOT_W;
            enemy_top = enemy_shot_y[i];
            enemy_bottom = enemy_top + ENEMY_SHOT_H;
            if (shot_right > enemy_left && enemy_right > shot_left &&
                shot_bottom > enemy_top && enemy_bottom > shot_top) {
                enemy_shot_active[i] = 0;
                player_shot_active = 0;
                return;
            }
        }
        i++;
    }

    row = 0;
    while (row < ALIEN_ROWS) {
        col = 0;
        while (col < ALIEN_COLS) {
            bit = 1 << col;
            if (alien_mask[row] & bit) {
                ax = alien_origin_x + col * (ALIEN_W + ALIEN_GAP_X);
                ay = alien_origin_y + row * (ALIEN_H + ALIEN_GAP_Y);
                shot_left = player_shot_x - 2;
                shot_right = shot_left + SHOT_W + 4;
                shot_top = sweep_y;
                shot_bottom = shot_top + sweep_h;
                enemy_left = ax - 2;
                enemy_right = enemy_left + ALIEN_W + 4;
                enemy_top = ay - 2;
                enemy_bottom = enemy_top + ALIEN_H + 4;
                if (shot_right > enemy_left && enemy_right > shot_left &&
                    shot_bottom > enemy_top && enemy_bottom > shot_top) {
                    alien_mask[row] = alien_mask[row] & (ALIEN_ROW_MASK ^ bit);
                    alien_alive_count--;
                    score += (ALIEN_ROWS - row) * 10;
                    player_shot_active = 0;
                    if (alien_alive_count <= 0) advance_wave();
                    return;
                }
            }
            col++;
        }
        row++;
    }
}

void spawn_enemy_shot() {
    int slot = 0;
    int pick = rand() % ALIEN_COLS;
    int tries = 0;
    int col;
    int row;
    int bit;

    while (slot < ENEMY_BULLETS && enemy_shot_active[slot]) slot++;
    if (slot >= ENEMY_BULLETS) return;

    while (tries < ALIEN_COLS) {
        col = (pick + tries) % ALIEN_COLS;
        row = ALIEN_ROWS - 1;
        while (row >= 0) {
            bit = 1 << col;
            if (alien_mask[row] & bit) {
                enemy_shot_active[slot] = 1;
                enemy_shot_x[slot] = alien_origin_x + col * (ALIEN_W + ALIEN_GAP_X) + ALIEN_W / 2 - ENEMY_SHOT_W / 2;
                enemy_shot_y[slot] = alien_origin_y + row * (ALIEN_H + ALIEN_GAP_Y) + ALIEN_H;
                return;
            }
            row--;
        }
        tries++;
    }
}

void update_enemy_shots() {
    int i = 0;
    int shot_left;
    int shot_right;
    int shot_top;
    int shot_bottom;
    int player_left;
    int player_right;
    int player_top;
    int player_bottom;
    while (i < ENEMY_BULLETS) {
        if (enemy_shot_active[i]) {
            enemy_shot_y[i] += ENEMY_SHOT_SPEED + wave / 4;
            if (enemy_shot_y[i] > SCREEN_H) {
                enemy_shot_active[i] = 0;
            } else {
                shot_left = enemy_shot_x[i];
                shot_right = shot_left + ENEMY_SHOT_W;
                shot_top = enemy_shot_y[i];
                shot_bottom = shot_top + ENEMY_SHOT_H;
                player_left = player_x;
                player_right = player_left + PLAYER_W;
                player_top = PLAYER_Y;
                player_bottom = player_top + PLAYER_H + 10;
                if (shot_right > player_left && player_right > shot_left &&
                    shot_bottom > player_top && player_bottom > shot_top) {
                    enemy_shot_active[i] = 0;
                    lose_life();
                    if (game_state != 0) return;
                }
            }
        }
        i++;
    }
}

void update_aliens() {
    int move_delay;

    if (alien_alive_count <= 0) return;

    move_delay = 24 - wave - (ALIEN_TOTAL - alien_alive_count) / 2;
    if (move_delay < 6) move_delay = 6;

    alien_move_tick--;
    if (alien_move_tick <= 0) {
        alien_move_tick = move_delay;
        if (alien_dir > 0 && alien_right_edge() + ALIEN_STEP_X >= SCREEN_W - ALIEN_EDGE) {
            alien_dir = -1;
            alien_origin_y += ALIEN_STEP_Y;
        } else if (alien_dir < 0 && alien_left_edge() - ALIEN_STEP_X <= ALIEN_EDGE) {
            alien_dir = 1;
            alien_origin_y += ALIEN_STEP_Y;
        } else {
            alien_origin_x += alien_dir * ALIEN_STEP_X;
        }
    }

    alien_fire_tick--;
    if (alien_fire_tick <= 0) {
        spawn_enemy_shot();
        alien_fire_tick = 36 - wave * 2;
        if (alien_fire_tick < 10) alien_fire_tick = 10;
    }

    if (alien_bottom_edge() >= PLAYER_Y - 10) {
        game_state = 1;
        set_game_over_title();
        clear_enemy_shots();
        player_shot_active = 0;
    }
}

void draw_player_ship(int x, int y, int color) {
    gpu_draw_rect(x + 22, y, 12, 4, color);
    gpu_draw_rect(x + 16, y + 4, 24, 6, color);
    gpu_draw_rect(x + 10, y + 10, 36, 6, color);
    gpu_draw_rect(x, y + 16, 56, 6, color);
}

void draw_alien(int x, int y, int row) {
    int color;
    if (row == 0) color = RGB(255, 130, 130);
    else if (row == 1) color = RGB(255, 205, 95);
    else if (row == 2) color = RGB(150, 225, 120);
    else color = RGB(120, 210, 255);

    gpu_draw_rect(x + 6, y, 22, 4, color);
    gpu_draw_rect(x + 2, y + 4, 30, 4, color);
    gpu_draw_rect(x, y + 8, 34, 4, color);
    gpu_draw_rect(x + 6, y + 12, 8, 6, color);
    gpu_draw_rect(x + 20, y + 12, 8, 6, color);
}

void draw_hud() {
    int i = 0;
    int score_blocks;
    gpu_draw_rect(0, 0, SCREEN_W, HUD_H, RGB(16, 20, 28));
    gpu_draw_rect(0, HUD_H - 4, SCREEN_W, 4, RGB(60, 180, 96));

    while (i < player_lives) {
        draw_player_ship(18 + i * 66, 12, RGB(120, 230, 120));
        i++;
    }

    score_blocks = score / 10;
    if (score_blocks > 20) score_blocks = 20;
    i = 0;
    while (i < score_blocks) {
        gpu_draw_rect(SCREEN_W - 18 - i * 10, 14, 6, 6, RGB(140, 225, 140));
        i++;
    }

    i = 0;
    while (i < wave && i < 10) {
        gpu_draw_rect(SCREEN_W / 2 - 45 + i * 10, 16, 6, 8, RGB(255, 205, 95));
        i++;
    }
}

void draw_restart_overlay() {
    gpu_draw_rect(SCREEN_W / 2 - 150, SCREEN_H / 2 - 52, 300, 104, RGB(38, 14, 14));
    gpu_draw_rect(SCREEN_W / 2 - 144, SCREEN_H / 2 - 46, 288, 92, RGB(78, 24, 24));
    gpu_draw_rect(SCREEN_W / 2 - 110, SCREEN_H / 2 - 14, 220, 8, RGB(255, 130, 130));
    gpu_draw_rect(SCREEN_W / 2 - 90, SCREEN_H / 2 + 12, 180, 8, RGB(255, 205, 95));
    draw_player_ship(SCREEN_W / 2 - 28, SCREEN_H / 2 - 40, RGB(255, 220, 220));
}

void draw_scene() {
    int row;
    int col;
    int x;
    int y;
    int i;
    int bit;

    gpu_batch_begin();
    gpu_draw_rect(0, 0, SCREEN_W, SCREEN_H, RGB(8, 10, 18));
    draw_hud();

    row = 0;
    while (row < ALIEN_ROWS) {
        col = 0;
        while (col < ALIEN_COLS) {
            bit = 1 << col;
            if (alien_mask[row] & bit) {
                x = alien_origin_x + col * (ALIEN_W + ALIEN_GAP_X);
                y = alien_origin_y + row * (ALIEN_H + ALIEN_GAP_Y);
                draw_alien(x, y, row);
            }
            col++;
        }
        row++;
    }

    if (game_state == 0) {
        draw_player_ship(player_x, PLAYER_Y, RGB(120, 230, 120));
        gpu_draw_rect(player_x + 24, PLAYER_Y - 6, 8, 8, RGB(200, 255, 200));
    } else {
        draw_player_ship(player_x, PLAYER_Y, RGB(255, 220, 220));
    }

    if (player_shot_active) {
        gpu_draw_rect(player_shot_x, player_shot_y, SHOT_W, SHOT_H, RGB(255, 245, 175));
    }

    i = 0;
    while (i < ENEMY_BULLETS) {
        if (enemy_shot_active[i]) {
            gpu_draw_rect(enemy_shot_x[i], enemy_shot_y[i], ENEMY_SHOT_W, ENEMY_SHOT_H, RGB(255, 130, 130));
        }
        i++;
    }

    gpu_draw_rect(20, PLAYER_Y + PLAYER_H + 18, SCREEN_W - 40, 4, RGB(60, 180, 96));

    if (game_state != 0) draw_restart_overlay();

    gpu_batch_flush();
    flush();
}

int main() {
    app_window(SCREEN_W, SCREEN_H);
    srand(syscall(73, 6, 0, 0, 0, 0, 0));
    reset_game();
    while (1) {
        if (key_pressed(113)) return 0;

        if (game_state != 0) {
            if (key_pressed(KEY_ENTER) || key_pressed(KEY_SPACE)) reset_game();
        } else {
            move_player();
            if (key_pressed(KEY_SPACE)) fire_player_shot();
            update_player_shot();
            if (game_state == 0) update_enemy_shots();
            if (game_state == 0) update_aliens();
        }

        draw_scene();
        vsync(60);
    }
    return 0;
}
]===]

return space_defenders_c