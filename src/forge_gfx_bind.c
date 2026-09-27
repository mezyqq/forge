// Привязки графики к движкам: модуль _gfx для pocketpy и таблица gfx для Lua. Только вызовы forge_gfx_* —
// поэтому собираются и на Linux (с заглушкой ядра) для проверки pygame и love.
#include "forge_gfx.h"

#include "engines/lua/lauxlib.h"
#include "engines/lua/lua.h"
#include "engines/pocketpy/pocketpy.h"

// MARK: Python (_gfx)

static double argf(py_StackRef argv, int i) {
	py_f64 v = 0;
	if (!py_castfloat(py_arg(i), &v)) { py_clearexc(NULL); v = 0; }
	return v;
}

#define PYF(name, body)                                  \
	static bool py_gfx_##name(int argc, py_StackRef argv) { \
		(void)argc;                                        \
		body;                                              \
		return true;                                       \
	}

PYF(open, { forge_gfx_open((int)argf(argv, 0), (int)argf(argv, 1)); py_newnone(py_retval()); })
PYF(width, py_newint(py_retval(), forge_gfx_width()))
PYF(height, py_newint(py_retval(), forge_gfx_height()))
PYF(color, { forge_gfx_color(argf(argv, 0), argf(argv, 1), argf(argv, 2), argc > 3 ? argf(argv, 3) : 255); py_newnone(py_retval()); })
PYF(clear, { forge_gfx_clear(); py_newnone(py_retval()); })
PYF(rect, { forge_gfx_rect(argf(argv, 0), argf(argv, 1), argf(argv, 2), argf(argv, 3), argc > 4 ? argf(argv, 4) : 0); py_newnone(py_retval()); })
PYF(ellipse, { forge_gfx_ellipse(argf(argv, 0), argf(argv, 1), argf(argv, 2), argf(argv, 3), argc > 4 ? argf(argv, 4) : 0); py_newnone(py_retval()); })
PYF(line, { forge_gfx_line(argf(argv, 0), argf(argv, 1), argf(argv, 2), argf(argv, 3), argc > 4 ? argf(argv, 4) : 1); py_newnone(py_retval()); })
PYF(text, { forge_gfx_text(py_isstr(py_arg(0)) ? py_tostr(py_arg(0)) : "", argf(argv, 1), argf(argv, 2), argf(argv, 3)); py_newnone(py_retval()); })
PYF(measure, py_newfloat(py_retval(), forge_gfx_measure(py_isstr(py_arg(0)) ? py_tostr(py_arg(0)) : "", argf(argv, 1))))
PYF(image_load, py_newint(py_retval(), py_isstr(py_arg(0)) ? forge_gfx_image_load(py_tostr(py_arg(0))) : -1))
PYF(image_w, py_newint(py_retval(), forge_gfx_image_w((int)argf(argv, 0))))
PYF(image_h, py_newint(py_retval(), forge_gfx_image_h((int)argf(argv, 0))))
PYF(image_draw, { forge_gfx_image_draw((int)argf(argv, 0), argf(argv, 1), argf(argv, 2), argc > 3 ? argf(argv, 3) : 0, argc > 4 ? argf(argv, 4) : 0); py_newnone(py_retval()); })
PYF(present, { forge_gfx_present(); py_newnone(py_retval()); })
PYF(ticks, py_newfloat(py_retval(), forge_gfx_ticks()))
PYF(sleep, { forge_gfx_sleep(argf(argv, 0)); py_newnone(py_retval()); })

// poly(список x, y, x, y…, толщина)
static bool py_gfx_poly(int argc, py_StackRef argv) {
	double xy[512];
	int n = 0;
	py_Ref list = py_arg(0);
	int len = py_islist(list) ? py_list_len(list) : 0;
	for (int i = 0; i < len && n < 512; i++) {
		py_f64 v = 0;
		if (!py_castfloat(py_list_getitem(list, i), &v)) { py_clearexc(NULL); v = 0; }
		xy[n++] = v;
	}
	forge_gfx_poly(xy, n / 2, argc > 1 ? argf(argv, 1) : 0);
	py_newnone(py_retval());
	return true;
}

// poll() → [тип, x, y, кнопка] или None
static bool py_gfx_poll(int argc, py_StackRef argv) {
	(void)argc, (void)argv;
	double x = 0, y = 0;
	int key = 0;
	int t = forge_gfx_poll(&x, &y, &key);
	if (t == GFX_NONE) {
		py_newnone(py_retval());
		return true;
	}
	py_newlistn(py_retval(), 4);
	py_newint(py_list_getitem(py_retval(), 0), t);
	py_newfloat(py_list_getitem(py_retval(), 1), x);
	py_newfloat(py_list_getitem(py_retval(), 2), y);
	py_newint(py_list_getitem(py_retval(), 3), key);
	return true;
}

void forge_gfx_register_python(void) {
	py_GlobalRef m = py_getmodule("_gfx");
	if (!m) m = py_newmodule("_gfx");
	py_bindfunc(m, "open", py_gfx_open);
	py_bindfunc(m, "width", py_gfx_width);
	py_bindfunc(m, "height", py_gfx_height);
	py_bindfunc(m, "color", py_gfx_color);
	py_bindfunc(m, "clear", py_gfx_clear);
	py_bindfunc(m, "rect", py_gfx_rect);
	py_bindfunc(m, "ellipse", py_gfx_ellipse);
	py_bindfunc(m, "line", py_gfx_line);
	py_bindfunc(m, "poly", py_gfx_poly);
	py_bindfunc(m, "text", py_gfx_text);
	py_bindfunc(m, "measure", py_gfx_measure);
	py_bindfunc(m, "image_load", py_gfx_image_load);
	py_bindfunc(m, "image_w", py_gfx_image_w);
	py_bindfunc(m, "image_h", py_gfx_image_h);
	py_bindfunc(m, "image_draw", py_gfx_image_draw);
	py_bindfunc(m, "present", py_gfx_present);
	py_bindfunc(m, "poll", py_gfx_poll);
	py_bindfunc(m, "ticks", py_gfx_ticks);
	py_bindfunc(m, "sleep", py_gfx_sleep);
}

// MARK: Lua (gfx)

static int l_open(lua_State *L) { forge_gfx_open((int)luaL_optinteger(L, 1, 800), (int)luaL_optinteger(L, 2, 600)); return 0; }
static int l_width(lua_State *L) { lua_pushinteger(L, forge_gfx_width()); return 1; }
static int l_height(lua_State *L) { lua_pushinteger(L, forge_gfx_height()); return 1; }
static int l_color(lua_State *L) {
	forge_gfx_color(luaL_optnumber(L, 1, 255), luaL_optnumber(L, 2, 255), luaL_optnumber(L, 3, 255), luaL_optnumber(L, 4, 255));
	return 0;
}
static int l_clear(lua_State *L) { (void)L; forge_gfx_clear(); return 0; }
static int l_rect(lua_State *L) {
	forge_gfx_rect(luaL_checknumber(L, 1), luaL_checknumber(L, 2), luaL_checknumber(L, 3), luaL_checknumber(L, 4), luaL_optnumber(L, 5, 0));
	return 0;
}
static int l_ellipse(lua_State *L) {
	forge_gfx_ellipse(luaL_checknumber(L, 1), luaL_checknumber(L, 2), luaL_checknumber(L, 3), luaL_checknumber(L, 4), luaL_optnumber(L, 5, 0));
	return 0;
}
static int l_line(lua_State *L) {
	forge_gfx_line(luaL_checknumber(L, 1), luaL_checknumber(L, 2), luaL_checknumber(L, 3), luaL_checknumber(L, 4), luaL_optnumber(L, 5, 1));
	return 0;
}
static int l_poly(lua_State *L) {
	luaL_checktype(L, 1, LUA_TTABLE);
	double xy[512];
	int n = (int)luaL_len(L, 1);
	if (n > 512) n = 512;
	for (int i = 0; i < n; i++) {
		lua_geti(L, 1, i + 1);
		xy[i] = lua_tonumber(L, -1);
		lua_pop(L, 1);
	}
	forge_gfx_poly(xy, n / 2, luaL_optnumber(L, 2, 0));
	return 0;
}
static int l_text(lua_State *L) {
	forge_gfx_text(luaL_tolstring(L, 1, NULL), luaL_optnumber(L, 2, 0), luaL_optnumber(L, 3, 0), luaL_optnumber(L, 4, 16));
	return 0;
}
static int l_measure(lua_State *L) { lua_pushnumber(L, forge_gfx_measure(luaL_tolstring(L, 1, NULL), luaL_optnumber(L, 2, 16))); return 1; }
static int l_image_load(lua_State *L) { lua_pushinteger(L, forge_gfx_image_load(luaL_checkstring(L, 1))); return 1; }
static int l_image_w(lua_State *L) { lua_pushinteger(L, forge_gfx_image_w((int)luaL_checkinteger(L, 1))); return 1; }
static int l_image_h(lua_State *L) { lua_pushinteger(L, forge_gfx_image_h((int)luaL_checkinteger(L, 1))); return 1; }
static int l_image_draw(lua_State *L) {
	forge_gfx_image_draw((int)luaL_checkinteger(L, 1), luaL_optnumber(L, 2, 0), luaL_optnumber(L, 3, 0), luaL_optnumber(L, 4, 0), luaL_optnumber(L, 5, 0));
	return 0;
}
static int l_present(lua_State *L) { (void)L; forge_gfx_present(); return 0; }
static int l_poll(lua_State *L) {
	double x = 0, y = 0;
	int key = 0, t = forge_gfx_poll(&x, &y, &key);
	if (t == GFX_NONE) return 0;
	lua_pushinteger(L, t);
	lua_pushnumber(L, x);
	lua_pushnumber(L, y);
	lua_pushinteger(L, key);
	return 4;
}
static int l_ticks(lua_State *L) { lua_pushnumber(L, forge_gfx_ticks()); return 1; }
static int l_sleep(lua_State *L) { forge_gfx_sleep(luaL_checknumber(L, 1)); return 0; }

void forge_gfx_register_lua(struct lua_State *L) {
	static const luaL_Reg fns[] = {
		{"open", l_open}, {"width", l_width}, {"height", l_height}, {"color", l_color}, {"clear", l_clear},
		{"rect", l_rect}, {"ellipse", l_ellipse}, {"line", l_line}, {"poly", l_poly}, {"text", l_text},
		{"measure", l_measure}, {"image_load", l_image_load}, {"image_w", l_image_w}, {"image_h", l_image_h},
		{"image_draw", l_image_draw}, {"present", l_present}, {"poll", l_poll}, {"ticks", l_ticks}, {"sleep", l_sleep},
		{NULL, NULL}};
	luaL_newlib(L, fns);
	lua_setglobal(L, "gfx");
}
