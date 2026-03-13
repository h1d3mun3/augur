# llm-docker

Claude Code と Codex CLI を同一の Docker コンテナで動かすツールです。  
任意のディレクトリで使え、ホストのファイルシステムはカレントディレクトリのみに限定されます。

## セットアップ

### クイックスタート（インストールスクリプト使用）

セットアップを自動化するスクリプトが用意されています：

```bash
# 1. スクリプトを実行（Dockerfile と llm-docker を ~/.llm-docker/ にコピー、PATH を設定）
bash install

# 2. シェル設定を反映
source ~/.zshrc  # または source ~/.bashrc

# 3. Docker イメージをビルド
llm-docker build
```

**注意事項：**
- このスクリプトは **セットアップとアップデートの両方** に使用できます。既にインストール済みの場合も実行して構いません。PATH は重複して追加されません。

---

### 手動セットアップ

自動スクリプトを使わない場合は、以下の手順で手動でセットアップできます。

### 1. ファイルを配置

```bash
mv ~/Downloads/llm-docker ~/.llm-docker
chmod +x ~/.llm-docker/llm-docker
```

### 2. PATH に追加

`~/.zshrc`（または `~/.bashrc`）に追記：

```bash
export PATH="$HOME/.llm-docker:$PATH"
```

反映：

```bash
source ~/.zshrc
```

### 3. API キーを設定

使うものだけでOKです。`~/.zshrc` に追記：

```bash
export ANTHROPIC_API_KEY="sk-ant-..."   # Claude Code 用
export OPENAI_API_KEY="sk-..."          # Codex 用（APIキー認証の場合）
```

Codex を ChatGPT アカウントで使う場合は API キー不要です。代わりに後述の `llm-docker login` で認証します。

### 4. Docker イメージをビルド

```bash
llm-docker build
```

初回のみ必要です（数分かかります）。

### 5. Codex のブラウザ認証（ChatGPT アカウントを使う場合）

```bash
llm-docker login
```

ターミナルに URL とコードが表示されます。URL をブラウザで開いてコードを入力すれば完了です。認証情報は `~/.codex` に保存されるので次回以降は不要です。

---

## 使い方

```bash
cd ~/projects/my-app

llm-docker up        # コンテナ起動
llm-docker claude    # Claude Code を起動
llm-docker codex     # Codex を起動
llm-docker down      # コンテナを停止・削除
```

その他のコマンド：

```bash
llm-docker shell     # bash でコンテナに入る（デバッグ用）
llm-docker status    # 状態と認証情報を確認
llm-docker login     # Codex のブラウザ認証（デバイスフロー）
llm-docker build     # Docker イメージをビルド
```

---

## ファイルの扱い

| パス | 説明 |
|------|------|
| カレントディレクトリ | `/workspace` にマウント（読み書き可） |
| `~/.claude/` | コンテナと共有（Claude の認証情報・設定） |
| `~/.codex/` | コンテナと共有（Codex の認証情報・設定・履歴） |
| `~/.gitconfig` | 読み取り専用でマウント（git の commit 名を統一） |
| それ以外 | **コンテナから見えない**（ホスト保護） |

---

## 動作要件

- Docker（Docker Desktop または Docker Engine）
- bash
