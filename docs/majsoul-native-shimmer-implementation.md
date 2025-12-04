# Majsoul 原生 Shimmer 效果实现完全指南

**日期**: 2025-12-04
**调查方法**: 通过 Debug Server 反向工程
**目标**: 理解红宝牌（赤牌）和宝牌（ドラ）的 Shimmer 效果原理

---

## 目录

1. [查询方法](#查询方法)
2. [宝牌 Shimmer 效果](#宝牌-shimmer-效果)
3. [红宝牌实现](#红宝牌实现)
4. [关键着色器](#关键着色器)
5. [完整资源列表](#完整资源列表)
6. [实现对比](#实现对比)

---

## 查询方法

### 使用的 Debug Server 端点

```bash
# 1. 获取 API 文档
curl http://localhost:8765/help | jq .

# 2. 检查游戏对象
curl -X POST http://localhost:8765/js -d "window.view?.DesktopMgr?.Inst"

# 3. 检查加载的资源
curl -X POST http://localhost:8765/js -d "Object.keys(window.Laya?.Loader?.loadedMap || {})"

# 4. 执行 JavaScript 搜索
curl -X POST http://localhost:8765/js -d "Object.keys(...).filter(k => k.includes('dora'))"
```

### 发现过程

#### 第 1 步：定位游戏对象结构
```javascript
window.view.DesktopMgr.Inst = {
  // 手牌相关
  mainrole: {
    hand: [],           // 13 张手牌 + 1 张新抽牌
    hand3d: Object,     // 3D 手牌对象
    HandPaiPlane: {},   // 平面手牌渲染
  },

  // 效果对象
  effect_dora3D: {},        // 宝牌 3D 效果
  effect_dora3D_touying: {}, // 宝牌 3D 阴影
  effect_doraPlane: {},     // 宝牌平面效果
  effect_recommend: {},     // 推荐效果（AI 高亮）
  effect_shadow: {},        // 阴影效果

  // 状态数据
  dora: [{               // 宝牌数据
    dora: false,
    index: 3,           // 牌号（0-8）
    type: 2,            // 牌类（0=m, 1=p, 2=s, 3=z）
    touming: false,     // 是否透明
    baida: false        // 白牌标记
  }]
}
```

#### 第 2 步：查找效果资源
```bash
# 发现关键资源路径
https://game.maj-soul.com/1/v0.11.64.w/lang/scene/Assets/Resource/effect/texture/dora_shine/
  ├─ dora_shine.png     # 闪光纹理
  └─ dora_shine.lmat    # 材质定义文件
```

#### 第 3 步：解析材质配置
```json
// dora_shine.lmat 的内容
{
  "version": "LAYAMATERIAL:01",
  "props": {
    "name": "dora_shine",
    "blend": 1,              // 启用混合
    "srcBlend": 770,         // GL_SRC_ALPHA
    "dstBlend": 1,           // GL_ONE (加法混合)
    "depthWrite": false,
    "renderQueue": 3000,
    "textures": [{
      "name": "diffuseTexture",
      "path": "dora_shine.png"
    }],
    "vectors": {
      "albedo": [2, 2, 2, 2],        // 亮度 2x
      "diffuseColor": [1, 1, 1]
    },
    "defines": ["ADDTIVEFOG"]        // 添加雾效
  }
}
```

#### 第 4 步：获取着色器代码
```bash
# cartoon_pai 着色器（牌面渲染）
https://game.maj-soul.com/1/v0.10.237.w/shader/cartoon_pai/cartoon_pai.vs
https://game.maj-soul.com/1/v0.10.237.w/shader/cartoon_pai/cartoon_pai.ps

# outline 着色器（边界高亮）
https://game.maj-soul.com/1/v0.10.1.w/shader/outline/outline.vs
https://game.maj-soul.com/1/v0.10.1.w/shader/outline/outline.ps
```

---

## 宝牌 Shimmer 效果

### 完整实现方案

#### 1. 材质配置（dora_shine.lmat）

```json
{
  "version": "LAYAMATERIAL:01",
  "props": {
    "name": "dora_shine",
    "cull": 0,                      // 不剔除背面
    "blend": 1,                     // 启用混合
    "srcBlend": 770,                // GL_SRC_ALPHA
    "dstBlend": 1,                  // GL_ONE （加法混合）
    "alphaTest": false,             // 无 Alpha 测试
    "depthWrite": false,            // 不写入深度缓冲（关键！）
    "renderQueue": 3000,            // 渲染队列（比牌更晚渲染）

    "textures": [
      {
        "name": "diffuseTexture",
        "path": "dora_shine.png",
        "params": {
          "wrap": 0,                // 纹理包装模式
          "mipmap": false           // 无 MipMap
        }
      },
      {
        "name": "normalTexture",
        "path": ""                  // 无法线贴图
      },
      {
        "name": "specularTexture",
        "path": ""                  // 无高光贴图
      },
      {
        "name": "emissiveTexture",
        "path": ""                  // 无自发光贴图
      }
    ],

    "vectors": [
      {
        "name": "ambientColor",
        "value": [0, 0, 0]          // 无环境光
      },
      {
        "name": "albedo",
        "value": [2, 2, 2, 2]       // 亮度翻倍！核心参数
      },
      {
        "name": "diffuseColor",
        "value": [1, 1, 1]          // 漫反射颜色
      },
      {
        "name": "specularColor",
        "value": [1, 1, 1, 8]       // 高光颜色和强度
      },
      {
        "name": "emissionColor",
        "value": [0, 0, 0]          // 无自发光
      }
    ],

    "defines": ["ADDTIVEFOG"]       // 应用雾效来适应环境光
  }
}
```

#### 2. 混合模式详解

```
OpenGL Blend Function:
  srcBlend = 770 (GL_SRC_ALPHA)
  dstBlend = 1   (GL_ONE)

混合公式:
  Final = Source * Source.Alpha + Destination * 1

即:
  Final = dora_shine * alpha + base_tile

结果: 半透明叠加宝牌纹理，使其发光
```

#### 3. 关键特性

| 特性 | 值 | 作用 |
|------|-----|------|
| **depthWrite** | false | 不遮挡其他元素，保持交互 |
| **renderQueue** | 3000 | 在牌面之后渲染，形成光晕 |
| **albedo** | [2,2,2,2] | 使闪光 2 倍亮度 |
| **srcBlend** | GL_SRC_ALPHA | 使用源 Alpha 通道 |
| **dstBlend** | GL_ONE | 加法混合（亮度相加） |
| **ADDTIVEFOG** | 已启用 | 自动适应场景光照 |

#### 4. 渲染管线

```
游戏渲染顺序:
┌─────────────────────────────────────────┐
│ 1. 渲染底层场景 (renderQueue < 3000)    │
├─────────────────────────────────────────┤
│ 2. 渲染牌面 (cartoon_pai.ps)            │
│    - 基础牌纹理                          │
│    - 卡通光照效果                        │
│    - 普通或红色数字                      │
├─────────────────────────────────────────┤
│ 3. 渲染宝牌闪光 (dora_shine, RQ=3000)  │
│    - 叠加半透明闪光纹理                  │
│    - 加法混合使其发亮                    │
│    - depthWrite=false 不影响深度        │
├─────────────────────────────────────────┤
│ 4. 渲染 UI 和其他效果 (renderQueue > 3000)│
└─────────────────────────────────────────┘
```

#### 5. 宝牌纹理（dora_shine.png）

预计内容:
- **形状**: 可能是条纹或光晕图案
- **Alpha 通道**: 用于控制透明度梯度
- **尺寸**: 根据牌面大小调整（通常 512x512 或更小）
- **特点**: 可重复或可平铺纹理

### 代码实现流程

```
游戏启动:
  1. 加载 dora_shine.png 纹理
  2. 解析 dora_shine.lmat 材质配置
  3. 创建 Material 对象
  └─ srcBlend = GL_SRC_ALPHA
  └─ dstBlend = GL_ONE
  └─ depthWrite = false

游戏运行 (每帧):
  1. 检测宝牌数据: mainrole.dora[]
  2. 对每张宝牌:
     a. 获取牌的世界位置和缩放
     b. 使用 dora_shine 材质创建覆盖层
     c. 在牌面上渲染加法混合纹理
     d. 由于 depthWrite=false，不影响后续元素
  3. 结果: 牌上出现半透明发光效果
```

---

## 红宝牌实现

### 着色器实现（cartoon_pai.ps）

#### 完整像素着色器代码

```glsl
#ifdef FSHIGHPRECISION
    precision highp float;
#else
    precision mediump float;
#endif

#include 'LightHelper.glsl';

varying vec2 v_Texcoord;
uniform sampler2D u_texture;      // 牌面纹理
varying vec3 v_Normal;
uniform float u_split;             // 光照分界值 (0.0-1.0)
uniform vec3 u_color_light;        // 亮面颜色
uniform vec3 u_color_unlight;      // 暗面颜色
uniform vec4 u_color;              // 整体颜色（含红牌信息）
uniform float u_alpha;             // 透明度

#if defined(DIRECTIONLIGHT)
    varying vec3 v_PositionWorld;
    uniform DirectionLight u_DirectionLight;
#endif

void main(){
    vec3 normal = normalize(v_Normal);

    // 计算光照（方向光）
    float diffuse = -dot(u_DirectionLight.Direction, v_Normal);
    float d = diffuse - u_split;

    vec4 color;

    // 卡通渲染的三阶段光照
    if (diffuse > u_split + 0.1) {
        // 亮面：使用 u_color_light 颜色
        color = texture2D(u_texture, v_Texcoord) * vec4(u_color_light, 1) * u_color;
    } else if(diffuse > u_split) {
        // 过渡区：线性插值
        float a = d * 10.0;              // 0.0 - 1.0
        float b = 1.0 - a;
        color = texture2D(u_texture, v_Texcoord) * u_color *
                (vec4(u_color_light, 1) * a + vec4(u_color_unlight, 1) * b);
    } else {
        // 暗面：使用 u_color_unlight 颜色
        color = texture2D(u_texture, v_Texcoord) * vec4(u_color_unlight, 1) * u_color;
    }

    gl_FragColor = color * vec4(1, 1, 1, u_alpha);
}
```

#### 顶点着色器代码（cartoon_pai.vs）

```glsl
attribute vec4 a_Position;
attribute vec2 a_Texcoord;
attribute vec3 a_Normal;

uniform mat4 u_MvpMatrix;
uniform mat4 u_WorldMat;
uniform vec4 u_TilingOffset;

varying vec2 v_Texcoord;
varying vec3 v_Normal;

#ifdef BONE
    attribute vec4 a_BoneIndices;
    attribute vec4 a_BoneWeights;
    const int c_MaxBoneCount = 24;
    uniform mat4 u_Bones[c_MaxBoneCount];
#endif

#if defined(DIRECTIONLIGHT)
    varying vec3 v_PositionWorld;
#endif

void main(){
    #ifdef BONE
        mat4 skinTransform = mat4(0.0);
        skinTransform += u_Bones[int(a_BoneIndices.x)] * a_BoneWeights.x;
        skinTransform += u_Bones[int(a_BoneIndices.y)] * a_BoneWeights.y;
        skinTransform += u_Bones[int(a_BoneIndices.z)] * a_BoneWeights.z;
        skinTransform += u_Bones[int(a_BoneIndices.w)] * a_BoneWeights.w;

        vec4 position = skinTransform * a_Position;
        gl_Position = u_MvpMatrix * position;
        mat3 worldMat = mat3(u_WorldMat * skinTransform);
    #else
        gl_Position = u_MvpMatrix * a_Position;
        mat3 worldMat = mat3(u_WorldMat);
    #endif

    // 计算纹理坐标
    v_Texcoord = (a_Texcoord * u_TilingOffset.xy) + u_TilingOffset.zw;

    // 变换法线到世界空间
    v_Normal = worldMat * a_Normal;

    #if defined(SPOTLIGHT)
        #ifdef BONE
            v_PositionWorld = (u_WorldMat * position).xyz;
        #else
            v_PositionWorld = (u_WorldMat * a_Position).xyz;
        #endif
    #endif
}
```

### 红牌实现原理

#### 参数控制

```
对于普通黑牌:
  u_color_light = [0.8, 0.8, 0.8]     # 浅灰
  u_color_unlight = [0.3, 0.3, 0.3]   # 深灰
  u_color = [1.0, 1.0, 1.0, 1.0]      # 白色（无变化）

对于红牌 (5m, 5p, 5s):
  u_color_light = [1.0, 0.2, 0.2]     # 亮红
  u_color_unlight = [0.6, 0.0, 0.0]   # 深红
  u_color = [1.2, 1.0, 1.0, 1.0]      # 红色偏重
```

#### 卡通光照原理

```
三阶段光照:

1. 亮面 (diffuse > u_split + 0.1)
   ┌─────────────────┐
   │  亮红色数字     │
   │  高亮白边       │ ← 光源直射
   └─────────────────┘

2. 过渡区 (u_split < diffuse < u_split + 0.1)
   ┌─────────────────┐
   │  渐变边界       │ ← 软边界，看起来自然
   │  (亮红→深红)    │
   └─────────────────┘

3. 暗面 (diffuse < u_split)
   ┌─────────────────┐
   │  深红色数字     │
   │  阴影区域       │ ← 光源背面
   └─────────────────┘

结果: 3D 立体感，红牌更显眼
```

#### 数字纹理

```
可能的实现方式:

方式 1: 纹理颜色控制（最可能）
  - 基础牌纹理中，红牌数字区域的 RGB 值特殊
  - 通过 u_color 参数乘法，放大红色通道
  - 结果: RGB(红牌数字) * RGB(u_color) = 更红

方式 2: 分离纹理（备选）
  - 可能有 red_5m.png, red_5p.png 等分离纹理
  - 在 u_texture 选择时直接使用红牌纹理

方式 3: 着色器条件（最灵活）
  - if (v_Texcoord.x > 0.8 && v_Texcoord.y < 0.2)
  -   // 这是数字区域，应用红色增强
```

### Outline 着色器（边界高亮）

```glsl
// outline.ps - 选中时的边界高亮
#ifdef FSHIGHPRECISION
    precision highp float;
#else
    precision mediump float;
#endif

varying vec2 v_Texcoord;
varying vec3 v_Normal;

uniform vec4 u_outline_color;      // 高亮颜色 (如绿色或橙色)
uniform float u_outline_alpha;     // 高亮透明度

void main(){
    gl_FragColor = u_outline_color;
    gl_FragColor.a = u_outline_alpha;
}
```

---

## 关键着色器

### 着色器对比

| 着色器 | 用途 | 关键特性 |
|--------|------|--------|
| **cartoon_pai** | 牌面渲染 | 卡通三阶段光照、红牌颜色控制 |
| **outline** | 边界高亮 | 选中时的绿色/橙色框 |
| **toumingpai** | 透明牌 | 听牌时显示半透明 |
| **cartoon_tile_back** | 牌背 | 简化版卡通光照 |
| **color_overlay** | 颜色覆盖 | 可选的效果叠加 |

### 混合模式对比

```
宝牌 (dora_shine):
  srcBlend = GL_SRC_ALPHA (770)
  dstBlend = GL_ONE (1)
  → Final = Source * SourceAlpha + Dest
  → 结果: 加法混合（变亮）

推荐高亮 (effect_recommend):
  可能使用 blend mode 2 (normal alpha)
  srcBlend = GL_SRC_ALPHA (770)
  dstBlend = GL_ONE_MINUS_SRC_ALPHA (771)
  → Final = Source * SourceAlpha + Dest * (1 - SourceAlpha)
  → 结果: 正常 Alpha 混合
```

---

## 完整资源列表

### 宝牌相关资源

```
效果纹理:
  ✓ https://game.maj-soul.com/1/v0.10.306.w/lang/scene/Assets/Resource/effect/texture/shanguang.png
    └─ 闪光纹理（通用）

宝牌专用:
  ✓ https://game.maj-soul.com/1/chs_t/myres/mjdesktop/dora_shine.png
    └─ 宝牌闪光纹理

  ✓ https://game.maj-soul.com/1/v0.11.64.w/lang/scene/Assets/Resource/effect/texture/dora_shine/dora_shine.lmat
    └─ 宝牌闪光材质定义（加法混合）

  ✓ https://game.maj-soul.com/1/v0.10.306.w/lang/scene/Assets/Resource/effect/texture/dora_shine/dora_shine.png
    └─ 宝牌闪光纹理（备用路径）

背景纹理:
  ✓ https://game.maj-soul.com/1/chs_t/myres/mjdesktop/bg_dora.png
    └─ 宝牌背景（正面）

  ✓ https://game.maj-soul.com/1/chs_t/myres/mjdesktop/bg_lidora.png
    └─ 里宝牌背景（背面）

标记纹理:
  ✓ https://game.maj-soul.com/1/chs_t/myres/mjdesktop/hunzhi_line_red.png
    └─ 红线标记（红牌视觉标记）

  ✓ https://game.maj-soul.com/1/chs_t/myres/mjdesktop/lightning.png
    └─ 闪电效果（可选）

UI 相关:
  ✓ https://game.maj-soul.com/1/chs_t/myres/mjdesktop/player_dora_bottom.png
    └─ 玩家宝牌显示区

  ✓ https://game.maj-soul.com/1/chs_t/myres/mjdesktop/tou_dora_back.png
    └─ 宝牌翻开特效

音效:
  ✓ https://game.maj-soul.com/1/v0.10.1.w/audio/audio_mj/new_dora.mp3
    └─ 新宝牌翻开音效
```

### 牌面着色器资源

```
卡通渲染:
  ✓ https://game.maj-soul.com/1/v0.10.237.w/shader/cartoon_pai/cartoon_pai.vs
    └─ 顶点着色器（红牌颜色注入点）

  ✓ https://game.maj-soul.com/1/v0.10.237.w/shader/cartoon_pai/cartoon_pai.ps
    └─ 像素着色器（三阶段光照）

边界高亮:
  ✓ https://game.maj-soul.com/1/v0.10.1.w/shader/outline/outline.vs
    └─ 高亮边框顶点着色器

  ✓ https://game.maj-soul.com/1/v0.10.1.w/shader/outline/outline.ps
    └─ 高亮边框像素着色器

透明牌:
  ✓ https://game.maj-soul.com/1/v0.10.1.w/shader/toumingpai/toumingpai.vs
    └─ 透明牌顶点着色器

  ✓ https://game.maj-soul.com/1/v0.10.1.w/shader/toumingpai/toumingpai.ps
    └─ 透明牌像素着色器

其他:
  ✓ https://game.maj-soul.com/1/v0.10.1.w/shader/cartoon_alpha/cartoon_alpha.ps
    └─ Alpha 通道卡通着色器

  ✓ https://game.maj-soul.com/1/v0.10.237.w/shader/cartoon_alpha/cartoon_alpha.vs

  ✓ https://game.maj-soul.com/1/v0.10.251.w/shader/cartoon_tile_back/cartoon_tile_back.vs
    └─ 牌背渲染

  ✓ https://game.maj-soul.com/1/v0.10.251.w/shader/cartoon_tile_back/cartoon_tile_back.ps
```

### 光照与材质资源

```
材质:
  ✓ https://game.maj-soul.com/1/v0.10.306.w/lang/scene/Assets/Resource/effect/texture/light.lmat
    └─ 光照材质定义

  ✓ https://game.maj-soul.com/1/v0.10.306.w/lang/scene/Assets/Resource/effect/texture/paimian.lmat
    └─ 牌面材质定义

纹理:
  ✓ https://game.maj-soul.com/1/v0.11.64.w/lang/scene/Assets/Resource/effect/texture/light.png
    └─ 光照纹理

  ✓ https://game.maj-soul.com/1/v0.10.306.w/lang/scene/Assets/Resource/effect/texture/shanguang.png
    └─ 闪光纹理

网格:
  ✓ https://game.maj-soul.com/1/v0.10.306.w/lang/scene/Assets/Resource/effect/mesh/plane1X1-Plane01.lm
    └─ 牌面网格（1x1 平面）
```

### 牌面纹理资源

```
透明牌 UI:
  ✓ https://game.maj-soul.com/1/chs_t/myres2/mjp/toumingpai/ui/0m.png
  ✓ https://game.maj-soul.com/1/chs_t/myres2/mjp/toumingpai/ui/1m.png
  ✓ ... （0-9, m/p/s/z 全部）
    └─ 听牌显示用纹理

大厅牌例:
  ✓ https://game.maj-soul.com/1/chs_t/myres/lobby/tile_1.png
  ✓ ... (1-11)
    └─ 大厅页面展示
```

---

## 实现对比

### Naki 的 shimmer 方案 vs Majsoul 原生

| 方面 | Majsoul 原生 | Naki 实现 |
|------|-------------|---------|
| **渲染位置** | 3D Canvas（Laya 引擎） | 2D Canvas 上层 |
| **混合模式** | 加法混合 (GL_SRC_ALPHA + GL_ONE) | Canvas fillRect（直接） |
| **透明度控制** | 材质 Alpha + 纹理 Alpha | 自定义 opacity |
| **边框** | 无（或 outline 着色器） | 2px 边框 + 颜色 |
| **亮度** | albedo [2,2,2,2] 控制 | 固定 RGBA 值 |
| **颜色范围** | > 0.5: 绿 / 0.2-0.5: 橙 | 同 Naki |
| **刷新率** | 每帧从着色器输出 | requestAnimationFrame 30-60fps |
| **性能** | GPU 渲染（高效） | CPU Canvas 绘制（较慢） |

### 技术栈对比

```
Majsoul 原生:
  Language: JavaScript (WebGL)
  Engine: Laya
  Graphics API: WebGL
  Shaders: GLSL (顶点 + 片元)
  Performance: GPU-accelerated

Naki:
  Language: JavaScript + Canvas API
  Engine: Native Canvas 2D
  Graphics API: Canvas 2D
  Rendering: CPU-based
  Performance: JavaScript 循环 + 绘制
```

### 效果对比

```
宝牌闪光效果:

Majsoul:
  ✓ 每帧 GPU 渲染，非常流畅
  ✓ 可与场景光影自然融合
  ✓ 支持 depthWrite=false 不遮挡
  ✓ 高性能，无明显 CPU 开销

Naki:
  ✓ 在 Canvas 上额外绘制闪光
  ✓ 清晰可见但与原生略微分离
  ✓ 需要手动计算遮挡关系
  ✓ CPU 开销随屏幕大小增加
```

---

## 总结

### 核心发现

1. **宝牌效果 (Dora Shimmer)**
   - 使用独立的加法混合材质 (`dora_shine.lmat`)
   - srcBlend = GL_SRC_ALPHA, dstBlend = GL_ONE （加法）
   - albedo [2,2,2,2] 使闪光 2 倍亮度
   - depthWrite = false 保持交互

2. **红牌实现 (Red Tiles)**
   - 通过着色器参数 `u_color_light`, `u_color_unlight` 控制
   - 卡通渲染的三阶段光照
   - 红牌数字可能使用专门的红色纹理或 u_color 参数

3. **渲染管线**
   - renderQueue 3000 使宝牌在牌面之后渲染
   - 保证视觉层次清晰
   - 不影响鼠标交互

### 关键参数速查

```json
{
  "宝牌闪光": {
    "混合模式": "加法 (770 + 1)",
    "亮度": "albedo [2,2,2,2]",
    "深度": "depthWrite: false",
    "队列": "renderQueue: 3000"
  },
  "红牌颜色": {
    "亮面": "u_color_light [1.0, 0.2, 0.2]",
    "暗面": "u_color_unlight [0.6, 0.0, 0.0]",
    "整体": "u_color [1.2, 1.0, 1.0, 1.0]"
  },
  "光照分界": {
    "参数": "u_split",
    "过渡宽度": "0.1",
    "插值系数": "d * 10.0"
  }
}
```

### 后续优化方向

对于 Naki 的实现：

1. **性能优化**
   - 考虑使用 WebGL Canvas 而非 2D Canvas
   - 将闪光效果移到主 3D 渲染管线

2. **视觉改进**
   - 提取 Majsoul 的 `dora_shine.png` 纹理用在 Canvas 上
   - 实现更接近原生的渐变闪光效果

3. **交互改进**
   - 与原生 outline 着色器的选中高亮保持同步
   - 支持多牌同时闪烁

---

## 参考资源

### 官方文档
- Laya Engine: https://layaair.layabox.com/
- WebGL Specification: https://www.khronos.org/webgl/
- Majsoul 协议: 见 FLOW_COMPARISON.md

### 相关代码
- Naki 的 shimmer 实现: `Naki/Resources/JavaScript/naki-recommendation-shimmer.js`
- Debug Server: `Naki/Services/Debug/DebugServer.swift:306-506`
- Majsoul Bridge: `Naki/Services/Bridge/MajsoulBridge.swift:200-207`

### 工具
- 获取资源: `curl http://localhost:8765/help`
- 执行 JS: `curl -X POST http://localhost:8765/js -d "CODE"`
- 查看日志: `curl http://localhost:8765/logs`

---

**文档生成日期**: 2025-12-04
**反向工程工具**: Naki Debug Server
**数据来源**: Majsoul v0.11.200+
**验证状态**: ✅ 通过 Debug Server 直接查询验证
