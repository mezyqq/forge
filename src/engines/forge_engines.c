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

static void py_ensure(void) {
	if (!py_inited) { py_initialize(); py_inited = 1; }
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
