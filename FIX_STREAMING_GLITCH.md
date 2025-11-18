# 流式音频播放毛刺修复指南

## 🎯 问题简述

在流式播放音频时（每收到一个 chunk 就调用 `playSound()`），chunk 切换时出现明显毛刺。

**根本原因**：工具库每次只调度一个 buffer 到播放器，下一个 buffer 必须等当前 buffer 播放完成后才会被调度，产生间隙。

## 💡 解决方案

修改工具库，实现 **buffer 预调度机制**：当新 chunk 到达时，如果播放队列还有空间，立即调度它。

---

## 🔧 代码修改步骤

### 第一步：Fork 工具库

```bash
git clone https://github.com/mykin-ai/expo-audio-stream.git
cd expo-audio-stream
```

### 第二步：修改 `ios/SoundPlayer.swift`

#### 1. 添加属性（约第 16 行附近）

在 `class SoundPlayer` 中添加：

```swift
class SoundPlayer {
    // ... 现有属性 ...
    private var isPlaying: Bool = false

    // ✅ 添加这两行
    private var scheduledBufferCount: Int = 0
    private let maxScheduledBuffers: Int = 3
```

#### 2. 修改 `play()` 方法（第 415-463 行）

找到这段代码：

```swift
let bufferTuple = (buffer: buffer, promise: resolver, turnId: strTurnId)
audioQueue.append(bufferTuple)
if self.segmentsLeftToPlay == 0 && strTurnId != suspendSoundEventTurnId {
    self.delegate?.onSoundStartedPlaying()
}
self.segmentsLeftToPlay += 1

// ❌ 删除这部分
if audioQueue.count == 1 {
    Logger.debug("[SoundPlayer] Starting playback [ \(audioQueue.count)]")
    playNextInQueue()
}
```

替换为：

```swift
let bufferTuple = (buffer: buffer, promise: resolver, turnId: strTurnId)
audioQueue.append(bufferTuple)
if self.segmentsLeftToPlay == 0 && strTurnId != suspendSoundEventTurnId {
    self.delegate?.onSoundStartedPlaying()
}
self.segmentsLeftToPlay += 1

// ✅ 替换为这行
scheduleWaitingBuffers()
```

#### 3. 替换 `playNextInQueue()` 方法（第 471-536 行）

**删除整个 `playNextInQueue()` 方法**，替换为：

```swift
/// 调度等待中的 buffer
/// 保持 2-3 个 buffer 在 AVAudioPlayerNode 的播放队列中
private func scheduleWaitingBuffers() {
    self.bufferAccessQueue.async { [weak self] in
        guard let self = self else { return }

        // 只要还有空间，就继续调度
        while !self.audioQueue.isEmpty && self.scheduledBufferCount < self.maxScheduledBuffers {
            guard let (buffer, promise, turnId) = self.audioQueue.first else { break }
            self.audioQueue.removeFirst()

            // 增加已调度计数
            self.scheduledBufferCount += 1

            Logger.debug("[SoundPlayer] Scheduling buffer \(self.scheduledBufferCount)/\(self.maxScheduledBuffers)")

            // 调度 buffer 到播放器
            self.audioPlayerNode.scheduleBuffer(buffer) { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else {
                        promise(nil)
                        return
                    }

                    // 减少已调度计数
                    self.scheduledBufferCount -= 1
                    self.segmentsLeftToPlay -= 1

                    Logger.debug("[SoundPlayer] Buffer completed, remaining: \(self.scheduledBufferCount)")

                    let isFinalSegment = self.segmentsLeftToPlay == 0

                    // 发送播放完成事件
                    if turnId != self.suspendSoundEventTurnId {
                        self.delegate?.onSoundChunkPlayed(isFinalSegment)
                    }

                    promise(nil)

                    // ✅ 关键：立即尝试调度更多等待中的 buffer
                    self.scheduleWaitingBuffers()

                    // 处理最后一个 segment 的清理工作
                    if isFinalSegment && self.config.playbackMode == .voiceProcessing {
                        Logger.debug("[SoundPlayer] Final segment in voice processing mode, stopping engine")
                        if let engine = self.audioEngine, engine.isRunning {
                            engine.stop()
                            try? self.disableVoiceProcessing()
                            self.isAudioEngineIsSetup = false
                        }
                    }
                }
            }
        }

        // 如果还没开始播放，现在开始
        if !self.audioPlayerNode.isPlaying && self.scheduledBufferCount > 0 {
            Logger.debug("[SoundPlayer] Starting playback with \(self.scheduledBufferCount) buffers")
            self.audioPlayerNode.play()
        }
    }
}
```

#### 4. 修改 `stop()` 方法（第 261-287 行）

在 `stop()` 方法中添加重置计数器：

```swift
func stop(_ promise: Promise) {
    Logger.debug("[SoundPlayer] Stopping Audio")
    if !self.audioQueue.isEmpty {
        Logger.debug("[SoundPlayer] Queue is not empty clearing")
        self.audioQueue.removeAll()
    }

    // Stop the audio player node
    if self.audioPlayerNode != nil && self.audioPlayerNode.isPlaying {
        Logger.debug("[SoundPlayer] Player is playing stopping")
        self.audioPlayerNode.pause()
        self.audioPlayerNode.stop()
    }

    // ✅ 添加这行
    self.scheduledBufferCount = 0

    // ... 其余代码保持不变 ...
    self.segmentsLeftToPlay = 0
    promise.resolve(nil)
}
```

---

## 🧪 测试修改

### 1. 重新构建

```bash
cd expo-audio-stream
yarn install
yarn build
```

### 2. 在您的项目中使用修改后的版本

修改 `package.json`：

```json
{
  "dependencies": {
    "@mykin-ai/expo-audio-stream": "file:../expo-audio-stream"
  }
}
```

然后：

```bash
cd your-project
yarn install
npx pod-install
```

### 3. 运行并查看日志

运行应用后，查看日志输出：

```
[SoundPlayer] Scheduling buffer 1/3
[SoundPlayer] Scheduling buffer 2/3
[SoundPlayer] Scheduling buffer 3/3
[SoundPlayer] Starting playback with 3 buffers
[SoundPlayer] Buffer completed, remaining: 2
[SoundPlayer] Scheduling buffer 3/3  ← 自动补充
```

如果看到类似日志，说明预调度机制正常工作。

---

## 📊 修改前后对比

### 修改前

```
T0: Chunk 1 到达 → 调度 → 播放
T1: Chunk 2 到达 → 入队 → 等待
T2: Chunk 3 到达 → 入队 → 等待

T10: Chunk 1 播放完 → 回调 → 延迟 20ms → 调度 Chunk 2
     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
     这段时间产生毛刺 ⚠️

T11: Chunk 2 开始播放
```

### 修改后

```
T0: Chunk 1 到达 → 调度 (count: 1) → 播放
T1: Chunk 2 到达 → 调度 (count: 2) ✅
T2: Chunk 3 到达 → 调度 (count: 3) ✅
T3: Chunk 4 到达 → 入队（已满 3）

AVAudioPlayerNode: [Chunk 1] → [Chunk 2] → [Chunk 3] 🔊

T10: Chunk 1 播放完 → Chunk 2 无缝衔接 ✅
     同时：回调触发 → 调度 Chunk 4 (count: 3)

AVAudioPlayerNode: [Chunk 2] → [Chunk 3] → [Chunk 4] 🔊
```

**关键区别**：Chunk 2 和 3 已经提前在播放器内部队列中了！

---

## ✅ 预期效果

- ✅ **消除毛刺**：chunk 切换完全无缝
- ✅ **流畅播放**：始终保持 2-3 个 buffer 预加载
- ✅ **容错性好**：即使回调延迟 50ms 也不会中断
- ✅ **低延迟**：首个 chunk 仍然立即播放
- ✅ **自适应**：根据网络速度自动调整缓冲

---

## 🐛 如果还有问题

### 检查 1：chunk 大小

如果 chunk 太小（< 50ms），可能还是会有轻微毛刺。建议每个 chunk 至少 100-200ms。

**检查方法**：

```typescript
const chunkDurationMs = (base64.length * 0.75 / 2 / 16000) * 1000;
console.log('Chunk duration:', chunkDurationMs, 'ms');
```

### 检查 2：增加预调度数量

如果网络延迟高，可以增加 `maxScheduledBuffers`：

```swift
private let maxScheduledBuffers: Int = 5  // 改为 5
```

### 检查 3：查看日志

确认是否看到连续的调度日志：

```
[SoundPlayer] Scheduling buffer 1/3
[SoundPlayer] Scheduling buffer 2/3
[SoundPlayer] Scheduling buffer 3/3
```

如果只看到 `1/3`，说明 chunk 到达太慢。

---

## 🚀 提交到上游

修改完成并测试通过后，建议提交 PR 到原仓库：

1. Fork https://github.com/mykin-ai/expo-audio-stream
2. 创建分支：`git checkout -b fix/streaming-audio-glitch`
3. 提交修改：`git commit -m "Fix audio glitch in streaming playback"`
4. 推送：`git push origin fix/streaming-audio-glitch`
5. 在 GitHub 上创建 Pull Request

PR 描述可以参考这个模板：

```markdown
## 问题描述

在流式播放场景下（每收到一个 chunk 就调用 playSound），chunk 切换时会出现明显的毛刺/爆音。

## 原因分析

当前实现每次只调度一个 buffer 到 AVAudioPlayerNode，下一个 buffer 必须等当前播放完成后才调度，产生间隙。

## 解决方案

实现 buffer 预调度机制：
- 维护 scheduledBufferCount 追踪已调度的 buffer 数量
- 新 chunk 到达时，如果未达上限（默认 3），立即调度
- 保持 AVAudioPlayerNode 内部队列始终有 2-3 个 buffer

## 测试

在流式语音对话应用中测试，chunk 切换完全无缝，无毛刺。

## Breaking Changes

无
```

---

## 📚 技术细节

### 为什么是 3 个 buffer？

- **1 个**：不够，仍会有间隙
- **2 个**：基本够用，但边缘情况下可能不足
- **3 个**：最佳平衡，覆盖大部分延迟情况
- **5+ 个**：增加延迟，不推荐

### 为什么不一次性调度所有 buffer？

- 占用更多内存
- 增加首次播放延迟
- 无法处理实时场景（如 TTS 边生成边播放）

### 线程安全

使用 `bufferAccessQueue`（串行队列）确保：
- `scheduledBufferCount` 的增减是原子操作
- `audioQueue` 的访问是线程安全的

---

**最后更新**: 2025-11-17
**适用版本**: `@mykin-ai/expo-audio-stream@0.2.28`
