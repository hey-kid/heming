#pragma once
#include <stdint.h>
#if defined(_WIN32)
#define HM_EXPORT __declspec(dllexport)
#else
#define HM_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif
#ifdef __cplusplus
extern "C" {
#endif
HM_EXPORT void* hm_create(void);
HM_EXPORT void hm_destroy(void* engine);
HM_EXPORT int64_t hm_now_us(void);
HM_EXPORT int hm_prepare_local(void*, const char* path, const char* session,
                               const char* task, int port);
HM_EXPORT int hm_prepare_remote(void*, const char* host, int port,
                                const char* session, const char* task);
HM_EXPORT void hm_stop(void*);
HM_EXPORT void hm_interrupt(void*);
HM_EXPORT int hm_schedule(void*, int64_t master_time_us);
HM_EXPORT void hm_output(void*, double volume, int channel, int muted);
HM_EXPORT void hm_latency_compensation(void*, int64_t microseconds);
HM_EXPORT char* hm_status(void*);
HM_EXPORT char* hm_probe(const char* path, int verify);
HM_EXPORT void hm_free(void*);
HM_EXPORT void* hm_convert(const char* input, const char* output);
HM_EXPORT char* hm_conversion_status(void*);
HM_EXPORT void hm_conversion_cancel(void*);
HM_EXPORT void hm_conversion_destroy(void*);
// Independent streaming local audition; no synchronized engine or transport.
HM_EXPORT void* hm_preview_create(void);
HM_EXPORT void hm_preview_destroy(void*);
HM_EXPORT int hm_preview_open(void*, const char* path);
HM_EXPORT int hm_preview_play(void*, int64_t epoch);
HM_EXPORT void hm_preview_pause(void*);
HM_EXPORT int hm_preview_seek(void*, int64_t milliseconds, int64_t epoch);
HM_EXPORT void hm_preview_stop(void*);
HM_EXPORT int64_t hm_preview_interrupt(void*);
HM_EXPORT void hm_preview_volume(void*, double volume);
HM_EXPORT char* hm_preview_status(void*);
#ifdef __cplusplus
}
#endif
