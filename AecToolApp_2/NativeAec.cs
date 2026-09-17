using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace AecToolApp_2
{
    /// <summary>
    /// P/Invoke declarations for aec_api.dll.
    ///
    /// Contract notes (these are not optional):
    ///  - CallingConvention.Cdecl: the DLL exports plain extern "C" __cdecl symbols.
    ///  - CharSet.Ansi + ExactSpelling: matches the DLL's char* (MultiByte project).
    ///  - The progress delegate must be kept alive by the caller for the whole
    ///    native call, otherwise the GC may collect the thunk and the callback
    ///    crashes the process. Keep a reference in a field.
    ///  - The process must be 64-bit: aec_api.dll is x64 (PE32+).
    /// </summary>
    internal static class NativeAec
    {
        internal const string Dll = "aec_api.dll";

        // Must match the enum in aec_c_api.h
        internal const int AEC_OK = 0;
        internal const int AEC_ERR_BAD_ARG = -1;
        internal const int AEC_ERR_OPEN_REF = -2;
        internal const int AEC_ERR_OPEN_MIC = -3;
        internal const int AEC_ERR_FORMAT_MISMATCH = -4;
        internal const int AEC_ERR_UNSUPPORTED_FMT = -5;
        internal const int AEC_ERR_CREATE_OUT = -6;
        internal const int AEC_ERR_INTERNAL = -7;
        internal const int AEC_ERR_ABORTED = -8;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate void ProgressCallback(int current, int total, IntPtr user);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern int AEC_ProcessAudioFiles(
            string refPath, string micPath, string outPath,
            ProgressCallback cb, IntPtr user);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern int AEC_ProcessAudioFilesEx(
            string refPath, string micPath, string outPath,
            int setDelay, int delayMs,
            ProgressCallback cb, IntPtr user, IntPtr abort);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern int AEC_GetAudioInfo(
            string filePath, StringBuilder buffer, int bufferSize);

        /// <summary>Mirrors AecAudioFormat in aec_c_api.h.</summary>
        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioFormat
        {
            public int SampleRateHz;
            public int Channels;
            public int BitsPerSample;
            public int FormatTag;
            public uint DataBytes;
            public int IsSupported;
        }

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern int AEC_GetAudioFormat(
            string filePath, out AudioFormat format);

        /// <summary>
        /// Validates a pair of files before a long run starts, so the user is not
        /// told about a format problem only after processing has begun.
        /// Returns null when the pair is usable, otherwise a message naming the
        /// file that failed.
        /// </summary>
        internal static string ValidatePair(string refPath, string micPath, out string summary)
        {
            summary = null;
            AudioFormat rf, mf;

            if (!File.Exists(refPath)) return "参考音频文件不存在";
            if (!File.Exists(micPath)) return "麦克风录音文件不存在";

            int rc = AEC_GetAudioFormat(refPath, out rf);
            if (rc != AEC_OK) return "参考音频：" + DescribeError(rc);
            rc = AEC_GetAudioFormat(micPath, out mf);
            if (rc != AEC_OK) return "麦克风录音：" + DescribeError(rc);

            summary = string.Format(
                "参考 {0} Hz/{1}ch/{2}bit，录音 {3} Hz/{4}ch/{5}bit",
                rf.SampleRateHz, rf.Channels, rf.BitsPerSample,
                mf.SampleRateHz, mf.Channels, mf.BitsPerSample);

            if (rf.IsSupported == 0)
                return "参考音频格式不受支持（需要 16bit PCM、单声道、16k/32k/48k）";
            if (mf.IsSupported == 0)
                return "麦克风录音格式不受支持（需要 16bit PCM、单声道、16k/32k/48k）";
            if (rf.SampleRateHz != mf.SampleRateHz || rf.Channels != mf.Channels ||
                rf.BitsPerSample != mf.BitsPerSample)
                return "两个文件的格式不一致：" + summary;

            return null;
        }


        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern IntPtr AEC_Create(int sampleRateHz, int channels);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern void AEC_Destroy(IntPtr handle);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern int AEC_Process(
            IntPtr handle, short[] render, short[] mic, short[] output,
            short[] linearOut, int frameSize);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern int AEC_SetAudioBufferDelay(IntPtr handle, int delayMs);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern int AEC_GetMetrics(
            IntPtr handle, out double erl, out double erle, out int delayMs);

        /// <summary>
        /// Pointer to the DLL's shared abort flag (8-byte aligned int32).
        /// Valid for the whole process, nothing to free. Shared by all
        /// concurrent calls, so only run one cancellable operation at a time.
        /// </summary>
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
                   CharSet = CharSet.Ansi, ExactSpelling = true)]
        internal static extern IntPtr AEC_GetAbortFlag();

        // Cached abort-flag pointer. Marshalling writes to unmanaged memory
        // directly, so no unsafe/fixed block is needed.
        private static IntPtr _abortFlag = IntPtr.Zero;

        /// <summary>Clears the abort flag. Call before starting a run.</summary>
        internal static void ResetCancel()
        {
            if (_abortFlag == IntPtr.Zero) _abortFlag = AEC_GetAbortFlag();
            if (_abortFlag != IntPtr.Zero) Marshal.WriteInt32(_abortFlag, 0);
        }

        /// <summary>
        /// Requests cancellation of the running operation. Safe to call from any
        /// thread. The native loop polls the flag every 8 frames (~80 ms of
        /// audio) and then returns AEC_ERR_ABORTED.
        /// </summary>
        internal static void RequestCancel()
        {
            if (_abortFlag == IntPtr.Zero) _abortFlag = AEC_GetAbortFlag();
            if (_abortFlag != IntPtr.Zero) Marshal.WriteInt32(_abortFlag, 1);
        }

        internal static IntPtr AbortFlagPointer
        {
            get
            {
                if (_abortFlag == IntPtr.Zero) _abortFlag = AEC_GetAbortFlag();
                return _abortFlag;
            }
        }

        /// <summary>Turns a native error code into a message a user can act on.</summary>
        internal static string DescribeError(int code)
        {
            switch (code)
            {
                case AEC_OK: return "成功";
                case AEC_ERR_BAD_ARG: return "参数不合法（路径为空或缓冲区过小）";
                case AEC_ERR_OPEN_REF: return "打不开参考音频文件，请确认路径存在且可读";
                case AEC_ERR_OPEN_MIC: return "打不开麦克风音频文件，请确认路径存在且可读";
                case AEC_ERR_FORMAT_MISMATCH: return "两个文件的格式不一致（采样率/声道/位深必须相同）";
                case AEC_ERR_UNSUPPORTED_FMT:
                    return "不支持的格式：必须是 16bit PCM、单声道、采样率 16k/32k/48k";
                case AEC_ERR_CREATE_OUT: return "无法创建输出文件，请确认输出目录存在且有写权限";
                case AEC_ERR_INTERNAL: return "AEC 处理内部错误";
                case AEC_ERR_ABORTED: return "处理已被用户取消";
                default: return "未知错误";
            }
        }

        /// <summary>
        /// Checks that the DLL can be loaded and both required entry points resolve,
        /// so the UI can report a precise problem instead of a raw exception.
        /// Returns null when everything is fine.
        /// </summary>
        internal static string ProbeAvailability()
        {
            try
            {
                var sb = new StringBuilder(64);
                // Cheap call that proves the module loaded and an export resolved.
                AEC_GetAudioInfo("__probe_does_not_exist__", sb, sb.Capacity);
                return null;
            }
            catch (DllNotFoundException)
            {
                return "找不到 " + Dll + "。请把 aec_api.dll 放到程序目录，"
                     + "或确认它与本程序的位数一致（本程序为 x64）。";
            }
            catch (BadImageFormatException)
            {
                return Dll + " 的位数与本程序不匹配（本程序为 x64，需要 x64 版 DLL）。";
            }
            catch (EntryPointNotFoundException ex)
            {
                return Dll + " 与当前 C# 声明版本不一致，缺少入口点：" + ex.Message;
            }
        }
    }
}
