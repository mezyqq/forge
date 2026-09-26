// Встроенные интерпретаторы: Python (pocketpy), Lua, C (picoc). Без JIT.
// Вывод идёт в stdout/stderr, ввод — из stdin: Runner перенаправляет их в консоль приложения.
#ifndef FORGE_ENGINES_H
#define FORGE_ENGINES_H

/// Каждая функция выполняет файл и возвращает код выхода (0 — успех). Вызывать с фонового потока,
/// по одному запуску за раз; текущая папка процесса = папка скрипта (для import / require / #include).
int forge_run_python(const char *path);
int forge_run_lua(const char *path);
int forge_run_c(const char *path);

/// Прерывает текущий запуск (можно звать с любого потока).
void forge_request_stop(void);

/// Проверка синтаксиса без запуска. NULL — ошибок нет, иначе сообщение (освободить free()).
/// Python и C нельзя проверять, пока идёт запуск того же языка (общий интерпретатор) — тогда вернётся NULL.
char *forge_check_python(const char *source, const char *filename);
char *forge_check_lua(const char *source, const char *filename);
char *forge_check_c(const char *source, const char *filename);

#endif
