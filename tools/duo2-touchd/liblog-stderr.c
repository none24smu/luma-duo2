// liblog-stderr: Android's log calls, printed to stderr.
//
// The stock touch library reports what it is doing through liblog, which on
// Android goes to logd. There is no logd on Luma; preload this (bionic's
// linker honours LD_PRELOAD) to see those messages from duo2-touchd.
#include <stdarg.h>
#include <stdio.h>

static const char kPrio[] = "??VDIWEFS";

int __android_log_write(int prio, const char *tag, const char *msg) {
    return fprintf(stderr, "%c/%s: %s\n", kPrio[prio & 7], tag ? tag : "", msg ? msg : "");
}

int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap) {
    char buf[1024];
    vsnprintf(buf, sizeof buf, fmt, ap);
    return __android_log_write(prio, tag, buf);
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = __android_log_vprint(prio, tag, fmt, ap);
    va_end(ap);
    return n;
}

int __android_log_buf_write(int buf, int prio, const char *tag, const char *msg) {
    (void)buf;
    return __android_log_write(prio, tag, msg);
}

int __android_log_buf_print(int buf, int prio, const char *tag, const char *fmt, ...) {
    (void)buf;
    va_list ap;
    va_start(ap, fmt);
    int n = __android_log_vprint(prio, tag, fmt, ap);
    va_end(ap);
    return n;
}

int __android_log_is_loggable(int prio, const char *tag, int def) {
    (void)prio; (void)tag; (void)def;
    return 1;
}
