// Графика для скриптов: CoreGraphics-холст, CoreText для текста, ImageIO для картинок.
#include "forge_gfx.h"

#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

extern volatile int forge_stop_flag;  // forge_engines.c: кнопка «Стоп»

static CGContextRef ctx;
static int cw, ch;
static CGColorSpaceRef rgb;
static double cr = 255, cg = 255, cb = 255, ca = 255;
static forge_gfx_present_fn presenter;
static atomic_int frame_busy;  // интерфейс ещё не показал прошлый кадр
static struct timespec opened;

#define MAX_IMAGES 256
static CGImageRef images[MAX_IMAGES];
static int image_count;

// очередь событий (кольцо) — пишет главный поток, читает поток запуска
typedef struct { int type, key; double x, y; } gfx_event;
#define QSIZE 256
static gfx_event queue[QSIZE];
static int qhead, qtail;
static pthread_mutex_t qlock = PTHREAD_MUTEX_INITIALIZER;

void forge_gfx_set_presenter(forge_gfx_present_fn fn) { presenter = fn; }
void forge_gfx_frame_consumed(void) { atomic_store(&frame_busy, 0); }

void forge_gfx_push(int type, float x, float y, int key) {
	pthread_mutex_lock(&qlock);
	int next = (qtail + 1) % QSIZE;
	// переполнение: старые движения выбрасываем, нажатия важнее
	if (next == qhead) qhead = (qhead + 1) % QSIZE;
	queue[qtail] = (gfx_event){type, key, x, y};
	qtail = next;
	pthread_mutex_unlock(&qlock);
}

void forge_gfx_reset(void) {
	if (ctx) CGContextRelease(ctx);
	ctx = NULL;
	cw = ch = 0;
	for (int i = 0; i < image_count; i++) CGImageRelease(images[i]);
	image_count = 0;
	pthread_mutex_lock(&qlock);
	qhead = qtail = 0;
	pthread_mutex_unlock(&qlock);
	atomic_store(&frame_busy, 0);
	cr = cg = cb = ca = 255;
}

static void apply_color(void) {
	if (!ctx) return;
	CGContextSetRGBFillColor(ctx, cr / 255, cg / 255, cb / 255, ca / 255);
	CGContextSetRGBStrokeColor(ctx, cr / 255, cg / 255, cb / 255, ca / 255);
}

void forge_gfx_open(int w, int h) {
	if (w < 1) w = 800;
	if (h < 1) h = 600;
	if (w > 4096) w = 4096;
	if (h > 4096) h = 4096;
	if (ctx && w == cw && h == ch) return;
	if (ctx) CGContextRelease(ctx);
	if (!rgb) rgb = CGColorSpaceCreateDeviceRGB();
	ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, rgb, kCGImageAlphaPremultipliedLast);
	cw = w;
	ch = h;
	// начало координат — левый верхний угол, как в pygame и LÖVE
	CGContextTranslateCTM(ctx, 0, h);
	CGContextScaleCTM(ctx, 1, -1);
	CGContextSetShouldAntialias(ctx, true);
	CGContextSetLineCap(ctx, kCGLineCapRound);
	CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
	CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
	apply_color();
	clock_gettime(CLOCK_MONOTONIC, &opened);
}

static void ensure(void) {
	if (!ctx) forge_gfx_open(800, 600);
}

int forge_gfx_width(void) { return ctx ? cw : 0; }
int forge_gfx_height(void) { return ctx ? ch : 0; }

void forge_gfx_color(double r, double g, double b, double a) {
	cr = r, cg = g, cb = b, ca = a;
	apply_color();
}

void forge_gfx_clear(void) {
	ensure();
	CGContextSaveGState(ctx);
	CGContextSetBlendMode(ctx, kCGBlendModeCopy);
	CGContextFillRect(ctx, CGRectMake(0, 0, cw, ch));
	CGContextRestoreGState(ctx);
}

void forge_gfx_rect(double x, double y, double w, double h, double line) {
	ensure();
	CGRect r = CGRectMake(x, y, w, h);
	if (line > 0) {
		CGContextSetLineWidth(ctx, line);
		CGContextStrokeRect(ctx, CGRectInset(r, line / 2, line / 2));
	} else {
		CGContextFillRect(ctx, r);
	}
}

void forge_gfx_ellipse(double x, double y, double w, double h, double line) {
	ensure();
	CGRect r = CGRectMake(x, y, w, h);
	if (line > 0) {
		CGContextSetLineWidth(ctx, line);
		CGContextStrokeEllipseInRect(ctx, CGRectInset(r, line / 2, line / 2));
	} else {
		CGContextFillEllipseInRect(ctx, r);
	}
}

void forge_gfx_line(double x1, double y1, double x2, double y2, double width) {
	ensure();
	CGContextSetLineWidth(ctx, width > 0 ? width : 1);
	CGContextBeginPath(ctx);
	CGContextMoveToPoint(ctx, x1, y1);
	CGContextAddLineToPoint(ctx, x2, y2);
	CGContextStrokePath(ctx);
}

void forge_gfx_poly(const double *xy, int n, double line) {
	ensure();
	if (n < 2) return;
	CGContextBeginPath(ctx);
	CGContextMoveToPoint(ctx, xy[0], xy[1]);
	for (int i = 1; i < n; i++) CGContextAddLineToPoint(ctx, xy[2 * i], xy[2 * i + 1]);
	CGContextClosePath(ctx);
	if (line > 0) {
		CGContextSetLineWidth(ctx, line);
		CGContextStrokePath(ctx);
	} else {
		CGContextFillPath(ctx);
	}
}

static CTLineRef make_line(const char *s, double size, int colored) {
	CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size > 0 ? size : 16, NULL);
	CFStringRef str = CFStringCreateWithCString(NULL, s ? s : "", kCFStringEncodingUTF8);
	if (!str) str = CFStringCreateWithCString(NULL, "?", kCFStringEncodingUTF8);
	CGColorRef color = CGColorCreateSRGB(cr / 255, cg / 255, cb / 255, ca / 255);
	CFStringRef keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
	CFTypeRef vals[] = {font, color};
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, colored ? 2 : 1,
	                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
	CTLineRef line = CTLineCreateWithAttributedString(as);
	CFRelease(as);
	CFRelease(attrs);
	CGColorRelease(color);
	CFRelease(str);
	CFRelease(font);
	return line;
}

void forge_gfx_text(const char *s, double x, double y, double size) {
	ensure();
	CTLineRef line = make_line(s, size, 1);
	CGFloat ascent = 0, descent = 0, leading = 0;
	CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
	CGContextSaveGState(ctx);
	// холст перевёрнут — текст отражаем обратно
	CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
	CGContextSetTextPosition(ctx, x, y + ascent);
	CTLineDraw(line, ctx);
	CGContextRestoreGState(ctx);
	CFRelease(line);
}

double forge_gfx_measure(const char *s, double size) {
	CTLineRef line = make_line(s, size, 0);
	double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	CFRelease(line);
	return w;
}

int forge_gfx_image_load(const char *path) {
	if (image_count >= MAX_IMAGES) return -1;
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	if (!url) return -1;
	CGImageSourceRef src = CGImageSourceCreateWithURL(url, NULL);
	CFRelease(url);
	if (!src) return -1;
	CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
	CFRelease(src);
	if (!img) return -1;
	images[image_count] = img;
	return image_count++;
}

int forge_gfx_image_w(int i) { return i >= 0 && i < image_count ? (int)CGImageGetWidth(images[i]) : 0; }
int forge_gfx_image_h(int i) { return i >= 0 && i < image_count ? (int)CGImageGetHeight(images[i]) : 0; }

void forge_gfx_image_draw(int i, double x, double y, double w, double h) {
	ensure();
	if (i < 0 || i >= image_count) return;
	if (w <= 0) w = CGImageGetWidth(images[i]);
	if (h <= 0) h = CGImageGetHeight(images[i]);
	CGContextSaveGState(ctx);
	CGContextTranslateCTM(ctx, x, y + h);
	CGContextScaleCTM(ctx, 1, -1);
	CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), images[i]);
	CGContextRestoreGState(ctx);
}

void forge_gfx_present(void) {
	if (!ctx || !presenter) return;
	// интерфейс не успевает — пропускаем кадр, игра не тормозит
	int expected = 0;
	if (!atomic_compare_exchange_strong(&frame_busy, &expected, 1)) return;
	CGImageRef img = CGBitmapContextCreateImage(ctx);
	if (!img) {
		atomic_store(&frame_busy, 0);
		return;
	}
	presenter(img, cw, ch);
	CGImageRelease(img);
}

int forge_gfx_poll(double *x, double *y, int *key) {
	if (forge_stop_flag) return GFX_QUIT;
	int type = GFX_NONE;
	pthread_mutex_lock(&qlock);
	if (qhead != qtail) {
		gfx_event e = queue[qhead];
		qhead = (qhead + 1) % QSIZE;
		type = e.type;
		*x = e.x;
		*y = e.y;
		*key = e.key;
	}
	pthread_mutex_unlock(&qlock);
	return type;
}

double forge_gfx_ticks(void) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (now.tv_sec - opened.tv_sec) * 1000.0 + (now.tv_nsec - opened.tv_nsec) / 1e6;
}

void forge_gfx_sleep(double ms) {
	// кусками, чтобы «Стоп» срабатывал сразу
	while (ms > 0 && !forge_stop_flag) {
		double part = ms > 20 ? 20 : ms;
		usleep((useconds_t)(part * 1000));
		ms -= part;
	}
}

