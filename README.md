# GCP Vertex AI 自动配置脚本

此脚本可在 Google Cloud Shell 中一键创建 Vertex AI 项目并生成 API 密钥。

## ✅ 一键执行（点击按钮后需在终端按提示确认）

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://ssh.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/xiliangliang/gcp-vertex-automation.git&cloudshell_print=instructions.txt&cloudshell_tutorial=README.md&cloudshell_run=chmod%20%2Bx%20vertex_setup.sh%20%26%26%20./vertex_setup.sh)

**操作步骤：**
1. 点击上方按钮
2. 等待 Cloud Shell 打开
3. 在右侧终端窗口中按提示输入 `y` 确认执行
4. 等待脚本完成（约 1-2 分钟）

## 手动执行步骤

```bash
# 完整复制粘贴这些命令：
git clone https://github.com/xiliangliang/gcp-vertex-automation.git
cd gcp-vertex-automation
chmod +x vertex_setup.sh
./vertex_setup.sh
```

## 预期输出
成功执行后您将看到：
```
✅ 配置完成！
========================================
项目ID: ai-api-xxxxxx
区域:   asia-southeast1
API密钥: AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ012345
========================================
```

## 常见问题解决
### 如果点击按钮后没有自动执行
1. 在 Cloud Shell 终端中手动输入：
   ```bash
   cd gcp-vertex-automation && chmod +x vertex_setup.sh && ./vertex_setup.sh
   ```
2. 或直接运行在线脚本：
   ```bash
   curl -sSL https://raw.githubusercontent.com/xiliangliang/gcp-vertex-automation/main/vertex_setup.sh | bash
   ```

### 如何删除创建的项目
在脚本最后会提示是否清理资源，输入 `y` 确认删除。
