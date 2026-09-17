// Console driver for the C# P/Invoke layer.
// Compiles NativeAec.cs directly so it exercises the exact same interop code
// the WinForms app uses, without needing anyone to click a button.
//
// Build: see tools/build_cs_test.ps1  (must be x64, matching aec_api.dll)
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace AecToolApp_2
{
    internal static class CsInteropTest
    {
        private static int _callbackCount;
        private static int _lastCurrent;
        private static int _lastTotal;
        private static bool _monotonic = true;
        private static int _fails;

        private static void Check(string name, bool ok, string detail)
        {
            Console.WriteLine((ok ? "  OK      " : "  FAIL    ") + name.PadRight(46) + detail);
            if (!ok) _fails++;
        }

        private static void OnProgress(int current, int total, IntPtr user)
        {
            _callbackCount++;
            if (current < _lastCurrent) _monotonic = false;
            _lastCurrent = current;
            _lastTotal = total;
        }

        private static int Main(string[] args)
        {
            Console.OutputEncoding = Encoding.UTF8;
            if (args.Length < 3)
            {
                Console.WriteLine("usage: cs_interop_test <ref.wav> <mic.wav> <out.wav>");
                return 2;
            }
            string refPath = args[0], micPath = args[1], outPath = args[2];

            Console.WriteLine("================ 1. DLL availability probe ================");
            string problem = NativeAec.ProbeAvailability();
            Check("ProbeAvailability returns null (DLL loads)", problem == null, problem ?? "(loaded)");
            if (problem != null) return 3;

            Console.WriteLine();
            Console.WriteLine("================ 2. GetAudioInfo via StringBuilder ================");
            var sb = new StringBuilder(512);
            int rc = NativeAec.AEC_GetAudioInfo(refPath, sb, sb.Capacity);
            Check("GetAudioInfo(ref) == AEC_OK", rc == NativeAec.AEC_OK, "rc=" + rc);
            Console.WriteLine("    -> " + sb.ToString().Replace("\r\n", " | "));

            // Small buffer must be rejected rather than overflow.
            var tiny = new StringBuilder(8);
            rc = NativeAec.AEC_GetAudioInfo(refPath, tiny, tiny.Capacity);
            Check("GetAudioInfo with 8-byte buffer rejected",
                  rc == NativeAec.AEC_ERR_BAD_ARG, "rc=" + rc);

            Console.WriteLine();
            Console.WriteLine("================ 3. error codes surfaced to C# ================");
            rc = NativeAec.AEC_ProcessAudioFiles(null, micPath, outPath, null, IntPtr.Zero);
            Check("null ref path -> BAD_ARG (-1)", rc == NativeAec.AEC_ERR_BAD_ARG, "rc=" + rc);

            rc = NativeAec.AEC_ProcessAudioFiles("no_such_zzz.wav", micPath, outPath, null, IntPtr.Zero);
            Check("missing ref -> OPEN_REF (-2)", rc == NativeAec.AEC_ERR_OPEN_REF, "rc=" + rc);

            rc = NativeAec.AEC_ProcessAudioFiles(refPath, "no_such_zzz.wav", outPath, null, IntPtr.Zero);
            Check("missing mic -> OPEN_MIC (-3)", rc == NativeAec.AEC_ERR_OPEN_MIC, "rc=" + rc);

            rc = NativeAec.AEC_ProcessAudioFiles(refPath, micPath,
                     Path.Combine("Z:\\definitely_missing_dir\\", "x.wav"), null, IntPtr.Zero);
            Check("bad output dir -> CREATE_OUT (-6)", rc == NativeAec.AEC_ERR_CREATE_OUT, "rc=" + rc);
            IntPtr bad = NativeAec.AEC_Create(44100, 1);
            Check("AEC_Create(44100) returns NULL", bad == IntPtr.Zero, "handle=" + bad);

            Console.WriteLine();
            Console.WriteLine("================ 4. DescribeError mapping ================");
            foreach (int code in new[] { 0, -1, -2, -3, -4, -5, -6, -7, -99 })
            {
                Console.WriteLine(string.Format("    {0,4} -> {1}", code, NativeAec.DescribeError(code)));
            }

            Console.WriteLine();
            Console.WriteLine("================ 5. end-to-end via Task.Run + callback ================");
            _callbackCount = 0; _lastCurrent = 0; _lastTotal = 0; _monotonic = true;

            // This is exactly how Form1 drives it: delegate kept in a field, call
            // off the UI thread, marshal progress back through a closure.
            NativeAec.ProgressCallback cb = OnProgress;
            GC.KeepAlive(cb);

            var uiMarshals = 0;
            var progressFromWorker = new Progress<int>(p => Interlocked.Increment(ref uiMarshals));

            if (File.Exists(outPath)) File.Delete(outPath);

            var sw = System.Diagnostics.Stopwatch.StartNew();
            int result = -999;
            Task.Run(() =>
            {
                result = NativeAec.AEC_ProcessAudioFiles(refPath, micPath, outPath, cb, IntPtr.Zero);
            }).GetAwaiter().GetResult();
            sw.Stop();

            Check("ProcessAudioFiles == AEC_OK", result == NativeAec.AEC_OK, "rc=" + result);
            Check("output file created", File.Exists(outPath),
                  File.Exists(outPath) ? new FileInfo(outPath).Length + " bytes" : "missing");
            Check("callback invoked", _callbackCount > 0, _callbackCount + " calls");
            Check("callback progress monotonic", _monotonic,
                  _lastCurrent + "/" + _lastTotal);
            Check("callback reached 100%", _lastTotal > 0 && _lastCurrent == _lastTotal,
                  _lastCurrent + "/" + _lastTotal);
            Console.WriteLine(string.Format("    elapsed: {0:F3} s", sw.Elapsed.TotalSeconds));

            Console.WriteLine();
            Console.WriteLine("================ 6. streaming API from C# ================");
            IntPtr h = NativeAec.AEC_Create(16000, 1);
            Check("AEC_Create(16000,1) != NULL", h != IntPtr.Zero, "handle=" + h);
            if (h != IntPtr.Zero)
            {
                int frame = 160;
                short[] render = new short[frame];
                short[] mic = new short[frame];
                short[] outp = new short[frame];
                short[] lin = new short[160];

                // feed silence for a few frames; only the ABI is under test here
                int src = NativeAec.AEC_Process(h, render, mic, outp, lin, frame);
                Check("AEC_Process(silence) == AEC_OK", src == NativeAec.AEC_OK, "rc=" + src);

                src = NativeAec.AEC_Process(h, render, mic, outp, null, frame);
                Check("AEC_Process with linearOut=null", src == NativeAec.AEC_OK, "rc=" + src);

                src = NativeAec.AEC_Process(h, render, mic, outp, lin, 999);
                Check("AEC_Process with wrong frameSize rejected",
                      src == NativeAec.AEC_ERR_BAD_ARG, "rc=" + src);

                double erl, erle; int delay;
                src = NativeAec.AEC_GetMetrics(h, out erl, out erle, out delay);
                Check("AEC_GetMetrics == AEC_OK", src == NativeAec.AEC_OK,
                      string.Format("ERL={0:F2} ERLE={1:F2} delay={2}", erl, erle, delay));

                src = NativeAec.AEC_SetAudioBufferDelay(h, 0);
                Check("AEC_SetAudioBufferDelay == AEC_OK", src == NativeAec.AEC_OK, "rc=" + src);

                NativeAec.AEC_Destroy(h);
                Console.WriteLine("  OK      AEC_Destroy(handle) did not crash");
            }

            Console.WriteLine();
            Console.WriteLine("================ 7. dispose safety ================");
            NativeAec.AEC_Destroy(IntPtr.Zero);   // must not crash
            Console.WriteLine("  OK      AEC_Destroy(NULL) did not crash");

            Console.WriteLine();
            Console.WriteLine("================ 8. cancellation ================");
            RunCancelTest(refPath, micPath, outPath);

            Console.WriteLine();
            Console.WriteLine("================ 9. format pre-check ================");
            string summary;
            string pairProblem = NativeAec.ValidatePair(refPath, micPath, out summary);
            Check("ValidatePair accepts matching 16k/mono/16bit", pairProblem == null, pairProblem ?? summary);

            NativeAec.AudioFormat af;
            rc = NativeAec.AEC_GetAudioFormat(refPath, out af);
            Check("GetAudioFormat == AEC_OK", rc == NativeAec.AEC_OK,
                  string.Format("{0} Hz/{1}ch/{2}bit/tag={3}/supported={4}",
                                af.SampleRateHz, af.Channels, af.BitsPerSample,
                                af.FormatTag, af.IsSupported));

            // A missing file must be rejected before any processing starts.
            pairProblem = NativeAec.ValidatePair(refPath, "no_such_file_zzz.wav", out summary);
            Check("ValidatePair rejects a missing file", pairProblem != null, pairProblem ?? "(accepted!)");

            Console.WriteLine();
            Console.WriteLine(_fails == 0
                ? "RESULT: ALL C# INTEROP TESTS PASSED"
                : string.Format("RESULT: {0} TEST(S) FAILED", _fails));
            return _fails == 0 ? 0 : 1;
        }

        // ------------------------------------------------------------------
        // cancellation: the abort flag must stop a long run promptly
        // ------------------------------------------------------------------
        private static int _cancelAtFrame;
        private static int _cancelRequested;
        private static int _cancelLastFrame;
        private static readonly ManualResetEventSlim _cancelSeen = new ManualResetEventSlim(false);

        private static void OnProgressCancel(int current, int total, IntPtr user)
        {
            _cancelLastFrame = current;
            if (current >= _cancelAtFrame && Interlocked.Exchange(ref _cancelRequested, 1) == 0)
            {
                NativeAec.RequestCancel();
                _cancelSeen.Set();
                Console.WriteLine(string.Format("    -> RequestCancel() at frame {0}/{1}", current, total));
            }
        }

        private static void RunCancelTest(string refPath, string micPath, string outPath)
        {
            _cancelAtFrame = 200;
            _cancelRequested = 0;
            _cancelLastFrame = 0;
            _cancelSeen.Reset();

            NativeAec.ResetCancel();

            string partial = outPath + ".cancelled.wav";
            // The DLL also writes a "<stem>_linear.wav" companion next to out_path.
            string partialLinear =
                Path.Combine(Path.GetDirectoryName(partial),
                             Path.GetFileNameWithoutExtension(partial) + "_linear.wav");
            foreach (string f in new[] { partial, partialLinear })
            {
                if (File.Exists(f)) File.Delete(f);
            }

            NativeAec.ProgressCallback cb = OnProgressCancel;
            GC.KeepAlive(cb);

            int result = -999;
            Task.Run(() =>
            {
                result = NativeAec.AEC_ProcessAudioFilesEx(
                    refPath, micPath, partial, 0, 0, cb, IntPtr.Zero,
                    NativeAec.AbortFlagPointer);
            }).GetAwaiter().GetResult();

            Check("cancel requested reached the DLL", _cancelSeen.IsSet, "at frame " + _cancelLastFrame);
            Check("aborted run returns ABORTED (-8)", result == NativeAec.AEC_ERR_ABORTED, "rc=" + result);
            // 999 frames total; stopping near 200 (+ one poll interval of 8) proves
            // cancellation is prompt rather than at end-of-file.
            Check("stopped promptly, not at end of file",
                  _cancelLastFrame > 0 && _cancelLastFrame < 300,
                  string.Format("last frame {0} of 999", _cancelLastFrame));

            // An aborted run leaves partial files with no valid wav header, so both
            // the main output AND its linear companion must be removable by the
            // caller. This is what Form1.DiscardPartialOutputs does.
            int removed = 0;
            foreach (string f in new[] { partial, partialLinear })
            {
                try { if (File.Exists(f)) { File.Delete(f); removed++; } }
                catch (IOException ex) { Console.WriteLine("    delete failed: " + ex.Message); }
            }
            Check("partial main+linear outputs are removable", removed >= 1,
                  string.Format("{0} file(s) removed", removed));
            Check("no partial files left behind",
                  !File.Exists(partial) && !File.Exists(partialLinear),
                  File.Exists(partial) || File.Exists(partialLinear) ? "leftovers remain" : "clean");

            // Flag must be resettable, otherwise every later run cancels instantly.
            NativeAec.ResetCancel();
            int again = NativeAec.AEC_ProcessAudioFilesEx(
                refPath, micPath, outPath, 0, 0, null, IntPtr.Zero, NativeAec.AbortFlagPointer);
            Check("rerun after ResetCancel succeeds", again == NativeAec.AEC_OK, "rc=" + again);

            foreach (string f in new[] { partial, partialLinear, outPath })
            {
                try { if (File.Exists(f)) File.Delete(f); } catch { }
            }
        }
    }
}
