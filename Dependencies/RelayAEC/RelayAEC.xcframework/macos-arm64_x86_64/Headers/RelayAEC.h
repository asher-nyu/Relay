#ifndef RELAY_AEC_H
#define RELAY_AEC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RelayAECHandle RelayAECHandle;
typedef struct RelayVADHandle RelayVADHandle;

/* Caller owns each handle on one serial queue. Inputs are finite, normalized
 * mono float PCM in [-1, 1]. Each call has exactly sample_rate_hz/100 frames.
 * Supported rates are 16000, 32000 and 48000. No audio files or network APIs.
 * Feed reverse/reference frames before capture frames containing their echo.
 * Delay is the measured render/capture buffer delay in milliseconds, 0..500.
 * Returns 0 on success, negative APM error otherwise; -10000 invalid argument,
 * -10001 unexpected C++ failure. No C++ types or exceptions cross this ABI.
 */
RelayAECHandle *relay_aec_create(int sample_rate_hz);
size_t relay_aec_frame_size(const RelayAECHandle *handle);
int relay_aec_process_reverse(RelayAECHandle *handle,
                              const float *render, size_t frames);
int relay_aec_process_capture(RelayAECHandle *handle,
                              const float *microphone, float *output,
                              size_t frames, int delay_ms);
int relay_aec_reset(RelayAECHandle *handle);
void relay_aec_destroy(RelayAECHandle *handle);

/* Independent speech-activity metadata; never filters or changes audio.
 * One caller-owned serial queue per handle. Mode is 0..3 (higher modes are
 * more restrictive and can miss quiet speech). Process exactly 160 finite
 * mono Float32 samples at 16000 Hz per call. Values outside [-1,1] saturate
 * during local Int16 conversion. Returns 1 speech, 0 non-speech, negative on
 * error. Reset preserves the selected mode. No AEC handle/state is shared.
 */
RelayVADHandle *relay_vad_create(int mode);
int relay_vad_process(RelayVADHandle *handle, const float *samples, size_t frames);
int relay_vad_reset(RelayVADHandle *handle);
void relay_vad_destroy(RelayVADHandle *handle);

#ifdef __cplusplus
}
#endif
#endif
