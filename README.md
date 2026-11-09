# iOS 移植 · 第一步：数值探针（POC）

这个工程**不是**完整 App，它只做一件事：

> 在 iPhone 上跑一次 DINOv2-small，看输出的 384 维向量与 PC/安卓是否一致。

**为什么先做这个**：iOS 上整条链路要重写（OpenCV 只有 C++、ORT 是另一套 API）。
在投入 3–5 周之前，先用 2 天确认「模型在 iOS 上算出来的数是对的」。
如果这一步过不了，后面全是白干。

## 判定标准（App 里会直接算给你看）

| 余弦 | 结论 |
| --- | --- |
| **≥ 0.999** | ✅ 数值可信，可以继续移植核心算法 |
| 0.99 – 0.999 | ⚠️ 多为预处理差异（resize/归一化），可修 |
| < 0.99 | ❌ 先确认模型文件和输入张量就是 PC 导出的那份 |

参考数据 `Resources/probe_input.bin` 和 `probe_expected.txt` 是在 PC 上
用 **ONNX Runtime 1.16.3 + 与安卓完全相同的预处理** 生成的，所以它是一个严格基准。

---

## 一、你要准备的东西（全免费）

| 东西 | 用途 | 备注 |
| --- | --- | --- |
| **Apple ID** | 给 App 签名 | 你已有 |
| **iTunes**（官网版） | Sideloadly / AltServer 需要它的设备驱动 | **不要装 Microsoft Store 版** |
| **Sideloadly** | 把 IPA 签进 iPhone | https://sideloadly.io |
| **AltServer**（可选） | 自动续期（7 天一次） | https://altstore.io |
| **GitHub 账号** | 用免费的 macOS 机器编译 | 下面第一节教注册 |
| **GitHub Desktop**（推荐） | 图形化上传，能传 45MB 的模型文件 | https://desktop.github.com |

---

## 二、注册 GitHub（约 3 分钟）

1. 打开 https://github.com/signup
2. 依次填：邮箱 → 密码 → 用户名（英文，如 `night-xiuxun`）→ 完成人机验证
3. 去邮箱点验证链接
4. 登录后右上角头像 → **Settings → Password and authentication → Enable two-factor authentication**（GitHub 现在强制要求，按提示用手机 App 或短信开通）
5. 右上角 `+` → **New repository**
   - Repository name: `xiuxun-ios`
   - 选 **Private**
   - 勾 **Add a README file**（随便有内容即可）
   - Create

---

## 三、把工程推上去（用 GitHub Desktop，最省事）

1. 安装并登录 GitHub Desktop
2. 本目录（`D:\AI搜图IOS版开发\04-iOS移植`）已经是初始化好的 git 仓库，不用解压、不用复制
   - 目录结构应该是：
     ```
     D:\AI搜图IOS版开发\04-iOS移植\
     ├── .github\workflows\ios-poc.yml
     └── POC\
         ├── project.yml
         ├── Podfile
         ├── Info.plist
         ├── Sources\*.swift
         └── Resources\
             ├── probe_input.bin
             ├── probe_expected.txt
             ├── probe_meta.txt
             ├── probe_image.jpg
             └── dinov2-small-fp16.onnx    ← 45MB，必须放这里
     ```
3. GitHub Desktop → **File → Add local repository** → 选 `D:\xiuxun-ios`
   （如果提示 "not a git repository"，选 **create a repository** 在这里）
4. 左下角填提交信息（随便写 `poc`）→ **Commit to main** → **Publish repository**
   - **务必取消勾选 "Keep this code private"**？→ 不，**保持勾选 Private**（代码私有）
5. 推送完成后，打开 `https://github.com/你的用户名/xiuxun-ios/actions`
   → 应该能看到一个叫 **Build iOS POC** 的流程在跑（或点 **Run workflow** 手动触发）

> 私有仓库的 macOS 编译额度：每月约 200 分钟，够跑 20–40 次。

---

## 四、下载编译好的 IPA

1. 等 Actions 变绿（约 8–15 分钟；第一次装依赖会久一点）
2. 点进这次运行 → 页面底部 **Artifacts** → 下载 **XiuxunPOC-unsigned-ipa**
3. 解压得到 `XiuxunPOC-unsigned.ipa`（未签名）

> 如果 Actions 失败：点开失败的步骤，把红色日志整段复制发我。
> 这套工程我是**盲写**的（手上没有 Mac，无法本地编译验证），第一次基本会有 1–2 处要改。

---

## 五、用 Sideloadly 装进 iPhone

1. iPhone 用数据线连电脑，解锁并点「信任此电脑」
2. 打开 Sideloadly
3. **IPA** 拖入 `XiuxunPOC-unsigned.ipa`
4. **Apple ID** 填你的 Apple ID（Sideloadly 是本地签名，密码只用于生成证书，走 Apple 官方接口）
5. 点 **Start**，等它提示成功
6. iPhone 上：**设置 → 通用 → VPN与设备管理 → 开发者App → 信任**
   - iOS 17+ 还要：**设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机**
7. 桌面上会出现「绣寻探针」，打开它

**有效期 7 天**，到期用 Sideloadly 重签一次即可（数据会保留在同一 App 上）。
想自动续：装 AltServer，让它在后台跑，同一 Wi-Fi 下会自动续签。

---

## 六、跑一次，把结果发我

1. 打开 App → 点 **开始验证**
2. 等 3–10 秒
3. 截图（或把下面三行文字发我）：
   ```
   余弦：xxxx
   最大单项差：xxxx
   耗时：xxxx ms
   ```

---

## 七、常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| Actions 报 `pod install` 失败 | CocoaPods 源或版本问题 | 把日志发我，我换成 SPM 方案 |
| Actions 报 `xcodegen` 找不到 | brew 步骤失败 | 日志发我 |
| Sideloadly 报 `Unable to connect` | 没装官网版 iTunes / 没信任电脑 | 重装 iTunes（官网版），重新插拔 |
| iPhone 打不开 App（闪退） | 未信任开发者 / 未开开发者模式 | 见第五节第 6 步 |
| App 提示「缺 dinov2-small-fp16.onnx」 | 模型没提交进仓库 | 检查 `POC/Resources/` 里有没有这个文件（45MB） |
| 余弦 0.99 左右 | 可能是 ORT 版本差异 | 再跑一次，仍这样就告我，我改探针（换 EP / 换版本） |

---

## 八、这一步通过之后

我会按下面顺序继续（每步都能独立验证）：

1. **预处理对齐**：把 PC 的 Pillow 重采样在 iOS 上复刻，验证 `probe_image.jpg` → `probe_input.bin` 完全一致
2. **核心算法移植**：`makeCanonical`、全局描述子、SIFT、RANSAC、dense/tiles、搜索主流程
3. **特征对齐**：用真实图库里的款，比对我们算出的特征与 `recall.bin` 里的余弦
4. **界面**：搜索页、框选、两列结果、保存/分享
5. **图库导入**：直接读 PC 导出的同一个图库包（不需要重新生成）
6. **签名分发**：TestFlight（$99/年）或继续 7 天自签

⚠️ 明确不做（按你的要求）：授权码、局域网共享。
