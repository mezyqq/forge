#include "engines/forge_engines.h"
#include <JavaScriptCore/JavaScriptCore.h>

// Экспортируется JavaScriptCore, но объявлено в приватном заголовке. Нужно для кнопки «Стоп» у JS:
// колбэк зовётся каждые `limit` секунд работы скрипта, true — прервать.
typedef bool (*JSShouldTerminateCallback)(JSContextRef ctx, void *context);
void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit, JSShouldTerminateCallback callback, void *context);
#include "forge_crash.h"
