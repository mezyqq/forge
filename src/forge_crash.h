// Журнал вылетов: перехват сигналов (SIGSEGV, SIGTRAP от ошибок Swift, SIGABRT…) с записью отчёта в файл.
#ifndef FORGE_CRASH_H
#define FORGE_CRASH_H

/// crashPath — куда писать отчёт; stderrPath — сюда перенаправляется stderr/stdout приложения
/// (Swift печатает туда текст фатальной ошибки); info — версия, устройство и т.п. в шапку отчёта.
void forge_crash_install(const char *crashPath, const char *stderrPath, const char *info);

/// Строка в журнал последних действий (попадает в отчёт).
void forge_crumb(const char *line);

/// Отчёт уже начат обработчиком исключений ObjC — сигнальный обработчик допишет, а не перезапишет.
void forge_crash_mark_exception(void);

/// Базовый адрес образа Forge в памяти (для «Forge+смещение» в отчёте).
unsigned long forge_image_base(void);

#endif
