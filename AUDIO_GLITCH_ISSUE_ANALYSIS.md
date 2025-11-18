- [音频播放毛刺问题分析报告](#音频播放毛刺问题分析报告)
  - [📋 问题概述](#-问题概述)
  - [🔍 根本原因分析](#-根本原因分析)
    - [1. 缺少 Buffer 预调度机制 ⚠️ (最严重问题)](#1-缺少-buffer-预调度机制-️-最严重问题)
    - [2. 单 Buffer 调度策略](#2-单-buffer-调度策略)
    - [3. Chunk 边界未对齐](#3-chunk-边界未对齐)
    - [4. 音频格式转换延迟](#4-音频格式转换延迟)
  - [💡 解决方案](#-解决方案)
    - [方案 1: 实现 Buffer 预调度机制 (★★★★★ 强烈推荐)](#方案-1-实现-buffer-预调度机制--强烈推荐)
      - [修改 1: 优化 `play()` 方法](#修改-1-优化-play-方法)
      - [修改 2: 新增追踪已调度 buffer 数量](#修改-2-新增追踪已调度-buffer-数量)
      - [修改 3: 实现智能调度方法](#修改-3-实现智能调度方法)
      - [修改 4: 删除旧的 `playNextInQueue()` 方法](#修改-4-删除旧的-playnextinqueue-方法)
    - [方案 2: 使用 scheduleBuffer 的连续播放特性 (★★★★☆)](#方案-2-使用-schedulebuffer-的连续播放特性-)
    - [方案 3: 优化异步调度路径 (★★★☆☆)](#方案-3-优化异步调度路径-)
    - [方案 4: 服务端优化 - 发送重叠的 Chunk (★★★☆☆)](#方案-4-服务端优化---发送重叠的-chunk-)
    - [方案 5: 客户端合并小 Chunk (★★☆☆☆)](#方案-5-客户端合并小-chunk-)
  - [🎯 推荐实施方案](#-推荐实施方案)
    - [立即可用的临时方案 (无需修改工具库)](#立即可用的临时方案-无需修改工具库)
      - [方案 A: 增加 Chunk 大小](#方案-a-增加-chunk-大小)
      - [方案 B: 客户端合并小 Chunk](#方案-b-客户端合并小-chunk)
    - [长期最佳方案 (需要修改工具库)](#长期最佳方案-需要修改工具库)
      - [实施方案 1: Buffer 预调度](#实施方案-1-buffer-预调度)
  - [🧪 验证和调试方法](#-验证和调试方法)
    - [1. 添加详细日志](#1-添加详细日志)
    - [2. 使用 Instruments 分析](#2-使用-instruments-分析)
    - [3. 波形分析](#3-波形分析)
    - [4. 简单测试代码](#4-简单测试代码)
  - [📊 问题总结](#-问题总结)
  - [🔧 快速修复建议（无需改库）](#-快速修复建议无需改库)
    - [立即可以尝试的方法](#立即可以尝试的方法)
  - [🛠️ 工具库改进建议 (提交 Issue 或 PR)](#️-工具库改进建议-提交-issue-或-pr)
  - [📝 相关代码位置](#-相关代码位置)
  - [📚 技术背景](#-技术背景)
    - [AVAudioPlayerNode 的工作原理](#avaudioplayernode-的工作原理)
    - [Buffer Underrun (缓冲区耗尽)](#buffer-underrun-缓冲区耗尽)
    - [理想的预调度机制](#理想的预调度机制)
  - [🎯 结论](#-结论)


# 音频播放毛刺问题分析报告

## 📋 问题概述

在使用 `@mykin-ai/expo-audio-stream` 工具库播放**流式音频**时，发现**在音频 chunk 切换时存在明显的毛刺和爆音**。

**使用场景**：
- 音频数据从服务端流式返回
- 每收到一个 chunk 立即调用 `ExpoPlayAudioStream.playSound()`
- 服务端音频数据本身质量正常，无问题
- 问题出现在客户端 chunk 边界处

**典型使用代码**：
```typescript
// 服务端流式返回音频数据
chatService.voiceChat(sessionId, content, async (data, index) => {
    if (data.audioBase64) {
        // 每次收到 chunk 立即播放
        await ExpoPlayAudioStream.playSound(
            data.audioBase64,
            `${index}`,
            EncodingTypes.PCM_S16LE,
        );
    }
})
```

---

## 🔍 根本原因分析

### 1. 缺少 Buffer 预调度机制 ⚠️ (最严重问题)

**影响程度**: ★★★★★

**问题位置**: `ios/SoundPlayer.swift:471-536`

**问题描述**:

在流式播放场景下，虽然您每次收到 chunk 都调用 `playSound()`，但工具库采用了**串行播放机制**，每次只调度一个 buffer：

```swift
// ios/SoundPlayer.swift:448-458
// 您调用 playSound() 时：
audioQueue.append(bufferTuple)  // 1. chunk 加入队列

if audioQueue.count == 1 {      // 2. ⚠️ 只有队列为空时才触发播放
    playNextInQueue()           // 3. 调度播放
}
// ❌ 如果队列中已有 chunk，新的 chunk 只会入队，不会立即调度
```

```swift
// ios/SoundPlayer.swift:494-533
// 播放逻辑：
self.audioPlayerNode.scheduleBuffer(buffer) { [weak self] in
    // ❌ 在当前 buffer 播放完成后才调度下一个 buffer
    DispatchQueue.main.async {
        guard let self = self else { return }

        // ... 各种回调处理 ...

        // ❌ 递归调用下一个 chunk
        if !self.isInterrupted && !self.audioQueue.isEmpty {
            self.playNextInQueue()  // 这时才调度队列中等待的下一个 buffer
        }
    }
}
```

**实际流程（流式播放场景）**:

```
T0: Chunk 1 到达 → 加入队列 → 立即调度播放 ✅
T1: Chunk 2 到达 → 加入队列 → ❌ 不调度（因为 count > 1）
T2: Chunk 3 到达 → 加入队列 → ❌ 不调度

T10: Chunk 1 播放完成 → 触发回调
     ↓
     回调进入主线程队列（延迟 5-10ms）
     ↓
     主线程执行回调
     ↓
     调用 playNextInQueue()
     ↓
     【音频空白期 - 产生毛刺】⚠️
     ↓
     调度 Chunk 2
     ↓
T11: Chunk 2 开始播放
```

**关键问题**：虽然 Chunk 2 和 Chunk 3 早就到达并在队列中了，但它们不会被提前调度到 AVAudioPlayerNode 的内部播放队列，只能等 Chunk 1 播放完成后的回调才会触发调度。

**导致的问题**:

1. **Buffer 间隙 (Buffer Gap)**
   - 当前 chunk 播放完成到下一个 chunk 开始播放之间存在时间间隔
   - 间隔时间 = 回调延迟 (5-10ms) + 主线程调度延迟 (0-50ms) + buffer 调度时间 (1-2ms)
   - 典型间隔: **10-50ms**
   - 即使下一个 chunk 早就到达并在队列中，也无法避免这个间隙

2. **音频不连续**
   - AVAudioPlayerNode 的内部播放队列在 Chunk 1 播放完时为空
   - 在等待 Chunk 2 调度期间，输出静音或随机噪声
   - 突然的静音→有声转换会产生明显的"咔嗒"声或爆音

3. **异步回调延迟**
   - 完成回调在 Core Audio 实时线程触发
   - 然后通过 `DispatchQueue.main.async` 切换到主线程处理
   - 主线程可能正在处理其他任务（UI 更新、触摸事件、网络回调等）
   - 延迟不可预测且无法优化

---

### 2. 单 Buffer 调度策略

**影响程度**: ★★★★★

**问题位置**: `ios/SoundPlayer.swift:455-458`

**问题描述**:

```swift
// ios/SoundPlayer.swift:455-458
// If not already playing, start playback
if audioQueue.count == 1 {
    Logger.debug("[SoundPlayer] Starting playback [ \(audioQueue.count)]")
    playNextInQueue()  // ❌ 只在队列只有1个时才开始播放
}
```

当前逻辑：
- 只有在队列为空时，新 chunk 才会触发播放
- 每次只调度一个 buffer
- 下一个 buffer 必须等待当前 buffer 完成

**正确的做法应该是**:
- 一次调度多个 buffer
- 利用 AVAudioPlayerNode 的内部队列
- 保持至少 2-3 个 buffer 在播放队列中

---

### 3. Chunk 边界未对齐

**影响程度**: ★★★☆☆

**问题描述**:

如果服务端发送的音频 chunk 在采样点上不连续，即使代码正确也会产生毛刺：

**示例**:

```
正常情况:
Chunk 1: [sample 0 ... sample 999]
Chunk 2: [sample 1000 ... sample 1999]  ✅ 连续

异常情况:
Chunk 1: [sample 0 ... sample 999]
Chunk 2: [sample 1005 ... sample 2004]  ❌ 跳过了 5 个采样点
```

如果 chunk 之间有采样点丢失或重叠，会在边界产生突变，导致爆音。

**检查方法**:

可以在 `AudioUtils.swift` 中添加日志检查每个 chunk 的长度：

```swift
Logger.debug("[AudioUtils] Chunk size: \(frameCount) frames, duration: \(Double(frameCount) / audioFormat.sampleRate) seconds")
```

---

### 4. 音频格式转换延迟

**影响程度**: ★★☆☆☆

**问题位置**: `ios/AudioUtils.swift:282-351`

**问题描述**:

在主线程或播放线程中进行 PCM 格式转换会增加延迟：

```swift
// ios/AudioUtils.swift:342-346
for i in 0..<intFrameCount {
    // ❌ 循环转换，对大 buffer 可能耗时较长
    let int16Sample = Int16(littleEndian: int16ptr[i])
    channelData.pointee[i] = Float(int16Sample) / 32768.0
}
```

如果 chunk 很大（例如 1 秒的音频 = 16000 个采样点），格式转换可能需要几毫秒。

---

## 💡 解决方案

### 方案 1: 实现 Buffer 预调度机制 (★★★★★ 强烈推荐)

**针对流式播放场景的最佳解决方案**

**需要修改工具库代码**

核心思路：当新的 chunk 加入队列时，如果队列中的 chunk 还没有被调度到 AVAudioPlayerNode，立即调度它们。

#### 修改 1: 优化 `play()` 方法

**文件**: `ios/SoundPlayer.swift:415-463`

**修改前**:
```swift
let bufferTuple = (buffer: buffer, promise: resolver, turnId: strTurnId)
audioQueue.append(bufferTuple)

if audioQueue.count == 1 {
    playNextInQueue()  // ❌ 只在队列为空时才调度
}
```

**修改后**:
```swift
let bufferTuple = (buffer: buffer, promise: resolver, turnId: strTurnId)
audioQueue.append(bufferTuple)

// ✅ 立即尝试调度等待中的 buffer（如果还有空间）
scheduleWaitingBuffers()
```

#### 修改 2: 新增追踪已调度 buffer 数量

**文件**: `ios/SoundPlayer.swift` (类属性部分)

```swift
class SoundPlayer {
    // ... 现有属性 ...

    // ✅ 新增：追踪已调度到 AVAudioPlayerNode 但还未播放完成的 buffer 数量
    private var scheduledBufferCount: Int = 0
    private let maxScheduledBuffers: Int = 3  // 最多同时调度 3 个 buffer
```

#### 修改 3: 实现智能调度方法

**文件**: `ios/SoundPlayer.swift` (新增方法)

```swift
/// ✅ 新增方法：调度等待中的 buffer
/// 保持至少 2-3 个 buffer 在 AVAudioPlayerNode 的播放队列中
private func scheduleWaitingBuffers() {
    self.bufferAccessQueue.async { [weak self] in
        guard let self = self else { return }

        // 只要还有空间，就继续调度
        while !self.audioQueue.isEmpty && self.scheduledBufferCount < self.maxScheduledBuffers {
            guard let (buffer, promise, turnId) = self.audioQueue.first else { break }
            self.audioQueue.removeFirst()

            // 增加已调度计数
            self.scheduledBufferCount += 1

            Logger.debug("[SoundPlayer] Scheduling buffer, count: \(self.scheduledBufferCount)")

            // 调度 buffer
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

                    if turnId != self.suspendSoundEventTurnId {
                        self.delegate?.onSoundChunkPlayed(isFinalSegment)
                    }

                    promise(nil)

                    // ✅ 尝试调度更多等待中的 buffer
                    self.scheduleWaitingBuffers()

                    // 处理最后一个 segment 的清理工作
                    if isFinalSegment && self.config.playbackMode == .voiceProcessing {
                        // ... 现有的清理逻辑 ...
                    }
                }
            }
        }

        // 如果还没开始播放，现在开始
        if !self.audioPlayerNode.isPlaying && self.scheduledBufferCount > 0 {
            Logger.debug("[SoundPlayer] Starting playback")
            self.audioPlayerNode.play()
        }
    }
}
```

#### 修改 4: 删除旧的 `playNextInQueue()` 方法

原来的 `playNextInQueue()` 方法可以删除，用新的 `scheduleWaitingBuffers()` 替代。

**预期效果**:
- ✅ **消除 chunk 切换间隙**：AVAudioPlayerNode 内部始终有 2-3 个 buffer 等待播放
- ✅ **流畅播放**：即使某个回调延迟，也不会中断播放
- ✅ **自适应**：根据网络速度自动调整，快速网络会预调度更多 buffer
- ✅ **低延迟**：首个 chunk 仍然立即播放，不增加启动延迟

**工作流程示例**:

```
T0: Chunk 1 到达 → 加入队列 → 立即调度 (scheduledCount: 1) → 开始播放 ✅
T1: Chunk 2 到达 → 加入队列 → 立即调度 (scheduledCount: 2) ✅
T2: Chunk 3 到达 → 加入队列 → 立即调度 (scheduledCount: 3) ✅
T3: Chunk 4 到达 → 加入队列 → 等待（已达最大值 3）

AVAudioPlayerNode 内部队列: [Chunk 1] → [Chunk 2] → [Chunk 3] → 🔊

T10: Chunk 1 播放完成 → 回调触发 → scheduledCount 减为 2
     ↓
     立即调度 Chunk 4 (scheduledCount: 3) ✅
     ↓
     Chunk 2 无缝衔接开始播放 ✅✅✅

AVAudioPlayerNode 内部队列: [Chunk 2] → [Chunk 3] → [Chunk 4] → 🔊
```

**关键优势**：
- 每个 chunk 播放完成后，下一个 chunk **已经在 AVAudioPlayerNode 的内部队列中**
- 不存在调度延迟，因为提前调度好了
- 即使回调有 50ms 延迟也不影响，因为还有 2 个 buffer 在播放

---

### 方案 2: 使用 scheduleBuffer 的连续播放特性 (★★★★☆)

利用 `AVAudioPlayerNode` 的 `scheduleBuffer(_:completionCallbackType:completionHandler:)` 方法：

```swift
// ✅ 指定在 buffer 数据渲染完成时回调，而不是播放完成
self.audioPlayerNode.scheduleBuffer(
    buffer,
    completionCallbackType: .dataRendered  // ✅ 数据渲染完成即回调
) { [weak self] in
    // 此时下一个 buffer 已经在播放了
    self?.handleBufferCompletion(promise, turnId)
}
```

这样可以在当前 buffer 的数据被渲染（但还在播放）时就调度下一个 buffer。

---

### 方案 3: 优化异步调度路径 (★★★☆☆)

**修改位置**: `ios/SoundPlayer.swift:481`

**修改前**:
```swift
self.bufferAccessQueue.async {
    // 在串行队列中处理
}
```

**修改后**:
```swift
// ✅ 使用高优先级队列
let highPriorityQueue = DispatchQueue.global(qos: .userInteractive)
highPriorityQueue.async {
    // 在高优先级队列中处理
}
```

或者直接在当前线程同步处理：

```swift
// ✅ 同步处理，减少调度延迟
self.bufferAccessQueue.sync {
    guard !self.audioQueue.isEmpty else { return }
    // ...
}
```

---

### 方案 4: 服务端优化 - 发送重叠的 Chunk (★★★☆☆)

**无需修改工具库**

让服务端在发送音频 chunk 时，每个 chunk 的开头包含上一个 chunk 的末尾几个采样点：

```
Chunk 1: [0 ... 999]
Chunk 2: [995 ... 1999]  ✅ 前 5 个采样点与 Chunk 1 重叠
Chunk 3: [1995 ... 2999] ✅ 前 5 个采样点与 Chunk 2 重叠
```

客户端在播放时：
- 第一个 chunk 正常播放全部
- 后续 chunk 跳过重叠部分

这样即使有小的间隙，重叠部分也能保证音频连续性。

**实现示例**:

```typescript
// 在服务端生成音频时
const overlapSamples = 80; // 5ms @ 16kHz

function generateChunk(allSamples, chunkIndex, chunkSize) {
    const start = chunkIndex * chunkSize;
    const overlapStart = Math.max(0, start - overlapSamples);
    const end = start + chunkSize;

    return allSamples.slice(overlapStart, end);
}
```

---

### 方案 5: 客户端合并小 Chunk (★★☆☆☆)

**修改位置**: `app/video-chat.tsx:73-77`

如果 chunk 太小（< 100ms），可以在客户端缓存多个 chunk 再播放：

**修改前**:
```typescript
if (data.audioBase64) {
    await ExpoPlayAudioStream.playSound(
        data.audioBase64,
        `${index}`,
        EncodingTypes.PCM_S16LE,
    );
}
```

**修改后**:
```typescript
// 缓存机制
let audioBuffer: string[] = [];
const MIN_CHUNK_DURATION_MS = 200; // 最小 200ms

if (data.audioBase64) {
    audioBuffer.push(data.audioBase64);

    // 计算当前缓存的时长
    const totalSamples = audioBuffer.reduce((sum, chunk) => {
        // base64 字符数 * 0.75 / 2 (Int16) = 采样点数
        return sum + (chunk.length * 0.75 / 2);
    }, 0);
    const durationMs = (totalSamples / 16000) * 1000;

    // 如果累积到足够长度，或者是最后一个 chunk，则播放
    if (durationMs >= MIN_CHUNK_DURATION_MS || data.isFinal) {
        // 合并所有 chunk
        const combinedBase64 = combineBase64Audio(audioBuffer);

        await ExpoPlayAudioStream.playSound(
            combinedBase64,
            `${index}`,
            EncodingTypes.PCM_S16LE,
        );

        audioBuffer = [];
    }
}
```

---

## 🎯 推荐实施方案

### 立即可用的临时方案 (无需修改工具库)

#### 方案 A: 增加 Chunk 大小

**修改服务端**，增加每个 chunk 的大小：

```
当前: 每个 chunk 约 50-100ms
建议: 每个 chunk 200-500ms
```

更大的 chunk 意味着：
- ✅ 切换次数减少
- ✅ 毛刺频率降低
- ⚠️ 首次播放延迟略增加

#### 方案 B: 客户端合并小 Chunk

使用方案 5，在客户端缓存并合并多个小 chunk。

---

### 长期最佳方案 (需要修改工具库)

#### 实施方案 1: Buffer 预调度

这是最根本的解决方案，需要：

1. Fork 工具库
2. 修改 `ios/SoundPlayer.swift` 实现预调度
3. 同样修改 Android 端 (`android/src/main/java/expo/modules/audiostream/ExpoPlayAudioStreamModule.kt`)
4. 测试验证
5. 提交 PR 到上游仓库

---

## 🧪 验证和调试方法

### 1. 添加详细日志

在工具库中添加时间戳日志：

```swift
// ios/SoundPlayer.swift
self.audioPlayerNode.scheduleBuffer(buffer) { [weak self] in
    let timestamp = Date().timeIntervalSince1970
    Logger.debug("[SoundPlayer] Buffer completed at \(timestamp)")

    DispatchQueue.main.async {
        let asyncTimestamp = Date().timeIntervalSince1970
        let delay = (asyncTimestamp - timestamp) * 1000 // ms
        Logger.debug("[SoundPlayer] Main queue delay: \(delay)ms")

        // ... 原有逻辑 ...
    }
}
```

检查日志中的延迟时间，如果超过 10ms，就可能导致听觉上的毛刺。

---

### 2. 使用 Instruments 分析

使用 Xcode Instruments 的 Audio 工具：

1. 运行应用并录制 audio trace
2. 查看 Audio Queue 的 buffer 填充情况
3. 检查是否有 buffer underrun (缓冲区耗尽)
4. 分析 buffer 调度的时间间隔

---

### 3. 波形分析

录制播放的音频并在 Audacity 中查看：

1. 在 iOS 模拟器或真机上录制系统音频
2. 导入 Audacity
3. 放大查看 chunk 边界处的波形
4. 检查是否有：
   - 突然的电平跳变（说明 chunk 不连续）
   - 短暂的静音（说明有 buffer gap）
   - 波形削波（说明有爆音）

---

### 4. 简单测试代码

创建一个测试场景，连续播放多个小 chunk：

```typescript
// 生成测试音频：1kHz 正弦波，分成 10 个 chunk
async function testChunkPlayback() {
    const sampleRate = 16000;
    const frequency = 1000; // 1kHz
    const duration = 1.0; // 1 秒
    const chunkCount = 10;
    const samplesPerChunk = Math.floor((sampleRate * duration) / chunkCount);

    for (let i = 0; i < chunkCount; i++) {
        const chunk = generateSineWaveChunk(
            frequency,
            sampleRate,
            samplesPerChunk,
            i * samplesPerChunk
        );

        await ExpoPlayAudioStream.playSound(
            chunk,
            `test-${i}`,
            EncodingTypes.PCM_S16LE,
        );

        // 可以尝试不同的延迟
        // await new Promise(resolve => setTimeout(resolve, 10));
    }
}
```

如果连续的正弦波在 chunk 边界出现明显的咔嗒声，就证明是 chunk 切换问题。

---

## 📊 问题总结

| 问题类型 | 严重程度 | 修复难度 | 是否需要改库 | 优先级 |
|---------|---------|---------|------------|--------|
| 缺少 Buffer 预调度 | ★★★★★ | ★★★★☆ | 是 | **P0** |
| 单 Buffer 调度策略 | ★★★★★ | ★★★★☆ | 是 | **P0** |
| Chunk 边界不对齐 | ★★★☆☆ | ★★☆☆☆ | 否（服务端） | P1 |
| 异步调度延迟 | ★★★☆☆ | ★★☆☆☆ | 是 | P1 |
| 格式转换延迟 | ★★☆☆☆ | ★★★☆☆ | 是 | P2 |

---

## 🔧 快速修复建议（无需改库）

### 立即可以尝试的方法

1. **增加 Chunk 大小** (最简单)

   让服务端发送更大的 chunk（300-500ms），减少切换频率。

2. **客户端合并 Chunk**

   ```typescript
   let chunkBuffer: string[] = [];

   // 收到 chunk 时
   chunkBuffer.push(data.audioBase64);

   // 每收集 3 个 chunk 或收到最后一个时播放
   if (chunkBuffer.length >= 3 || data.isFinal) {
       const combined = combineAudioChunks(chunkBuffer);
       await ExpoPlayAudioStream.playSound(combined, ...);
       chunkBuffer = [];
   }
   ```

3. **使用 playWav 方法** (如果可以)

   如果可以转换为 WAV 格式，`playWav` 方法使用不同的播放器：

   ```typescript
   await ExpoPlayAudioStream.playWav(wavBase64);
   ```

   查看 `ios/SoundPlayer.swift:305-317`，这个方法使用 `AVAudioPlayer` 而非 `AVAudioPlayerNode`，可能没有 chunk 切换问题。

---

## 🛠️ 工具库改进建议 (提交 Issue 或 PR)

建议向 `@mykin-ai/expo-audio-stream` 提交以下改进：

1. **实现 Buffer 预调度机制**
   - 一次调度多个 buffer (2-3 个)
   - 在播放过程中持续补充队列

2. **添加配置选项**
   ```typescript
   await ExpoPlayAudioStream.setSoundConfig({
       sampleRate: 16000,
       playbackMode: PlaybackModes.CONVERSATION,
       bufferCount: 3,  // 新增：预调度的 buffer 数量
   })
   ```

3. **使用 completionCallbackType: .dataRendered**
   - 在 buffer 数据渲染时回调，而非播放完成时

4. **优化线程调度**
   - 使用更高优先级的调度队列
   - 减少不必要的线程切换

---

## 📝 相关代码位置

| 功能 | 文件 | 行号 |
|-----|------|-----|
| 播放队列管理 | `ios/SoundPlayer.swift` | 471-536 |
| Buffer 调度 | `ios/SoundPlayer.swift` | 494 |
| 异步回调处理 | `ios/SoundPlayer.swift` | 496-532 |
| 新 Chunk 入队 | `ios/SoundPlayer.swift` | 415-463 |
| 触发播放条件 | `ios/SoundPlayer.swift` | 455-458 |
| PCM 格式转换 | `ios/AudioUtils.swift` | 282-351 |
| 用户播放调用 | `app/video-chat.tsx` | 73-77 |

---

## 📚 技术背景

### AVAudioPlayerNode 的工作原理

`AVAudioPlayerNode` 内部维护了一个播放队列：

```
[Buffer 1] → [Buffer 2] → [Buffer 3] → ... → 🔊 Audio Output
```

- 可以一次性调度多个 buffer
- 按照调度顺序连续播放
- 如果队列为空，会输出静音

### Buffer Underrun (缓冲区耗尽)

当播放队列中没有 buffer 时：

```
[Buffer 1] 播放中...
[Buffer 1] 播放完成
[空] ← 😱 没有 buffer 可播放
🔇 输出静音或产生爆音
```

### 理想的预调度机制

```
时刻 T0: [Buffer 1] → [Buffer 2] → [Buffer 3] (3个buffer在队列中)
时刻 T1: [Buffer 2] → [Buffer 3] → [Buffer 4] (Buffer 1 播放完，立即补充 Buffer 4)
时刻 T2: [Buffer 3] → [Buffer 4] → [Buffer 5] (Buffer 2 播放完，立即补充 Buffer 5)
```

始终保持队列中有 2-3 个 buffer，就不会出现 buffer underrun。

---

## 🎯 结论

**核心问题**: 工具库采用串行的 buffer 调度策略，每次只调度一个 buffer，在 chunk 切换时产生间隙。

**根本解决方案**: 实现 buffer 预调度机制，一次调度多个 buffer。

**临时方案**: 增加服务端 chunk 大小，或在客户端合并小 chunk 后再播放。

---

**文档版本**: 1.0
**创建时间**: 2025-11-17
**适用版本**: `@mykin-ai/expo-audio-stream@0.2.28`
