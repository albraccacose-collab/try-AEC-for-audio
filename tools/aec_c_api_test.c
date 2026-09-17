/*
 * aec_c_api_test.c - native test harness for aec_api.dll
 *
 * Two modes:
 *   streaming : drive AEC_Create/AEC_Process frame by frame from two wav files
 *               and write the result; used to prove byte-equality with demo.exe
 *   file      : call AEC_ProcessAudioFiles and report timing / progress
 *
 * Build (from a vcvars64 shell):
 *   cl /nologo /W3 /Fe:aec_c_api_test.exe aec_c_api_test.c /link aec_api.lib
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <windows.h>

#include "aec_c_api.h"
#include "wavreader.h"
#include "wavwriter.h"

static void AEC_CALL on_progress(int current, int total, void* user) {
  int* last = (int*)user;
  /* print roughly every 10% */
  if (total > 0 && (current == total || current - *last >= total / 10)) {
    *last = current;
    printf("    progress %d/%d (%d%%)\n", current, total,
           (int)((double)current / total * 100.0));
  }
}

/* Progress callback that requests cancellation part-way through. */
typedef struct {
  int cancel_at;
  int requested;
  int last_current;
} abort_ctx;

static void AEC_CALL on_progress_abort(int current, int total, void* user) {
  abort_ctx* c = (abort_ctx*)user;
  c->last_current = current;
  if (current >= c->cancel_at && !c->requested) {
    c->requested = 1;
    /* Any thread may store; the DLL polls this every 8 frames. */
    *AEC_GetAbortFlag() = 1;
    printf("    -> abort requested at frame %d/%d\n", current, total);
  }
}

static int run_cancel(int argc, char** argv) {
  if (argc < 5) {
    printf("usage: %s cancel ref.wav mic.wav out.wav [cancel_at_frame]\n", argv[0]);
    return 2;
  }
  const char* ref_path = argv[2];
  const char* mic_path = argv[3];
  const char* out_path = argv[4];
  const int cancel_at = (argc >= 6) ? atoi(argv[5]) : 200;
  int fails = 0;

  /* reset the flag before the run */
  *AEC_GetAbortFlag() = 0;

  abort_ctx ctx;
  ctx.cancel_at = cancel_at;
  ctx.requested = 0;
  ctx.last_current = 0;

  int rc = AEC_ProcessAudioFilesEx(ref_path, mic_path, out_path,
                                   /*set_delay=*/0, /*delay_ms=*/0,
                                   on_progress_abort, &ctx, AEC_GetAbortFlag());

  printf("  AEC_GetAbortFlag() non-NULL          : %s\n",
         AEC_GetAbortFlag() != NULL ? "yes" : "NO");
  if (AEC_GetAbortFlag() == NULL) fails++;
  printf("  cancel requested                     : %s (at frame %d)\n",
         ctx.requested ? "yes" : "NO", ctx.last_current);
  if (!ctx.requested) fails++;
  printf("  returned code                        : %d (expect %d = ABORTED)\n",
         rc, AEC_ERR_ABORTED);
  if (rc != AEC_ERR_ABORTED) fails++;
  printf("  stopped around the cancel point      : %s (last frame %d, cancel_at %d)\n",
         (ctx.last_current < cancel_at + 64) ? "yes" : "NO",
         ctx.last_current, cancel_at);
  if (ctx.last_current >= cancel_at + 64) fails++;

  /* a second, uncancelled run must succeed with the flag reset */
  *AEC_GetAbortFlag() = 0;
  int last = 0;
  rc = AEC_ProcessAudioFiles(ref_path, mic_path, out_path, on_progress, &last);
  printf("  rerun after resetting flag           : %d (expect 0 = OK)\n", rc);
  if (rc != AEC_OK) fails++;

  printf("  %s (%d unexpected results)\n",
         fails == 0 ? "ABORT SEMANTICS OK" : "ABORT CASES WRONG", fails);
  return (fails == 0) ? 0 : 1;
}

static int run_streaming(int argc, char** argv) {
  if (argc < 5) {
    printf("usage: %s <streaming|streaming-every> ref.wav mic.wav out.wav [linear.wav|-] [delay_ms]\n", argv[0]);
    return 2;
  }
  const int every_frame = (strcmp(argv[1], "streaming-every") == 0);
  const char* ref_path = argv[2];
  const char* mic_path = argv[3];
  const char* out_path = argv[4];
  const char* lin_path = (argc >= 6 && strcmp(argv[5], "-") != 0) ? argv[5] : NULL;
  const int want_delay = (argc >= 7) ? atoi(argv[6]) : -1;  /* -1 = don't set */

  void* h_ref = wav_read_open(ref_path);
  void* h_mic = wav_read_open(mic_path);
  if (h_ref == NULL || h_mic == NULL) {
    printf("FAIL: cannot open inputs\n");
    return 3;
  }

  int rfmt, rch, rrate, rbits, mfmt, mch, mrate, mbits;
  unsigned int rbytes, mbytes;
  wav_get_header(h_ref, &rfmt, &rch, &rrate, &rbits, &rbytes);
  wav_get_header(h_mic, &mfmt, &mch, &mrate, &mbits, &mbytes);

  printf("  ref : %d Hz, %d ch, %d bit, %u bytes\n", rrate, rch, rbits, rbytes);
  printf("  mic : %d Hz, %d ch, %d bit, %u bytes\n", mrate, mch, mbits, mbytes);

  const int frame_size = rrate / 100;          /* 10 ms */
  const int bytes_per_frame = frame_size * 2;

  size_t usable = (size_t)(rbytes / bytes_per_frame);
  if ((size_t)(mbytes / bytes_per_frame) < usable) usable = mbytes / bytes_per_frame;

  void* h_out = wav_write_open(out_path, rrate, 16, rch);
  if (h_out == NULL) { printf("FAIL: cannot open output\n"); return 3; }
  void* h_lin = NULL;
  if (lin_path != NULL) {
    h_lin = wav_write_open(lin_path, AEC_LINEAR_RATE_HZ, 16, rch);
  }

  void* aec = AEC_Create(rrate, rch);
  if (aec == NULL) { printf("FAIL: AEC_Create returned NULL\n"); return 4; }

  short* ref_buf = (short*)malloc(bytes_per_frame);
  short* mic_buf = (short*)malloc(bytes_per_frame);
  short* out_buf = (short*)malloc(bytes_per_frame);
  short* lin_buf = (short*)malloc(AEC_LINEAR_RATE_HZ / 100 * sizeof(short));

  int rc = AEC_OK;
  size_t i;
  for (i = 0; i < usable; ++i) {
    if (wav_read_data(h_ref, (unsigned char*)ref_buf, bytes_per_frame) < 0 ||
        wav_read_data(h_mic, (unsigned char*)mic_buf, bytes_per_frame) < 0) {
      printf("FAIL: short read at frame %zu\n", i);
      rc = AEC_ERR_INTERNAL;
      break;
    }
    rc = AEC_Process(aec, ref_buf, mic_buf, out_buf,
                     (h_lin != NULL) ? lin_buf : NULL, frame_size);
    if (rc != AEC_OK) {
      printf("FAIL: AEC_Process frame %zu returned %d\n", i, rc);
      break;
    }
    /* demo.cc calls SetAudioBufferDelay(0) on EVERY frame. "streaming-every"
     * reproduces that; plain "streaming" sets it once after frame 0. */
    if (want_delay >= 0 && (i == 0 || every_frame)) {
      AEC_SetAudioBufferDelay(aec, want_delay);
    }
    wav_write_data(h_out, (const unsigned char*)out_buf, bytes_per_frame);
    if (h_lin != NULL) {
      wav_write_data(h_lin, (const unsigned char*)lin_buf,
                     AEC_LINEAR_RATE_HZ / 100 * 2);
    }
  }

  double erl = 0.0, erle = 0.0;
  int delay = 0;
  AEC_GetMetrics(aec, &erl, &erle, &delay);
  printf("  frames processed : %zu\n", i);
  printf("  metrics          : ERL=%.2f dB  ERLE=%.2f dB  delay=%d ms\n",
         erl, erle, delay);

  free(lin_buf); free(out_buf); free(mic_buf); free(ref_buf);
  AEC_Destroy(aec);
  wav_write_close(h_out);
  if (h_lin) wav_write_close(h_lin);
  wav_read_close(h_ref);
  wav_read_close(h_mic);

  if (rc != AEC_OK) return 5;
  printf("  OK\n");
  return 0;
}

static int run_file(int argc, char** argv) {
  if (argc < 5) {
    printf("usage: %s file ref.wav mic.wav out.wav [-|<delay_ms>]\n", argv[0]);
    return 2;
  }
  int last = 0;
  int use_ex = 0;
  int delay_ms = 0;
  if (argc >= 6 && strcmp(argv[5], "-") != 0) {
    use_ex = 1;
    delay_ms = atoi(argv[5]);
  }
  clock_t t0 = clock();
  int rc = use_ex ? AEC_ProcessAudioFilesEx(argv[2], argv[3], argv[4], 1, delay_ms,
                                            on_progress, &last, NULL)
                  : AEC_ProcessAudioFiles(argv[2], argv[3], argv[4], on_progress, &last);
  clock_t t1 = clock();
  printf("  mode: %s (delay=%d ms)\n", use_ex ? "ProcessAudioFilesEx" : "ProcessAudioFiles",
         use_ex ? delay_ms : -999);
  printf("  AEC_ProcessAudioFiles returned %d\n", rc);
  printf("  elapsed: %.3f s\n", (double)(t1 - t0) / CLOCKS_PER_SEC);
  return (rc == AEC_OK) ? 0 : 1;
}

static int run_info(int argc, char** argv) {
  if (argc < 3) {
    printf("usage: %s info file.wav\n", argv[0]);
    return 2;
  }
  char buf[512];
  int rc = AEC_GetAudioInfo(argv[2], buf, (int)sizeof(buf));
  printf("  AEC_GetAudioInfo returned %d\n", rc);
  if (rc == AEC_OK) printf("---\n%s\n---\n", buf);
  return (rc == AEC_OK) ? 0 : 1;
}

static int run_errorcases(int argc, char** argv) {
  if (argc < 3) {
    printf("usage: %s errors ref.wav\n", argv[0]);
    return 2;
  }
  const char* ref = argv[2];
  char buf[512];
  int fails = 0;

  printf("  NULL ref_path          -> expect %d, got %d\n", AEC_ERR_BAD_ARG,
         AEC_ProcessAudioFiles(NULL, "x", "y", NULL, NULL));
  if (AEC_ProcessAudioFiles(NULL, "x", "y", NULL, NULL) != AEC_ERR_BAD_ARG) fails++;

  printf("  missing ref file       -> expect %d, got %d\n", AEC_ERR_OPEN_REF,
         AEC_ProcessAudioFiles("no_such_file_xyz.wav", ref, "o.wav", NULL, NULL));
  if (AEC_ProcessAudioFiles("no_such_file_xyz.wav", ref, "o.wav", NULL, NULL) != AEC_ERR_OPEN_REF) fails++;

  printf("  missing mic file       -> expect %d, got %d\n", AEC_ERR_OPEN_MIC,
         AEC_ProcessAudioFiles(ref, "no_such_file_xyz.wav", "o.wav", NULL, NULL));
  if (AEC_ProcessAudioFiles(ref, "no_such_file_xyz.wav", "o.wav", NULL, NULL) != AEC_ERR_OPEN_MIC) fails++;

  printf("  info buffer too small  -> expect %d, got %d\n", AEC_ERR_BAD_ARG,
         AEC_GetAudioInfo(ref, buf, 8));
  if (AEC_GetAudioInfo(ref, buf, 8) != AEC_ERR_BAD_ARG) fails++;

  printf("  AEC_Create(44100,1)    -> expect NULL, got %s\n",
         AEC_Create(44100, 1) == NULL ? "NULL" : "non-NULL");
  if (AEC_Create(44100, 1) != NULL) fails++;

  printf("  AEC_Create(16000,2)    -> expect NULL, got %s\n",
         AEC_Create(16000, 2) == NULL ? "NULL" : "non-NULL");
  if (AEC_Create(16000, 2) != NULL) fails++;

  printf("  AEC_Process(NULL,...)  -> expect %d, got %d\n", AEC_ERR_BAD_ARG,
         AEC_Process(NULL, NULL, NULL, NULL, NULL, 160));
  if (AEC_Process(NULL, NULL, NULL, NULL, NULL, 160) != AEC_ERR_BAD_ARG) fails++;

  printf("  AEC_Destroy(NULL)      -> must not crash ... ");
  AEC_Destroy(NULL);
  printf("ok\n");

  printf("  %s (%d unexpected results)\n", fails == 0 ? "ALL ERROR CASES OK" : "SOME CASES WRONG", fails);
  return (fails == 0) ? 0 : 1;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    printf("usage: %s <streaming|streaming-every|file|info|errors|cancel> ...\n", argv[0]);
    return 2;
  }
  const char* mode = argv[1];
  printf("mode: %s\n", mode);
  if (strcmp(mode, "streaming") == 0) return run_streaming(argc, argv);
  if (strcmp(mode, "streaming-every") == 0) return run_streaming(argc, argv);
  if (strcmp(mode, "file") == 0) return run_file(argc, argv);
  if (strcmp(mode, "cancel") == 0) return run_cancel(argc, argv);
  if (strcmp(mode, "info") == 0) return run_info(argc, argv);
  if (strcmp(mode, "errors") == 0) return run_errorcases(argc, argv);
  printf("unknown mode: %s\n", mode);
  return 2;
}
