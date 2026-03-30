local tetris_c = [===[
#include <rovm.h>
#include <stdlib.h>
#include <stdio.h>

#define gpu_draw_rect gpu_batch_rect

#define BOARD_W 10
#define BOARD_H 20
#define BOARD_CELLS 200
#define CELL 24
#define PAD 20
#define SIDE_W 200
#define SCREEN_W (BOARD_W * CELL + PAD * 2 + SIDE_W)
#define SCREEN_H (BOARD_H * CELL + PAD * 2)
#define DROP_FRAMES 18
#define CLEAR_ANIM_FRAMES 10
#define MAX_CLEAR_ROWS 4
#define HIGH_SCORE_COUNT 5
#define SAVE_PATH "/home/tetris.scores"
#define PANEL_X (PAD + BOARD_W * CELL + 20)
#define PANEL_W (SIDE_W - 40)
#define PREVIEW_Y (PAD + 20)
#define PREVIEW_H 128
#define STATS_Y (PREVIEW_Y + PREVIEW_H + 14)
#define STATS_H 110
#define SCORES_Y (STATS_Y + STATS_H + 14)
#define SCORES_H (SCREEN_H - SCORES_Y - PAD)
#define G5(a, b, c, d, e) (((a) << 12) | ((b) << 9) | ((c) << 6) | ((d) << 3) | (e))

int board[BOARD_CELLS];
int piece_colors[7];
int high_scores[HIGH_SCORE_COUNT];

int current_piece;
int current_rot;
int current_x;
int current_y;
int next_piece;
int score;
int lines_cleared;
int game_over;
int left_repeat;
int right_repeat;
int down_repeat;
int drop_timer;
int clear_anim_timer;
int clear_anim_count;
int clear_anim_rows[MAX_CLEAR_ROWS];
int active_x[4];
int active_y[4];
int temp_x[4];
int temp_y[4];

void clear_high_scores() {
    int i = 0;
    while (i < HIGH_SCORE_COUNT) {
        high_scores[i] = 0;
        i++;
    }
}

int insert_high_score(int value) {
    int rank = 0;
    int i;
    if (value <= 0) return -1;
    while (rank < HIGH_SCORE_COUNT && high_scores[rank] > 0 && value <= high_scores[rank]) rank++;
    if (rank >= HIGH_SCORE_COUNT) return -1;
    i = HIGH_SCORE_COUNT - 1;
    while (i > rank) {
        high_scores[i] = high_scores[i - 1];
        i--;
    }
    high_scores[rank] = value;
    return rank;
}

void load_high_scores() {
    FILE* f;
    char line[32];
    clear_high_scores();
    f = fopen(SAVE_PATH, "r");
    if (!f) return;
    while (fgets(line, 32, f)) {
        int value = atoi(line);
        if (value > 0) insert_high_score(value);
    }
    fclose(f);
}

void save_high_scores() {
    FILE* f;
    int i = 0;
    syscall(37, (int)SAVE_PATH, 0, 0, 0, 0, 0);
    f = fopen(SAVE_PATH, "w");
    if (!f) return;
    while (i < HIGH_SCORE_COUNT) {
        fprintf(f, "%d\n", high_scores[i], 0, 0);
        i++;
    }
    fclose(f);
}

void record_score() {
    if (insert_high_score(score) >= 0) save_high_scores();
}

int line_clear_points(int cleared_now) {
    if (cleared_now == 1) return 100;
    if (cleared_now == 2) return 300;
    if (cleared_now == 3) return 500;
    if (cleared_now >= 4) return 800;
    return 0;
}

int is_clearing_row(int y) {
    int i = 0;
    while (i < clear_anim_count) {
        if (clear_anim_rows[i] == y) return 1;
        i++;
    }
    return 0;
}

int begin_line_clear() {
    int y = BOARD_H - 1;
    int cleared_now = 0;
    while (y >= 0) {
        int x = 0;
        int full = 1;
        while (x < BOARD_W) {
            if (!board[y * BOARD_W + x]) {
                full = 0;
                break;
            }
            x++;
        }
        if (full) {
            if (cleared_now < MAX_CLEAR_ROWS) clear_anim_rows[cleared_now] = y;
            cleared_now++;
        }
        y--;
    }
    clear_anim_count = cleared_now;
    if (cleared_now > 0) {
        clear_anim_timer = CLEAR_ANIM_FRAMES;
        lines_cleared += cleared_now;
        score += line_clear_points(cleared_now);
    }
    return cleared_now;
}

void apply_cleared_rows() {
    int src = BOARD_H - 1;
    int dst = BOARD_H - 1;
    while (src >= 0) {
        if (!is_clearing_row(src)) {
            int col = 0;
            while (col < BOARD_W) {
                board[dst * BOARD_W + col] = board[src * BOARD_W + col];
                col++;
            }
            dst--;
        }
        src--;
    }
    while (dst >= 0) {
        int col = 0;
        while (col < BOARD_W) {
            board[dst * BOARD_W + col] = 0;
            col++;
        }
        dst--;
    }
    clear_anim_timer = 0;
    clear_anim_count = 0;
}

int glyph_mask(char ch) {
    if (ch >= 'a' && ch <= 'z') ch = ch - 32;
    if (ch == '0') return G5(7, 5, 5, 5, 7);
    if (ch == '1') return G5(2, 6, 2, 2, 7);
    if (ch == '2') return G5(7, 1, 7, 4, 7);
    if (ch == '3') return G5(7, 1, 7, 1, 7);
    if (ch == '4') return G5(5, 5, 7, 1, 1);
    if (ch == '5') return G5(7, 4, 7, 1, 7);
    if (ch == '6') return G5(7, 4, 7, 5, 7);
    if (ch == '7') return G5(7, 1, 1, 1, 1);
    if (ch == '8') return G5(7, 5, 7, 5, 7);
    if (ch == '9') return G5(7, 5, 7, 1, 7);
    if (ch == 'A') return G5(2, 5, 7, 5, 5);
    if (ch == 'B') return G5(6, 5, 6, 5, 6);
    if (ch == 'C') return G5(3, 4, 4, 4, 3);
    if (ch == 'D') return G5(6, 5, 5, 5, 6);
    if (ch == 'E') return G5(7, 4, 6, 4, 7);
    if (ch == 'F') return G5(7, 4, 6, 4, 4);
    if (ch == 'G') return G5(3, 4, 5, 5, 3);
    if (ch == 'H') return G5(5, 5, 7, 5, 5);
    if (ch == 'I') return G5(7, 2, 2, 2, 7);
    if (ch == 'J') return G5(1, 1, 1, 5, 2);
    if (ch == 'K') return G5(5, 5, 6, 5, 5);
    if (ch == 'L') return G5(4, 4, 4, 4, 7);
    if (ch == 'M') return G5(5, 7, 7, 5, 5);
    if (ch == 'N') return G5(5, 7, 7, 7, 5);
    if (ch == 'O') return G5(2, 5, 5, 5, 2);
    if (ch == 'P') return G5(6, 5, 6, 4, 4);
    if (ch == 'Q') return G5(2, 5, 5, 7, 3);
    if (ch == 'R') return G5(6, 5, 6, 5, 5);
    if (ch == 'S') return G5(3, 4, 2, 1, 6);
    if (ch == 'T') return G5(7, 2, 2, 2, 2);
    if (ch == 'U') return G5(5, 5, 5, 5, 7);
    if (ch == 'V') return G5(5, 5, 5, 5, 2);
    if (ch == 'W') return G5(5, 5, 7, 7, 5);
    if (ch == 'X') return G5(5, 5, 2, 5, 5);
    if (ch == 'Y') return G5(5, 5, 2, 2, 2);
    if (ch == 'Z') return G5(7, 1, 2, 4, 7);
    if (ch == ':') return G5(0, 2, 0, 2, 0);
    if (ch == '.') return G5(0, 0, 0, 0, 2);
    if (ch == '-') return G5(0, 0, 7, 0, 0);
    return 0;
}

int text_width(char* text, int size) {
    int len = 0;
    while (text[len]) len++;
    if (len <= 0) return 0;
    return len * 4 * size - size;
}

void draw_text_small(int sx, int sy, int size, int color, char* text) {
    int i = 0;
    int x = sx;
    while (text[i]) {
        int mask = glyph_mask(text[i]);
        int row = 0;
        while (row < 5) {
            int col = 0;
            while (col < 3) {
                int bit = 14 - (row * 3 + col);
                if ((mask >> bit) & 1) {
                    gpu_draw_rect(x + col * size, sy + row * size, size, size, color);
                }
                col++;
            }
            row++;
        }
        x += 4 * size;
        i++;
    }
}

void draw_text_centered(int x, int y, int w, int size, int color, char* text) {
    int tx = x + (w - text_width(text, size)) / 2;
    if (tx < x) tx = x;
    draw_text_small(tx, y, size, color, text);
}

void draw_panel(int x, int y, int w, int h) {
    gpu_draw_rect(x, y, w, h, RGB(56, 60, 72));
    gpu_draw_rect(x + 3, y + 3, w - 6, h - 6, RGB(24, 28, 36));
}

void fill_piece_cells(int piece, int rot, int* xs, int* ys) {
    rot = rot & 3;

    if (piece == 0) {
        if ((rot & 1) == 0) {
            xs[0] = 0; ys[0] = 1;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 2; ys[2] = 1;
            xs[3] = 3; ys[3] = 1;
        } else {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 1; ys[2] = 2;
            xs[3] = 1; ys[3] = 3;
        }
    } else if (piece == 1) {
        if (rot == 0) {
            xs[0] = 0; ys[0] = 0;
            xs[1] = 0; ys[1] = 1;
            xs[2] = 1; ys[2] = 1;
            xs[3] = 2; ys[3] = 1;
        } else if (rot == 1) {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 2; ys[1] = 0;
            xs[2] = 1; ys[2] = 1;
            xs[3] = 1; ys[3] = 2;
        } else if (rot == 2) {
            xs[0] = 0; ys[0] = 1;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 2; ys[2] = 1;
            xs[3] = 2; ys[3] = 2;
        } else {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 0; ys[2] = 2;
            xs[3] = 1; ys[3] = 2;
        }
    } else if (piece == 2) {
        if (rot == 0) {
            xs[0] = 2; ys[0] = 0;
            xs[1] = 0; ys[1] = 1;
            xs[2] = 1; ys[2] = 1;
            xs[3] = 2; ys[3] = 1;
        } else if (rot == 1) {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 1; ys[2] = 2;
            xs[3] = 2; ys[3] = 2;
        } else if (rot == 2) {
            xs[0] = 0; ys[0] = 1;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 2; ys[2] = 1;
            xs[3] = 0; ys[3] = 2;
        } else {
            xs[0] = 0; ys[0] = 0;
            xs[1] = 1; ys[1] = 0;
            xs[2] = 1; ys[2] = 1;
            xs[3] = 1; ys[3] = 2;
        }
    } else if (piece == 3) {
        xs[0] = 1; ys[0] = 0;
        xs[1] = 2; ys[1] = 0;
        xs[2] = 1; ys[2] = 1;
        xs[3] = 2; ys[3] = 1;
    } else if (piece == 4) {
        if ((rot & 1) == 0) {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 2; ys[1] = 0;
            xs[2] = 0; ys[2] = 1;
            xs[3] = 1; ys[3] = 1;
        } else {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 2; ys[2] = 1;
            xs[3] = 2; ys[3] = 2;
        }
    } else if (piece == 5) {
        if (rot == 0) {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 0; ys[1] = 1;
            xs[2] = 1; ys[2] = 1;
            xs[3] = 2; ys[3] = 1;
        } else if (rot == 1) {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 2; ys[2] = 1;
            xs[3] = 1; ys[3] = 2;
        } else if (rot == 2) {
            xs[0] = 0; ys[0] = 1;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 2; ys[2] = 1;
            xs[3] = 1; ys[3] = 2;
        } else {
            xs[0] = 1; ys[0] = 0;
            xs[1] = 0; ys[1] = 1;
            xs[2] = 1; ys[2] = 1;
            xs[3] = 1; ys[3] = 2;
        }
    } else {
        if ((rot & 1) == 0) {
            xs[0] = 0; ys[0] = 0;
            xs[1] = 1; ys[1] = 0;
            xs[2] = 1; ys[2] = 1;
            xs[3] = 2; ys[3] = 1;
        } else {
            xs[0] = 2; ys[0] = 0;
            xs[1] = 1; ys[1] = 1;
            xs[2] = 2; ys[2] = 1;
            xs[3] = 1; ys[3] = 2;
        }
    }
}

void sync_active_piece() {
    fill_piece_cells(current_piece, current_rot, active_x, active_y);
}

void set_title_running() { app_set_title("Tetris"); }
void set_title_game_over() { app_set_title("Tetris"); }

int collides(int piece, int rot, int px, int py) {
    int i = 0;
    int bx;
    int by;
    fill_piece_cells(piece, rot, temp_x, temp_y);
    while (i < 4) {
        bx = px + temp_x[i];
        by = py + temp_y[i];
        if (bx < 0 || bx >= BOARD_W || by >= BOARD_H) return 1;
        if (by >= 0 && board[by * BOARD_W + bx]) return 1;
        i++;
    }
    return 0;
}

void spawn_piece() {
    current_piece = next_piece;
    next_piece = rand() % 7;
    current_rot = 0;
    current_x = 3;
    current_y = 0;
    sync_active_piece();
    if (collides(current_piece, current_rot, current_x, current_y)) {
        game_over = 1;
        record_score();
        set_title_game_over();
    }
}

void lock_piece() {
    int i = 0;
    int bx;
    int by;
    while (i < 4) {
        bx = current_x + active_x[i];
        by = current_y + active_y[i];
        if (by >= 0 && bx >= 0 && bx < BOARD_W && by < BOARD_H) {
            board[by * BOARD_W + bx] = current_piece + 1;
        }
        i++;
    }
    if (begin_line_clear() <= 0) spawn_piece();
}

void reset_game() {
    int i = 0;
    while (i < BOARD_CELLS) {
        board[i] = 0;
        i++;
    }
    score = 0;
    lines_cleared = 0;
    game_over = 0;
    left_repeat = 0;
    right_repeat = 0;
    down_repeat = 0;
    drop_timer = 0;
    clear_anim_timer = 0;
    clear_anim_count = 0;
    next_piece = rand() % 7;
    spawn_piece();
}

void init_palette() {
    piece_colors[0] = RGB(90, 220, 255);
    piece_colors[1] = RGB(80, 110, 255);
    piece_colors[2] = RGB(255, 150, 70);
    piece_colors[3] = RGB(255, 225, 80);
    piece_colors[4] = RGB(80, 220, 120);
    piece_colors[5] = RGB(180, 90, 255);
    piece_colors[6] = RGB(255, 90, 110);
}

void try_move(int dx) {
    if (!collides(current_piece, current_rot, current_x + dx, current_y)) current_x += dx;
}

void try_rotate() {
    int nr = (current_rot + 1) & 3;
    if (!collides(current_piece, nr, current_x, current_y)) {
        current_rot = nr;
        sync_active_piece();
    }
    else if (!collides(current_piece, nr, current_x - 1, current_y)) {
        current_x--;
        current_rot = nr;
        sync_active_piece();
    } else if (!collides(current_piece, nr, current_x + 1, current_y)) {
        current_x++;
        current_rot = nr;
        sync_active_piece();
    }
}

void hard_drop() {
    int distance = 0;
    while (!collides(current_piece, current_rot, current_x, current_y + 1)) {
        current_y++;
        distance++;
    }
    score += distance * 2;
    lock_piece();
}

int get_drop_y() {
    int ghost_y = current_y;
    while (!collides(current_piece, current_rot, current_x, ghost_y + 1)) {
        ghost_y++;
    }
    return ghost_y;
}

void draw_block(int bx, int by, int color) {
    int px = PAD + bx * CELL;
    int py = PAD + by * CELL;
    gpu_draw_rect(px + 1, py + 1, CELL - 2, CELL - 2, color);
    gpu_draw_rect(px + 4, py + 4, CELL - 8, CELL - 8, RGB(30, 24, 22));
}

void draw_ghost_block(int bx, int by, int color) {
    int px = PAD + bx * CELL;
    int py = PAD + by * CELL;
    int r = ((color >> 16) & 0xFF) / 3;
    int g = ((color >> 8) & 0xFF) / 3;
    int b = (color & 0xFF) / 3;
    int ghost = RGB(r, g, b);
    gpu_draw_rect(px + 2, py + 2, CELL - 4, 2, ghost);
    gpu_draw_rect(px + 2, py + CELL - 4, CELL - 4, 2, ghost);
    gpu_draw_rect(px + 2, py + 4, 2, CELL - 8, ghost);
    gpu_draw_rect(px + CELL - 4, py + 4, 2, CELL - 8, ghost);
    gpu_draw_rect(px + 6, py + 6, CELL - 12, CELL - 12, RGB(26, 28, 34));
}

void draw_clear_animation() {
    int i = 0;
    int total_w = BOARD_W * CELL;
    int phase = CLEAR_ANIM_FRAMES - clear_anim_timer;
    int inset = phase * (total_w / 2) / CLEAR_ANIM_FRAMES;
    int width = total_w - inset * 2;
    int flash = (clear_anim_timer & 1) ? 255 : 220;
    if (width < 0) width = 0;
    while (i < clear_anim_count) {
        int py = PAD + clear_anim_rows[i] * CELL;
        gpu_draw_rect(PAD + inset, py + 2, width, CELL - 4, RGB(255, flash, 150));
        if (width > 12) {
            gpu_draw_rect(PAD + inset + 4, py + 6, width - 8, CELL - 12, RGB(255, 255, 240));
        }
        i++;
    }
}

void draw_preview() {
    int i;
    int min_x;
    int max_x;
    int min_y;
    int max_y;
    int piece_w;
    int piece_h;
    int ox;
    int oy;
    draw_panel(PANEL_X, PREVIEW_Y, PANEL_W, PREVIEW_H);
    draw_text_centered(PANEL_X, PREVIEW_Y + 12, PANEL_W, 3, RGB(230, 236, 245), "NEXT");
    fill_piece_cells(next_piece, 0, temp_x, temp_y);
    min_x = temp_x[0];
    max_x = temp_x[0];
    min_y = temp_y[0];
    max_y = temp_y[0];
    i = 1;
    while (i < 4) {
        if (temp_x[i] < min_x) min_x = temp_x[i];
        if (temp_x[i] > max_x) max_x = temp_x[i];
        if (temp_y[i] < min_y) min_y = temp_y[i];
        if (temp_y[i] > max_y) max_y = temp_y[i];
        i++;
    }
    piece_w = (max_x - min_x) * 22 + 18;
    piece_h = (max_y - min_y) * 22 + 18;
    ox = PANEL_X + 18 + (PANEL_W - 36 - piece_w) / 2 - min_x * 22;
    oy = PREVIEW_Y + 46 + (PREVIEW_H - 64 - piece_h) / 2 - min_y * 22;
    i = 0;
    while (i < 4) {
        gpu_draw_rect(ox + temp_x[i] * 22, oy + temp_y[i] * 22, 18, 18, piece_colors[next_piece]);
        gpu_draw_rect(ox + temp_x[i] * 22 + 3, oy + temp_y[i] * 22 + 3, 12, 12, RGB(24, 20, 18));
        i++;
    }
}

void draw_stats() {
    char buf[32];
    draw_panel(PANEL_X, STATS_Y, PANEL_W, STATS_H);
    draw_text_centered(PANEL_X, STATS_Y + 12, PANEL_W, 3, RGB(230, 236, 245), "SCORE");
    sprintf(buf, "%d", score, 0, 0);
    draw_text_centered(PANEL_X, STATS_Y + 34, PANEL_W, 4, RGB(255, 238, 130), buf);
    draw_text_small(PANEL_X + 12, STATS_Y + 72, 2, RGB(160, 176, 196), "LINES");
    sprintf(buf, "%d", lines_cleared, 0, 0);
    draw_text_small(PANEL_X + 12, STATS_Y + 88, 3, RGB(232, 236, 244), buf);
    draw_text_small(PANEL_X + 86, STATS_Y + 72, 2, RGB(160, 176, 196), "BEST");
    sprintf(buf, "%d", high_scores[0], 0, 0);
    draw_text_small(PANEL_X + 86, STATS_Y + 88, 3, RGB(232, 236, 244), buf);
}

void draw_high_scores() {
    int i = 0;
    int row_y = SCORES_Y + 38;
    char buf[32];
    draw_panel(PANEL_X, SCORES_Y, PANEL_W, SCORES_H);
    draw_text_centered(PANEL_X, SCORES_Y + 12, PANEL_W, 3, RGB(230, 236, 245), "TOP 5");
    while (i < HIGH_SCORE_COUNT) {
        gpu_draw_rect(PANEL_X + 10, row_y - 4, PANEL_W - 20, 28, i == 0 ? RGB(46, 54, 70) : RGB(34, 40, 52));
        sprintf(buf, "%d", i + 1, 0, 0);
        draw_text_small(PANEL_X + 18, row_y + 4, 2, RGB(160, 176, 196), buf);
        sprintf(buf, "%d", high_scores[i], 0, 0);
        draw_text_small(PANEL_X + 42, row_y + 2, 3, i == 0 ? RGB(255, 238, 130) : RGB(232, 236, 244), buf);
        row_y += 32;
        i++;
    }
}

void draw_game_over_overlay() {
    char buf[32];
    int overlay_x = PAD + 22;
    int overlay_y = PAD + 150;
    int overlay_w = BOARD_W * CELL - 44;
    int overlay_h = 162;
    gpu_draw_rect(overlay_x, overlay_y, overlay_w, overlay_h, RGB(120, 40, 40));
    gpu_draw_rect(overlay_x + 8, overlay_y + 8, overlay_w - 16, overlay_h - 16, RGB(48, 18, 18));
    draw_text_centered(overlay_x, overlay_y + 18, overlay_w, 4, RGB(255, 214, 214), "GAME OVER");
    draw_text_centered(overlay_x, overlay_y + 62, overlay_w, 2, RGB(212, 188, 188), "SCORE");
    sprintf(buf, "%d", score, 0, 0);
    draw_text_centered(overlay_x, overlay_y + 82, overlay_w, 4, RGB(255, 238, 130), buf);
    draw_text_centered(overlay_x, overlay_y + 126, overlay_w, 2, RGB(212, 188, 188), "ENTER RETRY");
    draw_text_centered(overlay_x, overlay_y + 144, overlay_w, 2, RGB(212, 188, 188), "Q QUIT");
}

void draw_game() {
    int x;
    int y;
    int idx;
    int cell_value;
    int bx;
    int by;
    int ghost_y;
    gpu_batch_begin();
    gpu_draw_rect(0, 0, SCREEN_W, SCREEN_H, RGB(12, 13, 16));
    gpu_draw_rect(PAD - 4, PAD - 4, BOARD_W * CELL + 8, BOARD_H * CELL + 8, RGB(72, 76, 86));
    gpu_draw_rect(PAD, PAD, BOARD_W * CELL, BOARD_H * CELL, RGB(22, 24, 30));
    idx = 0;
    y = 0;
    while (y < BOARD_H) {
        x = 0;
        while (x < BOARD_W) {
            cell_value = board[idx];
            if (cell_value && !(clear_anim_timer > 0 && is_clearing_row(y))) draw_block(x, y, piece_colors[cell_value - 1]);
            idx++;
            x++;
        }
        y++;
    }
    if (clear_anim_timer <= 0) {
        ghost_y = get_drop_y();
        x = 0;
        while (x < 4) {
            bx = current_x + active_x[x];
            by = ghost_y + active_y[x];
            if (by >= 0 && by != current_y + active_y[x]) draw_ghost_block(bx, by, piece_colors[current_piece]);
            x++;
        }
        x = 0;
        while (x < 4) {
            bx = current_x + active_x[x];
            by = current_y + active_y[x];
            if (by >= 0) draw_block(bx, by, piece_colors[current_piece]);
            x++;
        }
    }
    if (clear_anim_timer > 0) draw_clear_animation();
    draw_preview();
    draw_stats();
    draw_high_scores();
    if (game_over) {
        draw_game_over_overlay();
    }
    gpu_batch_flush();
    flush();
}

int main() {
    app_window(SCREEN_W, SCREEN_H);
    srand(syscall(73, 6, 0, 0, 0, 0, 0));
    set_title_running();
    init_palette();
    load_high_scores();
    reset_game();
    while (1) {
        if (key_pressed(113)) return 0;
        if (game_over) {
            if (key_pressed(KEY_ENTER) || key_pressed(KEY_SPACE)) {
                reset_game();
                set_title_running();
            }
            draw_game();
            vsync(30);
            continue;
        }

        if (clear_anim_timer > 0) {
            draw_game();
            vsync(30);
            clear_anim_timer--;
            if (clear_anim_timer <= 0) {
                apply_cleared_rows();
                spawn_piece();
            }
            continue;
        }

        if (key_pressed(119) || key_pressed(KEY_UP)) try_rotate();
        if (key_pressed(KEY_SPACE)) hard_drop();

        if (key_down(97) || key_down(KEY_LEFT)) {
            if (left_repeat <= 0) {
                try_move(-1);
                left_repeat = 2;
            } else left_repeat--;
        } else left_repeat = 0;

        if (key_down(100) || key_down(KEY_RIGHT)) {
            if (right_repeat <= 0) {
                try_move(1);
                right_repeat = 2;
            } else right_repeat--;
        } else right_repeat = 0;

        if (key_down(115) || key_down(KEY_DOWN)) {
            if (down_repeat <= 0) {
                if (!collides(current_piece, current_rot, current_x, current_y + 1)) {
                    current_y++;
                    score++;
                } else lock_piece();
                down_repeat = 1;
            } else down_repeat--;
        } else down_repeat = 0;

        drop_timer++;
        if (drop_timer >= DROP_FRAMES) {
            drop_timer = 0;
            if (!collides(current_piece, current_rot, current_x, current_y + 1)) current_y++;
            else lock_piece();
        }

        draw_game();
        vsync(30);
    }
    return 0;
}
]===]

return tetris_c