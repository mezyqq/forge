#include "forge_crash.h"

#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// В обработчике сигнала можно только async-signal-safe вызовы: open/write/read/backtrace,
// поэтому всё, что можно, готовим заранее, а числа форматируем вручную.

static char crash_path[1024];
static char stderr_path[1024];
static char info_text[2048];
static char crumbs[8192];
static volatile size_t crumbs_len = 0;
static volatile int exception_written = 0;
static uintptr_t image_base = 0;
static struct sigaction old_actions[NSIG];
static char alt_stack[64 * 1024];  // чтобы записать отчёт даже при переполнении стека

static const int handled[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE };

static void put(int fd, const char *s) { write(fd, s, strlen(s)); }

static void put_hex(int fd, uintptr_t v) {
	char b[19] = "0x";
	for (int i = 0; i < 16; i++) {
		int d = (int)((v >> ((15 - i) * 4)) & 15);
		b[2 + i] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
	}
	b[18] = 0;
	put(fd, b);
}

static void put_dec(int fd, long v) {
	char b[24];
	int i = 23;
	b[i] = 0;
	int neg = v < 0;
	unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
	do { b[--i] = (char)('0' + u % 10); u /= 10; } while (u && i > 1);
	if (neg) b[--i] = '-';
	put(fd, b + i);
}

static const char *signame(int s) {
	switch (s) {
	case SIGSEGV: return "SIGSEGV (обращение к неверной памяти)";
	case SIGBUS: return "SIGBUS (ошибка шины / выравнивания)";
	case SIGILL: return "SIGILL (недопустимая инструкция)";
	case SIGABRT: return "SIGABRT (abort: исключение или assert)";
	case SIGTRAP: return "SIGTRAP (ловушка: фатальная ошибка Swift — force unwrap, выход за границы массива…)";
	case SIGFPE: return "SIGFPE (арифметика: деление на ноль)";
	default: return "сигнал";
	}
}

static void handler(int sig, siginfo_t *si, void *uc) {
	(void)uc;
	int fd = open(crash_path, O_WRONLY | O_CREAT | (exception_written ? O_APPEND : O_TRUNC), 0644);
	if (fd >= 0) {
		if (!exception_written) {
			put(fd, "=== Отчёт о вылете Forge ===\n");
			put(fd, info_text);
		}
		put(fd, "\nСигнал: ");
		put(fd, signame(sig));
		put(fd, "\nАдрес: ");
		put_hex(fd, (uintptr_t)(si ? si->si_addr : 0));
		put(fd, "\n\n--- Стек вызовов (Forge+смещение → tools/symbolicate.sh) ---\n");
		void *frames[64];
		int n = backtrace(frames, 64);
		for (int i = 0; i < n; i++) {
			uintptr_t a = (uintptr_t)frames[i];
			put_dec(fd, i);
			put(fd, "  ");
			put_hex(fd, a);
			if (image_base && a >= image_base && a - image_base < 0x10000000) {
				put(fd, "  Forge+");
				put_hex(fd, a - image_base);
			}
			put(fd, "\n");
		}
		put(fd, "\n--- Символы ---\n");
		backtrace_symbols_fd(frames, n, fd);
		put(fd, "\n--- Последние действия ---\n");
		write(fd, crumbs, crumbs_len);
		put(fd, "\n--- stderr (последнее) ---\n");
		int e = open(stderr_path, O_RDONLY);
		if (e >= 0) {
			off_t end = lseek(e, 0, SEEK_END);
			lseek(e, end > 6000 ? end - 6000 : 0, SEEK_SET);
			char buf[2048];
			ssize_t r;
			while ((r = read(e, buf, sizeof buf)) > 0) write(fd, buf, (size_t)r);
			close(e);
		}
		close(fd);
	}
	// возвращаем прежний обработчик и повторяем сигнал — процесс завершится как обычно
	sigaction(sig, &old_actions[sig], NULL);
	raise(sig);
}

void forge_crash_install(const char *crashPath, const char *stderrPath, const char *info) {
	strlcpy(crash_path, crashPath, sizeof crash_path);
	strlcpy(stderr_path, stderrPath, sizeof stderr_path);

	// образ Forge (в LiveContainer это не главный исполняемый файл, ищем по имени)
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char *name = _dyld_get_image_name(i);
		if (name && strstr(name, "/Forge.app/Forge")) { image_base = (uintptr_t)_dyld_get_image_header(i); break; }
	}
	if (!image_base) image_base = (uintptr_t)_dyld_get_image_header(0);
	snprintf(info_text, sizeof info_text, "%sБаза образа Forge: 0x%lx\n", info, (unsigned long)image_base);

	// stdout/stderr приложения → файл (Swift пишет туда «Fatal error: …» перед вылетом)
	int fd = open(stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd >= 0) {
		fflush(stdout);
		fflush(stderr);
		dup2(fd, 1);
		dup2(fd, 2);
		close(fd);
		setvbuf(stderr, NULL, _IONBF, 0);
	}

	stack_t ss = { .ss_sp = alt_stack, .ss_size = sizeof alt_stack, .ss_flags = 0 };
	sigaltstack(&ss, NULL);
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = handler;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sigemptyset(&sa.sa_mask);
	for (size_t i = 0; i < sizeof handled / sizeof handled[0]; i++) sigaction(handled[i], &sa, &old_actions[handled[i]]);
}

void forge_crumb(const char *line) {
	size_t n = strlen(line);
	if (n > 400) n = 400;
	if (crumbs_len + n + 1 > sizeof crumbs) {
		// выкидываем старую половину
		size_t keep = crumbs_len / 2;
		memmove(crumbs, crumbs + crumbs_len - keep, keep);
		crumbs_len = keep;
	}
	memcpy(crumbs + crumbs_len, line, n);
	crumbs[crumbs_len + n] = '\n';
	crumbs_len += n + 1;
}

void forge_crash_mark_exception(void) { exception_written = 1; }

unsigned long forge_image_base(void) { return (unsigned long)image_base; }
