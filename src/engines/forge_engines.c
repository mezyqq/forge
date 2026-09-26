#include "forge_engines.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pocketpy/pocketpy.h"
#include "lua/lua.h"
#include "lua/lauxlib.h"
#include "lua/lualib.h"
#include "picoc/picoc.h"

volatile int forge_stop_flag = 0;  // читают Lua-хук и парсер picoc (patched parse.c)
static volatile int py_running = 0;
static volatile int c_running = 0;
static int py_inited = 0;

// пакеты проекта: import ищет сначала как обычно (папка скрипта), потом в py_modules/
static char *py_dirs = NULL, *lua_path_extra = NULL;

void forge_set_module_paths(const char *python_dirs, const char *lua_path) {
	free(py_dirs);
	free(lua_path_extra);
	py_dirs = python_dirs && *python_dirs ? strdup(python_dirs) : NULL;
	lua_path_extra = lua_path && *lua_path ? strdup(lua_path) : NULL;
}

static char *read_file(const char *path);

static char *forge_importfile(const char *path, int *size) {
	char *data = read_file(path);  // сначала как обычно — относительно папки скрипта
	if (!data && py_dirs && path[0] != '/') {
		char dir[1024], full[2048];
		const char *p = py_dirs;
		while (*p && !data) {
			const char *e = strchr(p, ':');
			size_t n = e ? (size_t)(e - p) : strlen(p);
			if (n > 0 && n < sizeof dir) {
				memcpy(dir, p, n);
				dir[n] = 0;
				snprintf(full, sizeof full, "%s/%s", dir, path);
				data = read_file(full);
			}
			p = e ? e + 1 : p + n;
		}
	}
	if (data && size) *size = (int)strlen(data);
	return data;
}

static void py_ensure(void) {
	if (!py_inited) {
		py_initialize();
		py_callbacks()->importfile = forge_importfile;
		py_inited = 1;
	}
}

void forge_request_stop(void) {
	forge_stop_flag = 1;
	// pocketpy сверяет дедлайн watchdog в цикле байткода — дедлайн «сейчас» даёт TimeoutError
	if (py_running) py_watchdog_begin(0);
}

// ---------------------------------------------------------------- Python

static char *read_file(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *buf = malloc(n + 1);
	if (buf && fread(buf, 1, n, f) != (size_t)n) { free(buf); buf = NULL; }
	if (buf) buf[n] = 0;
	fclose(f);
	return buf;
}

int forge_run_python(const char *path) {
	if (!py_inited) py_ensure(); else py_resetvm();
	py_callbacks()->importfile = forge_importfile;  // resetvm возвращает колбэки по умолчанию
	char *src = read_file(path);
	if (!src) { fprintf(stderr, "could not read %s\n", path); return 1; }
	forge_stop_flag = 0;
	py_watchdog_end();
	py_running = 1;
	bool ok = py_exec(src, path, EXEC_MODE, NULL);
	py_running = 0;
	py_watchdog_end();
	if (!ok) py_printexc();
	free(src);
	fflush(stdout);
	return ok ? 0 : 1;
}

// ---------------------------------------------------------------- Lua

static void lua_stop_hook(lua_State *L, lua_Debug *ar) {
	(void)ar;
	if (forge_stop_flag) luaL_error(L, "stopped");
}

int forge_run_lua(const char *path) {
	forge_stop_flag = 0;
	lua_State *L = luaL_newstate();
	luaL_openlibs(L);
	lua_sethook(L, lua_stop_hook, LUA_MASKCOUNT, 1000);
	if (lua_path_extra) {
		// пакеты проекта (lua_modules/) — перед стандартными путями
		lua_getglobal(L, "package");
		lua_getfield(L, -1, "path");
		lua_pushfstring(L, "%s;%s", lua_path_extra, lua_tostring(L, -1));
		lua_setfield(L, -3, "path");
		lua_pop(L, 2);
	}
	int r = luaL_dofile(L, path);
	if (r != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
	lua_close(L);
	fflush(stdout);
	return r;
}

// ---------------------------------------------------------------- C (picoc)

int forge_run_c(const char *path) {
	forge_stop_flag = 0;
	c_running = 1;
	static Picoc pc;  // структура большая — не на стеке фонового потока
	char *argv[] = { (char *)path, NULL };
	PicocInitialize(&pc, 512 * 1024);
	if (PicocPlatformSetExitPoint(&pc)) {
		PicocCleanup(&pc);
		fflush(stdout);
		c_running = 0;
		return pc.PicocExitValue;
	}
	PicocPlatformScanFile(&pc, path);
	PicocCallMain(&pc, 1, argv);
	PicocCleanup(&pc);
	fflush(stdout);
	c_running = 0;
	return pc.PicocExitValue;
}

// ---------------------------------------------------------------- проверка синтаксиса

char *forge_check_python(const char *source, const char *filename) {
	if (py_running) return NULL;
	py_ensure();
	if (py_compile(source, filename, EXEC_MODE, false)) return NULL;
	char *msg = py_formatexc();
	py_clearexc(NULL);
	return msg;
}

char *forge_check_lua(const char *source, const char *filename) {
	lua_State *L = luaL_newstate();
	if (!L) return NULL;
	char name[512];
	snprintf(name, sizeof name, "@%s", filename);
	char *res = NULL;
	if (luaL_loadbuffer(L, source, strlen(source), name) != LUA_OK) {
		const char *m = lua_tostring(L, -1);
		res = strdup(m ? m : "syntax error");
	}
	lua_close(L);
	return res;
}

char *forge_check_c(const char *source, const char *filename) {
	if (c_running) return NULL;
	forge_stop_flag = 0;
	Picoc *pc = calloc(1, sizeof(Picoc));
	char *buf = NULL;
	size_t len = 0;
	FILE *mem = open_memstream(&buf, &len);
	char *src = strdup(source);
	if (!pc || !mem || !src) { free(pc); free(src); if (mem) fclose(mem); free(buf); return NULL; }
	PicocInitialize(pc, 256 * 1024);
	pc->CStdOut = mem;  // ошибки парсера пишутся сюда, а не в консоль
	volatile int failed = 0;
	if (PicocPlatformSetExitPoint(pc) == 0) {
		PicocParse(pc, filename, src, (int)strlen(src), false, false, false, false);  // только разбор, без запуска
	} else {
		failed = 1;
	}
	PicocCleanup(pc);
	fclose(mem);
	free(src);
	free(pc);
	if (failed && buf && buf[0]) return buf;
	free(buf);
	return NULL;
}

// ---------------------------------------------------------------- rockspec (LuaRocks)

typedef struct { char *s; size_t n, cap; } rs_buf;

static void rs_put(rs_buf *b, const char *s) {
	size_t k = strlen(s);
	if (b->n + k + 1 > b->cap) {
		b->cap = (b->n + k + 1) * 2;
		b->s = realloc(b->s, b->cap);
	}
	memcpy(b->s + b->n, s, k + 1);
	b->n += k;
}

static void rs_add(rs_buf *b, const char *key, const char *value) {
	if (!value) return;
	rs_put(b, key);
	rs_put(b, "\t");
	rs_put(b, value);
	rs_put(b, "\n");
}

static const char *rs_field(lua_State *L, int t, const char *k) {
	lua_getfield(L, t, k);
	const char *s = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : NULL;
	lua_pop(L, 1);  // строка остаётся жить в таблице
	return s;
}

char *forge_parse_rockspec(const char *text, char **error) {
	*error = NULL;
	lua_State *L = luaL_newstate();
	// песочница: только базовые библиотеки, без io/os/package
	luaL_requiref(L, "_G", luaopen_base, 1);
	luaL_requiref(L, "string", luaopen_string, 1);
	luaL_requiref(L, "table", luaopen_table, 1);
	lua_settop(L, 0);
	lua_sethook(L, lua_stop_hook, LUA_MASKCOUNT, 100000);
	forge_stop_flag = 0;
	if (luaL_loadbufferx(L, text, strlen(text), "=rockspec", "t") != LUA_OK || lua_pcall(L, 0, 0, 0) != LUA_OK) {
		*error = strdup(lua_tostring(L, -1) ? lua_tostring(L, -1) : "rockspec error");
		lua_close(L);
		return NULL;
	}
	rs_buf b = {0};
	rs_put(&b, "");
	lua_getglobal(L, "source");
	int src = lua_gettop(L);
	if (lua_istable(L, src)) {
		const char *keys[] = {"url", "tag", "branch", "dir"};
		for (int i = 0; i < 4; i++) {
			const char *v = rs_field(L, src, keys[i]);
			if (v) rs_add(&b, keys[i], v);
		}
	}
	lua_getglobal(L, "dependencies");
	int deps = lua_gettop(L);
	if (lua_istable(L, deps)) {
		lua_Integer n = luaL_len(L, deps);
		for (lua_Integer i = 1; i <= n; i++) {
			lua_geti(L, deps, i);
			if (lua_type(L, -1) == LUA_TSTRING) rs_add(&b, "dep", lua_tostring(L, -1));
			lua_pop(L, 1);
		}
	}
	lua_getglobal(L, "build");
	int build = lua_gettop(L);
	if (lua_istable(L, build)) {
		const char *type = rs_field(L, build, "type");
		if (type) rs_add(&b, "type", type);
		lua_getfield(L, build, "modules");
		int mods = lua_gettop(L);
		if (lua_istable(L, mods)) {
			lua_pushnil(L);
			while (lua_next(L, mods)) {
				// модуль = "файл.lua"; таблица — модуль на C (sources = …), его не поставить
				if (lua_type(L, -2) == LUA_TSTRING) {
					const char *name = lua_tostring(L, -2);
					const char *file = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "<c>";
					rs_put(&b, "mod\t");
					rs_put(&b, name);
					rs_add(&b, "", file);
				}
				lua_pop(L, 1);
			}
		}
	}
	lua_close(L);
	return b.s;
}
