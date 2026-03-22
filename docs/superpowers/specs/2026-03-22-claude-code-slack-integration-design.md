# Symphony: Claude Code + Slack Integration Design

**Date:** 2026-03-22
**Status:** Draft

## Overview

Symphonyは現在Codex専用のチケット駆動型AIエージェントオーケストレーター。本設計では以下を追加する:

1. **Claude Code CLI統合** — `--dangerously-skip-permissions`でClaude Codeをエージェントバックエンドとして使用可能にする
2. **Slack双方向連携** — Socket Modeによるフル双方向Slack統合

## 要件

### Claude Code統合
- CLI呼び出し方式: `claude --dangerously-skip-permissions --output-format json -p "プロンプト"`
- `--resume <session-id>` でセッション継続（マルチターン対応）
- WORKFLOW.mdの設定でCodexとClaude Codeを排他的に切り替え
- 開発に人手を介さない完全自動化

### Slack連携
- **Socket Mode** (WebSocket) — 公開エンドポイント不要
- **全チャンネル対応** — SlackAppが参加している全チャンネルが対象
- **メンション駆動** — `@Bot` メンションで起動
- **スレッドコンテキスト** — スレッド内で呼ばれた場合、ルートメッセージまで遡り文脈把握
- **返信はスレッド内** — 進捗報告や質問は元メッセージのスレッドに集約
- **Linear = Source of Truth** — Slackからの操作はすべてLinear API経由
- **通知粒度** — ステート変更 + ターン単位サマリー
- **通知先**: Slack起点 → 元スレッド、Linear起点 → 設定した通知チャンネル
- **チケット作成時**: SlackスレッドURL + AI要約をdescriptionに記載

## アーキテクチャ

### アプローチ: レイヤード拡張

既存アーキテクチャを尊重し、3つの独立したレイヤーを追加:

```
[AgentAdapter]  — Codex/ClaudeCodeの切り替え抽象層
      ↓
[Orchestrator]  — 既存のまま、アダプター経由でエージェント呼び出し
      ↓
[SlackBot]      — 新GenServer群、Socket Mode接続、Orchestrator/Linearと連携
```

### データフロー全体図

```
┌─────────┐     Socket Mode      ┌──────────────────┐
│  Slack   │◄────────────────────►│  Slack.Socket    │
│  Users   │   WebSocket          │  EventHandler    │
└─────────┘                       │  ThreadContext   │
                                  │  Notifier        │
                                  └────────┬─────────┘
                                           │
                                           ▼
┌─────────┐   GraphQL API        ┌──────────────────┐
│  Linear  │◄───────────────────►│  Orchestrator    │
│          │   Poll + Mutate      │                  │
└─────────┘                       └────────┬─────────┘
                                           │
                                    AgentAdapter
                                    behaviour
                                   ┌───────┴────────┐
                                   ▼                 ▼
                            ┌────────────┐   ┌─────────────┐
                            │ Codex      │   │ ClaudeCode  │
                            │ AppServer  │   │ CLI         │
                            └────────────┘   └─────────────┘
```

## 1. Agent Adapter 層

### Behaviour定義

```elixir
defmodule SymphonyElixir.AgentAdapter do
  @callback start_session(workspace :: String.t(), prompt :: String.t(), config :: map()) ::
              {:ok, session_state :: term()} | {:error, term()}

  @callback send_turn(session_state :: term(), prompt :: String.t()) ::
              {:ok, result :: map(), updated_state :: term()} | {:error, term()}

  @callback stop_session(session_state :: term()) :: :ok
end
```

### ClaudeCode.CLI アダプター

- `start_session/3`:
  - `claude --dangerously-skip-permissions --output-format json -p "プロンプト"` を実行
  - stdout JSON から session-id を抽出・保存
  - ワークスペースは `cd workspace &&` で切り替え
- `send_turn/2`:
  - `claude --dangerously-skip-permissions --output-format json --resume <session-id> -p "指示"` を実行
  - 結果をパースして返却
- `stop_session/1`:
  - プロセスはターンごとに終了済みのため特に操作なし

### Codex.AppServer アダプター

- 既存の `app_server.ex` をbehaviourにラップ
- 内部的には既存のJSON-RPC 2.0プロトコルをそのまま使用

### 設定 (WORKFLOW.md)

```yaml
agent:
  backend: claude_code  # or "codex"

claude_code:
  command: "claude"
  model: "sonnet"
  additional_flags: []
  turn_timeout_ms: 3600000
```

## 2. Slack Bot 層

### モジュール構成

```
lib/symphony_elixir/slack/
├── socket.ex          # Socket Mode WebSocket接続管理 (GenServer)
├── event_handler.ex   # イベント振り分け (メンション検出、スレッド解析)
├── thread_context.ex  # スレッド全文取得 → AI要約 → Linearチケット作成
├── notifier.ex        # 進捗通知 (スレッド返信 + 通知チャンネル)
└── commands.ex        # Slackからのコマンド解析 (pause, retry, status等)
```

### Socket Mode接続 (`socket.ex`)

- GenServerとしてSupervision tree配下で起動
- `apps.connections.open` でWebSocket URLを取得
- WebSocketで接続、`envelope_id` でack応答
- 自動再接続ロジック内蔵（exponential backoff）
- `slack.enabled: true` の場合のみ起動

### イベントハンドラ (`event_handler.ex`)

受信イベントを振り分け:

- `app_mention` → メンション処理
- `message` (in thread with bot) → スレッド内の追加指示

処理フロー:
1. メンション検出
2. スレッド内かどうか判定
3. スレッド内 → `thread_context` でルートまで遡り全文取得
4. スレッド外 → 当該メッセージのみ取得
5. コマンド解析 or チケット作成フローへ

### スレッドコンテキスト (`thread_context.ex`)

```
@Bot この仕様で実装して (スレッド内)
  ↓
conversations.replies API でスレッド全文取得
  ↓
Claude Code (-p) で要約 + 仕様化
  ↓
Linear にチケット作成:
  - title: AIが生成
  - description: |
      ## Slack Thread Context
      [元スレッド](https://slack.com/archives/C.../p...)

      ## Summary
      (AI要約)
  ↓
元スレッドに返信:
  「チケット MT-456 を作成し、作業を開始します」
```

### 通知 (`notifier.ex`)

| トリガー | 通知先 |
|----------|--------|
| Slack起点の作業: ステート変更 | 元スレッドに返信 |
| Slack起点の作業: ターン完了 | 元スレッドにサマリー |
| Linear起点の作業: ステート変更 | 通知チャンネル (チケットごとにスレッド化) |
| Linear起点の作業: ターン完了 | 通知チャンネルの該当スレッド |

### コマンド (`commands.ex`)

Slackメッセージからのコマンド解析:

- `@Bot MT-123 を対応して` → チケット着手指示
- `@Bot pause MT-123` → エージェント一時停止
- `@Bot retry MT-123` → リトライ
- `@Bot status` → 稼働状況
- `@Bot この仕様で実装して` (スレッド内) → スレッドコンテキスト → チケット作成

## 3. Orchestrator への変更

最小限の変更:

- `agent_runner.ex` の Codex 呼び出し部分を `AgentAdapter` 経由に変更
- ターン完了時に通知フック: `Slack.Notifier.on_turn_complete/2`
- ステート変更時に通知フック: `Slack.Notifier.on_state_change/2`
- Slack起点のチケットについて、origin情報（channel_id, thread_ts）を保持

## 4. Supervision Tree

```
SymphonyElixir.Supervisor (strategy: :one_for_one)
├── Phoenix.PubSub
├── Task.Supervisor
├── WorkflowStore
├── Orchestrator              # 既存、アダプター経由に変更
├── Slack.Socket              # 新規: Socket Mode接続 (slack.enabled時のみ)
├── HttpServer
└── StatusDashboard
```

## 5. 設定スキーマ追加

```yaml
# WORKFLOW.md に追加
agent:
  backend: claude_code       # "codex" | "claude_code"

claude_code:
  command: "claude"
  model: "sonnet"
  additional_flags: []
  turn_timeout_ms: 3600000

slack:
  enabled: true
  app_token: $SLACK_APP_TOKEN          # xapp-... (Socket Mode)
  bot_token: $SLACK_BOT_TOKEN          # xoxb-... (API呼び出し)
  notification_channel: "#symphony-notifications"
```

環境変数:
- `SLACK_APP_TOKEN` — Socket Mode用アプリレベルトークン
- `SLACK_BOT_TOKEN` — Slack API呼び出し用Botトークン

## 6. Slack App必要権限

### Bot Token Scopes
- `app_mentions:read` — メンション検出
- `channels:history` — チャンネルメッセージ読み取り
- `channels:read` — チャンネル情報取得
- `chat:write` — メッセージ送信
- `groups:history` — プライベートチャンネル対応
- `groups:read` — プライベートチャンネル情報

### Socket Mode
- App-Level Token with `connections:write` scope

### Event Subscriptions (Socket Mode経由)
- `app_mention`
- `message.channels`
- `message.groups`

## 7. エラーハンドリング

- Socket Mode切断 → exponential backoffで再接続
- Linear API失敗 → Slackスレッドにエラー通知、リトライ
- Claude Code CLI タイムアウト → ターン失敗としてOrchestratorに通知
- Slack API rate limit → 429レスポンスの`Retry-After`に従う

## 8. テスト戦略

- `AgentAdapter` behaviour のモックによるUnit test
- `Slack.EventHandler` の入力→出力テスト
- `Slack.ThreadContext` のスレッド解析テスト
- 既存のE2Eテスト拡張 (Claude Code backend)
- Slack統合テスト (Mock WebSocket server)
