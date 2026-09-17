/*
 * aec_c_api.cc - implementation of the flat C ABI declared in aec_c_api.h
 *
 * The frame-by-frame pipeline mirrors AEC3-master/demo/demo.cc so that results
 * are identical to what the reference console demo produces.
 */

#include "api/aec_c_api.h"

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>

#include "api/echo_canceller3_config.h"
#include "api/echo_canceller3_factory.h"
#include "api/echo_control.h"
#include "audio_processing/audio_buffer.h"
#include "audio_processing/audio_frame.h"
#include "audio_processing/high_pass_filter.h"
#include "audio_processing/include/audio_processing.h"

#include "wavreader.h"
#include "wavwriter.h"

namespace {

using webrtc::AudioBuffer;
using webrtc::AudioFrame;
using webrtc::EchoCanceller3Config;
using webrtc::EchoCanceller3Factory;
using webrtc::EchoControl;
using webrtc::HighPassFilter;
using webrtc::StreamConfig;

constexpr int kFrameMs = 10;
constexpr int kLinearRateHz = AEC_LINEAR_RATE_HZ;

inline size_t FrameSamplesFor(int sample_rate_hz) {
  return static_cast<size_t>(sample_rate_hz / 1000) * kFrameMs;
}

inline size_t LinearFrameSamples() {
  return static_cast<size_t>(kLinearRateHz / 1000) * kFrameMs;  // 160 @ 16 kHz
}

bool IsSupportedRate(int rate) {
  return rate == AEC_RATE_16K || rate == AEC_RATE_32K || rate == AEC_RATE_48K;
}

struct AecContext {
  int sample_rate_hz = 0;
  int channels = 0;
  size_t frame_samples = 0;
  size_t linear_samples = 0;
  size_t bytes_per_frame = 0;

  std::unique_ptr<EchoControl> aec;
  std::unique_ptr<HighPassFilter> hp_filter;
  std::unique_ptr<AudioBuffer> render_buf;
  std::unique_ptr<AudioBuffer> capture_buf;
  std::unique_ptr<AudioBuffer> linear_buf;
  AudioFrame render_frame;
  AudioFrame capture_frame;
  AudioFrame out_frame;
  AudioFrame linear_frame;
};

/* Creates the pipeline but not the AEC controller; caller assigns ctx->aec. */
bool BuildPipeline(AecContext* ctx, int sample_rate_hz, int channels) {
  const size_t ch = static_cast<size_t>(channels);
  const size_t rate = static_cast<size_t>(sample_rate_hz);

  ctx->render_buf = std::make_unique<AudioBuffer>(rate, ch, rate, ch, rate, ch);
  ctx->capture_buf = std::make_unique<AudioBuffer>(rate, ch, rate, ch, rate, ch);
  ctx->linear_buf = std::make_unique<AudioBuffer>(
      static_cast<size_t>(kLinearRateHz), ch, static_cast<size_t>(kLinearRateHz),
      ch, static_cast<size_t>(kLinearRateHz), ch);
  if (!ctx->render_buf || !ctx->capture_buf || !ctx->linear_buf) {
    return false;
  }

  /* demo.cc constructs the high-pass filter unconditionally (it has dedicated
   * 16 kHz coefficients too), so do the same rather than gating on the rate.
   * It runs on the split-band data, i.e. it high-passes the 0-8 kHz band. */
  ctx->hp_filter = std::make_unique<HighPassFilter>(sample_rate_hz, ch);
  if (!ctx->hp_filter) {
    return false;
  }
  return true;
}

int ProcessFrame(AecContext* ctx,
                 const short* render,
                 const short* mic,
                 short* out,
                 short* linear_out) {
  const size_t fs = ctx->frame_samples;
  const int rate = ctx->sample_rate_hz;
  const size_t ch = static_cast<size_t>(ctx->channels);

  ctx->render_frame.UpdateFrame(0, reinterpret_cast<const int16_t*>(render), fs,
                               rate, AudioFrame::kNormalSpeech,
                               AudioFrame::kVadActive, ch);
  ctx->capture_frame.UpdateFrame(0, reinterpret_cast<const int16_t*>(mic), fs,
                                rate, AudioFrame::kNormalSpeech,
                                AudioFrame::kVadActive, ch);
  /* CopyTo asserts that the frame length matches the buffer's output_num_frames_,
   * and a default-constructed AudioFrame has samples_per_channel_ == 0, so every
   * destination frame must be sized before its CopyTo call. */
  ctx->out_frame.UpdateFrame(0, nullptr, fs, rate, AudioFrame::kNormalSpeech,
                             AudioFrame::kVadActive, ch);

  /* Render path: time -> freq -> analyze -> back to time. */
  ctx->render_buf->CopyFrom(&ctx->render_frame);
  ctx->render_buf->SplitIntoFrequencyBands();
  ctx->aec->AnalyzeRender(ctx->render_buf.get());
  ctx->render_buf->MergeFrequencyBands();

  /* Capture path. */
  ctx->capture_buf->CopyFrom(&ctx->capture_frame);
  ctx->aec->AnalyzeCapture(ctx->capture_buf.get());
  ctx->capture_buf->SplitIntoFrequencyBands();
  if (ctx->hp_filter) {
    ctx->hp_filter->Process(ctx->capture_buf.get(), true);
  }
  ctx->aec->ProcessCapture(ctx->capture_buf.get(), ctx->linear_buf.get(), false);
  ctx->capture_buf->MergeFrequencyBands();

  ctx->capture_buf->CopyTo(&ctx->out_frame);
  memcpy(out, ctx->out_frame.data(), fs * sizeof(short));

  if (linear_out != nullptr) {
    /* AudioBuffer::CopyTo asserts that the frame length matches the buffer's
     * output_num_frames_, so the frame must be re-sized before every copy. */
    ctx->linear_frame.UpdateFrame(0, nullptr, ctx->linear_samples, kLinearRateHz,
                                  AudioFrame::kNormalSpeech, AudioFrame::kVadActive,
                                  ch);
    ctx->linear_buf->CopyTo(&ctx->linear_frame);
    memcpy(linear_out, ctx->linear_frame.data(),
           ctx->linear_samples * sizeof(short));
  }
  return AEC_OK;
}

void CloseWavs(void* ref, void* mic, void* out, void* lin) {
  if (lin != nullptr) wav_write_close(lin);
  if (out != nullptr) wav_write_close(out);
  if (mic != nullptr) wav_read_close(mic);
  if (ref != nullptr) wav_read_close(ref);
}

/* Strips the directory and extension from a path. */
std::string StripDirAndExt(const std::string& path) {
  size_t slash = path.find_last_of("\\/");
  std::string base = (slash == std::string::npos) ? path : path.substr(slash + 1);
  size_t dot = base.find_last_of('.');
  if (dot != std::string::npos && dot > 0) {
    base = base.substr(0, dot);
  }
  return base;
}

bool FileExists(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (f == nullptr) return false;
  fclose(f);
  return true;
}

/* Implementation-static abort flag. 8-byte aligned so it can be read/written
 * atomically by the caller. Volatile because another thread may store to it
 * while this thread polls; a plain read is fine since a torn int32 read cannot
 * happen on x86/x64 and a stale-but-correct value at worst delays cancellation
 * by one poll interval. */
volatile int g_abort_flag = 0;

inline bool AbortRequested(int* abort) {
  if (abort == nullptr) return false;
  return *reinterpret_cast<volatile int*>(abort) != 0;
}

}  // namespace

/* ================================================================== */
/* cancellation                                                        */
/* ================================================================== */

extern "C" AEC_API int* AEC_CALL AEC_GetAbortFlag(void) {
  return const_cast<int*>(&g_abort_flag);
}

/* ================================================================== */
/* streaming API                                                       */
/* ================================================================== */

extern "C" AEC_API void* AEC_CALL AEC_Create(int sample_rate_hz, int channels) {
  if (!IsSupportedRate(sample_rate_hz) || channels != 1) {
    return nullptr;
  }

  std::unique_ptr<AecContext> ctx(new (std::nothrow) AecContext());
  if (!ctx) {
    return nullptr;
  }

  ctx->sample_rate_hz = sample_rate_hz;
  ctx->channels = channels;
  ctx->frame_samples = FrameSamplesFor(sample_rate_hz);
  ctx->linear_samples = LinearFrameSamples();
  ctx->bytes_per_frame = ctx->frame_samples * sizeof(short);

  EchoCanceller3Config config;
  config.filter.export_linear_aec_output = true;
  EchoCanceller3Factory factory(config);
  ctx->aec = factory.Create(sample_rate_hz, channels, channels);
  if (!ctx->aec) {
    return nullptr;
  }

  if (!BuildPipeline(ctx.get(), sample_rate_hz, channels)) {
    return nullptr;
  }

  /* Delay handling: do NOT call SetAudioBufferDelay here. Doing so before any
   * render block has been pushed makes RenderDelayBuffer apply a non-zero
   * total delay to an empty buffer and the very first capture call then reads
   * uninitialized data (crash in AudioBuffer::CopyTo). Leave the delay to
   * AEC3's own estimator; AEC_SetAudioBufferDelay exists for callers that know
   * the fixed latency, and must be called after at least one AEC_Process. */

  return ctx.release();
}

extern "C" AEC_API void AEC_CALL AEC_Destroy(void* handle) {
  delete static_cast<AecContext*>(handle);
}

extern "C" AEC_API int AEC_CALL AEC_Process(void* handle,
                                            const short* render,
                                            const short* mic,
                                            short* out,
                                            short* linear_out,
                                            int frame_size) {
  if (handle == nullptr || render == nullptr || mic == nullptr || out == nullptr) {
    return AEC_ERR_BAD_ARG;
  }
  AecContext* ctx = static_cast<AecContext*>(handle);
  if (static_cast<size_t>(frame_size) != ctx->frame_samples) {
    return AEC_ERR_BAD_ARG;
  }
  return ProcessFrame(ctx, render, mic, out, linear_out);
}

extern "C" AEC_API int AEC_CALL AEC_SetAudioBufferDelay(void* handle,
                                                        int delay_ms) {
  if (handle == nullptr || delay_ms < 0) {
    return AEC_ERR_BAD_ARG;
  }
  static_cast<AecContext*>(handle)->aec->SetAudioBufferDelay(delay_ms);
  return AEC_OK;
}

extern "C" AEC_API int AEC_CALL AEC_GetMetrics(void* handle,
                                               double* echo_return_loss,
                                               double* echo_return_loss_enhancement,
                                               int* delay_ms) {
  if (handle == nullptr) {
    return AEC_ERR_BAD_ARG;
  }
  const EchoControl::Metrics m = static_cast<AecContext*>(handle)->aec->GetMetrics();
  if (echo_return_loss != nullptr) {
    *echo_return_loss = m.echo_return_loss;
  }
  if (echo_return_loss_enhancement != nullptr) {
    *echo_return_loss_enhancement = m.echo_return_loss_enhancement;
  }
  if (delay_ms != nullptr) {
    *delay_ms = m.delay_ms;
  }
  return AEC_OK;
}

/* ================================================================== */
/* whole-file API                                                      */
/* ================================================================== */

extern "C" AEC_API int AEC_CALL AEC_ProcessAudioFiles(const char* ref_path,
                                                      const char* mic_path,
                                                      const char* out_path,
                                                      AecProgressFn cb,
                                                      void* user) {
  return AEC_ProcessAudioFilesEx(ref_path, mic_path, out_path, 0, 0, cb, user,
                                 nullptr);
}

extern "C" AEC_API int AEC_CALL AEC_ProcessAudioFilesEx(const char* ref_path,
                                                        const char* mic_path,
                                                        const char* out_path,
                                                        int set_delay,
                                                        int delay_ms,
                                                        AecProgressFn cb,
                                                        void* user,
                                                        int* abort) {
  if (ref_path == nullptr || mic_path == nullptr || out_path == nullptr) {
    return AEC_ERR_BAD_ARG;
  }

  void* h_ref = nullptr;
  void* h_mic = nullptr;
  void* h_out = nullptr;
  void* h_linear = nullptr;
  unsigned char* ref_raw = nullptr;
  unsigned char* mic_raw = nullptr;
  int rc = AEC_OK;

  h_ref = wav_read_open(ref_path);
  if (h_ref == nullptr) {
    return AEC_ERR_OPEN_REF;
  }
  h_mic = wav_read_open(mic_path);
  if (h_mic == nullptr) {
    wav_read_close(h_ref);
    return AEC_ERR_OPEN_MIC;
  }

  int ref_fmt = 0, ref_ch = 0, ref_rate = 0, ref_bits = 0;
  int mic_fmt = 0, mic_ch = 0, mic_rate = 0, mic_bits = 0;
  unsigned int ref_bytes = 0, mic_bytes = 0;

  if (!wav_get_header(h_ref, &ref_fmt, &ref_ch, &ref_rate, &ref_bits, &ref_bytes) ||
      !wav_get_header(h_mic, &mic_fmt, &mic_ch, &mic_rate, &mic_bits, &mic_bytes)) {
    CloseWavs(h_ref, h_mic, nullptr, nullptr);
    return AEC_ERR_INTERNAL;
  }

  if (ref_fmt != 1 || mic_fmt != 1 || ref_bits != 16 || mic_bits != 16 ||
      ref_ch != 1 || mic_ch != 1 || !IsSupportedRate(ref_rate)) {
    CloseWavs(h_ref, h_mic, nullptr, nullptr);
    return AEC_ERR_UNSUPPORTED_FMT;
  }
  if (ref_rate != mic_rate || ref_ch != mic_ch || ref_bits != mic_bits) {
    CloseWavs(h_ref, h_mic, nullptr, nullptr);
    return AEC_ERR_FORMAT_MISMATCH;
  }

  const size_t samples_per_frame = FrameSamplesFor(ref_rate);
  const size_t bytes_per_frame = samples_per_frame * sizeof(short);
  const size_t total_frames =
      static_cast<size_t>(ref_bytes) / bytes_per_frame;
  const size_t usable_frames =
      (static_cast<size_t>(mic_bytes) / bytes_per_frame < total_frames)
          ? static_cast<size_t>(mic_bytes) / bytes_per_frame
          : total_frames;

  h_out = wav_write_open(out_path, ref_rate, ref_bits, ref_ch);
  if (h_out == nullptr) {
    CloseWavs(h_ref, h_mic, nullptr, nullptr);
    return AEC_ERR_CREATE_OUT;
  }

  /* Linear output goes next to out_path; fall back to the CWD (demo behavior). */
  {
    const std::string out_str(out_path);
    size_t slash = out_str.find_last_of("\\/");
    const std::string dir =
        (slash == std::string::npos) ? std::string() : out_str.substr(0, slash + 1);
    const std::string linear_primary = dir + StripDirAndExt(out_str) + "_linear.wav";
    h_linear = wav_write_open(linear_primary.c_str(), kLinearRateHz, ref_bits, ref_ch);
    if (h_linear == nullptr && slash != std::string::npos) {
      const std::string linear_fallback = std::string("linear.wav");
      if (FileExists(linear_fallback)) {
        h_linear = wav_write_open("linear_new.wav", kLinearRateHz, ref_bits, ref_ch);
      } else {
        h_linear = wav_write_open(linear_fallback.c_str(), kLinearRateHz, ref_bits, ref_ch);
      }
    }
  }

  void* handle = AEC_Create(ref_rate, ref_ch);
  if (handle == nullptr) {
    CloseWavs(h_ref, h_mic, h_out, h_linear);
    return AEC_ERR_INTERNAL;
  }
  AecContext* ctx = static_cast<AecContext*>(handle);

  ref_raw = new (std::nothrow) unsigned char[bytes_per_frame];
  mic_raw = new (std::nothrow) unsigned char[bytes_per_frame];
  short* out_frame = new (std::nothrow) short[samples_per_frame];
  short* linear_frame =
      new (std::nothrow) short[LinearFrameSamples()];
  if (ref_raw == nullptr || mic_raw == nullptr || out_frame == nullptr ||
      linear_frame == nullptr) {
    rc = AEC_ERR_INTERNAL;
  }

  for (size_t i = 0; rc == AEC_OK && i < usable_frames; ++i) {
    /* Poll the abort flag every 8 frames (~80 ms of audio) rather than every
     * frame: cheap enough to be free, prompt enough to feel instant. */
    if ((i & 7u) == 0u && AbortRequested(abort)) {
      rc = AEC_ERR_ABORTED;
      break;
    }

    if (wav_read_data(h_ref, ref_raw, static_cast<unsigned int>(bytes_per_frame)) < 0 ||
        wav_read_data(h_mic, mic_raw, static_cast<unsigned int>(bytes_per_frame)) < 0) {
      rc = AEC_ERR_INTERNAL;
      break;
    }

    rc = ProcessFrame(ctx, reinterpret_cast<const short*>(ref_raw),
                      reinterpret_cast<const short*>(mic_raw), out_frame,
                      (h_linear != nullptr) ? linear_frame : nullptr);
    if (rc != AEC_OK) {
      break;
    }

    wav_write_data(h_out, reinterpret_cast<const unsigned char*>(out_frame),
                   static_cast<int>(bytes_per_frame));
    if (h_linear != nullptr) {
      wav_write_data(h_linear, reinterpret_cast<const unsigned char*>(linear_frame),
                     static_cast<int>(ctx->linear_samples * sizeof(short)));
    }

    if (cb != nullptr) {
      cb(static_cast<int>(i + 1), static_cast<int>(usable_frames), user);
    }

    /* Apply an explicit delay only after real render data exists in the delay
     * buffer (see AEC_SetAudioBufferDelay). Done once, after frame 0. */
    if (set_delay && i == 0) {
      ctx->aec->SetAudioBufferDelay(delay_ms);
    }
  }

  delete[] linear_frame;
  delete[] out_frame;
  delete[] mic_raw;
  delete[] ref_raw;
  AEC_Destroy(handle);
  CloseWavs(h_ref, h_mic, h_out, h_linear);
  return rc;
}

extern "C" AEC_API int AEC_CALL AEC_GetAudioInfo(const char* file_path,
                                                 char* buffer,
                                                 int buffer_size) {
  if (file_path == nullptr || buffer == nullptr || buffer_size < 64) {
    return AEC_ERR_BAD_ARG;
  }
  buffer[0] = '\0';

  void* h = wav_read_open(file_path);
  if (h == nullptr) {
    return AEC_ERR_OPEN_REF;
  }
  int fmt = 0, ch = 0, rate = 0, bits = 0;
  unsigned int bytes = 0;
  if (!wav_get_header(h, &fmt, &ch, &rate, &bits, &bytes)) {
    wav_read_close(h);
    return AEC_ERR_INTERNAL;
  }
  wav_read_close(h);

  const double seconds =
      (rate > 0 && ch > 0 && bits > 0)
          ? static_cast<double>(bytes) / (rate * ch * (bits / 8))
          : 0.0;

  char line[256];
  snprintf(line, sizeof(line),
           "channels: %d\r\nsample_rate: %d\r\nbits_per_sample: %d\r\n"
           "data_bytes: %u\r\nduration: %.3f s",
           ch, rate, bits, bytes, seconds);

  if (static_cast<int>(strlen(line)) >= buffer_size) {
    return AEC_ERR_BAD_ARG;
  }
  memcpy(buffer, line, strlen(line) + 1);
  return AEC_OK;
}

extern "C" AEC_API int AEC_CALL AEC_GetAudioFormat(const char* file_path,
                                                   AecAudioFormat* out_format) {
  if (file_path == nullptr || out_format == nullptr) {
    return AEC_ERR_BAD_ARG;
  }
  memset(out_format, 0, sizeof(*out_format));

  void* h = wav_read_open(file_path);
  if (h == nullptr) {
    return AEC_ERR_OPEN_REF;
  }
  int fmt = 0, ch = 0, rate = 0, bits = 0;
  unsigned int bytes = 0;
  if (!wav_get_header(h, &fmt, &ch, &rate, &bits, &bytes)) {
    wav_read_close(h);
    return AEC_ERR_INTERNAL;
  }
  wav_read_close(h);

  out_format->sample_rate_hz = rate;
  out_format->channels = ch;
  out_format->bits_per_sample = bits;
  out_format->format_tag = fmt;
  out_format->data_bytes = bytes;
  out_format->is_supported =
      (fmt == 1 && bits == 16 && ch == 1 && IsSupportedRate(rate)) ? 1 : 0;
  return AEC_OK;
}
