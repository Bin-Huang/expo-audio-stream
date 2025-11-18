# 使用 pnpm 安装修复后的版本

## 🎯 适用场景

如果您的项目使用 **pnpm** 作为包管理器，请按照本指南操作。

---

## 🚀 方法 1: 使用 pnpm link（推荐用于开发测试）

### 步骤 1: 在工具库中创建全局链接

```bash
cd /Users/benn/Documents/w/expo-audio-stream

# 构建库
pnpm install
pnpm build

# 创建全局链接
pnpm link --global
```

### 步骤 2: 在您的项目中链接

```bash
cd /path/to/your/project

# 链接修改后的库
pnpm link --global @mykin-ai/expo-audio-stream

# 安装 iOS pods
npx pod-install

# 运行
pnpm ios
```

### 步骤 3: 测试完成后取消链接

```bash
# 在您的项目中
pnpm unlink --global @mykin-ai/expo-audio-stream

# 恢复原版本
pnpm install
```

---

## 🚀 方法 2: 使用本地路径（推荐用于长期使用）

### 步骤 1: 修改 package.json

编辑您项目的 `package.json`：

```json
{
  "dependencies": {
    "@mykin-ai/expo-audio-stream": "file:../expo-audio-stream"
  }
}
```

**注意路径**：
- 如果工具库和项目是兄弟目录：`"file:../expo-audio-stream"`
- 如果在其他位置：`"file:/Users/benn/Documents/w/expo-audio-stream"`

### 步骤 2: 安装

```bash
cd /path/to/your/project

# pnpm 会自动处理本地依赖
pnpm install

# 安装 iOS pods
npx pod-install

# 运行
pnpm ios
```

### 工作原理

pnpm 会在 `node_modules` 中创建符号链接指向本地库：

```
your-project/node_modules/@mykin-ai/expo-audio-stream
  → /Users/benn/Documents/w/expo-audio-stream
```

---

## 🚀 方法 3: 使用 workspace（如果项目支持）

如果您的项目使用 pnpm workspace，可以将工具库添加为 workspace 成员。

### 步骤 1: 修改项目根目录的 pnpm-workspace.yaml

```yaml
packages:
  - 'apps/*'
  - 'packages/*'
  - '../expo-audio-stream'  # 添加工具库路径
```

### 步骤 2: 在子项目中引用

```json
{
  "dependencies": {
    "@mykin-ai/expo-audio-stream": "workspace:*"
  }
}
```

### 步骤 3: 安装

```bash
pnpm install
npx pod-install
pnpm ios
```

---

## 🔧 常见问题

### 问题 1: pnpm link 不工作

**症状**：执行 `pnpm link --global` 后找不到包

**解决方案**：

```bash
# 检查 pnpm 全局路径
pnpm root -g

# 应该看到类似: /Users/benn/.local/share/pnpm/global/5/node_modules

# 确认链接是否创建
ls -la $(pnpm root -g)/@mykin-ai/

# 如果没有，手动指定包名
cd /Users/benn/Documents/w/expo-audio-stream
pnpm link --global --link-workspace-packages
```

---

### 问题 2: 修改未生效

**症状**：修改了代码但应用中没有更新

**解决方案**：

```bash
# 1. 在工具库中重新构建
cd /Users/benn/Documents/w/expo-audio-stream
pnpm build

# 2. 在项目中清理并重新安装
cd /path/to/your/project
rm -rf node_modules
rm -rf ios/Pods
pnpm install
npx pod-install

# 3. 清理 iOS 缓存
cd ios
xcodebuild clean
cd ..

# 4. 重新运行
pnpm ios
```

---

### 问题 3: 符号链接权限错误

**症状**：`EACCES: permission denied, symlink`

**解决方案**：

```bash
# 使用绝对路径
{
  "dependencies": {
    "@mykin-ai/expo-audio-stream": "file:/Users/benn/Documents/w/expo-audio-stream"
  }
}

# 然后
pnpm install --shamefully-hoist
```

---

### 问题 4: Watchman 冲突

**症状**：修改库代码后，Metro bundler 没有重新加载

**解决方案**：

```bash
# 清理 watchman
watchman watch-del-all

# 重启 Metro bundler
pnpm start --reset-cache
```

---

## 📋 完整工作流程示例

### 开发-测试-部署流程

```bash
# === 阶段 1: 设置开发环境 ===
cd /Users/benn/Documents/w/expo-audio-stream
pnpm install
pnpm build

cd /path/to/your/project
# 编辑 package.json 添加 file: 路径
pnpm install
npx pod-install

# === 阶段 2: 开发和测试 ===
# 修改工具库代码
cd /Users/benn/Documents/w/expo-audio-stream
# ... 修改 Swift 代码 ...
pnpm build

# 测试
cd /path/to/your/project
pnpm ios

# === 阶段 3: 迭代调试 ===
# 如果需要修改，重复上面步骤
# 不需要每次都 pnpm install，除非修改了依赖

# === 阶段 4: 部署到生产 ===
# 方式 A: 使用本地路径（继续使用 file:）
# 方式 B: 发布到 npm/私有仓库
# 方式 C: 使用 git 依赖
```

---

## 🎯 推荐方案对比

| 方案 | 优点 | 缺点 | 适用场景 |
|------|------|------|----------|
| `pnpm link` | 快速切换、不污染 package.json | 需要手动管理、重启后失效 | 临时测试 |
| `file:` 路径 | 自动同步、持久化 | 需要提交 package.json 更改 | 开发期长期使用 |
| workspace | 统一管理、最佳开发体验 | 需要 monorepo 结构 | 大型项目 |

---

## 💡 最佳实践

### 1. 使用相对路径

```json
{
  "dependencies": {
    "@mykin-ai/expo-audio-stream": "file:../expo-audio-stream"
  }
}
```

**优点**：团队其他成员只需保持相同的目录结构即可。

---

### 2. 添加 .npmrc 配置

在项目根目录创建 `.npmrc`：

```ini
# 启用 shamefully-hoist 以兼容 React Native
shamefully-hoist=true

# 自动安装 peers
auto-install-peers=true

# 使用硬链接节省空间
store-dir=~/.pnpm-store
```

---

### 3. 在 .gitignore 中排除

如果使用 `file:` 路径，确保不提交到 git：

```gitignore
# .gitignore

# 开发时的本地依赖配置
package.json.local
pnpm-lock.yaml.local
```

可以创建两个版本：
- `package.json` - 用于生产（指向 npm 版本）
- `package.json.local` - 用于开发（指向 file: 路径）

使用时：
```bash
# 开发
cp package.json.local package.json
pnpm install

# 部署前
git checkout package.json
```

---

### 4. 自动化脚本

在项目根目录创建 `scripts/use-local-audio-stream.sh`：

```bash
#!/bin/bash

AUDIO_STREAM_PATH="${1:-../expo-audio-stream}"

echo "Using local expo-audio-stream from: $AUDIO_STREAM_PATH"

# 修改 package.json
node -e "
const fs = require('fs');
const pkg = require('./package.json');
pkg.dependencies['@mykin-ai/expo-audio-stream'] = 'file:$AUDIO_STREAM_PATH';
fs.writeFileSync('./package.json', JSON.stringify(pkg, null, 2));
"

# 安装
pnpm install
npx pod-install

echo "✅ Local expo-audio-stream setup complete!"
echo "Run: pnpm ios"
```

使用：
```bash
chmod +x scripts/use-local-audio-stream.sh
./scripts/use-local-audio-stream.sh
```

---

## ✅ 验证安装

安装完成后，检查是否正确：

```bash
# 1. 检查符号链接
ls -la node_modules/@mykin-ai/expo-audio-stream
# 应该显示 -> ../../../expo-audio-stream 或绝对路径

# 2. 检查版本
pnpm list @mykin-ai/expo-audio-stream
# 应该显示本地路径

# 3. 验证构建产物
ls node_modules/@mykin-ai/expo-audio-stream/build/
# 应该看到 index.js, index.d.ts 等文件

# 4. 检查 iOS 链接
ls ios/Pods/Headers/Public/ | grep ExpoPlayAudioStream
# 应该有相关头文件
```

---

## 🆘 终极修复

如果所有方法都不工作，使用这个终极方案：

```bash
cd /path/to/your/project

# 1. 完全清理
rm -rf node_modules
rm -rf ~/.pnpm-store
rm -rf ios/Pods
rm -rf ios/build
rm pnpm-lock.yaml

# 2. 重新构建工具库
cd /Users/benn/Documents/w/expo-audio-stream
rm -rf node_modules build
pnpm install
pnpm build

# 3. 在项目中重新安装（使用绝对路径）
cd /path/to/your/project
# 修改 package.json 使用绝对路径:
# "@mykin-ai/expo-audio-stream": "file:/Users/benn/Documents/w/expo-audio-stream"

pnpm install --no-frozen-lockfile
npx pod-install

# 4. 清理 Metro bundler
pnpm start --reset-cache

# 5. 在另一个终端运行
pnpm ios
```

---

## 📞 需要帮助？

如果遇到 pnpm 特定的问题：

1. 检查 pnpm 版本：`pnpm --version`（推荐 ≥ 8.0）
2. 查看详细日志：`pnpm install --loglevel debug`
3. 参考 pnpm 文档：https://pnpm.io/workspaces

---

**祝使用顺利！** 🚀
