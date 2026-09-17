/*
 * aec_c_api.h - the only public ABI of aec_api.dll
 *
 * Plain C interface around WebRTC's EchoCanceller3, intended for P/Invoke
 * consumption from C# (and consumable from any other language).
 *
 * Conventions:
 *   - Every exported symbol is extern "C" with __cdecl, so no name mangling
 *     and no A/W suffix probing.
 *   - Every function returns 0 (AEC_OK) on success or a negative AEC_ERR_* code.
 *   - No function returns a heap pointer that the caller must free; string
 *     outputs use a caller-owned buffer.
 *   - Handles are opaque void*.
 */

#ifndef AEC_C_API_H_
#define AEC_C_API_H_

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(AEC_C_API_BUILD_DLL)
#    define AEC_API __declspec(dllexport)
#  else
#    define AEC_API __declspec(dllimport)
#  endif
#  define AEC_CALL __cdecl
#else
#  define AEC_API
#  define AEC_CALL
#endif

/* ------------------------------------------------------------------ */
/* error codes                                                         */
/* ------------------------------------------------------------------ */
enum {
  AEC_OK                  =  0,
  AEC_ERR_BAD_ARG         = -1,  /* null / malformed argument                */
  AEC_ERR_OPEN_REF        = -2,  /* cannot open reference wav                 */
  AEC_ERR_OPEN_MIC        = -3,  /* cannot open microphone wav                */
  AEC_ERR_FORMAT_MISMATCH = -4,  /* ref and mic formats differ                */
  AEC_ERR_UNSUPPORTED_FMT = -5,  /* not 16-bit PCM / not mono / bad rate      */
  AEC_ERR_CREATE_OUT      = -6,  /* cannot create output wav                  */
  AEC_ERR_INTERNAL        = -7,  /* instantiation or processing failure       */
  AEC_ERR_ABORTED         = -8   /* cancelled through the abort flag          */
};

/* Sample rates accepted by EchoCanceller3. */
#define AEC_RATE_16K 16000
#define AEC_RATE_32K 32000
#define AEC_RATE_48K 48000

/* Linear-filter output rate produced by AEC_Process (fixed by the algorithm). */
#define AEC_LINEAR_RATE_HZ 16000

/* Progress callback: called once per processed frame.
 * current runs 1..total. user is the pointer passed to the entry point.
 * Never call back into the AEC from inside this callback. */
typedef void (AEC_CALL *AecProgressFn)(int current, int total, void* user);

/* ------------------------------------------------------------------ */
/* cancellation                                                        */
/* ------------------------------------------------------------------ */

/* Returns a pointer to an implementation-static, 8-byte aligned int32 flag
 * whose initial value is 0.
 *
 * Lifetime: the flag belongs to the DLL and stays valid for the whole process,
 * so there is nothing to free. It is shared by all concurrent calls, therefore
 * only one cancellation-able operation should run at a time.
 *
 * Usage:
 *   1. write 0 into the flag before starting,
 *   2. hand the pointer to AEC_ProcessAudioFilesEx / AEC_ProcessAudioFiles via
 *      the abort param,
 *   3. write a non-zero value (atomically) from any thread to cancel.
 *
 * The processing loop polls it roughly every 8 frames (~80 ms of audio), so a
 * long file stops promptly. On cancellation the function returns
 * AEC_ERR_ABORTED and the partially written output file is left in place; the
 * caller is responsible for deleting it. Writing the value 0 back is all that
 * is needed before the next run. */
AEC_API int* AEC_CALL AEC_GetAbortFlag(void);

/* ------------------------------------------------------------------ */
/* streaming API                                                       */
/* ------------------------------------------------------------------ */

/* Creates an AEC instance.
 * sample_rate_hz must be AEC_RATE_16K, AEC_RATE_32K or AEC_RATE_48K.
 * channels must be 1 (mono) for now.
 * Returns NULL on failure. */
AEC_API void* AEC_CALL AEC_Create(int sample_rate_hz, int channels);

/* Number of frames that must be processed before AEC_SetAudioBufferDelay may be
 * called. Feeding at least this many frames first is required: the render delay
 * buffer must contain real data before an explicit delay is applied, otherwise
 * the first capture call reads uninitialized samples. */
#define AEC_MIN_FRAMES_BEFORE_DELAY 1

/* Releases an instance. NULL is ignored. */
AEC_API void AEC_CALL AEC_Destroy(void* handle);

/* Processes exactly one 10 ms frame, in place on the caller's buffers.
 *
 *   render      [in]  frame_size samples of the far-end / reference signal
 *   mic         [in]  frame_size samples of the microphone signal (with echo)
 *   out         [out] frame_size samples of the echo-cancelled signal
 *   linear_out  [out] AEC_LINEAR_RATE_HZ/100 samples, or NULL to skip.
 *                     Must have room for AEC_LINEAR_RATE_HZ/100 samples.
 *   frame_size  must equal sample_rate_hz / 100.
 *
 * Call order per frame is render-before-capture; do not interleave.
 * Returns AEC_OK or a negative error code. On error nothing is written. */
AEC_API int AEC_CALL AEC_Process(void* handle,
                                 const short* render,
                                 const short* mic,
                                 short* out,
                                 short* linear_out,
                                 int frame_size);

/* Optional external estimate of the end-to-end buffer delay, in ms.
 * Must be called AFTER at least AEC_MIN_FRAMES_BEFORE_DELAY frames have been
 * processed, never before the first AEC_Process (doing so applies a non-zero
 * delay to an empty render buffer and the next capture call reads uninitialized
 * data). Call it once; repeated calls keep resetting the delay estimate.
 * Passing 0 tells AEC3 there is no additional fixed latency, which is the right
 * value for offline file processing and measurably outperforms letting AEC3
 * estimate the delay itself. */
AEC_API int AEC_CALL AEC_SetAudioBufferDelay(void* handle, int delay_ms);

/* Reads current metrics. Any of the three out-pointers may be NULL. */
AEC_API int AEC_CALL AEC_GetMetrics(void* handle,
                                    double* echo_return_loss,
                                    double* echo_return_loss_enhancement,
                                    int* delay_ms);

/* ------------------------------------------------------------------ */
/* whole-file API                                                      */
/* ------------------------------------------------------------------ */

/* Processes two wav files end to end and writes the echo-cancelled result.
 *
 *   ref_path   far-end / reference wav   (16-bit PCM, mono, 16k|32k|48k)
 *   mic_path   microphone wav            (same format as ref)
 *   out_path   output wav; the directory must exist
 *   cb         optional progress callback
 *   user       opaque pointer handed back to cb
 *
 * Also writes the linear-filter output as "<out_path without extension>_linear.wav"
 * next to out_path when it can be created; failure to create it is not an error.
 *
 * Both inputs must have the same format. The trailing partial frame, if any,
 * is ignored. Returns AEC_OK or a negative error code. */
AEC_API int AEC_CALL AEC_ProcessAudioFiles(const char* ref_path,
                                           const char* mic_path,
                                           const char* out_path,
                                           AecProgressFn cb,
                                           void* user);

/* Same as AEC_ProcessAudioFiles, but reports an explicit end-to-end delay in ms
 * (0 = no additional fixed latency, which is correct for offline file pairs).
 * Pass set_delay = 0 to leave the delay to AEC3's own estimator.
 * The delay is applied after the first frame, so this is safe from the start.
 * abort may be NULL; otherwise pass AEC_GetAbortFlag() to make the run
 * cancellable. */
AEC_API int AEC_CALL AEC_ProcessAudioFilesEx(const char* ref_path,
                                             const char* mic_path,
                                             const char* out_path,
                                             int set_delay,
                                             int delay_ms,
                                             AecProgressFn cb,
                                             void* user,
                                             int* abort);

/* Writes a human-readable description of a wav header into buffer.
 * buffer must hold at least buffer_size bytes; 512 is plenty.
 * Always NUL-terminates on success. */
AEC_API int AEC_CALL AEC_GetAudioInfo(const char* file_path,
                                      char* buffer,
                                      int buffer_size);

/* Plain fields of a wav header, so a caller can validate inputs up front
 * instead of discovering a format problem after processing has started. */
typedef struct AecAudioFormat {
  int sample_rate_hz;
  int channels;
  int bits_per_sample;
  int format_tag;      /* 1 = PCM */
  unsigned int data_bytes;
  int is_supported;    /* 1 when this DLL can process the file as-is */
} AecAudioFormat;

AEC_API int AEC_CALL AEC_GetAudioFormat(const char* file_path,
                                        AecAudioFormat* out_format);

#ifdef __cplusplus
}
#endif

#endif /* AEC_C_API_H_ */
