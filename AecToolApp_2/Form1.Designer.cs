namespace AecToolApp_2
{
    partial class Form1
    {
        /// <summary>
        /// 必需的设计器变量。
        /// </summary>
        private System.ComponentModel.IContainer components = null;

        /// <summary>
        /// 清理所有正在使用的资源。
        /// </summary>
        /// <param name="disposing">如果应释放托管资源，为 true；否则为 false。</param>
        protected override void Dispose(bool disposing)
        {
            if (disposing && (components != null))
            {
                components.Dispose();
            }
            base.Dispose(disposing);
        }

        #region Windows 窗体设计器生成的代码

        /// <summary>
        /// 设计器支持所需的方法 - 不要修改
        /// 使用代码编辑器修改此方法的内容。
        /// </summary>
        private void InitializeComponent()
        {
            this.lblRef = new System.Windows.Forms.Label();
            this.txtRefPath = new System.Windows.Forms.TextBox();
            this.btnBrowseRef = new System.Windows.Forms.Button();
            this.lblMic = new System.Windows.Forms.Label();
            this.txtMicPath = new System.Windows.Forms.TextBox();
            this.btnBrowseMic = new System.Windows.Forms.Button();
            this.txtLog = new System.Windows.Forms.TextBox();
            this.btnProcess = new System.Windows.Forms.Button();
            this.btnPlayMic = new System.Windows.Forms.Button();
            this.btnPlayOut = new System.Windows.Forms.Button();
            this.btnCancel = new System.Windows.Forms.Button();
            this.progressBar1 = new System.Windows.Forms.ProgressBar();
            this.lblStatus = new System.Windows.Forms.Label();
            this.panelBottom = new System.Windows.Forms.Panel();
            this.panelInputs = new System.Windows.Forms.TableLayoutPanel();
            this.panelBottom.SuspendLayout();
            this.panelInputs.SuspendLayout();
            this.SuspendLayout();
            // 
            // lblRef
            // 
            this.lblRef.Dock = System.Windows.Forms.DockStyle.Fill;
            this.lblRef.Location = new System.Drawing.Point(3, 0);
            this.lblRef.Name = "lblRef";
            this.lblRef.Size = new System.Drawing.Size(84, 32);
            this.lblRef.TabIndex = 0;
            this.lblRef.Text = "参考音频";
            this.lblRef.TextAlign = System.Drawing.ContentAlignment.MiddleLeft;
            // 
            // txtRefPath
            // 
            this.txtRefPath.Dock = System.Windows.Forms.DockStyle.Fill;
            this.txtRefPath.Location = new System.Drawing.Point(93, 4);
            this.txtRefPath.Margin = new System.Windows.Forms.Padding(3, 4, 3, 4);
            this.txtRefPath.Name = "txtRefPath";
            this.txtRefPath.Size = new System.Drawing.Size(688, 21);
            this.txtRefPath.TabIndex = 1;
            // 
            // btnBrowseRef
            // 
            this.btnBrowseRef.Dock = System.Windows.Forms.DockStyle.Fill;
            this.btnBrowseRef.Location = new System.Drawing.Point(787, 4);
            this.btnBrowseRef.Margin = new System.Windows.Forms.Padding(3, 4, 3, 4);
            this.btnBrowseRef.Name = "btnBrowseRef";
            this.btnBrowseRef.Size = new System.Drawing.Size(94, 24);
            this.btnBrowseRef.TabIndex = 2;
            this.btnBrowseRef.Text = "浏览参考…";
            this.btnBrowseRef.UseVisualStyleBackColor = true;
            this.btnBrowseRef.Click += new System.EventHandler(this.btnBrowseRef_Click);
            // 
            // lblMic
            // 
            this.lblMic.Dock = System.Windows.Forms.DockStyle.Fill;
            this.lblMic.Location = new System.Drawing.Point(3, 32);
            this.lblMic.Name = "lblMic";
            this.lblMic.Size = new System.Drawing.Size(84, 32);
            this.lblMic.TabIndex = 3;
            this.lblMic.Text = "麦克风录音";
            this.lblMic.TextAlign = System.Drawing.ContentAlignment.MiddleLeft;
            // 
            // txtMicPath
            // 
            this.txtMicPath.Dock = System.Windows.Forms.DockStyle.Fill;
            this.txtMicPath.Location = new System.Drawing.Point(93, 36);
            this.txtMicPath.Margin = new System.Windows.Forms.Padding(3, 4, 3, 4);
            this.txtMicPath.Name = "txtMicPath";
            this.txtMicPath.Size = new System.Drawing.Size(688, 21);
            this.txtMicPath.TabIndex = 4;
            // 
            // btnBrowseMic
            // 
            this.btnBrowseMic.Dock = System.Windows.Forms.DockStyle.Fill;
            this.btnBrowseMic.Location = new System.Drawing.Point(787, 36);
            this.btnBrowseMic.Margin = new System.Windows.Forms.Padding(3, 4, 3, 4);
            this.btnBrowseMic.Name = "btnBrowseMic";
            this.btnBrowseMic.Size = new System.Drawing.Size(94, 24);
            this.btnBrowseMic.TabIndex = 5;
            this.btnBrowseMic.Text = "浏览录音…";
            this.btnBrowseMic.UseVisualStyleBackColor = true;
            this.btnBrowseMic.Click += new System.EventHandler(this.btnBrowseMic_Click);
            // 
            // txtLog
            // 
            this.txtLog.Dock = System.Windows.Forms.DockStyle.Fill;
            this.txtLog.Location = new System.Drawing.Point(8, 72);
            this.txtLog.Multiline = true;
            this.txtLog.Name = "txtLog";
            this.txtLog.ReadOnly = true;
            this.txtLog.ScrollBars = System.Windows.Forms.ScrollBars.Both;
            this.txtLog.Size = new System.Drawing.Size(884, 320);
            this.txtLog.TabIndex = 1;
            this.txtLog.WordWrap = false;
            // 
            // btnProcess
            // 
            this.btnProcess.Location = new System.Drawing.Point(0, 54);
            this.btnProcess.Name = "btnProcess";
            this.btnProcess.Size = new System.Drawing.Size(120, 26);
            this.btnProcess.TabIndex = 2;
            this.btnProcess.Text = "开始处理";
            this.btnProcess.UseVisualStyleBackColor = true;
            this.btnProcess.Click += new System.EventHandler(this.btnProcess_Click);
            // 
            // btnPlayMic
            // 
            this.btnPlayMic.Location = new System.Drawing.Point(128, 54);
            this.btnPlayMic.Name = "btnPlayMic";
            this.btnPlayMic.Size = new System.Drawing.Size(120, 26);
            this.btnPlayMic.TabIndex = 3;
            this.btnPlayMic.Text = "播放原始录音";
            this.btnPlayMic.UseVisualStyleBackColor = true;
            this.btnPlayMic.Click += new System.EventHandler(this.btnPlayMic_Click);
            // 
            // btnPlayOut
            // 
            this.btnPlayOut.Location = new System.Drawing.Point(256, 54);
            this.btnPlayOut.Name = "btnPlayOut";
            this.btnPlayOut.Size = new System.Drawing.Size(120, 26);
            this.btnPlayOut.TabIndex = 4;
            this.btnPlayOut.Text = "播放处理结果";
            this.btnPlayOut.UseVisualStyleBackColor = true;
            this.btnPlayOut.Click += new System.EventHandler(this.btnPlayOut_Click);
            // 
            // btnCancel
            // 
            this.btnCancel.Enabled = false;
            this.btnCancel.Location = new System.Drawing.Point(384, 54);
            this.btnCancel.Name = "btnCancel";
            this.btnCancel.Size = new System.Drawing.Size(120, 26);
            this.btnCancel.TabIndex = 5;
            this.btnCancel.Text = "取消";
            this.btnCancel.UseVisualStyleBackColor = true;
            this.btnCancel.Click += new System.EventHandler(this.btnCancel_Click);
            // 
            // progressBar1
            // 
            this.progressBar1.Anchor = ((System.Windows.Forms.AnchorStyles)(((System.Windows.Forms.AnchorStyles.Top | System.Windows.Forms.AnchorStyles.Left) 
            | System.Windows.Forms.AnchorStyles.Right)));
            this.progressBar1.Location = new System.Drawing.Point(0, 6);
            this.progressBar1.Name = "progressBar1";
            this.progressBar1.Size = new System.Drawing.Size(884, 20);
            this.progressBar1.TabIndex = 0;
            // 
            // lblStatus
            // 
            this.lblStatus.Anchor = ((System.Windows.Forms.AnchorStyles)(((System.Windows.Forms.AnchorStyles.Top | System.Windows.Forms.AnchorStyles.Left) 
            | System.Windows.Forms.AnchorStyles.Right)));
            this.lblStatus.Location = new System.Drawing.Point(0, 30);
            this.lblStatus.Name = "lblStatus";
            this.lblStatus.Size = new System.Drawing.Size(884, 20);
            this.lblStatus.TabIndex = 1;
            this.lblStatus.Text = "就绪";
            this.lblStatus.TextAlign = System.Drawing.ContentAlignment.MiddleLeft;
            // 
            // panelBottom
            // 
            this.panelBottom.Controls.Add(this.lblStatus);
            this.panelBottom.Controls.Add(this.progressBar1);
            this.panelBottom.Controls.Add(this.btnCancel);
            this.panelBottom.Controls.Add(this.btnPlayOut);
            this.panelBottom.Controls.Add(this.btnPlayMic);
            this.panelBottom.Controls.Add(this.btnProcess);
            this.panelBottom.Dock = System.Windows.Forms.DockStyle.Bottom;
            this.panelBottom.Location = new System.Drawing.Point(8, 392);
            this.panelBottom.Name = "panelBottom";
            this.panelBottom.Size = new System.Drawing.Size(884, 81);
            this.panelBottom.TabIndex = 2;
            // 
            // panelInputs
            // 
            this.panelInputs.ColumnCount = 3;
            this.panelInputs.ColumnStyles.Add(new System.Windows.Forms.ColumnStyle(System.Windows.Forms.SizeType.Absolute, 90F));
            this.panelInputs.ColumnStyles.Add(new System.Windows.Forms.ColumnStyle(System.Windows.Forms.SizeType.Percent, 100F));
            this.panelInputs.ColumnStyles.Add(new System.Windows.Forms.ColumnStyle(System.Windows.Forms.SizeType.Absolute, 100F));
            this.panelInputs.Controls.Add(this.lblRef, 0, 0);
            this.panelInputs.Controls.Add(this.txtRefPath, 1, 0);
            this.panelInputs.Controls.Add(this.btnBrowseRef, 2, 0);
            this.panelInputs.Controls.Add(this.lblMic, 0, 1);
            this.panelInputs.Controls.Add(this.txtMicPath, 1, 1);
            this.panelInputs.Controls.Add(this.btnBrowseMic, 2, 1);
            this.panelInputs.Dock = System.Windows.Forms.DockStyle.Top;
            this.panelInputs.Location = new System.Drawing.Point(8, 8);
            this.panelInputs.Name = "panelInputs";
            this.panelInputs.RowCount = 2;
            this.panelInputs.RowStyles.Add(new System.Windows.Forms.RowStyle(System.Windows.Forms.SizeType.Absolute, 32F));
            this.panelInputs.RowStyles.Add(new System.Windows.Forms.RowStyle(System.Windows.Forms.SizeType.Absolute, 32F));
            this.panelInputs.Size = new System.Drawing.Size(884, 64);
            this.panelInputs.TabIndex = 0;
            // 
            // Form1
            // 
            this.AutoScaleDimensions = new System.Drawing.SizeF(6F, 12F);
            this.AutoScaleMode = System.Windows.Forms.AutoScaleMode.Font;
            this.ClientSize = new System.Drawing.Size(900, 481);
            this.Controls.Add(this.txtLog);
            this.Controls.Add(this.panelBottom);
            this.Controls.Add(this.panelInputs);
            this.MinimumSize = new System.Drawing.Size(720, 420);
            this.Name = "Form1";
            this.Padding = new System.Windows.Forms.Padding(8);
            this.Text = "AEC 回声消除工具";
            this.Load += new System.EventHandler(this.Form1_Load);
            this.panelBottom.ResumeLayout(false);
            this.panelInputs.ResumeLayout(false);
            this.panelInputs.PerformLayout();
            this.ResumeLayout(false);
            this.PerformLayout();

        }

        #endregion

        private System.Windows.Forms.Label lblRef;
        private System.Windows.Forms.TextBox txtRefPath;
        private System.Windows.Forms.Button btnBrowseRef;
        private System.Windows.Forms.Label lblMic;
        private System.Windows.Forms.TextBox txtMicPath;
        private System.Windows.Forms.Button btnBrowseMic;
        private System.Windows.Forms.TextBox txtLog;
        private System.Windows.Forms.Button btnProcess;
        private System.Windows.Forms.Button btnPlayMic;
        private System.Windows.Forms.Button btnPlayOut;
        private System.Windows.Forms.Button btnCancel;
        private System.Windows.Forms.ProgressBar progressBar1;
        private System.Windows.Forms.Label lblStatus;
        private System.Windows.Forms.Panel panelBottom;
        private System.Windows.Forms.TableLayoutPanel panelInputs;
    }
}
