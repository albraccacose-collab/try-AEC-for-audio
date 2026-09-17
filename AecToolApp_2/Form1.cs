using System;
using System.Diagnostics;
using System.IO;
using System.Media;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AecToolApp_2
{
    public partial class Form1 : Form
    {
        // The native side keeps this delegate pointer for the duration of the call,
        // so it must not be collected. A field (not a local) guarantees that.
        private NativeAec.ProgressCallback _progressCallback;

        // Outputs of the most recent successful run, so the play buttons and the
        // log always agree on one path instead of each re-deriving it.
        private string _lastOutPath;
        private string _lastLinearPath;

        private int _lastPercent = -1;
        private bool _busy;
        private bool _cancelRequested;   // only touched on the UI thread

        public Form1()
        {
            InitializeComponent();
            _progressCallback = OnNativeProgress;
        }

        private void Form1_Load(object sender, EventArgs e)
        {
            string problem = NativeAec.ProbeAvailability();
            if (problem != null)
            {
                txtLog.AppendText("⚠ 原生库不可用：" + problem + "\r\n");
                btnProcess.Enabled = false;
                btnPlayOut.Enabled = false;
            }
            else
            {
                AppendLog("aec_api.dll 已就绪。");
            }
        }

        private void AppendLog(string text)
        {
            if (txtLog.IsDisposed) return;
            txtLog.AppendText(text + "\r\n");
        }

        private void SetStatus(string text)
        {
            if (lblStatus != null && !lblStatus.IsDisposed) lblStatus.Text = text;
        }

        // ---------------------------------------------------------------
        // progress callback: runs on the native processing thread
        // ---------------------------------------------------------------
        private void OnNativeProgress(int current, int total, IntPtr user)
        {
            if (total <= 0) return;

            int percent = (int)((long)current * 100 / total);
            if (percent == _lastPercent) return;   // throttle: one marshal per percent
            _lastPercent = percent;

            // The form may already be gone by the time a long run finishes.
            if (IsDisposed || !IsHandleCreated) return;

            try
            {
                BeginInvoke(new Action(() =>
                {
                    if (IsDisposed) return;
                    int v = Math.Max(progressBar1.Minimum,
                            Math.Min(progressBar1.Maximum, percent));
                    progressBar1.Value = v;
                    SetStatus(string.Format("处理中 {0}/{1} 帧 ({2}%)", current, total, percent));
                }));
            }
            catch (ObjectDisposedException)
            {
                // form closed mid-run: nothing to update
            }
        }

        // ---------------------------------------------------------------
        // file pickers
        // ---------------------------------------------------------------
        private void btnBrowseRef_Click(object sender, EventArgs e)
        {
            string path = PickWav();
            if (path == null) return;
            txtRefPath.Text = path;
            AppendLog("参考音频：" + path);
            AppendLog(ReadAudioInfo(path, "参考音频信息"));
        }

        private void btnBrowseMic_Click(object sender, EventArgs e)
        {
            string path = PickWav();
            if (path == null) return;
            txtMicPath.Text = path;
            AppendLog("麦克风录音：" + path);
            AppendLog(ReadAudioInfo(path, "麦克风录音信息"));
        }

        private string PickWav()
        {
            using (var ofd = new OpenFileDialog())
            {
                ofd.Filter = "WAV 文件|*.wav";
                ofd.Title = "选择 WAV 文件";
                return ofd.ShowDialog() == DialogResult.OK ? ofd.FileName : null;
            }
        }

        /// <summary>
        /// Reads the header via the native helper. The buffer is owned by the
        /// caller, so there is no pointer to free and nothing to leak.
        /// </summary>
        private string ReadAudioInfo(string path, string caption)
        {
            var sb = new System.Text.StringBuilder(512);
            int rc;
            try
            {
                rc = NativeAec.AEC_GetAudioInfo(path, sb, sb.Capacity);
            }
            catch (Exception ex)
            {
                return caption + "：读取失败 - " + ex.Message;
            }
            if (rc != NativeAec.AEC_OK)
            {
                return caption + "：读取失败 - " + NativeAec.DescribeError(rc);
            }
            return caption + "：\r\n" + sb.ToString().Replace("\n", "\r\n");
        }

        // ---------------------------------------------------------------
        // processing
        // ---------------------------------------------------------------
        private async void btnProcess_Click(object sender, EventArgs e)
        {
            if (_busy) return;

            string refPath = txtRefPath.Text;
            string micPath = txtMicPath.Text;
            if (string.IsNullOrWhiteSpace(refPath) || string.IsNullOrWhiteSpace(micPath))
            {
                MessageBox.Show("请先选择参考音频和麦克风录音两个文件。", "缺少输入",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (!File.Exists(refPath) || !File.Exists(micPath))
            {
                MessageBox.Show("文件不存在，请重新选择。", "文件缺失",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // Validate the pair up front so the user is not told about a format
            // problem only after a long run has already started.
            string summary;
            string formatProblem = NativeAec.ValidatePair(refPath, micPath, out summary);
            if (formatProblem != null)
            {
                AppendLog("格式检查未通过：" + formatProblem);
                MessageBox.Show(formatProblem, "格式检查未通过",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            AppendLog("格式检查通过：" + summary);

            // Output goes next to the microphone recording, named after it, so two
            // different recordings never overwrite each other's result.
            string outPath = BuildOutputPath(micPath, "_aec.wav");
            string linearPath = BuildOutputPath(micPath, "_aec_linear.wav");

            _busy = true;
            _cancelRequested = false;
            btnProcess.Enabled = false;
            btnCancel.Enabled = true;
            btnPlayOut.Enabled = false;
            _lastPercent = -1;
            progressBar1.Value = 0;
            AppendLog(string.Format("开始处理… 输出：{0}", outPath));
            SetStatus("处理中…");

            var sw = Stopwatch.StartNew();
            try
            {
                NativeAec.ResetCancel();

                // The native call blocks for the whole file, so keep it off the UI thread.
                int rc = await Task.Run(() => NativeAec.AEC_ProcessAudioFilesEx(
                    refPath, micPath, outPath,
                    0, 0,                                  // let the DLL pick the delay
                    _progressCallback, IntPtr.Zero,
                    NativeAec.AbortFlagPointer));

                sw.Stop();

                if (rc == NativeAec.AEC_OK)
                {
                    _lastOutPath = outPath;
                    _lastLinearPath = File.Exists(linearPath) ? linearPath : null;

                    progressBar1.Value = progressBar1.Maximum;
                    AppendLog(string.Format("处理成功，用时 {0:F2} 秒。", sw.Elapsed.TotalSeconds));
                    AppendLog("输出文件：" + outPath);
                    if (_lastLinearPath != null)
                        AppendLog("线性滤波输出：" + _lastLinearPath);
                    SetStatus("完成");
                    btnPlayOut.Enabled = true;
                }
                else if (rc == NativeAec.AEC_ERR_ABORTED)
                {
                    AppendLog(string.Format("已取消，用时 {0:F2} 秒。", sw.Elapsed.TotalSeconds));
                    SetStatus("已取消");
                    // The native side stops mid-frame, so the partial file has no
                    // valid wav header; do not leave a broken file behind.
                    DiscardPartialOutputs(outPath, linearPath);
                }
                else
                {
                    string msg = NativeAec.DescribeError(rc);
                    AppendLog(string.Format("处理失败：{0}（错误码 {1}）", msg, rc));
                    SetStatus("失败：" + msg);
                    DiscardPartialOutputs(outPath, linearPath);
                    MessageBox.Show(msg, "处理失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
            catch (DllNotFoundException)
            {
                ReportFatal("找不到 aec_api.dll，请确认它位于程序目录。");
            }
            catch (BadImageFormatException)
            {
                ReportFatal("aec_api.dll 位数为 32 位，而本程序是 64 位（或反之），无法加载。");
            }
            catch (EntryPointNotFoundException ex)
            {
                ReportFatal("aec_api.dll 与当前程序版本不匹配：\r\n" + ex.Message);
            }
            catch (Exception ex)
            {
                ReportFatal("发生未预期的错误：\r\n" + ex);
            }
            finally
            {
                _busy = false;
                btnProcess.Enabled = true;
                btnCancel.Enabled = false;
            }
        }

        private void btnCancel_Click(object sender, EventArgs e)
        {
            if (!_busy || _cancelRequested) return;
            _cancelRequested = true;
            NativeAec.RequestCancel();
            btnCancel.Enabled = false;
            SetStatus("正在取消…");
            AppendLog("已请求取消，等待当前帧结束…");
        }

        /// <summary>
        /// Removes outputs of an aborted or failed run: the native side stops
        /// mid-write, so the file exists but has no valid header.
        /// </summary>
        private void DiscardPartialOutputs(string outPath, string linearPath)
        {
            foreach (string p in new[] { outPath, linearPath })
            {
                try
                {
                    if (p != null && File.Exists(p)) File.Delete(p);
                }
                catch (IOException ex)
                {
                    AppendLog("清理未完成输出失败：" + ex.Message);
                }
            }
        }

        private void ReportFatal(string message)
        {
            AppendLog("错误：" + message);
            SetStatus("错误");
            MessageBox.Show(message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        /// <summary>
        /// Builds a non-colliding output path derived from the input file name.
        /// </summary>
        private static string BuildOutputPath(string sourceWav, string suffix)
        {
            string dir = Path.GetDirectoryName(sourceWav);
            if (string.IsNullOrEmpty(dir)) dir = Environment.CurrentDirectory;

            string stem = Path.GetFileNameWithoutExtension(sourceWav);
            return Path.Combine(dir, stem + suffix);
        }

        // ---------------------------------------------------------------
        // playback
        // ---------------------------------------------------------------
        private void btnPlayOut_Click(object sender, EventArgs e)
        {
            string path = _lastOutPath;
            if (path == null || !File.Exists(path))
            {
                MessageBox.Show("还没有可播放的输出文件，请先执行处理。", "无输出",
                                MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            PlayWav(path, "输出");
        }

        private void btnPlayMic_Click(object sender, EventArgs e)
        {
            string path = txtMicPath.Text;
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                MessageBox.Show("请先选择麦克风录音文件。", "无输入",
                                MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            PlayWav(path, "麦克风录音");
        }

        private void PlayWav(string path, string what)
        {
            try
            {
                using (var player = new SoundPlayer(path))
                {
                    player.PlaySync();
                }
                AppendLog("已播放：" + what);
            }
            catch (Exception ex)
            {
                AppendLog("播放失败：" + ex.Message);
                MessageBox.Show("播放失败：" + ex.Message, "播放",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
    }
}
