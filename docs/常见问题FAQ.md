# 常见问题 FAQ

> 用户高频问题和解答，可用于售后回复或自助查阅。

---

## 安装相关

### Q1: 双击 install.ps1 没反应？
**A:** PowerShell 脚本不能双击运行。请：
1. 在项目文件夹中，按住 Shift + 右键空白处
2. 选择 "在此处打开 PowerShell 窗口"
3. 输入命令：`powershell -ExecutionPolicy Bypass -File .\install.ps1`

### Q2: 提示"无法加载文件...因为在此系统上禁止运行脚本"？
**A:** 这是 Windows 默认安全策略。已在命令中包含 `-ExecutionPolicy Bypass` 参数，请确保完整复制整条命令运行。

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

### Q5: 安装成功了但 claude 命令不存在？
**A:** PATH 没刷新。请关闭当前 PowerShell 窗口，重新打开即可。

### Q6: 什么是 PATH 刷新？
**A:** 当你安装新软件时，Windows 需要"记住"新命令在哪里。重启终端窗口可以让 Windows 重新加载这个列表。

---

## API Key 相关

### Q7: 我没有 DeepSeek API Key 怎么办？
**A:** 需要自己注册获取（免费）：
1. 访问 https://platform.deepseek.com
2. 手机号注册
3. 在 API Keys 页面创建 Key
4. 按 DeepSeek 平台当前页面提示完成创建

### Q8: API Key 安全吗？
**A:** 安全。Key 只保存在你电脑的 `C:\Users\你的用户名\.claude\settings.json` 中，不会发送给卖家或第三方。运行 API 测试时，Key 会发送到 DeepSeek 官方接口用于验证。

### Q9: 输入 Key 时为什么不显示？
**A:** 这是安全设计。输入的内容实际已经接收，只是不显示在屏幕上，防止旁人看到。

### Q10: 我的 Key 会不会被卖家看到？
**A:** 不会。所有配置都在你本机完成。诊断报告的 Key 会自动打码（如 `sk-abc****wxyz`）。**不要主动把 Key 发给卖家。**

---

## 使用相关

### Q11: 为什么不是 Claude 官方模型？
**A:** 本工具配置的是 **DeepSeek API 兼容接入**方案。你将使用 DeepSeek 的模型，但通过 Claude Code 的交互界面。这不是 Claude 官方服务。

### Q12: 和直接用 Claude 有什么区别？
**A:** 
- 相同：都可以在终端/VS Code 中 AI 编程
- 不同：底层模型是 DeepSeek 而非 Anthropic Claude
- 费用：DeepSeek 价格不同，请查看 DeepSeek 官方定价
- 功能：部分能力以 DeepSeek 官方兼容情况为准

### Q13: 为什么不能发图片/文档给 AI？
**A:** 多模态功能（图片、文档理解）取决于 DeepSeek 对 Claude 兼容接口的支持程度。请查阅 DeepSeek 官方文档了解最新支持情况。

### Q14: 用起来很慢怎么办？
**A:** 
1. 检查网络（延迟可能影响速度）
2. DeepSeek 服务端高峰期会慢
3. 查看 DeepSeek 官方状态页面

### Q15: 消耗多少 API 额度？
**A:** 取决于使用量。每次对话都会消耗 token。建议：
- 在 platform.deepseek.com 查看使用量
- 设置使用预算提醒
- 避免无意义的超长对话

---

## 错误代码

### Q16: 401 Unauthorized？
**A:** API Key 错误。
- 检查是否完整复制了 Key
- Key 是否已过期/被删除
- 到 platform.deepseek.com 重新创建 Key
- 回来运行 `configure-deepseek.ps1` 更新

### Q17: 402 Payment Required？
**A:** DeepSeek 账户余额不足。
- 到 platform.deepseek.com 充值
- 充值后等待几分钟生效

### Q18: 429 Too Many Requests？
**A:** 请求太频繁，被限流了。
- 等 3-5 分钟再试
- 减少并发请求
- 检查是否有其他程序也在用同一个 Key

### Q19: 500/502/503 错误？
**A:** DeepSeek 官方服务端问题。
- **这不是你的问题，也不是卖家的问题**
- 等待官方修复（通常几分钟到几小时）
- 查看 DeepSeek 官方公告

### Q20: 网络连接失败/超时？
**A:** 
1. 检查网络是否正常（打开网页试试）
2. 是否能访问 https://api.deepseek.com
3. 公司网络可能封锁了 → 试试手机热点
4. 是否需要代理/VPN

### Q21: DNS 解析失败？
**A:** 
1. 尝试更换 DNS：设置 → 网络 → 更改 DNS 为 `114.114.114.114`
2. 或重启路由器

---

## WSL 相关

### Q22: WSL 是什么？我需要吗？
**A:** WSL = Windows Subsystem for Linux，在 Windows 里运行 Linux。**不是必须的**，Claude Code 在 PowerShell 中也能用。

### Q23: WSL 内安装失败？
**A:** 
1. 确保 WSL Ubuntu 已正确安装：管理员 PowerShell 中运行 `wsl --install`
2. 进入 Ubuntu 终端
3. 导航到脚本目录：`cd /mnt/c/Users/你的用户名/Downloads/claude-deepseek-installer`
4. 运行：`chmod +x install_wsl.sh && ./install_wsl.sh`

---

## 售后相关

### Q24: 能用多久？
**A:** 本服务是**一次性安装配置**。环境配好后可以一直使用。费用只产生在 DeepSeek API 调用端。Claude Code 工具本身的计费规则以 Anthropic 官方为准。

### Q25: Claude Code 更新了怎么办？
**A:** 在 PowerShell 中运行 `npm install -g @anthropic-ai/claude-code@latest` 即可更新。

### Q26: 换了电脑怎么办？
**A:** 重新在新电脑上运行安装脚本即可。需要重新配置 API Key。

### Q27: 如何确认安装成功了？
**A:** 运行诊断：`powershell -ExecutionPolicy Bypass -File .\doctor.ps1`，查看 `report.txt` 中是否全部 ✅。
