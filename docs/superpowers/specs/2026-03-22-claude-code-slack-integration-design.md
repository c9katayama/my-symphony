# Symphony: Claude Code + Slack Integration Design

**Date:** 2026-03-22
**Status:** Reviewed

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
- ローカル実行のみ（SSH workerは非対応 — backend: claude_code時にssh_hostsが設定されていればバリデーションエラー）

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

既存の `Codex.AppServer` のインターフェースに合わせた設計:

```elixir
defmodule SymphonyElixir.AgentAdapter do
  @type session_state :: term()

  @callback start_session(workspace :: String.t(), opts :: keyword()) ::
              {:ok, session_state()} | {:error, term()}

  @callback run_turn(session_state(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, result :: map()} | {:error, term()}

  @callback stop_session(session_state()) :: :ok
end
```

**opts に含まれるキー:**
- `:on_message` — ストリーミングメッセージコールバック（進捗通知に使用）
- `:tool_executor` — 動的ツール実行関数（Codex: linear_graphql等、Claude Code: MCP tools）
- `:config` — バックエンド固有の設定 (turn_timeout_ms, sandbox policy等)
- `:worker_host` — SSH接続先（Codexのみ、Claude Codeでは使用不可）

### ClaudeCode.CLI アダプター

**プロセス管理:** `Port.open/2` を使用（Codex AppServerと同様）

- `start_session/2`:
  - session_stateとして `%{session_id: nil, workspace: workspace, config: opts[:config]}` を返す
  - セッション開始は最初のターンで行う（CLIは接続を維持しないため）
- `run_turn/4`:
  - 初回: `Port.open({:spawn, "claude --dangerously-skip-permissions --output-format json -p \"#{prompt}\""}, [:binary, :exit_status, cd: workspace])`
  - 継続: `--resume <session-id>` フラグを追加
  - Port出力を行単位でパースし、`on_message` コールバックに転送
  - プロセス終了時に exit_status を確認、JSON結果をパース
  - タイムアウト: `turn_timeout_ms` 経過後に `Port.close/1` + OSプロセスkill
  - session-id を結果JSONの `session_id` フィールドから抽出し state に保存
- `stop_session/1`:
  - プロセスはターンごとに終了済みのため特に操作なし

**Claude Code CLI JSON出力形式 (--output-format json):**

```json
// 成功時
{
  "type": "result",
  "session_id": "abc123-...",
  "result": "実行結果テキスト",
  "cost_usd": 0.05,
  "duration_ms": 12345,
  "num_turns": 3
}

// エラー時 (非ゼロexit code)
{
  "type": "error",
  "error": "エラーメッセージ"
}

// --resume で無効なsession-id の場合: 新規セッションとして開始（フォールバック）
```

**SSH Worker制約:**
- `backend: claude_code` 時に `worker.ssh_hosts` が設定されている場合、設定バリデーションでエラー
- Claude Code CLIはローカル実行のみサポート

### Codex.AppServer アダプター

- 既存の `app_server.ex` をbehaviourにラップ
- 内部的には既存のJSON-RPC 2.0プロトコルをそのまま使用
- `worker_host` 対応もそのまま維持

### AgentRunner リファクタリング

現在の `agent_runner.ex` はCodex固有のコンセプト（thread_id, sandbox policy等）に直接依存している。以下のように分離:

```
AgentRunner (共通インフラ)
├── ワークスペース作成・クリーンアップ
├── ターンループ（max_turns管理）
├── ターン間のissue state再チェック
├── リトライロジック
└── on_message → Orchestratorへの codex_worker_update 転送

AgentAdapter実装 (バックエンド固有)
├── Codex: thread_id, turn_id, sandbox, approval_policy
└── ClaudeCode: session_id, --resume, Port管理
```

AgentRunnerは `config.agent.backend` を読み、対応するアダプターモジュールを取得:

```elixir
defp adapter_module(config) do
  case config.agent.backend do
    "codex" -> SymphonyElixir.Codex.Adapter
    "claude_code" -> SymphonyElixir.ClaudeCode.Adapter
  end
end
```

### 設定 (WORKFLOW.md)

```yaml
agent:
  backend: claude_code  # or "codex"

claude_code:
  command: "claude"
  model: "sonnet"
  additional_flags: []
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
```

## 2. Slack Bot 層

### モジュール構成とプロセスモデル

```
lib/symphony_elixir/slack/
├── supervisor.ex      # Slack.Supervisor (strategy: :rest_for_one)
├── socket.ex          # GenServer: Socket Mode WebSocket接続管理
├── event_handler.ex   # 純粋モジュール: イベント振り分けロジック
├── thread_context.ex  # 純粋モジュール: スレッド全文取得・要約
├── notifier.ex        # GenServer: 進捗通知 (rate limit管理)
└── commands.ex        # 純粋モジュール: コマンド解析
```

**GenServer:** `Socket`, `Notifier` (状態管理が必要)
**純粋モジュール:** `EventHandler`, `ThreadContext`, `Commands` (ステートレス)

### WebSocketライブラリ

`fresh` (WebSocket client for Elixir) を使用。軽量でMintベース、OTPフレンドリー。

```elixir
# mix.exs に追加
{:fresh, "~> 0.4"}
```

### Socket Mode接続 (`socket.ex`)

- GenServerとしてSlack.Supervisor配下で起動
- `apps.connections.open` (HTTP POST) でWebSocket URLを取得
- `fresh` でWebSocket接続
- 受信メッセージごとに `envelope_id` でack応答
- `event_callback` イベントを `EventHandler` に委譲
- 自動再接続ロジック内蔵（exponential backoff: 1s, 2s, 4s, ... max 30s）

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
Anthropic Messages API で要約 (バックエンド非依存)
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

**要約にはAnthropic Messages APIを直接使用**（`req`でHTTP POST）。エージェントバックエンド（codex/claude_code）とは独立して動作するため、どちらのバックエンド設定でもSlack機能が使える。

**スレッドのチケット重複防止:** 同一スレッドから複数回 `@Bot` が呼ばれた場合、既存チケットがあればそのチケットに追加指示として渡す（Notifierが `thread_ts → issue_id` のマッピングを保持）。

### 通知 (`notifier.ex`)

| トリガー | 通知先 |
|----------|--------|
| Slack起点の作業: ステート変更 | 元スレッドに返信 |
| Slack起点の作業: ターン完了 | 元スレッドにサマリー |
| Linear起点の作業: ステート変更 | 通知チャンネル (チケットごとにスレッド化) |
| Linear起点の作業: ターン完了 | 通知チャンネルの該当スレッド |

**内部マッピング:**
- `issue_id → {channel_id, thread_ts}` — Slack起点のチケットの通知先
- `issue_id → {notification_channel, thread_ts}` — Linear起点のチケットの通知先（初回通知時にスレッド作成）

**Rate limiting:** Slack APIの429応答に対し、`Retry-After` ヘッダに従ってキューイング。

### コマンド (`commands.ex`)

Slackメッセージからのコマンド解析:

- `@Bot MT-123 を対応して` → チケット着手指示
- `@Bot pause MT-123` → エージェント一時停止
- `@Bot retry MT-123` → リトライ
- `@Bot status` → 稼働状況
- `@Bot この仕様で実装して` (スレッド内) → スレッドコンテキスト → チケット作成

## 3. Orchestratorとの連携

### AgentRunner変更

- Codex呼び出し部分を `AgentAdapter` behaviour 経由に変更
- `config.agent.backend` でアダプターモジュールを選択

### 通知フック

- ターン完了時: `Slack.Notifier.on_turn_complete(issue_id, turn_summary)`
- ステート変更時: `Slack.Notifier.on_state_change(issue_id, old_state, new_state)`
- Slack起点チケットの origin情報: `{channel_id, thread_ts}` をOrchestratorのランタイムステートに保持

### Slackコマンド → Orchestrator連携

Slackからのコマンド（`@Bot MT-123 を対応して`）は以下の流れで処理:

1. Slack EventHandler がコマンドを解析
2. **Linear APIでチケットのステートを変更**（例: Backlog → Todo）
3. Orchestratorが次のポーリングサイクルで検出・ディスパッチ

Orchestratorへの直接メッセージ送信は行わない（Linear = Source of Truthの原則を維持）。

## 4. Supervision Tree

```
SymphonyElixir.Supervisor (strategy: :one_for_one)
├── Phoenix.PubSub
├── Task.Supervisor
├── WorkflowStore
├── Orchestrator
├── Slack.Supervisor          # 新規 (slack.enabled時のみ, strategy: :rest_for_one)
│   ├── Slack.Socket          # WebSocket接続 (他が依存)
│   └── Slack.Notifier        # 通知管理 (Socketに依存)
├── HttpServer
└── StatusDashboard
```

**グレースフルデグラデーション:** `slack.enabled: true` だがトークンが無効/接続失敗の場合、`Slack.Supervisor` は再起動を試みるが、Symphony本体（Orchestrator, Linear polling）は影響を受けない。`max_restarts` 超過後はSlack機能のみ停止し、ログに警告を出力。

## 5. 設定スキーマ追加

### WORKFLOW.md 設定

```yaml
agent:
  backend: claude_code       # "codex" | "claude_code"
  max_concurrent_agents: 10
  max_turns: 20

claude_code:
  command: "claude"
  model: "sonnet"
  additional_flags: []
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000

slack:
  enabled: true
  app_token: $SLACK_APP_TOKEN          # xapp-... (Socket Mode)
  bot_token: $SLACK_BOT_TOKEN          # xoxb-... (API呼び出し)
  notification_channel: "#symphony-notifications"
  summarization_model: "claude-sonnet-4-6"  # スレッド要約に使用するモデル
```

### Ecto Schema定義

```elixir
# Agent schema に追加
field :backend, :string, default: "codex"
# バリデーション: backend in ["codex", "claude_code"]
# バリデーション: backend == "claude_code" の場合 worker.ssh_hosts は空であること

# 新規: ClaudeCode embedded schema
embedded_schema do
  field :command, :string, default: "claude"
  field :model, :string, default: "sonnet"
  field :additional_flags, {:array, :string}, default: []
  field :turn_timeout_ms, :integer, default: 3_600_000
  field :stall_timeout_ms, :integer, default: 300_000
end

# 新規: Slack embedded schema
embedded_schema do
  field :enabled, :boolean, default: false
  field :app_token, :string  # resolve_secret_setting で $ENV_VAR 展開
  field :bot_token, :string  # resolve_secret_setting で $ENV_VAR 展開
  field :notification_channel, :string
  field :summarization_model, :string, default: "claude-sonnet-4-6"
end
```

環境変数:
- `SLACK_APP_TOKEN` — Socket Mode用アプリレベルトークン
- `SLACK_BOT_TOKEN` — Slack API呼び出し用Botトークン
- `ANTHROPIC_API_KEY` — スレッド要約用 (Anthropic Messages API)

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

- Socket Mode切断 → exponential backoffで再接続 (1s, 2s, 4s, ... max 30s)
- Slack接続起動失敗 → Slack.Supervisor内で再起動試行、本体に影響なし
- Linear API失敗 → Slackスレッドにエラー通知、リトライ
- Claude Code CLI タイムアウト → Port.close + OSプロセスkill、ターン失敗としてOrchestratorに通知
- Claude Code CLIの非ゼロexit → エラーJSONをパースしてエラーハンドリング
- Slack API rate limit → 429レスポンスの`Retry-After`に従いキューイング
- Anthropic API失敗 (要約) → Slackスレッドにエラー通知、スレッド全文をそのままdescriptionに入れるフォールバック

## 8. Observability

- `codex_worker_update` メッセージパターンをClaude Codeでも踏襲
  - Claude Code CLIのPort出力を `on_message` コールバック経由で転送
  - StatusDashboardにはバックエンド名を表示
- Slack通知自体がobservabilityの役割も果たす（ターンサマリー = 人間向けダッシュボード）

## 9. テスト戦略

- `AgentAdapter` behaviour のモックによるUnit test
- `ClaudeCode.Adapter` のPort出力パースのUnit test
- `Slack.EventHandler` の入力→出力テスト
- `Slack.ThreadContext` のスレッド解析テスト
- `Slack.Commands` のコマンドパーステスト
- 設定バリデーションテスト（claude_code + ssh_hosts の排他等）
- 既存のE2Eテスト拡張 (Claude Code backend)
- Slack統合テスト (Mock WebSocket server)
