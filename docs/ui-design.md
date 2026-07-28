# Plana App · UI 设计方案

> v1 目标:**NovelAI 直连客户端** —— token 登录、原生直调 NAI API 生图、本地图库。不依赖 Plana 后端(v2 再接入)。
> 本文档是 UI 的唯一事实来源,**改设计 = 改本文档**。
> 创建于 2026-07-05。

---

## 1. 设计原则

1. **M3 骨架,NAI 的脸**:组件形态、交互规范、无障碍全部沿用 Material 3;色彩人格完全复刻 web 端 NAI 主题(藏青 + 淡金)。
2. **暗色唯一**:v1 只做暗色主题(看图应用,且 NAI 品牌即暗色)。亮色主题无限期不做。
3. **渐进披露**:创作主屏只放高频决策(提示词/角色/模型/比例/生成);低频参数一律收进 bottom sheet。
4. **金色 = 唯一 CTA 色**:淡金(`#fceda4`)只用于"生成"类主行动和 Anlas 数字;其余交互高亮一律用紫(`#6a6afb`)。一屏至多一个金色按钮。
5. **功能对齐 ≠ 布局对齐**:对齐桌面 web 的是能力清单,布局按移动端重新设计。

## 2. 色彩 Token(源:web 端 tailwind.config.js)

| Token | 值 | M3 角色映射 | 用途 |
|---|---|---|---|
| `bg` | `#0b0f19` | surface | 页面底 |
| `panel` | `#121624` | surfaceContainer | 卡片/导航栏 |
| `input` | `#1c2030` | surfaceContainerHigh | 输入框/chips 底 |
| `panelHigh` | `#232840` | surfaceContainerHighest | 选中态底/徽章底/边框 |
| `accent` | `#fceda4` | primary | 生成按钮/Anlas/激活图标 |
| `accentHover` | `#ebd576` | — | 金按钮按压态/嵌套徽章 |
| `onAccent` | `#3a3000` | onPrimary | 金底上的字(自定,web 端无) |
| `purple` | `#6a6afb` | secondary | 开关/选中 chip/链接/角色序号 |
| `green` | `#95e5a5` | tertiary | 成功态/“免费”徽章 |
| `text` | `#ffffff` | onSurface | 主文本 |
| `textDim` | `#8a8d98` | onSurfaceVariant | 次级文本/标签 |
| `textFaint` | `#565a68` | outline | 占位符/说明文字(自定) |
| `dark` | `#06080e` | — | 全屏查看器底 |
| error | M3 暗色默认 `#F2B8B5` | error | 表单错误/失败态 |

Flutter 实现:手写 `ColorScheme`(不用 `fromSeed`,品牌色要精确),文件 `lib/core/theme/`。

## 3. 排版 / 形状

- 字体:系统默认(中文走系统,后续可选配 MiSans);字号遵 M3 五档,正文 14、标签 11-12。
- 圆角:卡片 12、输入框 10、chips 8、主按钮全药丸、bottom sheet 顶部 20。
- 触控目标 ≥ 44dp;列表页底部留出手势条安全区。

## 4. 信息架构

```
登录页(无 token 时)
└─ 主框架(底部导航,3 tab)
   ├─ 创作
   │   ├─ 高级参数 bottom sheet(采样器/步数/CFG/seed/SMEA…)
   │   ├─ 角色编辑器 bottom sheet(每角色:提示词/负面/位置)
   │   ├─ 模型选择 sheet · 尺寸比例 sheet
   │   └─ 生成结果 → 全屏查看器
   ├─ 图库(本地历史)
   │   └─ 全屏查看器(共用)
   └─ 我的(账户/默认参数/token 管理/关于)
```

## 5. 屏幕规格

### 5.1 登录页
- 居中 logo + "Plana / NovelAI 移动创作端"。
- token 输入框(密文显示,右侧粘贴按钮)+ 金色"验证并登录"。
- 验证 = `GET /user/subscription`;成功后 token 写入 flutter_secure_storage,失败在框下方红字提示。
- 辅助链接"如何获取 token?"(说明弹层:NAI 官网 → Account Settings → Get Persistent API Token)。
- 隐私说明:token 仅存本机、只与 novelai.net 通信。

### 5.2 创作页(核心屏)
自上而下:
1. **标题栏**:「创作」+ Anlas 徽章(⚡ 金色数字,点击进「我的」)。
2. **提示词卡**:多行输入,自动增高(上限 ~6 行后内滚)。
3. **负面提示词**:默认折叠为一行,点击展开成同款卡。
4. **角色区**:标题「角色 · N」+ 右侧「AI 摆位」开关(紫)。
   - 角色卡横向排列:序号圆徽(紫)+ 位置徽章(如 `C3`,AI 摆位开启时隐藏)+ 提示词前两行摘要;尾部「+」虚线卡添加。
   - 点卡片 → **角色编辑器 sheet**:提示词、负面、5×5 位置网格选择器(与 NAI 网格坐标 A1-E5 对应)、删除按钮。上限 6 个角色(NAI v4 限制)。
5. **快捷参数行**(chips):模型、尺寸比例、步数、「更多」。
   - 模型 sheet:NAI 4.5 Full / 4.5 Curated / 4.0 Full / 4.0 Curated / v3(radio list)。
   - 尺寸 sheet:竖版 832×1216 / 横版 1216×832 / 方 1024×1024 + Large/Wallpaper 档(标注 Anlas 消耗)。
6. **生成按钮**(金,全宽):文案 = 「生成」+ 费用徽章(见 §6)。
   - 状态机:空闲 → 生成中(按钮变进度条 + 可取消)→ 完成(滚动到结果)/ 失败(按钮下红字 + 重试)。
7. **结果区**:生成完成后按钮下方出现结果卡(缩略图 + 复用参数/保存/全屏);历史结果向下堆叠,冷启动恢复最近一次。

### 5.3 高级参数 sheet
采样器(radio)、步数 slider(1-50)、CFG slider(0-10,步 0.1)、seed(输入框 + 随机骰子按钮)、SMEA/DYN 开关(仅 v3 显示)、cfg_rescale、noise_schedule。底部「恢复默认」。

### 5.4 全屏查看器
- 底色 `#06080e`,沉浸式;左右滑动切换同批次图。
- 底部操作条:保存到相册 / 复用参数(回填创作页)/ 收藏 / 删除 / 分享。
- 上滑或 info 按钮:参数面板(model/size/steps/cfg/seed/完整提示词,逐项可复制)。

### 5.5 图库
- 2 列瀑布流,按日期分组;筛选 chips:全部/今天/收藏。
- 数据源:App 私有目录的本地文件 + sqlite 索引(参数元数据);NAI 返回的 PNG 自带元数据,另存相册时保留。
- 长按多选 → 批量删除/保存。

### 5.6 我的
- 账户卡:订阅等级徽章(Opus/Scroll/Tablet)+ Anlas 余额 + 刷新。
- 默认参数(新任务的初始值)、token 管理(更换/退出登录=清 secure storage)、关于/版本。

## 6. Anlas 费用显示规则

- Opus 订阅 + 尺寸 ≤ 1024×1024 + 步数 ≤ 28 + 单张 → 徽章「Opus 免费」(绿字)。
- 其余情况 → 徽章「≈ N Anlas」(金字);N 按 NAI 定价公式本地估算,生成后以 `/user/subscription` 刷新真实余额。
- 余额不足以生成当前配置时,生成按钮变禁用灰 + 提示。

## 7. 路线图

| 版本 | 内容 |
|---|---|
| **v1** | 本文档全部内容:token 登录、文生图(含 v4 多角色)、本地图库、我的 |
| v1.5 | vibe transfer、img2img、超分、更多尺寸档、提示词预设/词库 |
| v2 | 接入 Plana 后端:Bot 账号登录、画师串/OC/CR 库、图像工坊、点数账单 |

## 8. 视觉参考

- 高保真 mockup:登录/创作/图库三屏(设计阶段产物,未入库)。
- 配色沿用 web 端的 NAI 主题(该项目不在本仓库内)。
- 组件行为规范:m3.material.io。
