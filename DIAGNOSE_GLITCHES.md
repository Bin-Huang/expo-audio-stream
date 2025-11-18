# 诊断音频毛刺问题

## 🔍 步骤 1: 收集日志信息

重新构建并运行应用，现在会有详细的诊断日志。

### 构建并运行

```bash
cd /Users/benn/Documents/w/expo-audio-stream
pnpm build

cd /path/to/your/project
pnpm install
npx pod-install
pnpm ios
```

### 查看日志

```bash
npx react-native log-ios | grep SoundPlayer
```

---

## 📊 应该看到的日志模式

### 正常情况（无毛刺）

```
[SoundPlayer] 🎤 New chunk arrived: 250.0ms, 4000 frames, queue size: 0, scheduled: 0
[SoundPlayer] 📥 Scheduling buffer 1/100, duration: 250.0ms, queue: 0, frames: 4000
[SoundPlayer] 🎵 Starting playback with 1 buffers scheduled (scheduled 1 in 0.50ms)

[SoundPlayer] 🎤 New chunk arrived: 250.0ms, 4000 frames, queue size: 0, scheduled: 1
[SoundPlayer] 📥 Scheduling buffer 2/100, duration: 250.0ms, queue: 0, frames: 4000
[SoundPlayer] 📦 Scheduled 1 more buffers in 0.30ms, total: 2

[SoundPlayer] 🎤 New chunk arrived: 250.0ms, 4000 frames, queue size: 0, scheduled: 2
[SoundPlayer] 📥 Scheduling buffer 3/100, duration: 250.0ms, queue: 0, frames: 4000
[SoundPlayer] 📦 Scheduled 1 more buffers in 0.25ms, total: 3

[SoundPlayer] ✅ Buffer completed, remaining scheduled: 2, segments left: 9, queue: 0
[SoundPlayer] 🎤 New chunk arrived: 250.0ms, 4000 frames, queue size: 0, scheduled: 2
[SoundPlayer] 📥 Scheduling buffer 3/100, duration: 250.0ms, queue: 0, frames: 4000
[SoundPlayer] 📦 Scheduled 1 more buffers in 0.28ms, total: 3
```

**关键点**：
- ✅ `scheduled` 数量始终保持在 2-3 个
- ✅ 新 chunk 到达时立即调度（`queue size: 0`）
- ✅ buffer 完成时仍有 2 个在播放

---

### 异常情况 1: Chunk 到达太慢

```
[SoundPlayer] 🎤 New chunk arrived: 250.0ms, 4000 frames, queue size: 0, scheduled: 0
[SoundPlayer] 📥 Scheduling buffer 1/100, duration: 250.0ms, queue: 0, frames: 4000
[SoundPlayer] 🎵 Starting playback with 1 buffers scheduled

[SoundPlayer] ✅ Buffer completed, remaining scheduled: 0, segments left: 9, queue: 0
⚠️ 间隔 300ms 无新 chunk
[SoundPlayer] 🎤 New chunk arrived: 250.0ms, 4000 frames, queue size: 0, scheduled: 0
```

**问题**：
- ❌ Buffer 播放完了，但下一个 chunk 还没到达
- ❌ `scheduled: 0` 说明播放队列已空
- ❌ 这会产生明显的间隙和毛刺

**原因**：
- 网络延迟
- 服务端发送太慢
- Chunk 太小（250ms 不够缓冲时间）

---

### 异常情况 2: Chunk 堆积在队列中

```
[SoundPlayer] 🎤 New chunk arrived: 250.0ms, 4000 frames, queue size: 95, scheduled: 100
⚠️ queue size 很大，但没有被调度

[SoundPlayer] ✅ Buffer completed, remaining scheduled: 99, segments left: 200, queue: 95
[SoundPlayer] 📥 Scheduling buffer 100/100, duration: 250.0ms, queue: 94, frames: 4000
```

**问题**：
- ⚠️ 虽然 100 个 buffer 在调度，但还是有毛刺？
- 说明问题可能不在调度机制

**可能原因**：
- Chunk 本身有问题（边界不连续）
- 音频格式问题
- 采样率不匹配

---

### 异常情况 3: Buffer 持续时间太短

```
[SoundPlayer] 🎤 New chunk arrived: 50.0ms, 800 frames, queue size: 0, scheduled: 2
[SoundPlayer] 📥 Scheduling buffer 3/100, duration: 50.0ms, queue: 0, frames: 800
```

**问题**：
- ❌ Chunk 只有 50ms，太短了
- ❌ 即使有 3 个 buffer，总共也只有 150ms 缓冲
- ❌ 任何延迟都会导致间隙

**解决**：
- 服务端发送更大的 chunk（至少 200ms）
- 或客户端合并多个小 chunk

---

## 🔎 诊断步骤

### 第 1 步：检查日志模式

运行应用并查看日志，回答：

1. **Chunk 大小是多少？**
   ```
   查看 "duration: XXXms" 和 "frames: XXXX"
   ```
   - 如果 < 100ms：太小，需要增大
   - 如果 100-200ms：勉强可以
   - 如果 > 200ms：理想

2. **Scheduled 数量如何变化？**
   ```
   查看 "scheduled: X"
   ```
   - 应该保持在 2-3 个（如果 chunk 大）
   - 或 5-10 个（如果 chunk 小）

3. **有没有出现 `scheduled: 0`？**
   ```
   查看 "✅ Buffer completed, remaining scheduled: 0"
   ```
   - 如果有：说明 chunk 到达不及时
   - 如果没有：说明调度正常

4. **Queue size 是多少？**
   ```
   查看 "queue size: X"
   ```
   - 应该保持在 0（立即调度）
   - 如果 > 10：说明调度赶不上到达速度（不太可能）

---

### 第 2 步：根据日志模式判断问题

#### 情况 A: `scheduled` 经常变为 0

**表现**：
```
✅ Buffer completed, remaining scheduled: 0
（等待）
🎤 New chunk arrived
```

**根本原因**：Chunk 到达不够快

**解决方案**：

1. **服务端增大 chunk**

   让服务端每次发送更大的 chunk（300-500ms）

2. **客户端合并 chunk**

   在 `app/video-chat.tsx` 中缓存多个 chunk：

   ```typescript
   let chunkBuffer: string[] = [];

   if (data.audioBase64) {
       chunkBuffer.push(data.audioBase64);

       // 累积到 500ms 或遇到最后一个 chunk 时播放
       if (chunkBuffer.length >= 3 || data.isFinal) {
           // 合并所有 chunk
           const combined = combineBase64Chunks(chunkBuffer);
           await ExpoPlayAudioStream.playSound(combined, `${index}`, EncodingTypes.PCM_S16LE);
           chunkBuffer = [];
       }
   }

   function combineBase64Chunks(chunks: string[]): string {
       // 将 base64 解码为二进制
       const buffers = chunks.map(chunk => {
           const binary = atob(chunk);
           const bytes = new Uint8Array(binary.length);
           for (let i = 0; i < binary.length; i++) {
               bytes[i] = binary.charCodeAt(i);
           }
           return bytes;
       });

       // 合并二进制数据
       const totalLength = buffers.reduce((sum, buf) => sum + buf.length, 0);
       const combined = new Uint8Array(totalLength);
       let offset = 0;
       for (const buf of buffers) {
           combined.set(buf, offset);
           offset += buf.length;
       }

       // 转回 base64
       let binary = '';
       for (let i = 0; i < combined.length; i++) {
           binary += String.fromCharCode(combined[i]);
       }
       return btoa(binary);
   }
   ```

---

#### 情况 B: `scheduled` 很高但仍有毛刺

**表现**：
```
✅ Buffer completed, remaining scheduled: 50+
但仍然听到毛刺
```

**根本原因**：不是调度问题，是 chunk 内容问题

**可能性**：

1. **Chunk 边界不连续**

   检查每个 chunk 的最后一个采样点和下一个 chunk 的第一个采样点是否连续：

   ```swift
   // 在 AudioUtils.swift 中添加检测
   static func detectDiscontinuity(previousBuffer: AVAudioPCMBuffer?, currentBuffer: AVAudioPCMBuffer) -> Bool {
       guard let prev = previousBuffer,
             let prevData = prev.floatChannelData,
             let currData = currentBuffer.floatChannelData else {
           return false
       }

       let lastSample = prevData.pointee[Int(prev.frameLength) - 1]
       let firstSample = currData.pointee[0]
       let diff = abs(lastSample - firstSample)

       // 如果突变超过 0.5，说明不连续
       if diff > 0.5 {
           Logger.debug("[AudioUtils] ⚠️ Discontinuity detected: \(diff)")
           return true
       }
       return false
   }
   ```

2. **采样率不匹配**

   确认服务端和客户端的采样率一致：

   ```typescript
   // 检查配置
   await ExpoPlayAudioStream.setSoundConfig({
       sampleRate: 16000,  // 必须与服务端一致！
       playbackMode: PlaybackModes.CONVERSATION,
   })
   ```

3. **音频编码问题**

   确认使用正确的编码：
   ```typescript
   EncodingTypes.PCM_S16LE  // 确保与服务端一致
   ```

---

#### 情况 C: 只有前几个 chunk 有毛刺

**表现**：
```
前 3-5 个 chunk 有毛刺，之后就流畅了
```

**根本原因**：初始缓冲不足

**解决方案**：

在第一个 chunk 到达时，等待更多 chunk 再开始播放：

```typescript
let initialBufferSize = 3;
let bufferedChunks: string[] = [];

if (data.audioBase64) {
    bufferedChunks.push(data.audioBase64);

    // 前几个 chunk 需要缓冲
    if (index < initialBufferSize) {
        if (bufferedChunks.length >= initialBufferSize || data.isFinal) {
            // 一次性发送多个 chunk
            for (const chunk of bufferedChunks) {
                await ExpoPlayAudioStream.playSound(chunk, `${index}`, EncodingTypes.PCM_S16LE);
            }
            bufferedChunks = [];
        }
    } else {
        // 后续 chunk 直接播放
        await ExpoPlayAudioStream.playSound(data.audioBase64, `${index}`, EncodingTypes.PCM_S16LE);
    }
}
```

---

## 🧪 实验：确定问题类型

### 实验 1: 测试连续音调

创建一个测试，播放连续的正弦波：

```typescript
async function testContinuousTone() {
    const frequency = 1000; // 1kHz
    const sampleRate = 16000;
    const chunkDuration = 200; // 200ms per chunk
    const samplesPerChunk = (sampleRate * chunkDuration) / 1000;

    for (let i = 0; i < 20; i++) {
        const buffer = new Int16Array(samplesPerChunk);

        for (let j = 0; j < samplesPerChunk; j++) {
            // 连续相位，确保 chunk 边界无突变
            const t = (i * samplesPerChunk + j) / sampleRate;
            buffer[j] = Math.sin(2 * Math.PI * frequency * t) * 32767;
        }

        const base64 = arrayBufferToBase64(buffer.buffer);
        await ExpoPlayAudioStream.playSound(base64, `test-${i}`, EncodingTypes.PCM_S16LE);

        // 模拟网络延迟
        await new Promise(resolve => setTimeout(resolve, 50));
    }
}
```

**预期**：
- 如果听到连续的音调无毛刺：说明调度机制工作正常，问题在服务端数据
- 如果仍有毛刺：说明调度机制仍有问题

---

### 实验 2: 测试不同 chunk 大小

```typescript
// 测试 50ms chunk
// 测试 200ms chunk
// 测试 500ms chunk

// 观察哪个大小无毛刺
```

---

## 📋 诊断检查清单

请按顺序检查：

- [ ] 日志中 chunk duration 是多少？
- [ ] 日志中 scheduled 数量保持在多少？
- [ ] 有没有出现 `scheduled: 0`？
- [ ] `maxScheduledBuffers` 设置为多少？（现在是 100）
- [ ] 服务端采样率是多少？
- [ ] 客户端配置的采样率是多少？
- [ ] 毛刺是规律出现还是随机？
- [ ] 毛刺是"咔嗒"声还是"爆音"？
- [ ] 只有前几个 chunk 有问题还是全程都有？

---

## 📞 反馈格式

请提供以下信息：

```
1. 日志片段（至少 20 行）：
   [粘贴日志]

2. Chunk 信息：
   - Duration: XXX ms
   - Frames: XXXX
   - 到达间隔: XXX ms

3. Scheduled 变化：
   - 最小值: X
   - 最大值: Y
   - 通常: Z

4. 毛刺特征：
   - 频率: 每个 chunk / 部分 chunk / 随机
   - 声音: 咔嗒 / 爆音 / 静音
   - 位置: 开头 / 全程 / 随机

5. 配置：
   - 服务端采样率: XXXX Hz
   - 客户端采样率: XXXX Hz
   - Chunk 大小设置: XXX ms
```

有了这些信息，我可以更精确地定位问题！

---

**运行日志收集命令**：

```bash
npx react-native log-ios | grep SoundPlayer > audio-debug.log 2>&1
```

播放一段音频后，将 `audio-debug.log` 的内容发给我。
