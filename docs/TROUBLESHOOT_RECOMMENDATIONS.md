# 🔧 推荐牌不显示 - 诊断指南

**问题**: 推荐牌（shimmer 效果）没有显示
**日期**: 2025-12-04
**诊断工具**: Debug Server (port 8765)

---

## 📋 诊断步骤

### 步骤 1: 验证 JavaScript 模块是否加载

```bash
# 检查 WebGL Shimmer 是否存在
curl -X POST http://localhost:8765/js \
  -d "typeof window.__nakiWebGLShimmer"

# 预期输出: "function"
# 如果是 "undefined"，说明 JS 没有加载
```

**如果返回 "undefined"**:
- ❌ JavaScript 模块未加载
- 解决方案: 检查 `naki-webgl-shimmer.js` 是否在 Xcode 的 "Copy Bundle Resources" 中

---

### 步骤 2: 验证游戏对象是否就绪

```bash
# 检查 Majsoul 游戏对象
curl -X POST http://localhost:8765/js \
  -d "window.view?.DesktopMgr?.Inst ? '✅ Game Ready' : '❌ Game Not Ready'"

# 检查宝牌效果对象
curl -X POST http://localhost:8765/js \
  -d "window.view?.DesktopMgr?.Inst?.effect_dora3D ? '✅ Dora3D Found' : '❌ Not Found'"

# 检查手牌 3D 对象
curl -X POST http://localhost:8765/js \
  -d "window.view?.DesktopMgr?.Inst?.mainrole?.hand3d ? '✅ Hand3D Found' : '❌ Not Found'"
```

**如果返回 "Not Ready"**:
- ⏳ 游戏还在加载（等待 2-5 秒）
- 🔄 Majsoul 版本有变化（需要调整初始化逻辑）

---

### 步骤 3: 验证 WebGL Shimmer 是否初始化成功

```bash
# 检查初始化状态
curl -X POST http://localhost:8765/js \
  -d "window.__nakiWebGLShimmer?.doraMaterial ? '✅ Material Loaded' : '❌ Material Not Found'"

# 查看日志
curl http://localhost:8765/logs | grep -i "webgl\|shimmer" | tail -20
```

**关键日志信息**:
- ✅ "[WebGL Shimmer] ✅ Initialized"
- ✅ "[WebGL Shimmer] ✅ Initialized (dora_shine-style effect)"
- ❌ "[WebGL Shimmer] ❌ Material not initialized"

---

### 步骤 4: 验证推荐数据是否存在

```bash
# 检查是否有推荐
curl -X POST http://localhost:8765/js \
  -d "window.view?.DesktopMgr?.Inst?.mainrole?.hand?.length"

# 应该返回一个数字 (13 或 14 张牌)

# 检查 Bot 状态
curl http://localhost:8765/bot/status | jq '.recommendations'

# 应该看到推荐列表，例如:
# [
#   {"tile": "5m", "probability": 0.85, "action": "discard"},
#   ...
# ]
```

**如果没有推荐**:
- 游戏没有要求推荐（还没有轮到玩家行动）
- Bot 没有初始化
- 没有接收到游戏状态

---

### 步骤 5: 手动测试 Shimmer

```bash
# 手动设置推荐（测试 WebGL 是否工作）
curl -X POST http://localhost:8765/js \
  -d "window.__nakiWebGLShimmer?.setRecommendationByName('5m', 0.85); 'Called'"

# 应该看到卡牌上的闪光效果

# 清除推荐
curl -X POST http://localhost:8765/js \
  -d "window.__nakiWebGLShimmer?.clearAllRecommendations(); 'Cleared'"
```

---

## 🐛 常见问题及解决方案

### 问题 1: "typeof window.__nakiWebGLShimmer" 返回 "undefined"

**原因**: JavaScript 模块没有加载

**解决**:
```bash
# 1. 检查文件是否存在
ls -la Naki/Resources/JavaScript/naki-webgl-shimmer.js

# 2. 在 Xcode 中验证:
#    - 选择 Naki 项目
#    - Build Phases → Copy Bundle Resources
#    - 确保 naki-webgl-shimmer.js 在列表中
#    - 如果不在，点击 + 添加它

# 3. 清除并重新构建
xcodebuild clean -project Naki.xcodeproj -scheme Naki
xcodebuild build -project Naki.xcodeproj -scheme Naki
```

---

### 问题 2: "Game Not Ready" 或 "Not Found"

**原因**: 游戏还在加载或 Majsoul 版本有变化

**解决**:
```bash
# 等待游戏加载（2-5 秒后再试）
sleep 5
curl -X POST http://localhost:8765/js \
  -d "window.view?.DesktopMgr?.Inst?.effect_dora3D ? '✅ Ready' : '❌ Not Ready'"

# 如果还是 Not Found，可能是版本问题
# 查看 Majsoul 是否有更新
```

---

### 问题 3: "Material Not Found"

**原因**: 无法获取原生宝牌材质

**解决**:
```bash
# 检查宝牌效果对象的结构
curl -X POST http://localhost:8765/js -d "Object.keys(window.view?.DesktopMgr?.Inst?.effect_dora3D || {})"

# 检查是否有 material 属性
curl -X POST http://localhost:8765/js \
  -d "window.view?.DesktopMgr?.Inst?.effect_dora3D?.material ? 'Found' : 'Not Found'"

# 可能需要调整初始化逻辑或使用其他效果对象
```

---

### 问题 4: 手动设置推荐成功，但自动推荐不显示

**原因**: WebViewModel 的调用有问题或推荐数据没有被传递

**解决**:
```bash
# 检查推荐是否被生成
curl http://localhost:8765/bot/status | jq '.recommendations'

# 查看 WebViewModel 的日志
curl http://localhost:8765/logs | grep -i "webviewmodel\|update.*shimmer" | tail -10

# 可能原因:
# 1. Bot 没有初始化（还没有生成推荐）
# 2. 推荐列表为空
# 3. JavaScript 调用失败（查看浏览器控制台）
```

---

### 问题 5: 颜色显示不对或闪光效果奇怪

**原因**: albedo 参数设置不当或颜色转换有问题

**解决**:
```bash
# 编辑 naki-webgl-shimmer.js，调整颜色
# 第 45-55 行的 colors 配置：

colors: {
    green: {
        albedo: { x: 2.0, y: 2.5, z: 2.0, w: 2.0 },  // 尝试调整这些值
        emissionColor: { x: 0.2, y: 0.8, z: 0.2, w: 1.0 }
    },
    orange: {
        albedo: { x: 2.5, y: 1.5, z: 0.5, w: 2.0 },  // 或这些
        emissionColor: { x: 0.8, y: 0.5, z: 0.0, w: 1.0 }
    }
}

# 然后重新启动应用
```

---

## 🔍 高级诊断

### 查看完整的日志

```bash
curl http://localhost:8765/logs | jq '.' | grep -i -A 2 -B 2 "shimmer\|webgl"
```

### 查看所有加载的 JavaScript 模块

```bash
curl -X POST http://localhost:8765/js \
  -d "Object.keys(window).filter(k => k.includes('naki')).slice(0, 20)"
```

### 检查 WebView 是否有错误

```bash
# 在 Xcode 中启用 Web Inspector（如果是 DEBUG 模式）
# 然后用浏览器访问 localhost:8765 看实时日志
```

---

## 📊 诊断流程图

```
推荐不显示
    │
    ├─ 是否有推荐数据？
    │  ├─ 否 → Bot 没有初始化或没有轮到玩家
    │  └─ 是 → 继续
    │
    ├─ JavaScript 是否加载？
    │  ├─ 否 → 检查 Copy Bundle Resources
    │  └─ 是 → 继续
    │
    ├─ 游戏对象是否就绪？
    │  ├─ 否 → 等待游戏加载（2-5 秒）
    │  └─ 是 → 继续
    │
    ├─ 宝牌材质是否存在？
    │  ├─ 否 → Majsoul 版本变化，需要调整
    │  └─ 是 → 继续
    │
    └─ 手动调用是否工作？
       ├─ 是 → WebViewModel 调用方式有问题
       └─ 否 → WebGL Shimmer 初始化失败
```

---

## 📞 快速诊断命令套餐

```bash
# 一条命令诊断所有问题
echo "=== 诊断报告 ===" && \
echo "1. JS 加载:" && curl -s -X POST http://localhost:8765/js -d "typeof window.__nakiWebGLShimmer" && \
echo "" && \
echo "2. 游戏就绪:" && curl -s -X POST http://localhost:8765/js -d "!!window.view?.DesktopMgr?.Inst" && \
echo "" && \
echo "3. 宝牌材质:" && curl -s -X POST http://localhost:8765/js -d "!!window.view?.DesktopMgr?.Inst?.effect_dora3D?.material" && \
echo "" && \
echo "4. 推荐数据:" && curl -s http://localhost:8765/bot/status | jq '.recommendationCount // 0' && \
echo "" && \
echo "5. 最近日志:" && curl -s http://localhost:8765/logs | tail -5 | grep -i shimmer
```

---

## ✅ 验证清单

完整的诊断需要以下全部通过：

- [ ] `typeof window.__nakiWebGLShimmer` → "function"
- [ ] `window.view?.DesktopMgr?.Inst` → 存在
- [ ] `window.view?.DesktopMgr?.Inst?.effect_dora3D?.material` → 存在
- [ ] `window.view?.DesktopMgr?.Inst?.mainrole?.hand3d` → 存在
- [ ] Bot 生成了推荐 (概率 >= 0.2)
- [ ] 日志中有 "WebGL Shimmer" 相关信息
- [ ] 手动调用 `setRecommendationByName` 成功

---

**作者**: Claude Code
**日期**: 2025-12-04
**用途**: 快速诊断和解决推荐不显示问题
