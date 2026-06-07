# 常见问题 FAQ (v1.3)

> 用户高频问题和解答，可用于售后回复或自助查阅。

---

## 安装相关

### Q1: 为什么双击「开始安装.cmd」没有反应？
**A:** 可能原因和解决方法：
1. 先确认已经右键 ZIP →「全部解压缩」，不要在压缩包里直接双击
2. 如果中文文件名异常，改双击 `Start-Install.cmd`
3. Windows 安全提示可能被遮挡 → 看看任务栏有没有闪烁的图标
4. 如果弹出 "Windows 保护了你的电脑" → 点击「更多信息」→「仍要运行」
5. 如果还是不行 → 截图窗口内容发给技术支持；确认为权限问题时再尝试管理员运行

### Q2: 提示"无法加载文件...因为在此系统上禁止运行脚本"？
**A:** 不会出现这个问题。所有 .cmd 文件已经包含 `-ExecutionPolicy Bypass` 参数，会自动绕过执行策略限制。

### Q3: 安装 Node.js 失败？
**A:** 手动安装更可靠：
1. 访问 https://nodejs.org
2. 下载 LTS 版本（左侧绿色按钮）
3. 安装时全部默认选项即可
4. 安装完成后重新打开 PowerShell

### Q4: npm 安装 Claude Code 失败？
**A:** 常见原因和方案：
- 网络问题 → 尝试换个网络或开代理
- 权限问题 → 建议使用 nvm 管理 Node.js，或使用官方 Native Install 方式
- npm 版本过旧 → 运行 `npm install -g npm@latest`
- 脚本会优先尝试 Native Install，npm 只是备用方案

### Q5: 安装成功了但 claude 命令不存在？
**A:** PATH 没刷新。请关闭当前窗口，重新打开 PowerShell 或命令提示符即可。

### Q6: Native Install 和 npm 安装有什么区别？
**A:**
- Native Install：Claude 官方推荐的安装方式，脚本会优先使用
- npm fallback：如果 Native Install 不可用（网络问题等），自动切换到 npm 方式
- DeepSeek 官方集成文档中采用 npm 方式作为参考
- 两种方式功能相同，用户不需要关心具体用哪种

---

## API Key 相关

### Q7: 输入 API Key 为什么不显示？
**A:** 这是安全设计。输入的内容实际已经接收，只是不显示在屏幕上，防止旁人看到。直接粘贴后按回车即可。

### Q8: 我没有 DeepSeek API Key 怎么办？
**A:** 需要自己注册获取：
1. 访问 https://platform.deepseek.com
2. 手机号注册
3. 在 API Keys 页面创建 Key
4. 脚本会自动帮你打开这个页面

### Q9: API Key 安全吗？
**A:** 安全。Key 只保存在你电脑的 `C:\Users\你的用户名\.claude\settings.json` 中，不会发送给卖家或第三方。运行 API 测试时，Key 会发送到 DeepSeek 官方接口用于验证。

### Q10: 我可以不给卖家 API Key 吗？
**A:** **可以并且应该这样做。** Key 是你自己输入的，不会发给卖家。诊断报告中的 Key 已自动打码。也请不要主动把 Key 发给卖家。

### Q11: 我的 Key 会不会被卖家看到？
**A:** 不会。所有配置都在你本机完成。诊断报告中 Key 自动脱敏（如 `sk-abc****wxyz`）。请勿主动发送 Key。

---

## 使用相关

### Q12: API 测试失败是不是安装失败？
**A:** 不一定。API 测试可能因为以下原因失败：
- Key 不对（重新获取）
- 余额不足（充值）
- 网络问题（换网络/开代理）
- DeepSeek 服务异常（等官方修复）

Claude Code 本身可能已安装成功，配置也已写入。请先确认 Key 和余额，运行「一键诊断.cmd」获取详细信息。

### Q13: 没有 VS Code 能不能用？
**A:** **可以。** Claude Code CLI 是核心交付，可以在 PowerShell/CMD 中直接使用。VS Code 是可选增强项，不是必需的。

### Q14: Windows 和 WSL 有什么区别？
**A:**
- Windows 原生：默认推荐方式，Claude Code 直接在 Windows 中运行
- WSL：Windows 中的 Linux 子系统，适合需要 Linux 环境的开发者
- 本工具默认配置 Windows 环境，WSL 是高级选项
- 普通用户不需要关心 WSL

### Q15: 为什么不是 Claude 官方模型？
**A:** 本工具配置的是 **DeepSeek API 兼容接入**方案。你将使用 DeepSeek 的模型，但通过 Claude Code 的交互界面。

### Q16: 和直接用 Claude 有什么区别？
**A:** 
- 相同：都可以在终端/VS Code 中 AI 编程
- 不同：底层模型是 DeepSeek 而非 Anthropic Claude
- 费用：DeepSeek 价格不同，请查看 DeepSeek 官方定价
- 功能：部分能力以 DeepSeek 官方兼容情况为准

### Q17: 为什么不能发图片/文档给 AI？
**A:** 多模态功能取决于 DeepSeek 对 Claude 兼容接口的支持程度。请查阅 DeepSeek 官方文档了解最新情况。

### Q18: 用起来很慢怎么办？
**A:** 
1. 检查网络（延迟可能影响速度）
2. DeepSeek 服务端高峰期会慢
3. 查看 DeepSeek 官方状态页面

---

## 错误代码

### Q19: 401 Unauthorized？
**A:** API Key 错误。
- 检查是否完整复制了 Key
- Key 是否已过期/被删除
- 到 platform.deepseek.com 重新创建 Key

### Q20: 402 Payment Required？
**A:** DeepSeek 账户余额不足。
- 到 platform.deepseek.com 充值
- 充值后等待几分钟生效

### Q21: 429 Too Many Requests？
**A:** 请求太频繁，被限流了。等 3-5 分钟再试。

### Q22: 500/502/503 错误？
**A:** DeepSeek 官方服务端问题。
- **这不是你的问题，也不是卖家的问题**
- 等待官方修复（通常几分钟到几小时）

### Q23: 网络连接失败/超时？
**A:** 
1. 检查网络是否正常
2. 是否能访问 https://api.deepseek.com
3. 公司网络可能封锁了 → 试试手机热点
4. 是否需要代理/VPN

---

## 诊断和售后

### Q24: 如何生成诊断报告？
**A:** 双击「一键诊断.cmd」即可。最新报告保存在项目目录下，文件名为 `report.txt`；历史报告保存在 `reports/report-YYYYMMDD-HHMMSS.txt`。

### Q25: 如何恢复旧配置？
**A:** 双击「恢复或卸载配置.cmd」→ 选择从备份恢复。

### Q26: 能用多久？
**A:** 本服务是**一次性安装配置**。环境配好后可以一直使用。费用只产生在 DeepSeek API 调用端。Claude Code 工具本身的计费规则以 Anthropic 官方为准。

### Q27: Claude Code 更新了怎么办？
**A:** 重新双击「开始安装.cmd」，选择 [1] 懒人一键安装，脚本会检测已有版本并询问是否更新。

### Q28: 换了电脑怎么办？
**A:** 重新在新电脑上运行「开始安装.cmd」即可。需要重新配置 API Key。

### Q29: 如何确认安装成功了？
**A:** 安装完成后会显示完成状态，并生成安装报告。也可以双击「一键诊断.cmd」获取详细报告。

---

## WSL 相关

### Q30: WSL 是什么？我需要吗？
**A:** WSL = Windows Subsystem for Linux。**普通用户不需要。** 本工具默认配置 Windows 原生环境。WSL 是给需要 Linux 环境的高级用户的可选项。

### Q31: WSL 内安装失败？
**A:** 
1. 确保 WSL Ubuntu 已正确安装
2. 在 Ubuntu 终端中导航到脚本目录
3. 运行：`chmod +x install_wsl.sh && ./install_wsl.sh`
4. 也可以从「开始安装.cmd」→ 选择 [4] 配置 WSL
