# 短剧盒子 iOS

红果短剧的非官方第三方 iOS 客户端。列表、搜索、选集、播放，1080p 自动解密，源站编码 iOS 播不了的会在本机转码后播放。

> 仅供自用与学习交流，请勿公开分发。剧集内容的版权归原站所有。

## 安装

没有上架 App Store，用**免费 Apple ID** 自己签名安装就行 —— 不需要开发者账号、不需要越狱。

两种方式任选一种，装的是同一个 App，数据互通：

- **方式一：Sideloadly** —— 需要电脑，7 天到期后重签，最简单。
- **方式二：iloader + SideStore** —— 首次需要电脑，之后在手机上续签；配合本仓库的源还能直接收到新版本更新。

### 方式一：Sideloadly（需电脑，7 天续期）

**需要准备**：

- iPhone 或 iPad，系统 **iOS 17 或更高**
- 一台 Mac 或 Windows 电脑
- [Sideloadly](https://sideloadly.io/)（免费侧载工具）
- 一个 Apple ID，免费账号即可

#### 1. 下载 IPA

打开 [Releases](https://github.com/gengbo1999/hongguo-box/releases/latest)，下载 `ShortDramaBox-unsigned.ipa`（约 1 MB）。

#### 2. 用 Sideloadly 安装

1. 电脑上装好 Sideloadly。macOS 用 dmg；**Windows 需要先装好 iTunes**（微软商店版或官网版都行，用来提供苹果设备驱动）
2. 数据线连上 iPhone，手机上如果弹出「要信任此电脑吗」，点**信任**
3. 把下载好的 IPA 拖进 Sideloadly 窗口
4. 在 `Apple ID` 那一栏填你的 Apple ID（只用它在本机做签名，密码不会存到别处）
5. 点 `Start`。过程中会要求输入 Apple ID 密码；如果账号开了双重验证，还要在弹窗里填一次收到的验证码
6. 等进度条走完，手机上出现「短剧盒子」图标就是装好了

#### 3. 信任证书

不信任的话，点开应用会提示「未受信任的开发者」，打不开。

手机「**设置 → 通用 → VPN 与设备管理 → 开发者应用**」，找到你的 Apple ID，点「信任」。

#### 4. 打开开发者模式（iOS 16 及以上必须）

手机「**设置 → 隐私与安全性 → 开发者模式**」，打开开关，手机会重启一次。首次打开应用时若弹出「启用开发者模式」，按提示确认并重启即可。

#### 5. 关于 7 天有效期

免费 Apple ID 签出来的应用 **7 天后失效**：图标还在，点开就闪退。到期前重跑一次上面的第 2 步即可，
**直接覆盖安装，观看记录不会丢**。想免去这个麻烦就只能用付费开发者账号（99 美元/年）签名。

> 其它侧载工具（AltStore、Xcode 直接运行等）也能装这个 IPA，流程大同小异，按上面第 3、4 步处理信任和开发者模式即可。

### 方式二：iloader + SideStore（手机端自动续签 + 源内更新）

原理：先用电脑上的 [iloader](https://iloader.app) 把 [SideStore](https://sidestore.io) 签好、装到手机上；之后由 SideStore 在手机端用同一个 Apple ID 续签，不再需要电脑。SideStore 还能订阅本仓库的源，直接提示新版本。

**准备**：

- iOS 17 或更高
- 一台 Mac 或 Windows 电脑，装 [iloader](https://iloader.app)
- iPhone 上装 [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)（App Store 免费；SideStore 续签/安装要走它建的本机隧道）
- 一个 Apple ID（免费号即可；**建议用小号**，不要用主账号）

**步骤**：

1. **电脑装 SideStore**：USB 连上 iPhone，手机上点「信任」。打开 iloader，登录 Apple ID，选中设备，安装 SideStore。
   - 如果 iloader 提供 Stable / Nightly 选择，优先选 **Nightly（0.7.0）**：2026 年 11 月 Apple 改了服务端，0.6.4 及更早版本会卡在登录 503。
2. **手机信任 + 开发者模式**：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID；设置 → 隐私与安全性 → 开发者模式 → 打开并重启（和方式一第 3、4 步一样）。
3. **手机端登录**：打开 LocalDevVPN 并连接；打开 SideStore，用同一个 Apple ID 登录；在 My Apps 里点 SideStore 自己的「7 DAYS」刷新一次（iloader 装的 SideStore 用的是 iloader 的 App Group，刷一次才会切到 SideStore 自己的）。
   - 登录报 `503` / `-22410`：到 Settings → User Customizations 关掉 On-Device Anisette Servers，换一个 Anisette 服务器再试。这是 Apple 服务端改动导致的，不是账号问题。
4. **添加本仓库的源**：SideStore → Sources → 右上角「+」→ 粘贴：

   ```
   https://fastly.jsdelivr.net/gh/gengbo1999/hongguo-box@main/docs/sidestore.json
   ```

   国内网络优先用上面的 `fastly.jsdelivr.net` 节点；如果它也打不开，把域名换成 `cdn.jsdelivr.net` 再试。

   然后在 Sources 里打开「短剧盒子」→ Get / 安装。
   - 不想用源也可以：把 `ShortDramaBox-unsigned.ipa` 存到「文件」，SideStore → My Apps →「+」选这个 IPA。
5. **续签与更新**：
   - 续签：保持 LocalDevVPN + Wi-Fi 连接，iOS 设置里给 SideStore 开「后台 App 刷新」，关低电量模式，SideStore 会在后台自动续，7 天证书一般不会断。iOS 的后台调度不保证准时，最稳是每周打开一次 SideStore 点「Refresh All」。
   - 更新：每次发版 CI 会自动更新源里的版本号，SideStore 里会显示 Update，点更新即可，数据保留。
   - iOS 同时只能开一个 VPN：LocalDevVPN 和你平时用的代理（Shadowrocket 等）互斥，续签/装 App 时切到 LocalDevVPN，平时可以切回代理。
   - 免费账号最多 3 个自签 App（含 SideStore 自身），装本 App 后还剩 1 个名额。

## 功能

五个标签页：

- **推荐** —— 只放**新剧**和**爆剧**，比例 **7 : 3**；上下滑动换一部，点画面继续观看，每张卡片左上角的标签会写明是哪一类
- **首页** —— 站内首页的各频道区块，每个区块 9 条，右侧「查看更多」进频道分页
- **分类** —— 顶部是最热的 16 个标签，其余收在「查看更多」里（可搜索）；点进去的内容**按上架时间倒序，最新的在最前面**
- **搜索** —— 服务端全库（约 59 万部，按片名包含匹配，冷门老剧也搜得到）；首屏会顺带查一次站内搜索，把新剧补进全库，站方超时或改版时退回纯全库结果
- **记录** —— 「观看记录 / 我的关注」两个页签：观看历史记到「看到第几集第几秒」，点一下接着看；关注的剧按季合并，更新新季会在页签上提示

播放器：

- 一部剧有多季时，**本季最后一集播完自动接下一季第一集**
- 点画面暂停 / 继续，**长按住 2 倍速**，松手回到原来的倍速
- **进度条默认隐藏**（不挡画面）：点视频下方区域才露出，3 秒后自动收起；拖动中不收
- 倍速档位 0.5x / 0.75x / 1x / 1.25x / 1.5x / 2x / 3x
- 只保留 **1080p**：没有 1080p 的剧直接提示，不静默降级；1080p 编码 iOS 不支持时走**本机转码**
- 播放框按片源真实比例自适应，横屏片源（实测约占 58%）不会被裁

关于「本机转码」：有些 1080p 档位用 bytevc2 等编码，iOS 没有对应解码器。这种会自动在本机转成 H.264 播放，
首次进入会慢几秒，之后有缓存。播放页会标出当前是「本机转码」还是「明文源」。

## 版本号与发布规则

- Release 的 tag 形如 `v1.0.N`，每次发布 N 加一；`CFBundleShortVersionString` 就是 `1.0.N`
- **每次发布只保留最新的一个 Release 和 tag**，历史的会自动删掉
- 应用内「首页 → 右上角 ⓘ → 检查更新」会比对这里的最新版本号
- 发版后 CI 会同步把 `docs/sidestore.json` 的版本号更新到最新，SideStore 源据此提示更新

## 常见问题

**装了但打不开 / 点开闪退**
九成是这两件事没做：没在第 3 步信任证书，或者没在第 4 步打开开发者模式。也可能只是 7 天到期了，重跑一次 Sideloadly 覆盖安装即可。

**提示「无法安装此 App」**
换一根数据线或换一个 USB 口；Windows 上确认 iTunes 已正确安装；或者先重启手机再试。

**一直停在「正在解析…」**
换一部试试。个别老剧的公开备用源可能已经失效，属于源站那边的问题。也可以先确认网络是否正常。

**搜索很慢 / 第一次进搜索页卡一下**
搜索打的是你自建服务端的全库（约 59 万部）。服务端连不上时页面会直接提示「服务端暂时连不上」，这时搜不出东西——检查手机网络，以及服务端是否还在跑（部署见 `server/README.md`）。

**「检查更新」显示暂时拿不到版本信息**
它是直接读 GitHub 的 Release 订阅源，网络不通或被拦时就会这样，不影响看剧。

**为什么不用 App Store**
这是非官方客户端，不可能上架；侧载是唯一的分发方式。

## 自己从源码构建

```bash
cd ShortDramaBox
brew install xcodegen          # 只用来生成 Xcode 工程
xcodegen generate
open ShortDramaBox.xcodeproj  # 选自己的设备，签名后直接运行
```

命令行出未签名 IPA：

```bash
cd ShortDramaBox
MARKETING_VERSION=1.0.0 ./make-ipa.sh    # 产物：ShortDramaBox-unsigned.ipa
```

仓库自带两个 GitHub Actions 工作流，按改动路径触发：

- `.github/workflows/build-ipa.yml`：只有 `ShortDramaBox/**`（App 代码、工程、测试）推到 `main` 时，才跑单元测试、打未签名 IPA、发布 Release，并清理历史 Release/tag；只改 `server/**` 或文档不会出包。
- `.github/workflows/build-image.yml`：只有 `server/hg/**`、`server/sign/**`、`server/resolver/**`、`server/Dockerfile`、`server/entrypoint.sh`、`server/k8s.yaml` 推到 `main` 时，才构建并部署服务端镜像；iOS 的 `v*` 标签不会误触发。

环境要求：macOS + Xcode 15.4 或更高；工程最低支持 iOS 17.0，设备族群仅 iPhone。
单元测试跑在 iOS 模拟器上，可以在 Xcode 里直接 `⌘U`。

## 目录结构

```
ShortDramaBox/
├── project.yml                  XcodeGen 工程定义
├── make-ipa.sh                  命令行打未签名 IPA
├── Sources/
│   ├── Core/                    接口、播放、解密、转码、目录层接口、关注/多季、版本检查
│   └── UI/                      五个标签页与播放器
└── Tests/                       单元测试
```

## 免责声明

- 本项目是非官方的第三方客户端，与红果短剧 / 字节跳动没有任何关系，也未获得其授权或认可
- 所有剧集内容、图片与接口均来自原站，版权归原权利人所有；本项目只做播放与整理
- 仅供个人学习、研究与自用，请勿公开分发、传播或用于任何商业用途
- 使用产生的一切后果由使用者自行承担，请遵守当地法律法规与原站服务条款

## 致谢

界面与逆向思路参考了 [hongguo-desktop-releases](https://github.com/waligoraamodio288-rgb/hongguo-desktop-releases)。
