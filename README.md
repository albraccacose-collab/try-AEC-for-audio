# AEC 回声消除工具 (AEC3 + C#)

把 WebRTC 的 **AEC3 回声消除算法**封装成可被 C# 直接 P/Invoke 调用的原生 DLL，
并配一个 Windows 桌面工具：**选两个 WAV → 输出消回声结果**。

项目起点是一个只能命令行运行的 C++ 算法库（[AEC3-master](AEC3-master/)）；
本仓库补齐了缺失的 **C ABI 桥接层**与**图形界面**，并建立了自动化验证。

---

## 快速开始

**环境**：Visual Studio 2022（含「使用 C++ 的桌面开发」工作负载）、
Windows SDK 10.0.22621+、.NET Framework 4.7.2、PowerShell 5.1。

一条命令完成全部步骤 —— 构建 native → 部署 DLL → 构建 C# → 合成测试音频 → 跑 24 项检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify_all.ps1
```

只想手动构建（`<VS>` 指 Visual Studio 安装路径）：

```powershell
# 1. 原生侧
& "<VS>\MSBuild\Current\Bin\MSBuild.exe" `
    AEC3-master\AEC3.sln /p:Configuration=Debug /p:Platform=x64 /m

# 2. 部署 DLL（必须和 exe 同目录）
Copy-Item AEC3-master\output\Debug_x64\aec_api.dll AecToolApp_2\bin\x64\Debug\ -Force

# 3. C# 侧
& "<VS>\MSBuild\Current\Bin\MSBuild.exe" AecToolApp_2\AecToolApp_2.sln `
    /p:Configuration=Debug /p:Platform=x64
```

> 两个解决方案彼此独立，**必须先 native 后 C#**。原因见
> [技术细节](docs/技术细节.md#构建详解)。

---

## 使用

### 图形界面

双击 `AecToolApp_2\bin\x64\Debug\AecToolApp_2.exe`：

1. **参考音频** —— 选远端信号（扬声器播放的那路）
2. **麦克风录音** —— 选近端录音（含回声的那路）
3. 点**开始处理**

处理前会做格式预检；输出写在**麦克风录音所在目录**，文件名加 `_aec` 后缀，
另有 `_aec_linear.wav` 是线性滤波结果。处理中可随时取消（约 80 ms 响应，
自动删除残缺输出）。

### 命令行

```powershell
AEC3-master\output\Debug_x64\demo.exe ref.wav mic.wav out.wav
```

---

## 测试音频

仓库**不含**任何第三方音频。合成一对回声通路已知的测试音频：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_test_audio.ps1
```

在 `testdata\` 生成 `synth_farend_16k.wav`（参考）、`synth_mic_16k.wav`（含回声的麦克风）、
`synth_nearend_16k.wav`（干净近端，仅用于算 ERLE）。

想用真实录音，可自行下载 [microsoft/AEC-Challenge](https://github.com/microsoft/AEC-Challenge)
数据集 —— 但**务必先看** [选材注意事项](docs/技术细节.md#测试音频的构造与选材)。

---

## 实测效果

合成测试对（10 s / 16 kHz / mono）纯回声段（0.5–3.0 s）：

| 指标 | 结果 |
|---|---|
| ERLE（回声抑制量，越高越好） | **35.90 dB** |
| 输出 RMS | -68.65 dBFS |
| 处理速度 | 约 8.7× 实时 |
| 流式 / 文件模式输出一致性 | **SHA-256 完全相同** |

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/技术细节.md](docs/技术细节.md) | 架构、目录结构、完整构建步骤、C API 参考、错误码、全部性能数据、踩过的坑、ANC 路线图 |
| [docs/AEC3_CSharp_改造方案.md](docs/AEC3_CSharp_改造方案.md) | 完整改造方案 + 实测报告 |

---

## 许可与致谢

**本仓库新增部分**：`api/aec_c_api.{h,cc}`、`aec_api.vcxproj`、`AecToolApp_2/`、
`tools/`、`docs/`、`README.md`。

**第三方组件**：

| 组件 | 来源 | 许可 |
|---|---|---|
| AEC3 算法、`base/`、`demo/` | [WebRTC](https://webrtc.googlesource.com/src/) | BSD 3-Clause（各源文件头部保留原始版权声明） |
| [Abseil](https://abseil.io/) | Google | Apache-2.0 |
| [jsoncpp](https://github.com/open-source-parsers/jsoncpp) | open-source-parsers | MIT / Public Domain |

`AEC3-master\android\`（Android 打包的重复副本）未纳入版本控制。
