local doom_c = [===[
#include <rovm.h>
#include <math.h>

#define gpu_draw_rect gpu_batch_rect

#define SCREEN_W 1280
#define SCREEN_H 720
#define VIEW_H 600
#define HUD_H 120
#define HUD_Y 600
#define MAP_W 20
#define MAP_H 20
#define ABS(x) ((x) < 0 ? -(x) : (x))

#define PI_2 411774
#define FOV 68629
#define RENDER_SCALE 16
#define MOVE_ACCEL 2600
#define MOVE_FRICTION 1800
#define MOVE_MAX 11000
#define TURN_ACCEL 850
#define TURN_FRICTION 600
#define TURN_MAX 3200
#define NUM_COLS 80
#define MAX_DEPTH 15
#define HALF_VH 300
#define MAX_ENM 8
#define ENM_SPEED 3000
#define MAX_ITEMS 8

#define ST_TITLE 0
#define ST_PLAY 1
#define ST_DEAD 2
#define ST_WIN 3

int map[400] = {
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,0,0,0,1,0,0,0,0,0,0,0,0,0,1,0,0,0,0,1,
    1,0,0,0,1,0,0,0,0,0,0,0,0,0,1,0,0,0,0,1,
    1,0,0,0,9,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,1,1,1,1,0,0,2,2,0,0,2,2,0,1,1,9,1,1,1,
    1,0,0,0,0,0,0,2,0,0,0,0,2,0,0,0,0,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,0,0,0,0,0,2,0,0,0,0,2,0,0,0,0,0,0,1,
    1,0,0,0,0,0,0,2,2,0,0,2,2,0,0,0,0,0,0,1,
    1,1,9,1,1,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,
    1,0,0,0,1,0,0,0,0,0,0,0,0,0,1,0,0,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,0,0,1,0,0,3,0,0,0,0,3,0,1,0,0,0,0,1,
    1,0,0,0,1,0,0,0,0,0,0,0,0,0,1,0,0,0,0,1,
    1,1,1,1,1,0,0,3,0,0,0,0,3,0,1,1,9,1,1,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,4,0,0,1,
    1,0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,4,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1
};

int door_map[400];
int zbuf[80];

int px, py, pa;
int cos_pa, sin_pa;
int move_vel, turn_vel;
int player_hp, player_ammo;
int gun_state, gun_timer;
int kills;
int game_state = 0;

int fish_cos[80];
int col_off[80];
int wall_colors[10];
int enm_colors[4];

int enm_x[8];
int enm_y[8];
int enm_hp[8];
int enm_state[8];
int enm_type[8];
int enm_timer[8];
int num_enm = 0;

int item_x[8];
int item_y[8];
int item_type[8];
int item_active[8];
int num_items = 0;

int seg_mask[10];

void add_enemy(int gx, int gy, int type, int hp) {
    if (num_enm >= MAX_ENM) return;
    int i = num_enm;
    enm_x[i] = fix_from_int(gx) + FIXPOINT_ONE / 2;
    enm_y[i] = fix_from_int(gy) + FIXPOINT_ONE / 2;
    enm_hp[i] = hp;
    enm_type[i] = type;
    enm_state[i] = 0;
    enm_timer[i] = 0;
    num_enm++;
}

void add_item(int gx, int gy, int type) {
    if (num_items >= MAX_ITEMS) return;
    int i = num_items;
    item_x[i] = fix_from_int(gx) + FIXPOINT_ONE / 2;
    item_y[i] = fix_from_int(gy) + FIXPOINT_ONE / 2;
    item_type[i] = type;
    item_active[i] = 1;
    num_items++;
}

void spawn_entities() {
    num_enm = 0;
    num_items = 0;
    add_enemy(9, 6, 1, 3);
    add_enemy(15, 3, 2, 4);
    add_enemy(5, 11, 1, 3);
    add_enemy(15, 11, 3, 2);
    add_enemy(10, 16, 2, 4);
    add_enemy(5, 16, 1, 3);
    add_item(3, 1, 0);
    add_item(18, 1, 1);
    add_item(9, 9, 0);
    add_item(15, 9, 1);
    add_item(3, 15, 1);
    add_item(18, 18, 0);
}

void init() {
    int hf = FOV / 2;
    for (int i = 0; i < NUM_COLS; i++) {
        col_off[i] = -hf + (i * FOV) / NUM_COLS;
        fish_cos[i] = fix_cos(col_off[i]);
    }
    wall_colors[1] = RGB(139, 90, 43);
    wall_colors[2] = RGB(110, 110, 115);
    wall_colors[3] = RGB(47, 79, 47);
    wall_colors[4] = RGB(139, 69, 19);
    wall_colors[9] = RGB(80, 55, 25);
    for (int i = 0; i < 400; i++) door_map[i] = (map[i] == 9) ? 1 : 0;
    enm_colors[1] = RGB(160, 80, 40);
    enm_colors[2] = RGB(170, 50, 90);
    enm_colors[3] = RGB(90, 110, 55);
    seg_mask[0] = 63;
    seg_mask[1] = 6;
    seg_mask[2] = 91;
    seg_mask[3] = 79;
    seg_mask[4] = 102;
    seg_mask[5] = 109;
    seg_mask[6] = 125;
    seg_mask[7] = 7;
    seg_mask[8] = 127;
    seg_mask[9] = 111;
}

void reset_game() {
    player_hp = 100;
    player_ammo = 20;
    gun_state = 0;
    gun_timer = 0;
    move_vel = 0;
    turn_vel = 0;
    kills = 0;
    for (int i = 0; i < 400; i++) {
        if (door_map[i]) map[i] = 9;
    }
    spawn_entities();
    px = fix_from_int(2) + FIXPOINT_ONE / 2;
    py = fix_from_int(2) + FIXPOINT_ONE / 2;
    pa = 60000;
}

void try_door() {
    int cx = fix_to_int(px + cos_pa);
    int cy = fix_to_int(py + sin_pa);
    if (cx >= 0 && cx < MAP_W && cy >= 0 && cy < MAP_H) {
        int idx = cy * MAP_W + cx;
        if (door_map[idx]) {
            if (map[idx] == 9) map[idx] = 0;
            else map[idx] = 9;
        }
    }
}

int has_los(int x1, int y1, int x2, int y2) {
    int dx = x2 - x1;
    int dy = y2 - y1;
    int adx = ABS(dx);
    int ady = ABS(dy);
    int steps = fix_to_int(adx > ady ? adx : ady);
    if (steps == 0) return 1;
    if (steps > 20) return 0;
    int sx = dx / steps;
    int sy = dy / steps;
    int cx = x1;
    int cy = y1;
    for (int i = 0; i < steps; i++) {
        cx += sx;
        cy += sy;
        int gx = fix_to_int(cx);
        int gy = fix_to_int(cy);
        if (gx < 0 || gx >= MAP_W || gy < 0 || gy >= MAP_H) return 0;
        if (map[gy * MAP_W + gx]) return 0;
    }
    return 1;
}

void update_enemies() {
    for (int i = 0; i < num_enm; i++) {
        if (enm_state[i] == 3) continue;
        if (enm_state[i] == 4) {
            enm_timer[i]--;
            if (enm_timer[i] <= 0) enm_state[i] = 1;
            continue;
        }
        int dx = px - enm_x[i];
        int dy = py - enm_y[i];
        int adx = fix_to_int(ABS(dx));
        int ady = fix_to_int(ABS(dy));
        int mdist = adx + ady;
        if (enm_state[i] == 0) {
            if (mdist < 8 && has_los(enm_x[i], enm_y[i], px, py))
                enm_state[i] = 1;
        }
        if (enm_state[i] == 1) {
            if (mdist <= 1) {
                enm_state[i] = 2;
                enm_timer[i] = 0;
            } else {
                int mx = 0;
                int my = 0;
                if (adx > ady) mx = (dx > 0) ? ENM_SPEED : -ENM_SPEED;
                else my = (dy > 0) ? ENM_SPEED : -ENM_SPEED;
                int nx = enm_x[i] + mx;
                int ny = enm_y[i] + my;
                int gx = fix_to_int(nx);
                int gy = fix_to_int(ny);
                if (gx >= 0 && gx < MAP_W && gy >= 0 && gy < MAP_H) {
                    if (map[gy * MAP_W + gx] == 0) {
                        enm_x[i] = nx;
                        enm_y[i] = ny;
                    }
                }
            }
        }
        if (enm_state[i] == 2) {
            enm_timer[i]--;
            if (enm_timer[i] <= 0) {
                player_hp -= 10;
                if (player_hp < 0) player_hp = 0;
                enm_timer[i] = 15;
            }
            if (mdist > 2) enm_state[i] = 1;
        }
    }
}

void check_pickups() {
    for (int i = 0; i < num_items; i++) {
        if (!item_active[i]) continue;
        int dx = fix_to_int(ABS(px - item_x[i]));
        int dy = fix_to_int(ABS(py - item_y[i]));
        if (dx > 0 || dy > 0) continue;
        if (item_type[i] == 0) {
            if (player_hp >= 100) continue;
            player_hp += 25;
            if (player_hp > 100) player_hp = 100;
        } else {
            if (player_ammo >= 50) continue;
            player_ammo += 10;
            if (player_ammo > 50) player_ammo = 50;
        }
        item_active[i] = 0;
    }
}

void shoot() {
    if (gun_state != 0 || player_ammo <= 0) return;
    gun_state = 1;
    player_ammo--;
    int best = -1;
    int best_d = 2147483647;
    for (int i = 0; i < num_enm; i++) {
        if (enm_state[i] == 3) continue;
        int dx = enm_x[i] - px;
        int dy = enm_y[i] - py;
        int depth = fix_mul(dx, cos_pa) + fix_mul(dy, sin_pa);
        if (depth <= 0) continue;
        int angle = fix_atan2(dy, dx);
        int rel = angle - pa;
        if (rel > PI_2 / 2) rel -= PI_2;
        if (rel < -(PI_2 / 2)) rel += PI_2;
        if (ABS(rel) > 4000) continue;
        int scr_x = SCREEN_W / 2 + (rel * SCREEN_W) / FOV;
        int col = scr_x / RENDER_SCALE;
        if (col < 0 || col >= NUM_COLS) continue;
        if (depth >= zbuf[col]) continue;
        if (depth < best_d) { best_d = depth; best = i; }
    }
    if (best >= 0) {
        enm_hp[best]--;
        if (enm_hp[best] <= 0) { enm_state[best] = 3; kills++; }
        else { enm_state[best] = 4; enm_timer[best] = 3; }
    }
}

void draw_digit(int x, int y, int w, int h, int d, int c) {
    int m = seg_mask[d];
    int hw = h / 2;
    int t = w / 5;
    if (t < 2) t = 2;
    if (m & 1)  gpu_draw_rect(x + t, y, w - t * 2, t, c);
    if (m & 2)  gpu_draw_rect(x + w - t, y + t, t, hw - t, c);
    if (m & 4)  gpu_draw_rect(x + w - t, y + hw, t, hw - t, c);
    if (m & 8)  gpu_draw_rect(x + t, y + h - t, w - t * 2, t, c);
    if (m & 16) gpu_draw_rect(x, y + hw, t, hw - t, c);
    if (m & 32) gpu_draw_rect(x, y + t, t, hw - t, c);
    if (m & 64) gpu_draw_rect(x + t, y + hw - t / 2, w - t * 2, t, c);
}

void draw_number(int x, int y, int w, int h, int num, int c) {
    if (num >= 100) {
        draw_digit(x, y, w, h, num / 100, c);
        draw_digit(x + w + 4, y, w, h, (num / 10) % 10, c);
        draw_digit(x + (w + 4) * 2, y, w, h, num % 10, c);
    } else if (num >= 10) {
        draw_digit(x, y, w, h, num / 10, c);
        draw_digit(x + w + 4, y, w, h, num % 10, c);
    } else {
        draw_digit(x, y, w, h, num, c);
    }
}

void draw_pct(int x, int y, int sz, int c) {
    gpu_draw_rect(x, y, 12, 12, c);
    gpu_draw_rect(x + 3, y + 3, 6, 6, RGB(35, 28, 22));
    gpu_draw_rect(x + 22, y + 26, 12, 12, c);
    gpu_draw_rect(x + 25, y + 29, 6, 6, RGB(35, 28, 22));
    gpu_draw_rect(x + 24, y + 2, 8, 8, c);
    gpu_draw_rect(x + 16, y + 10, 8, 8, c);
    gpu_draw_rect(x + 8, y + 18, 8, 8, c);
    gpu_draw_rect(x, y + 26, 8, 8, c);
}

void draw_hud_divider(int x) {
    gpu_draw_rect(x, HUD_Y + 4, 3, HUD_H - 8, RGB(130, 120, 105));
    gpu_draw_rect(x + 3, HUD_Y + 4, 2, HUD_H - 8, RGB(50, 42, 35));
}

void draw_hud() {

    gpu_draw_rect(0, HUD_Y, SCREEN_W, HUD_H, RGB(90, 80, 68));
    gpu_draw_rect(0, HUD_Y, SCREEN_W, 4, RGB(160, 145, 125));
    gpu_draw_rect(0, HUD_Y + 4, SCREEN_W, 2, RGB(120, 110, 95));
    gpu_draw_rect(0, SCREEN_H - 3, SCREEN_W, 3, RGB(45, 38, 30));

    draw_hud_divider(310);
    draw_hud_divider(550);
    draw_hud_divider(730);
    draw_hud_divider(960);

    gpu_draw_rect(20, HUD_Y + 12, 280, 96, RGB(50, 42, 35));
    gpu_draw_rect(24, HUD_Y + 16, 272, 88, RGB(35, 28, 22));
    draw_number(40, HUD_Y + 22, 42, 74, player_hp, RGB(220, 30, 30));
    draw_pct(195, HUD_Y + 50, 10, RGB(220, 30, 30));

    gpu_draw_rect(970, HUD_Y + 12, 290, 96, RGB(50, 42, 35));
    gpu_draw_rect(974, HUD_Y + 16, 282, 88, RGB(35, 28, 22));
    draw_number(990, HUD_Y + 22, 42, 74, player_ammo, RGB(220, 200, 40));

    int base_x = 560; 
    int base_y = HUD_Y + 8;
    int cx = base_x + 80; 

    gpu_draw_rect(base_x, base_y, 160, 104, RGB(35, 30, 25));

    int yellow = RGB(245, 215, 45);
    int shadow = RGB(215, 185, 35); 

    gpu_draw_rect(cx - 16, base_y + 10, 32, 2, yellow);  
    gpu_draw_rect(cx - 26, base_y + 12, 52, 4, yellow);
    gpu_draw_rect(cx - 32, base_y + 16, 64, 4, yellow);
    gpu_draw_rect(cx - 36, base_y + 20, 72, 6, yellow);

    gpu_draw_rect(cx - 38, base_y + 26, 76, 54, yellow);

    gpu_draw_rect(cx - 36, base_y + 80, 72, 6, yellow);
    gpu_draw_rect(cx - 32, base_y + 86, 64, 4, yellow);
    gpu_draw_rect(cx - 26, base_y + 90, 52, 4, shadow); 
    gpu_draw_rect(cx - 16, base_y + 94, 32, 4, shadow); 

    int eye_h = 16;
    int eye_y = base_y + 36; 
    int damage_tier = 0;

    if (player_hp <= 60 && player_hp > 30) {
        eye_h = 12; 
        eye_y = base_y + 40; 
        damage_tier = 1;
    } else if (player_hp <= 30) {
        eye_h = 8;  
        eye_y = base_y + 44; 
        damage_tier = 2;
    }

    gpu_draw_rect(cx - 16, eye_y, 8, eye_h, RGB(30, 30, 30));
    gpu_draw_rect(cx + 8,  eye_y, 8, eye_h, RGB(30, 30, 30));

    if (damage_tier == 0) {

        gpu_draw_rect(cx - 20, base_y + 58, 6, 8, RGB(30, 30, 30)); 
        gpu_draw_rect(cx + 14, base_y + 58, 6, 8, RGB(30, 30, 30)); 
        gpu_draw_rect(cx - 14, base_y + 66, 28, 6, RGB(30, 30, 30)); 
    } else if (damage_tier == 1) {

        gpu_draw_rect(cx - 12, base_y + 66, 24, 6, RGB(30, 30, 30));
    } else {

        gpu_draw_rect(cx - 12, base_y + 60, 24, 16, RGB(30, 30, 30)); 
        gpu_draw_rect(cx - 6, base_y + 64, 12, 8, RGB(180, 40, 30));  
    }

    if (damage_tier >= 1) {
        gpu_draw_rect(cx - 32, base_y + 66, 8, 4, RGB(180, 25, 15));
        gpu_draw_rect(cx + 26, base_y + 56, 6, 4, RGB(180, 25, 15));
    }
    if (damage_tier == 2) {
        gpu_draw_rect(cx - 18, base_y + 82, 6, 4, RGB(180, 20, 10));
        gpu_draw_rect(cx + 18, base_y + 78, 8, 6, RGB(180, 20, 10));
        gpu_draw_rect(cx - 4,  base_y + 48, 8, 6, RGB(180, 15, 10)); 
    }

    int kx = 324;
    int ky = HUD_Y + 20;
    for (int i = 0; i < num_enm; i++) {
        int kc = (i < kills) ? RGB(200, 50, 40) : RGB(55, 45, 38);
        gpu_draw_rect(kx + (i % 3) * 50, ky + (i / 3) * 38, 40, 30, kc);
    }
}

void draw_weapon() {
    int gy = (gun_state == 1) ? 370 : 390;
    gpu_draw_rect(626, gy, 28, 70, RGB(95, 88, 80));
    gpu_draw_rect(620, gy + 10, 40, 55, RGB(85, 78, 72));
    gpu_draw_rect(600, gy + 65, 80, 60, RGB(78, 72, 65));
    gpu_draw_rect(595, gy + 120, 90, 12, RGB(68, 62, 55));
    gpu_draw_rect(618, gy + 130, 44, 70, RGB(60, 48, 35));
    gpu_draw_rect(622, gy + 135, 36, 60, RGB(52, 40, 28));
    gpu_draw_rect(636, gy + 80, 4, 30, RGB(50, 45, 40));
    gpu_draw_rect(570, gy + 130, 50, 50, RGB(210, 160, 120));
    gpu_draw_rect(560, gy + 140, 22, 40, RGB(200, 150, 110));
    gpu_draw_rect(612, gy + 135, 10, 45, RGB(210, 160, 120));
    gpu_draw_rect(658, gy + 140, 10, 40, RGB(200, 150, 110));
    gpu_draw_rect(668, gy + 145, 18, 35, RGB(195, 145, 105));
    gpu_draw_rect(555, gy + 170, 135, 40, RGB(210, 160, 120));
    gpu_draw_rect(540, gy + 180, 30, 30, RGB(200, 150, 110));
    if (gun_state == 1) {
        gpu_draw_rect(605, gy - 40, 70, 45, RGB(255, 240, 90));
        gpu_draw_rect(615, gy - 65, 50, 30, RGB(255, 200, 50));
        gpu_draw_rect(625, gy - 80, 30, 20, RGB(255, 160, 30));
    }
}

void render_walls() {
    int hfix = fix_from_int(VIEW_H);
    for (int col = 0; col < NUM_COLS; col++) {
        int ra = pa + col_off[col];
        if (ra < 0) ra += PI_2;
        else if (ra >= PI_2) ra -= PI_2;
        int rc = fix_cos(ra);
        int rs = fix_sin(ra);
        int mx = fix_to_int(px);
        int my = fix_to_int(py);
        int ddx = (rc == 0) ? 2147483647 : ABS(fix_div(FIXPOINT_ONE, rc));
        int ddy = (rs == 0) ? 2147483647 : ABS(fix_div(FIXPOINT_ONE, rs));
        int sx, sy, sdx, sdy;
        if (rc < 0) { sx = -1; sdx = fix_mul(px - fix_from_int(mx), ddx); }
        else { sx = 1; sdx = fix_mul(fix_from_int(mx + 1) - px, ddx); }
        if (rs < 0) { sy = -1; sdy = fix_mul(py - fix_from_int(my), ddy); }
        else { sy = 1; sdy = fix_mul(fix_from_int(my + 1) - py, ddy); }
        int hit = 0;
        int side = 0;
        int d = 0;
        while (!hit && d < MAX_DEPTH) {
            if (sdx < sdy) { sdx += ddx; mx += sx; side = 0; }
            else { sdy += ddy; my += sy; side = 1; }
            if (mx >= 0 && mx < MAP_W && my >= 0 && my < MAP_H) {
                if (map[my * MAP_W + mx]) hit = 1;
            } else { hit = 1; }
            d++;
        }
        int pwd = (side == 0) ? (sdx - ddx) : (sdy - ddy);
        pwd = fix_mul(pwd, fish_cos[col]);
        if (pwd <= 0) pwd = 1;
        zbuf[col] = pwd;
        int lh = hfix / pwd;
        int ds = HALF_VH - lh / 2;
        int de = HALF_VH + lh / 2;
        if (ds < 0) ds = 0;
        if (de >= VIEW_H) de = VIEW_H - 1;
        int wt = 0;
        if (mx >= 0 && mx < MAP_W && my >= 0 && my < MAP_H)
            wt = map[my * MAP_W + mx];
        int bc = wall_colors[wt];
        int di = fix_to_int(pwd);
        if (di > 10) di = 10;
        int it = 255 - (di * 22);
        if (it < 20) it = 20;
        if (side) it = (it * 3) / 4;
        int r = ((bc >> 16) & 0xFF) * it / 255;
        int g = ((bc >> 8) & 0xFF) * it / 255;
        int b = (bc & 0xFF) * it / 255;
        if (de > ds)
            gpu_draw_rect(col * RENDER_SCALE, ds, RENDER_SCALE, de - ds, RGB(r, g, b));
    }
}

void render_items() {
    int hfix = fix_from_int(VIEW_H);
    for (int i = 0; i < num_items; i++) {
        if (!item_active[i]) continue;
        int dx = item_x[i] - px;
        int dy = item_y[i] - py;
        int depth = fix_mul(dx, cos_pa) + fix_mul(dy, sin_pa);
        if (depth <= 0) continue;
        int angle = fix_atan2(dy, dx);
        int rel = angle - pa;
        if (rel > PI_2 / 2) rel -= PI_2;
        if (rel < -(PI_2 / 2)) rel += PI_2;
        int hfov = FOV / 2;
        if (rel < -hfov || rel > hfov) continue;
        int scr_x = SCREEN_W / 2 + (rel * SCREEN_W) / FOV;
        int sh = (hfix / depth) / 3;
        int sw = sh;
        if (sw < 4) { sw = 4; sh = 4; }
        int col = scr_x / RENDER_SCALE;
        if (col < 0 || col >= NUM_COLS) continue;
        if (depth >= zbuf[col]) continue;
        int sx = scr_x - sw / 2;
        int sy = HALF_VH + sh / 4;
        if (item_type[i] == 0) {
            gpu_draw_rect(sx + sw / 3, sy, sw / 3, sh, RGB(50, 80, 220));
            gpu_draw_rect(sx, sy + sh / 3, sw, sh / 3, RGB(50, 80, 220));
        } else {
            gpu_draw_rect(sx, sy, sw, sh, RGB(200, 170, 30));
            gpu_draw_rect(sx + 2, sy + 2, sw - 4, sh - 4, RGB(160, 130, 20));
        }
    }
}

void render_enemies() {
    int order[8];
    int dists[8];
    int count = 0;
    int hfix = fix_from_int(VIEW_H);
    for (int i = 0; i < num_enm; i++) {
        if (enm_state[i] == 3) continue;
        int dx = enm_x[i] - px;
        int dy = enm_y[i] - py;
        int d = fix_mul(dx, cos_pa) + fix_mul(dy, sin_pa);
        if (d <= 0) continue;
        dists[count] = d;
        order[count] = i;
        count++;
    }
    for (int i = 1; i < count; i++) {
        for (int j = i; j > 0 && dists[j] > dists[j-1]; j--) {
            int t = dists[j]; dists[j] = dists[j-1]; dists[j-1] = t;
            t = order[j]; order[j] = order[j-1]; order[j-1] = t;
        }
    }
    for (int i = 0; i < count; i++) {
        int ei = order[i];
        int dx = enm_x[ei] - px;
        int dy = enm_y[ei] - py;
        int depth = dists[i];
        int angle = fix_atan2(dy, dx);
        int rel = angle - pa;
        if (rel > PI_2 / 2) rel -= PI_2;
        if (rel < -(PI_2 / 2)) rel += PI_2;
        int hfov = FOV / 2;
        if (rel < -hfov || rel > hfov) continue;
        int scr_x = SCREEN_W / 2 + (rel * SCREEN_W) / FOV;
        int sh = (hfix / depth) * 3 / 4;
        int sw = sh / 2;
        if (sw < 4) sw = 4;
        int col = scr_x / RENDER_SCALE;
        if (col < 0 || col >= NUM_COLS) continue;
        if (depth >= zbuf[col]) continue;
        int sx = scr_x - sw / 2;
        int sy = HALF_VH - sh / 2 + sh / 8;
        int bc = enm_colors[enm_type[ei]];
        if (enm_state[ei] == 4) bc = RGB(255, 255, 255);
        int di = fix_to_int(depth);
        if (di > 10) di = 10;
        int it = 255 - (di * 22);
        if (it < 30) it = 30;
        int r = ((bc >> 16) & 0xFF) * it / 255;
        int g = ((bc >> 8) & 0xFF) * it / 255;
        int b = (bc & 0xFF) * it / 255;
        gpu_draw_rect(sx, sy, sw, sh, RGB(r, g, b));
        if (sw > 8) {
            int esz = sw / 6;
            if (esz < 2) esz = 2;
            gpu_draw_rect(sx + sw/3, sy + sh/8, esz, esz, RGB(255, 50, 50));
            gpu_draw_rect(sx + sw*2/3 - esz, sy + sh/8, esz, esz, RGB(255, 50, 50));
        }
    }
}

void draw_text_mini(int sx, int sy, int size, int c, const char* str) {
    int i = 0;
    int x = sx;
    while(str[i] != '\0') {
        int mask = 0;
        char ch = str[i];

        if (ch == 'A') mask = 11245;
        else if (ch == 'E') mask = 31143;
		else if (ch == 'K') mask = 23861;
        else if (ch == 'N') mask = 31597;
        else if (ch == 'O') mask = 11114;
        else if (ch == 'P') mask = 27556;
        else if (ch == 'R') mask = 27565;
        else if (ch == 'S') mask = 31183;
        else if (ch == 'T') mask = 29842;
        else if (ch == 'Y') mask = 23186;

        if (mask != 0) {
            for (int row = 0; row < 5; row++) {
                for (int col = 0; col < 3; col++) {
                    int bit = 14 - (row * 3 + col);
                    if ((mask >> bit) & 1) {
                        gpu_draw_rect(x + col * size, sy + row * size, size, size, c);
                    }
                }
            }
        }
        x += 4 * size; 
        i++;
    }
}

void draw_title() {

    gpu_draw_rect(0, 0, SCREEN_W, SCREEN_H, RGB(20, 10, 5));

    gpu_draw_rect(0, 160, SCREEN_W, 180, RGB(60, 20, 10));
    gpu_draw_rect(0, 160, SCREEN_W, 4, RGB(120, 50, 20));
    gpu_draw_rect(0, 336, SCREEN_W, 4, RGB(120, 50, 20));

    for (int layer = 0; layer < 2; layer++) {

        int dx = (layer == 0) ? 8 : 0;
        int dy = (layer == 0) ? 8 : 0;
        int c  = (layer == 0) ? RGB(20, 5, 0) : RGB(220, 40, 20);

        gpu_draw_rect(390 + dx, 180 + dy, 30, 140, c); 
        gpu_draw_rect(420 + dx, 180 + dy, 30, 30, c);  
        gpu_draw_rect(420 + dx, 290 + dy, 30, 30, c);  
        gpu_draw_rect(450 + dx, 210 + dy, 30, 80, c);  

        gpu_draw_rect(510 + dx, 180 + dy, 30, 140, c); 
        gpu_draw_rect(570 + dx, 180 + dy, 30, 140, c); 
        gpu_draw_rect(540 + dx, 180 + dy, 30, 30, c);  
        gpu_draw_rect(540 + dx, 290 + dy, 30, 30, c);  

        gpu_draw_rect(630 + dx, 180 + dy, 30, 140, c); 
        gpu_draw_rect(690 + dx, 180 + dy, 30, 140, c); 
        gpu_draw_rect(660 + dx, 180 + dy, 30, 30, c);  
        gpu_draw_rect(660 + dx, 290 + dy, 30, 30, c);  

        gpu_draw_rect(750 + dx, 180 + dy, 30, 140, c);
        gpu_draw_rect(860 + dx, 180 + dy, 30, 140, c);
        gpu_draw_rect(780 + dx, 195 + dy, 25, 60, c);
        gpu_draw_rect(835 + dx, 195 + dy, 25, 60, c);
        gpu_draw_rect(805 + dx, 210 + dy, 30, 80, c);
    }

    gpu_draw_rect(200, 400, 880, 60, RGB(40, 15, 8));
    gpu_draw_rect(210, 410, 860, 40, RGB(70, 30, 15));

    gpu_draw_rect(440, 415, 400, 30, RGB(35, 10, 5)); 

    draw_text_mini(464, 420, 4, RGB(255, 230, 80), "PRESS ANY KEY TO START");

    gpu_draw_rect(100, 550, 1080, 3, RGB(80, 30, 15));
    gpu_draw_rect(100, 560, 1080, 3, RGB(60, 20, 10));
}

void draw_death() {
    gpu_draw_rect(0, 0, SCREEN_W, SCREEN_H, RGB(80, 5, 5));
    gpu_draw_rect(0, 200, SCREEN_W, 200, RGB(120, 10, 10));
    gpu_draw_rect(0, 200, SCREEN_W, 3, RGB(180, 30, 20));
    gpu_draw_rect(0, 397, SCREEN_W, 3, RGB(180, 30, 20));
    gpu_draw_rect(440, 230, 80, 60, RGB(200, 30, 25));
    gpu_draw_rect(460, 245, 40, 30, RGB(80, 5, 5));
    gpu_draw_rect(700, 230, 80, 60, RGB(200, 30, 25));
    gpu_draw_rect(720, 245, 40, 30, RGB(80, 5, 5));
    gpu_draw_rect(500, 340, 220, 30, RGB(200, 30, 25));
    gpu_draw_rect(520, 350, 180, 10, RGB(80, 5, 5));
    gpu_draw_rect(440, 490, 400, 50, RGB(50, 8, 8));
    gpu_draw_rect(450, 500, 380, 30, RGB(100, 20, 15));
}

void draw_win() {
    gpu_draw_rect(0, 0, SCREEN_W, SCREEN_H, RGB(10, 25, 10));
    gpu_draw_rect(0, 180, SCREEN_W, 160, RGB(15, 60, 15));
    gpu_draw_rect(0, 180, SCREEN_W, 3, RGB(30, 120, 30));
    gpu_draw_rect(0, 337, SCREEN_W, 3, RGB(30, 120, 30));
    draw_number(460, 210, 50, 100, kills, RGB(40, 200, 40));
    gpu_draw_rect(590, 240, 30, 40, RGB(30, 150, 30));
    gpu_draw_rect(620, 210, 30, 100, RGB(30, 150, 30));
    draw_number(700, 210, 50, 100, num_enm, RGB(40, 200, 40));
    draw_number(480, 400, 40, 70, player_hp, RGB(200, 50, 40));
    draw_pct(600, 420, 8, RGB(200, 50, 40));
    gpu_draw_rect(440, 530, 400, 50, RGB(15, 50, 15));
    gpu_draw_rect(450, 540, 380, 30, RGB(30, 100, 30));
}

int main() {
    app_window(SCREEN_W, SCREEN_H);
    app_set_title("DOOM");
    init();
    reset_game();
    int frame = 0;

    while (1) {
        if (game_state == ST_TITLE) {
            gpu_batch_begin();
            draw_title();
            gpu_batch_flush();
            flush();
            getkey();
            game_state = ST_PLAY;
        } else if (game_state == ST_DEAD) {
            gpu_batch_begin();
            draw_death();
            gpu_batch_flush();
            flush();
            getkey();
            reset_game();
            game_state = ST_TITLE;
        } else if (game_state == ST_WIN) {
            gpu_batch_begin();
            draw_win();
            gpu_batch_flush();
            flush();
            getkey();
            reset_game();
            game_state = ST_TITLE;
        } else {
            cos_pa = fix_cos(pa);
            sin_pa = fix_sin(pa);
            gpu_batch_begin();
            gpu_draw_rect(0, 0, SCREEN_W, HALF_VH, RGB(30, 25, 20));
            gpu_draw_rect(0, HALF_VH, SCREEN_W, HALF_VH, RGB(68, 52, 36));
            render_walls();
            render_items();
            render_enemies();
            draw_weapon();
            draw_hud();
            gpu_draw_rect(638, HALF_VH - 2, 4, 4, RGB(255, 255, 0));
            gpu_batch_flush();
            flush();
            vsync(30);

            check_pickups();
            if ((frame & 1) == 0) update_enemies();
            frame++;

            if (player_hp <= 0) { game_state = ST_DEAD; continue; }
            if (kills >= num_enm) { game_state = ST_WIN; continue; }

            if (gun_state == 1) { gun_state = 2; gun_timer = 4; }
            else if (gun_state == 2) { gun_timer--; if (gun_timer <= 0) gun_state = 0; }

            int move_fwd = key_down(119) || key_down(KEY_UP);
            int move_back = key_down(115) || key_down(KEY_DOWN);
            int turn_left = key_down(97) || key_down(KEY_LEFT);
            int turn_right = key_down(100) || key_down(KEY_RIGHT);

            if (move_fwd == move_back) {
                if (move_vel > 0) {
                    move_vel -= MOVE_FRICTION;
                    if (move_vel < 0) move_vel = 0;
                } else if (move_vel < 0) {
                    move_vel += MOVE_FRICTION;
                    if (move_vel > 0) move_vel = 0;
                }
            } else if (move_fwd) {
                move_vel += MOVE_ACCEL;
                if (move_vel > MOVE_MAX) move_vel = MOVE_MAX;
            } else {
                move_vel -= MOVE_ACCEL;
                if (move_vel < -MOVE_MAX) move_vel = -MOVE_MAX;
            }

            if (turn_left == turn_right) {
                if (turn_vel > 0) {
                    turn_vel -= TURN_FRICTION;
                    if (turn_vel < 0) turn_vel = 0;
                } else if (turn_vel < 0) {
                    turn_vel += TURN_FRICTION;
                    if (turn_vel > 0) turn_vel = 0;
                }
            } else if (turn_left) {
                turn_vel -= TURN_ACCEL;
                if (turn_vel < -TURN_MAX) turn_vel = -TURN_MAX;
            } else {
                turn_vel += TURN_ACCEL;
                if (turn_vel > TURN_MAX) turn_vel = TURN_MAX;
            }

            if (turn_vel != 0) {
                pa += turn_vel;
                if (pa < 0) pa += PI_2;
                else if (pa >= PI_2) pa -= PI_2;
            }

            if (move_vel != 0) {
                int mvx = fix_mul(cos_pa, move_vel);
                int mvy = fix_mul(sin_pa, move_vel);
                if (map[fix_to_int(py) * MAP_W + fix_to_int(px + mvx)] == 0) px += mvx;
                if (map[fix_to_int(py + mvy) * MAP_W + fix_to_int(px)] == 0) py += mvy;
            }

            if (key_pressed(101)) { try_door(); }
            if (key_pressed(KEY_SPACE)) { shoot(); }
        }
    }
    return 0;
}
]===]

return doom_c