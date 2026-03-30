local pong_c = [===[
#include <rovm.h>
#include <stdlib.h>

#define gpu_draw_rect gpu_batch_rect

#define SCREEN_W 760
#define SCREEN_H 520
#define WALL 20
#define PADDLE_W 12
#define PADDLE_H 84
#define BALL_SIZE 12
#define PLAYER_X 28
#define CPU_X (SCREEN_W - 28 - PADDLE_W)
#define PADDLE_SPEED 6
#define BALL_SPEED 5
#define CPU_SPEED 4
#define CPU_DEADZONE 6
#define SCORE_W 14
#define SCORE_H 16
#define SCORE_GAP 4

int paddle_left_y;
int paddle_right_y;
int ball_x;
int ball_y;
int ball_vx;
int ball_vy;
int score_left;
int score_right;

void set_title() { app_set_title("Pong"); }

int clamp_int(int value, int low, int high) {
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

void reset_ball(int dir) {
    int vy;
    ball_x = SCREEN_W / 2 - BALL_SIZE / 2;
    ball_y = SCREEN_H / 2 - BALL_SIZE / 2;
    vy = (rand() % 5) - 2;
    if (vy == 0) {
        if (rand() & 1) vy = 1;
        else vy = -1;
    }
    ball_vx = dir * BALL_SPEED;
    ball_vy = vy;
}

void reset_round(int dir) {
    paddle_left_y = SCREEN_H / 2 - PADDLE_H / 2;
    paddle_right_y = SCREEN_H / 2 - PADDLE_H / 2;
    reset_ball(dir);
}

void reset_match() {
    score_left = 0;
    score_right = 0;
    if (rand() & 1) reset_round(1);
    else reset_round(-1);
}

void bounce_from_paddle(int paddle_y, int dir) {
    int ball_mid = ball_y + BALL_SIZE / 2;
    int paddle_mid = paddle_y + PADDLE_H / 2;
    int offset = ball_mid - paddle_mid;
    int new_vy = (offset * 7) / (PADDLE_H / 2);
    int tweak = (rand() % 3) - 1;

    ball_vx = dir * BALL_SPEED;

    if (new_vy == 0) {
        if (ball_vy > 0) new_vy = 2;
        else if (ball_vy < 0) new_vy = -2;
        else if (rand() & 1) new_vy = 2;
        else new_vy = -2;
    } else if (new_vy > 0 && new_vy < 2) {
        new_vy = 2;
    } else if (new_vy < 0 && new_vy > -2) {
        new_vy = -2;
    }

    new_vy += tweak;
    if (new_vy == 0) {
        if (offset >= 0) new_vy = 1;
        else new_vy = -1;
    }
    if (new_vy > 7) new_vy = 7;
    if (new_vy < -7) new_vy = -7;
    ball_vy = new_vy;
}

void update_player() {
    if (key_down(119) || key_down(KEY_UP)) paddle_left_y -= PADDLE_SPEED;
    if (key_down(115) || key_down(KEY_DOWN)) paddle_left_y += PADDLE_SPEED;
    paddle_left_y = clamp_int(paddle_left_y, WALL, SCREEN_H - WALL - PADDLE_H);
}

void update_cpu() {
    int target = SCREEN_H / 2 - PADDLE_H / 2;
    int delta;
    if (ball_vx > 0) target = ball_y + BALL_SIZE / 2 - PADDLE_H / 2;
    delta = target - paddle_right_y;
    if (delta > CPU_DEADZONE) paddle_right_y += CPU_SPEED;
    else if (delta < -CPU_DEADZONE) paddle_right_y -= CPU_SPEED;
    paddle_right_y = clamp_int(paddle_right_y, WALL, SCREEN_H - WALL - PADDLE_H);
}

void step_ball() {
    int ball_right;
    int ball_bottom;

    ball_x += ball_vx;
    ball_y += ball_vy;

    if (ball_y <= WALL) {
        ball_y = WALL;
        ball_vy = -ball_vy;
    }
    if (ball_y + BALL_SIZE >= SCREEN_H - WALL) {
        ball_y = SCREEN_H - WALL - BALL_SIZE;
        ball_vy = -ball_vy;
    }

    ball_right = ball_x + BALL_SIZE;
    ball_bottom = ball_y + BALL_SIZE;

    if (ball_vx < 0) {
        if (ball_x <= PLAYER_X + PADDLE_W && ball_right >= PLAYER_X &&
            ball_bottom >= paddle_left_y && ball_y <= paddle_left_y + PADDLE_H) {
            ball_x = PLAYER_X + PADDLE_W;
            bounce_from_paddle(paddle_left_y, 1);
        }
    } else {
        if (ball_right >= CPU_X && ball_x <= CPU_X + PADDLE_W &&
            ball_bottom >= paddle_right_y && ball_y <= paddle_right_y + PADDLE_H) {
            ball_x = CPU_X - BALL_SIZE;
            bounce_from_paddle(paddle_right_y, -1);
        }
    }

    if (ball_x + BALL_SIZE < 0) {
        score_right++;
        if (score_right > 9) score_right = 0;
        reset_round(-1);
        return;
    }
    if (ball_x > SCREEN_W) {
        score_left++;
        if (score_left > 9) score_left = 0;
        reset_round(1);
    }
}

void draw_score(int left_side, int score) {
    int i = 0;
    int base_x;
    int color = RGB(242, 242, 242);
    if (left_side) base_x = SCREEN_W / 2 - 20 - score * (SCORE_W + SCORE_GAP);
    else base_x = SCREEN_W / 2 + 20;
    while (i < score) {
        gpu_draw_rect(base_x + i * (SCORE_W + SCORE_GAP), WALL + 10, SCORE_W, SCORE_H, color);
        i++;
    }
}

void draw_game() {
    int y;
    gpu_batch_begin();
    gpu_draw_rect(0, 0, SCREEN_W, SCREEN_H, RGB(10, 12, 16));
    gpu_draw_rect(0, 0, SCREEN_W, WALL, RGB(24, 28, 36));
    gpu_draw_rect(0, SCREEN_H - WALL, SCREEN_W, WALL, RGB(24, 28, 36));

    y = WALL + 8;
    while (y < SCREEN_H - WALL - 18) {
        gpu_draw_rect(SCREEN_W / 2 - 3, y, 6, 18, RGB(70, 76, 88));
        y += 32;
    }

    draw_score(1, score_left);
    draw_score(0, score_right);

    gpu_draw_rect(PLAYER_X, paddle_left_y, PADDLE_W, PADDLE_H, RGB(240, 240, 240));
    gpu_draw_rect(CPU_X, paddle_right_y, PADDLE_W, PADDLE_H, RGB(240, 240, 240));
    gpu_draw_rect(ball_x, ball_y, BALL_SIZE, BALL_SIZE, RGB(255, 150, 70));

    gpu_batch_flush();
    flush();
}

int main() {
    app_window(SCREEN_W, SCREEN_H);
    srand(syscall(73, 6, 0, 0, 0, 0, 0));
    set_title();
    reset_match();
    while (1) {
        if (key_pressed(113)) return 0;
        if (key_pressed(KEY_SPACE)) reset_match();
        update_player();
        update_cpu();
        step_ball();
        draw_game();
        vsync(60);
    }
    return 0;
}
]===]

return pong_c