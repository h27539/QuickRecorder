# 第二轮审查（基线 main / 31cc5e8）

## 修改前证据、触发条件与设计

本表区分可由代码构造的路径和实机观察：本轮尚未观察到真实设备挂起，不将“系统永不回调”等假设当作已发生故障。

| 项目 | 基线证据与触发条件 | 处理 |
| --- | --- | --- |
| iDevice 提前停止/退出 | `AVOutputClass.stopRecording` 要求 `output.isRecording`，而 startRecording 请求与实际进入 recording 并不同步。此间停止会直接返回；`applicationShouldTerminate` 仍返回 terminateLater。 | 跟踪实际发出的 recording request，停止不依赖 isRecording；迟到 didStart 再发停止；didFinish 按请求对象识别，包含失败回调。没有 request 的残留状态直接清理。 |
| iDevice 启动失败并不必然挂起 | setup guard/无视频 connection 的 return 在设置 streamType 前，因此正常退出是 terminateNow；SDK AVCaptureFileOutput.h 明确保证每个发出的 recording request 都调用 didFinish，即使没写出数据。 | 不凭空加入强制超时或提前宣布文件完成；真正发出请求后仍等待 didFinish，保留第一轮按 error/key 判断成功的逻辑。 |
| SCStream 提前停止 | record 在 await startCapture 前已赋值全局 stream；stop 此时直接 stopCapture 并 finish writer，启动返回后又可能 stopCapture。非 actor record 的同步配置与主线程停止也可交错。 | 同步配置放在 MainActor；start pending 期间记录停止意图，等启动返回/抛错后才停流和 finish；保持当前录制占用到收尾完成。 |
| 延迟任务跨会话 | prepRecord 的 Task 在执行时读取 `SCContext.filter!`；record 的首个 guard 只检查“当前是否有录制”，不识别排队任务属于谁；failRecording 的 main.async 也无会话身份。旧任务可在新会话活动时操作新全局状态。 | 每次 prep 分配 UUID，Task 捕获 filter 和 UUID；启动、异步错误、停止回调、writer 完成回调校验 UUID。不引入新的录制架构。 |
| 纯音频误判成功 | `.audio` 分支先设置 startTime，随后 PCM 转换可能返回 nil，`audioFile?.write` 在文件为空时也不抛错；finish 仅以 startTime 排除空音频。 | 只在非空 PCM 成功写入后累加帧数；关闭文件后重新打开并检查长度。QMA 的系统音轨也执行相同检查，writer 麦克风完成屏障继续保留。 |
| 普通 MP3 目标重名 | processFinishedRecording 直接调用 m4a2mp3；锁定 SwiftLAME 源码 `_encode` 使用 OutputStream(destination, append:true)。 | 同目录唯一临时文件编码，检查可读非空，再 moveItem 发布到目标（目标已存在则失败）；任何失败都不删除原录音或既有目标。编码参数保持原值。 |
| 菜单栏命中、布局和弹窗 | StatusBar 的坐标 monitor 只在 27+ 且当前状态栏窗口启用；hosting 使用约束，未再改 button.frame。但 `getStatusBarWidth` 仍返回 36/68/78/114/138/158，height 22；离屏时只回退浮动控制器。#255 未有本工程 UI 复现结果。 | 本轮不修改按钮路由、宽度或弹窗。命中补丁已实现不等于 27 实测通过；固定宽度没有变成自适应；弹窗跳位仍待自动隐藏菜单栏实机验证。 |

## 测试与剩余验证

实施后补充结果。新增测试将控制启动返回/失败和迟到回调顺序，运行当前生产函数；硬件 API 用替身，不能证明系统回调本身的可靠性。

### 执行结果（2026-10-29）

环境：macOS 26.7.2，Xcode 26.4 / macOS 26.4 SDK。部署版本和工程构建设置未修改。

- 双架构 Debug `xcodebuild`：**BUILD SUCCEEDED**；`lipo -archs` 为 `x86_64 arm64`。仍有原选择器代码的并发警告，本轮不重构那些模块。
- `python3 scripts/verify_recording_lifecycle.py`：**10 组 PASS**。执行当前生产 stopRecording、finishCaptureStart、停止回调、failRecording、completeRecordingStop、iDevice 事件和应用退出函数；替换硬件/UI，主动控制启动/结束/错误顺序。覆盖无请求退出、尚未 recording 时退出、迟到 didStart、启动抛错、重复停止/完成、无请求残留、异常结束、正常停止，以及旧启动/停止/设备完成/错误任务不能清除新会话。
- `python3 scripts/verify_media_pipeline.py`：**14 组 PASS**。保留原有 10 组测试，新增旧 writer 完成回调隔离、纯音频实际写入与最终文件检查、真实 SwiftLAME 转换/目标重名/错误输入，以及编码期间目标被其他写入者创建的竞态。所有既有音视频合并与可解码检查继续通过。
- MP3 测试链接当前 Debug 构建的 `SwiftLAME.o` / `LAME.o`，不再用转换替身。确认既有目标和竞态目标逐字节不变，输入错误与发布失败保留源文件，`.qr-*.mp3` 临时文件被清理。
- `git diff --check`：通过。日志保存于 `build/validation/round2-{build,media,lifecycle}.log`。本地完整评审补丁见 `build/validation/round2-review.patch`（包含新增文档和测试）。

复现命令（先构建，再运行媒体测试）：

```sh
xcodebuild build -project QuickRecorder.xcodeproj -scheme QuickRecorder \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
  -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
python3 scripts/verify_recording_lifecycle.py
python3 scripts/verify_media_pipeline.py
```

`record` 的同步配置改为 MainActor 后，硬件编码警告也会在主线程触发。因此 `showAlertSyncOnMainThread` 增加主线程直接执行分支，避免把自己的 modal 任务投到主队列再 semaphore.wait；其他线程调用方式保留。

### 尚需实机验证

1. iDevice 接入后立即停止/退出、设备断开、权限/输出创建失败：观察 didStart/didFinish 和一次退出回复；确认成功文件尾部可播放。SDK 保证的回调若因系统故障不送达，本轮没有强制超时退出；未把这种尚未复现的情况当作本轮已修复问题。
2. ScreenCaptureKit 在 startCapture 尚未完成时停止/退出、正常启动失败、快速连续开始/停止：确认旧请求收尾前不能开始新会话，退出在流与文件完成后回复。测试替身验证本应用顺序，不模拟真实权限弹窗、设备服务延迟或系统 API 永不返回。
3. 系统声音 + 默认/指定麦克风/AEC，纯音频的 AAC/ALAC/FLAC/Opus/MP3、QMA 合并与不合并：检查采样、暂停/恢复和最终时长；本轮新增最终文件检查的自动化样本为 AAC/M4A。
4. 外接盘断开、真实磁盘耗尽、编码器写入错误仍需受限测试卷验证；未改变锁定 SwiftLAME 的编码算法或其内部写入错误处理。可读非空检查不是完整的音质/全时长证明。
5. macOS 12–26/27 的菜单栏按钮、mini、拥挤/刘海、自动隐藏、多屏和 #255 弹窗跳位仍按第一轮矩阵验证。本轮没有 StatusBar.swift 改动；固定宽度未消除，弹窗未宣布修复。

默认编码、音频质量、输出格式与第一轮音视频合成算法均未改变。所有修改仅在工作区，未提交、未推送。
