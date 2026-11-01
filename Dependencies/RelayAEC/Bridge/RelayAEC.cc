#include "RelayAEC.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <vector>
#include "api/audio/audio_processing.h"
#include "common_audio/vad/include/webrtc_vad.h"

struct RelayAECHandle {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::ProcessingConfig processing;
    webrtc::StreamConfig mono;
    std::vector<float> reverse_scratch;
    size_t frames = 0;
};

struct RelayVADHandle {
    VadInst *vad = nullptr;
    int mode = 0;
    ~RelayVADHandle() { WebRtcVad_Free(vad); }
};

namespace {
constexpr int invalid_argument = -10000;
constexpr int unexpected_failure = -10001;
}

extern "C" RelayAECHandle *relay_aec_create(int sample_rate_hz) {
    if (sample_rate_hz != 16000 && sample_rate_hz != 32000 && sample_rate_hz != 48000) {
        return nullptr;
    }
    try {
        auto handle = std::make_unique<RelayAECHandle>();
        webrtc::AudioProcessing::Config settings;
        settings.echo_canceller.enabled = true;
        settings.echo_canceller.mobile_mode = false; // AEC3, not the mobile AECM.
        settings.high_pass_filter.enabled = true;
        settings.noise_suppression.enabled = false;
        settings.gain_controller1.enabled = false;
        settings.gain_controller2.enabled = false;
        handle->apm = webrtc::AudioProcessingBuilder().SetConfig(settings).Create();
        if (!handle->apm) { return nullptr; }
        handle->mono = webrtc::StreamConfig(sample_rate_hz, 1);
        handle->processing.input_stream() = handle->mono;
        handle->processing.output_stream() = handle->mono;
        handle->processing.reverse_input_stream() = handle->mono;
        handle->processing.reverse_output_stream() = handle->mono;
        if (handle->apm->Initialize(handle->processing) != 0) { return nullptr; }
        handle->frames = handle->mono.num_frames();
        handle->reverse_scratch.resize(handle->frames);
        return handle.release();
    } catch (...) {
        return nullptr;
    }
}

extern "C" size_t relay_aec_frame_size(const RelayAECHandle *handle) {
    return handle ? handle->frames : 0;
}

extern "C" int relay_aec_process_reverse(RelayAECHandle *handle,
                                          const float *render, size_t frames) {
    if (!handle || !render || frames != handle->frames) { return invalid_argument; }
    try {
        const float *input[] = {render};
        float *output[] = {handle->reverse_scratch.data()};
        return handle->apm->ProcessReverseStream(input, handle->mono, handle->mono, output);
    } catch (...) {
        return unexpected_failure;
    }
}

extern "C" int relay_aec_process_capture(RelayAECHandle *handle,
                                          const float *microphone, float *output,
                                          size_t frames, int delay_ms) {
    if (!handle || !microphone || !output || frames != handle->frames ||
        delay_ms < 0 || delay_ms > 500) { return invalid_argument; }
    try {
        const int delay_status = handle->apm->set_stream_delay_ms(delay_ms);
        if (delay_status != 0) { return delay_status; }
        const float *input[] = {microphone};
        float *result[] = {output};
        return handle->apm->ProcessStream(input, handle->mono, handle->mono, result);
    } catch (...) {
        return unexpected_failure;
    }
}

extern "C" int relay_aec_reset(RelayAECHandle *handle) {
    if (!handle) { return invalid_argument; }
    try {
        return handle->apm->Initialize(handle->processing);
    } catch (...) {
        return unexpected_failure;
    }
}

extern "C" void relay_aec_destroy(RelayAECHandle *handle) { delete handle; }

extern "C" RelayVADHandle *relay_vad_create(int mode) {
    if (mode < 0 || mode > 3) { return nullptr; }
    try {
        auto handle = std::make_unique<RelayVADHandle>();
        handle->mode = mode;
        handle->vad = WebRtcVad_Create();
        if (!handle->vad || WebRtcVad_Init(handle->vad) != 0 ||
            WebRtcVad_set_mode(handle->vad, mode) != 0) { return nullptr; }
        return handle.release();
    } catch (...) {
        return nullptr;
    }
}

extern "C" int relay_vad_process(RelayVADHandle *handle,
                                   const float *samples, size_t frames) {
    if (!handle || !handle->vad || !samples || frames != 160) {
        return invalid_argument;
    }
    // Validate the entire frame before updating the classifier's history.
    std::array<int16_t, 160> pcm;
    for (size_t index = 0; index < pcm.size(); ++index) {
        if (!std::isfinite(samples[index])) { return invalid_argument; }
        const float normalized = std::clamp(samples[index], -1.f, 1.f);
        const long quantized = std::lround(normalized * 32768.f);
        pcm[index] = static_cast<int16_t>(std::clamp(quantized, -32768L, 32767L));
    }
    return WebRtcVad_Process(handle->vad, 16000, pcm.data(), pcm.size());
}

extern "C" int relay_vad_reset(RelayVADHandle *handle) {
    if (!handle || !handle->vad) { return invalid_argument; }
    const int initialized = WebRtcVad_Init(handle->vad);
    return initialized == 0 ? WebRtcVad_set_mode(handle->vad, handle->mode) : initialized;
}

extern "C" void relay_vad_destroy(RelayVADHandle *handle) { delete handle; }
