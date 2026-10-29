# macOS 26 / 27 兼容性与保存流程审计

## 修改前证据与设计

下列位置指修改前函数，行号会随补丁变化。上游讨论是复现线索，不是本机验证结果。

| 问题 | 代码证据与影响 | 最小修复设计 |
| --- | --- | --- |
| macOS 27 状态栏按钮命中错误 | `StatusBar.swift:StatusBarItem` 将多个 SwiftUI Button 放在 NSStatusBarButton 内。#281/#295/#296 报告无响应；#295 评论用最小复现测得 locationInWindow 总在中点。普通浮动窗口不受此系统回归影响。 | 仅 macOS 27+、仅当前状态栏窗口，local event monitor 修正 down/up/drag 坐标；保留 SwiftUI 的按压、拖出取消、键盘和辅助功能。保存 monitor token，避免重复安装并在退出时移除。 |
| 固定宽高、mini 与拥挤菜单栏 | `updateStatusBar` 修改系统 button.frame，hosting 高度固定 21/22；`getStatusBarWidth` 固定 36/68/78/114/138/158；浮动回退只看 occlusionState，未检测离屏位置；浮动 x 未加屏幕原点。 | 用 statusItem.length 申请宽度，hosting 约束到系统 button.bounds、内容单独固定高度；mini 保留稳定宽度；检查实际屏幕交集并显示原有浮动控制器，修正多屏坐标。不添加第二套按钮路由。 |
| macOS 26 弹窗偏移 #255 | 同一 hosting view 挂载 `.popover`，系统按钮 frame 被手改。上游补充仅自动隐藏菜单栏时出现；代码无法证明其唯一根因。 | 首先消除错误锚点布局；自动隐藏、多屏、缩放下实际打开和移入弹窗验证。在复现前不添加移动弹窗的全局补丁。 |
| stopCapture 与写入并发 | `SCContext.stopRecording` 不等 stopCapture；screen/audio 回调在 global 并发队列，麦克风来自 tap/AEC/AVCapture；markAsFinished 与 append 可并发；主线程 DispatchGroup.wait 阻塞界面。 | 停止入口主线程去重；等待 stopCapture completion，再异步 finishWriting；用共用锁保护写入和结束边界，拒绝停止后的样本，保留 streamType 到保存结束，防止新录制覆盖全局状态。 |
| 系统声音+麦克风损坏 PR #266 | 纯音频分支 `vW.finishWriting {}` 后立即关闭文件、load qma、saveFile，可能读到尚无 moov 的 mic.m4a。 | 两种录制路径共用异步 writer 完成屏障；成功后才关闭 AVAudioFile 并转换/合并，不复制主线程 wait。 |
| 合并失败仅日志、误删下一次文件 | 视频 `.failure` 仅 print；`mixAudioTracks` 完成后删除全局 filePath；导出格式读活动偏好。 | 使用传入源 URL 和其扩展名；失败通知并保留可播放的独立音轨源文件；空间预检；目标已存在时不覆盖、不删除；只在完成后删除本次源文件。 |
| 磁盘满、写入失败 PR #288 | 五个 append 返回值丢弃；AVAudioFile.write catch 仅 assertionFailure；无剩余空间检查。 | 统一写入失败上报与停止，启动/录制中/导出前检查输出卷容量；有限余量保守停止。不伪造修复已缺 moov 的文件。 |
| AVContext 错误误报成功 | didFinishRecordingTo 忽略 error，始终通知完成；stop 后立即清空状态。 | 按 AVErrorRecordingSuccessfullyFinishedKey 判断可用输出；失败通知附保留路径；等待 delegate 完成后释放录制状态。 |
| 崩溃恢复 PR #276 | 默认完整 MP4/MOV 依赖 finishWriting 写索引；补丁无条件开启 fragmentation（含音频 writer）。 | 本次不改变默认容器布局或编码；保留失败源与 qma，说明恢复边界。断电/进程被杀导致缺 moov 无法保证恢复；fragmentation 需另行跨播放器验证。 |

## 上游方案比较

- [PR #294](https://github.com/lihaoyun6/QuickRecorder/pull/294)：注册 GeometryReader 区域、代际清理、禁用按钮命中、target/action 横向路由与去抖；维护两种事件路径，改动较大。不能将该 PR 的自测当作当前工程的验证。
- [Issue #295 坐标方案](https://github.com/lihaoyun6/QuickRecorder/issues/295#issuecomment-6492659666)：保留原生 SwiftUI 命中；采用该较小思路，但加系统版本隔离和 monitor 生命周期。当前鼠标坐标不等同历史事件坐标，修正仅限已报告有回归的系统和窗口；排队/合成事件仍需实机测。
- [#281](https://github.com/lihaoyun6/QuickRecorder/issues/281)、[#296](https://github.com/lihaoyun6/QuickRecorder/issues/296)、[#255](https://github.com/lihaoyun6/QuickRecorder/issues/255)；保存参考 [#266](https://github.com/lihaoyun6/QuickRecorder/pull/266)、[#288](https://github.com/lihaoyun6/QuickRecorder/pull/288)、[#276](https://github.com/lihaoyun6/QuickRecorder/pull/276)。

## 验证计划（需要逐项记录结果）

1. 每阶段运行 xcodebuild，禁签名；记录 Xcode/SDK、架构、日志与结果。编译只能验证 API/类型/链接。
2. macOS 27 实机：屏幕、窗口、纯音频、iDevice，普通/mini 各测停止、暂停/恢复、摄像头或设备显示；点按钮两端和间隙、按下拖出、快速点击，动作只能触发一次。mini 悬停后控件完整且时间不撑破布局。浮动窗口各按钮仍能直接点击。
3. macOS 12–26 回归：同上；macOS 26/27 自动隐藏菜单栏、刘海、拥挤状态、多个缩放比例及负坐标副屏。拥挤时浮动控制器可见且可停止；空闲弹窗打开后鼠标移入不跳到左侧（#255），摄像头弹窗锚点正确。
4. 正常停止：录制 15 秒与立即停止/暂停中停止，连续点停止、快捷键与系统“停止共享”交错。UI 不冻结、仅完成一次、保存中禁止再次启动；保存后可再次录制。
5. 音频矩阵：系统声音开/关 × 麦克风开/关 × remux 开/关，分别测屏幕视频和纯音频（macOS 12 无系统声音）；默认麦克风、指定设备、AEC。播放已知系统音并口述时间标记，检查两者都存在、时长/同步及暂停段。
6. 每个输出用 QuickTime 打开、播放开头/中段/结尾并拖动；检查视频/音频 track 数量与时长。qma 的 sys/mic 分别打开，特别检查 mic.m4a 索引完成；合并后符合原编码、格式和质量设置。
7. 异常仅在测试输出目录/受限测试卷：启动空间不足、录制中容量阈值、writer append/音频写入失败、外接盘断开、stopCapture 错误、导出失败和目标重名。错误可见、无成功误报、源文件保留；确认未删其他文件。禁止通过填满系统盘验证。
8. 强杀/断电模拟仅用可丢弃测试录制：记录可恢复边界，缺 moov 文件不承诺可播放。不得以正常停止测试代替崩溃恢复验证。

## 执行结果

2026-10-29，主机 macOS 26.7.2，Xcode 26.4 / macOS 26.4 SDK：

| 验证 | 结果与范围 |
| --- | --- |
| 第一阶段 xcodebuild Debug，禁签名 | **BUILD SUCCEEDED**，当前 Intel 架构。日志 `build/validation/phase1-build.log`。 |
| 第二阶段最终 xcodebuild Debug，禁签名，ONLY_ACTIVE_ARCH=NO | **BUILD SUCCEEDED**；`lipo -archs` 确认 `x86_64 arm64`。日志 `build/validation/phase2-build.log`。 |
| 实际 AVFoundation 合成回归 | **10 项 PASS**，日志 `build/validation/media-regression.log`。当前源码的 writer 完成函数、视频合并函数、QMA 离线导出函数被提取到独立执行程序，使用合成数据、真实 writer/exporter/decoder；通知、UI 与 MP3 转换未覆盖。 |
| macOS 27 菜单栏、12–26 UI 回归、#255 | **未执行实机 UI 验证**。版本隔离、约束布局和离屏回退已经实现；不将代码检查或编译通过视为兼容性验证通过。 |
| ScreenCaptureKit 正常/系统停止共享、真实系统声音与各类麦克风/AEC、磁盘耗尽、移除存储卷、应用退出保存 | **仍待端到端测试**，按上面的矩阵执行。合成数据不证明真实采集或按钮操作正常。 |

合成回归逐项检查：

- 异步 writer 完成屏障后，麦克风 AAC/M4A 有可读索引，整条音轨可解码。
- 尚未开始写入的空 writer 只报一次失败；没有 writer 的空系统音频也不报成功。
- QMA 离线合并在回调前关闭输出文件，输出可解码；缺少输入与自动导出重名均报失败。
- MP4、MOV 的双音轨输入经生产代码合并后，有一条视频和一条音轨，完整可解码；成功只删除本次源文件，不删除无关文件。
- 单音轨输入、已完成第一遍音频导出后缺少视频、最终目标重名均返回失败；保留源文件和既有目标，并验证保留源可解码。

可重复执行：

```sh
xcodebuild build -project QuickRecorder.xcodeproj -scheme QuickRecorder \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
  -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
python3 scripts/verify_media_pipeline.py
```

首次构建需下载 Package.resolved 锁定的 Swift Package 依赖。测试需要本机 AVFoundation 编解码服务；受限沙箱可能拒绝编解码或构建缓存访问。测试夹具只生成在 `build/media-regression/` 下的临时目录，用完自动清理；不采集真实屏幕或麦克风。

## 实现范围与保留限制

- 新录制入口检查 `streamType`，直到保存/合并完成才释放状态；异步退出用 `terminateLater` 等待同一完成回调。保存期间停止是幂等操作，暂停被拒绝。
- SCStream 使用串行 sample queue；tap/AEC/AVCapture 回调共用 mediaLock；停止边界拒绝新样本，停止生产者时不持锁，避免相互等待。麦克风清理闭包记录实际启动方式，避免根据中途修改的偏好移除错误的 tap。写入 helper 还验证 input 属于当前 writer，丢弃旧会话回调。
- 保存路径的合并/MP3 选项在初始化时确定。视频合并使用传入 URL 推导格式及清理路径，不再读取下一次录制的全局路径；音轨按真实 timeRange 插入，混音参数绑定 composition 的轨道，视频透传保留方向。QMA 输出覆盖较长音轨，关闭文件后才能转换 MP3，取消固定延迟与提前成功通知。
- 启动低于 512 MiB 拒绝，录制期间每 5 秒检查，低于 256 MiB 请求有序停止；视频导出前保守预留源文件大小的两倍加 256 MiB。容量查询失败不阻止录制，依赖 writer/AVAudioFile 错误检测。阈值是保守边界，不保证高码率、空间骤降、文件系统配额或外接盘移除时仍有足够余量。
- 合并失败保留完成写入的原文件（可能仍有 `.mp4.mp4.mp4`/`.mov.mov.mov` 后缀）及中间文件，并通知准确源路径；QMA 失败保留包，可手动检查 sys/mic。自动导出发现已有目标时拒绝覆盖；手动 QMA 导出保留 NSSavePanel 的替换选择。
- 没有加入碎片容器、编码切换、降低质量或输出格式变更。没有实现修复历史缺 moov 文件的工具。保留失败文件只保证不主动删除，不保证磁盘满、断电或强杀后媒体本身完整。
- 仍有原仓库 Swift 并发/旧 API 警告；本次没有重构其他选择器或迁移整个应用到 Swift 6 actor 模型。内存/性能、Thread Sanitizer 与长时间设备采集仍需专门验证。
