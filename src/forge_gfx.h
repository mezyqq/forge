// Графика для скриптов Forge: холст, на котором рисуют Python (_gfx → pygame) и Lua (gfx → love).
// Рисует поток запуска (Runner), кадры уходят в интерфейс через колбэк, касания и кнопки приходят обратно очередью.
#ifndef FORGE_GFX_H
#define FORGE_GFX_H

#include <CoreGraphics/CoreGraphics.h>

// События (forge_gfx_poll): тип и поля.
enum { GFX_NONE = 0, GFX_DOWN = 1, GFX_UP = 2, GFX_MOVE = 3, GFX_KEYDOWN = 4, GFX_KEYUP = 5, GFX_QUIT = 6 };
// Кнопки экранного пульта: влево, вправо, вверх, вниз, пробел, ввод, escape.
enum { GFX_KEY_LEFT = 1, GFX_KEY_RIGHT, GFX_KEY_UP, GFX_KEY_DOWN, GFX_KEY_SPACE, GFX_KEY_RETURN, GFX_KEY_ESCAPE };

// Интерфейс: получает готовый кадр (CGImage живёт только внутри вызова — сохранить через CGImageRetain).
// Вызывается с потока запуска; следующий кадр не придёт, пока не вызван forge_gfx_frame_consumed().
typedef void (*forge_gfx_present_fn)(CGImageRef frame, int width, int height);
void forge_gfx_set_presenter(forge_gfx_present_fn fn);
void forge_gfx_frame_consumed(void);
// Касание/кнопка из интерфейса (координаты — в пикселях холста).
void forge_gfx_push(int type, float x, float y, int key);
// Перед каждым запуском: закрыть холст, очистить события.
void forge_gfx_reset(void);

// API для движков (поток запуска)
void forge_gfx_open(int w, int h);
int forge_gfx_width(void);
int forge_gfx_height(void);
void forge_gfx_color(double r, double g, double b, double a);  // 0…255
void forge_gfx_clear(void);
void forge_gfx_rect(double x, double y, double w, double h, double line);  // line 0 — заливка
void forge_gfx_ellipse(double x, double y, double w, double h, double line);
void forge_gfx_line(double x1, double y1, double x2, double y2, double width);
void forge_gfx_poly(const double *xy, int n, double line);  // n точек
void forge_gfx_text(const char *s, double x, double y, double size);  // x, y — левый верхний угол
double forge_gfx_measure(const char *s, double size);
int forge_gfx_image_load(const char *path);  // -1 — не загрузилось
int forge_gfx_image_w(int img);
int forge_gfx_image_h(int img);
void forge_gfx_image_draw(int img, double x, double y, double w, double h);  // w, h <= 0 — свой размер
void forge_gfx_present(void);
int forge_gfx_poll(double *x, double *y, int *key);  // GFX_NONE, если событий нет
double forge_gfx_ticks(void);  // мс с открытия холста
void forge_gfx_sleep(double ms);  // прерывается «Стоп»

// Регистрация в движках (вызывают forge_engines.c)
void forge_gfx_register_python(void);
struct lua_State;
void forge_gfx_register_lua(struct lua_State *L);

#endif
