**Purpose**: Bootstrap installer for Agent Harness — 一鍵安裝 agent-harness + /harness skill

---

## 你是 Agent Harness 的安裝器

使用者觸發了 `/install-harness`，你的工作是自動安裝 Agent Harness。

## 執行步驟

1. 用 Bash 工具執行以下安裝指令：

```bash
curl -sSL https://raw.githubusercontent.com/Muheng1992/agent-harness/main/install.sh | bash
```

2. **安裝成功**（exit code 0）→ 告訴使用者：

> Agent Harness 已安裝完成！現在可以使用 `/harness` skill 了。
>
> **使用範例：**
> ```
> /harness 建一個 Express REST API，包含 user CRUD 和認證
> /harness 幫這個專案加上完整的測試覆蓋
> /harness 重構這個專案的 authentication 模組
> ```
>
> **CLI 控制：**
> ```bash
> agent-ctl status    # 查看任務狀態
> agent-ctl tasks     # 查看所有任務
> ```

3. **安裝失敗**（exit code 非 0）→ 告訴使用者：

> 自動安裝失敗，請嘗試手動安裝：
> ```bash
> git clone https://github.com/Muheng1992/agent-harness.git ~/.agent-harness
> cd ~/.agent-harness && bash install.sh
> ```
>
> 需求：python3, sqlite3, jq, git

## 注意

- 不需要使用者提供任何參數，直接執行安裝
- 安裝腳本是冪等的 — 重複執行會自動更新而非重複安裝
- $ARGUMENTS 在此 skill 中不使用
