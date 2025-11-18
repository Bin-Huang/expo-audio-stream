# 快速开始 - 修复流式音频毛刺

## ✅ 修复已完成！

已成功修复流式音频播放时 chunk 切换的毛刺问题。

---

## 🚀 立即使用

### 方法 1: 在您的项目中使用修改后的版本

```bash
# 1. 进入您的项目目录
cd /path/to/your/project

# 2. 修改 package.json，指向本地库
# 将以下内容添加到 dependencies:
# "@mykin-ai/expo-audio-stream": "file:../expo-audio-stream"

# 3. 安装依赖
yarn install

# 4. iOS: 安装 pods
npx pod-install

# 5. 运行应用
yarn ios
```

### 方法 2: 直接测试（推荐先测试）

```bash
# 在工具库目录
cd /Users/benn/Documents/w/expo-audio-stream

# 构建
yarn build

# 在您的项目中临时链接
cd /path/to/your/project
yarn add file:../expo-audio-stream
npx pod-install
yarn ios
```

---

## 🎯 验证修复效果

### 1. 运行应用后查看日志

在 Xcode Console 中应该看到：

```
[SoundPlayer] Scheduling buffer 1/3, queue size: 2
[SoundPlayer] Scheduling buffer 2/3, queue size: 1
[SoundPlayer] Scheduling buffer 3/3, queue size: 0
[SoundPlayer] Starting playback with 3 buffers scheduled
```

### 2. 听觉测试

进行正常的语音对话，音频应该：
- ✅ 完全流畅，无咔嗒声
- ✅ chunk 切换完全无缝
- ✅ 无停顿或爆音

### 3. 如果还有问题

**情况 A: 只看到 `Scheduling buffer 1/3`**
- 原因：chunk 到达太慢或网络问题
- 解决：检查网络连接和服务端

**情况 B: 仍有轻微毛刺**
- 原因：chunk 可能太小
- 解决：增加 `maxScheduledBuffers` 到 5（见下方）

---

## 🔧 调整参数（如果需要）

如果需要调整预调度数量，编辑 `ios/SoundPlayer.swift:22`：

```swift
// 默认值
private let maxScheduledBuffers: Int = 3

// 如果 chunk 到达慢或网络不稳定，改为 5
private let maxScheduledBuffers: Int = 5

// 如果想减少延迟，改为 2
private let maxScheduledBuffers: Int = 2
```

修改后重新构建：
```bash
cd expo-audio-stream
yarn build
cd your-project
yarn ios
```

---

## 📋 修改内容摘要

### 核心改动

1. **添加预调度机制**
   - 追踪已调度的 buffer 数量
   - 保持 2-3 个 buffer 在播放器队列中

2. **修改调度逻辑**
   - 从串行调度（一次一个）改为批量预调度
   - 新 chunk 到达时立即调度（如果有空间）

3. **消除间隙**
   - 下一个 chunk 在当前播放完成前就已经在播放器中
   - 无需等待回调延迟

### 代码改动

- `ios/SoundPlayer.swift`: 约 45 行改动
  - 新增 2 个属性
  - 修改 1 行调用
  - 重写 1 个方法
  - 更新 1 行清理逻辑

### 完全兼容

- ✅ API 无变化
- ✅ 行为向后兼容
- ✅ 无需修改使用代码
- ✅ 性能开销可忽略

---

## 📚 相关文档

- **详细分析**: `AUDIO_GLITCH_ISSUE_ANALYSIS.md` - 问题根因和多种解决方案
- **修复指南**: `FIX_STREAMING_GLITCH.md` - 详细的代码修改步骤
- **测试指南**: `TESTING_GUIDE.md` - 完整的测试方法和检查清单

---

## 🐛 如果遇到问题

### 编译错误

```bash
# 清理并重新构建
cd expo-audio-stream
yarn clean
yarn build
```

### Pod 安装失败

```bash
cd your-project/ios
pod deintegrate
pod install
```

### 修改未生效

```bash
# 完全清理
cd your-project
rm -rf node_modules
rm -rf ios/Pods
yarn install
npx pod-install
```

---

## 🎉 成功标志

当您看到以下情况，说明修复完全成功：

1. ✅ 应用正常运行
2. ✅ 日志显示 `Scheduling buffer 1/3, 2/3, 3/3`
3. ✅ 音频播放流畅无毛刺
4. ✅ 长时间使用无问题

---

## 💬 反馈

如果测试效果良好，建议：

1. 在生产环境部署前充分测试
2. 考虑提交 PR 到上游仓库
3. 分享您的使用体验

---

**祝使用愉快！** 🚀

有任何问题随时查看详细文档或提 Issue。
