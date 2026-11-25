# Remote Probe for Transport Fever 3

[English README](README.md) · [命令の参照](docs/REFERENCE.ja.md) · [既知の振る舞い](docs/KNOWN_BEHAVIOR.ja.md) · [AI エージェント向け (英語)](AGENTS.md)

Transport Fever 3 の MOD (`hummer_remote_probe`) と、コマンドラインのツール (`tools/tf3ctl.py`) の組です。
**MOD の作者のため**のもので、動いているゲームをシェル・試験のスクリプト・AI のコーディングエージェントから操作し、
人がキーボードの前にいなくても MOD を検証できます。

ゲームを AI に遊ばせるものではなく、検証のツールです。想定している一周:

1. **ロード**: 新しいゲームを始める (または試験用のセーブを読む)。検証する MOD と、試したい設定を入れて。
2. **検証**: 自分の建物を置く、道路を引く、車両を買う、路線を作る、指定の日まで進める。
3. **値を読む**: 駅・路線・車両・産業・町・収支を JSON で。
4. **ログを読む**: エラーと、MOD が出した行。

そして MOD を直して、もう一周します。

ゲームの GUI の Lua にはソケットが無いので、ツールと MOD はゲームの userdata のフォルダの小さなファイルでやり取りします。
ツールが命令を書き、MOD が読み (0.25〜2 秒ごと)、実行して答えを書きます。命令は JSON のオブジェクトを 1 つ出力します (例外: `log` はログの行をそのまま、`--every` は 1 行に 1 つの JSON、ツールのエラーは理由を stderr にだけ出します)。
ツールはクリックもキーも送りません。詳しくは[参照](docs/REFERENCE.ja.md#仕組み)の「仕組み」。

## 必要なもの

- Steam 版の Transport Fever 3 (build 40444 で試験)。
- **Linux**: 検証した環境です。**Windows**: ツールには Windows 向けの分岐 (パス・ロック・プロセスの一覧) がありますが、
  **Windows の実機では確認していません**。`frame` と `pointer` は Linux だけです。動く・動かないの報告を歓迎します。
- Python 3.8 以上と、`PATH` 上の `luajit`。
- 任意: `ffmpeg` と Steam のバックグラウンド録画 (`frame` で画面の静止画を取るため)、Track Connector MOD (`connect` のため)。
- **Time Warp (modId `mobarzik_faster_game_speed`) とは一緒に使えません**。どちらも速度ボタンを置き換えます。MOD は
  非互換として載せてあり、両方を有効にするとゲームが警告します。

詳しくは[必要なもの](docs/REFERENCE.ja.md#必要なもの)。

## 入れ方

ゲームのローカルの MOD フォルダは `<Steam>/userdata/<Steam の ID>/3493540/local/mods/` です (Linux では `<Steam>` は
ふつう `~/.local/share/Steam`)。

**GitHub から** (MOD とツールが 1 つのフォルダに入る):

```
cd ~/.local/share/Steam/userdata/<Steam の ID>/3493540/local/mods/
git clone https://github.com/hummer98/tpf3-remote-probe.git hummer_remote_probe_1
```

フォルダの直下に `mod.json` が来るようにします。ツールは `python3 hummer_remote_probe_1/tools/tf3ctl.py ...` で打ちます
(シェルの alias にしてもかまいません)。

**mod.io から**: ゲームの中で Remote Probe を購読します。mod.io から入るのは **MOD の部分だけで、ツールは入りません**
(mod.io は `.py` のファイルを受け付けないため)。ツールは GitHub からも取り、ゲームのローカルの MOD フォルダと
mod.io のフォルダの、どちらの**外**にも置いてください (中に置くと、同じ modId が 2 つになります)。リポジトリを
ほかの場所に clone するか、release の zip (GitHub の releases のページの `hummer_remote_probe_1-vX.Y.Z.zip`) を
ほかの場所に展開します。版は mod.io のページに出ているもの (下の `X.Y.Z`) を使います:

```
git clone https://github.com/hummer98/tpf3-remote-probe.git ~/tpf3-remote-probe
git -C ~/tpf3-remote-probe checkout vX.Y.Z
python3 ~/tpf3-remote-probe/tools/tf3ctl.py launch
```

ツールはゲームの場所を自分で探すので、MOD のフォルダに置く必要はありません。購読した MOD のフォルダ (Linux では `~/mod.io/common/10640/mods/<数字>/` の下) は、
mod.io のクライアントが更新のたびにまるごと作り直すので、そこでは何も変えないでください。

そのあと:

1. ゲームで、セーブに「Remote Probe」を有効にしてロードします。または、ツールにゲームを起動させます (下の `launch`)。
2. 答えるか確認します: `python3 tools/tf3ctl.py status` (`tools/` は、clone か展開をしたフォルダの中です。GitHub から入れたなら MOD の
   フォルダ、mod.io で購読したなら MOD フォルダの外に置いた写し)。ゲームのログに `[remote_probe] ready` が出ます。
   MOD が一度も動いていないうちは、`status` (と `state`、`log`) は終了コード 2 と「no hello file from the mod yet」で
   止まります。先に `launch` (下) でゲームを起動してください。

## 最初の一周

下では `tf3ctl.py` と書きます。`tools/` を含むフォルダ (clone か展開をしたフォルダ。「入れ方」) で `python3 tools/tf3ctl.py`
として打ってください。`my_mod` は自分の
MOD の modId に読み替えます。

```
tf3ctl.py status          # ゲームが答えるか (初回は launch まで終了コード 2)。日付・速度・MOD とその設定・gameState
tf3ctl.py config          # どの切り替えが入っているか、どのファイルからか (ファイルが無ければ既定)

# ゲームが動いていないとき: 起動して、メインメニューから自分の MOD を入れた新しいゲームを始める
# (もう動いているとき: 先に `quit`、または `restart --no-kill --new ...`)
tf3ctl.py launch --new --size tiny --year 1900 --add my_mod

# 先にエンジンに聞いてから建てる
tf3ctl.py build --res my_mod::/my_depot.con --at 600,40 --dry-run --engine-check
tf3ctl.py build --res my_mod::/my_depot.con --at 600,40

tf3ctl.py run --until 1900-03-01      # 指定の日まで進めて止める
tf3ctl.py vehicles --state            # 値を読む (ほかに lines、stations、industry-stocks、finance など)
tf3ctl.py log --grep my_mod --tail 40 # ゲームのログ。自分の MOD が print する文字で grep (時刻は UTC)
tf3ctl.py quit
```

- `build --res` は建物のリソース名を取ります。MOD の `content/<dir>/x.con.lua` は `<modId>::/<dir>/x.con` です。
  `--dry-run --engine-check` は何も建てず、エンジンの答え (エラー・衝突・費用) を返します。
- MOD の設定を変えて試験用のセーブを読む: `load probe-base --param my_mod:someSetting=2` (数は `mod.json` のその設定の
  `values` の 1 から数えた番号で、値そのものではありません)。
- MOD のファイルを変えたら次のロードで入ります。**新しい**ファイルを足したら、ゲームの再起動が要ります。
- 終了コード: 0 成功、1 ゲームがエラーを返した、2 応答なし・ツールのエラー・読めない設定ファイル、3 ゲームが今いる
  場所では答えられない (メニュー・ロード中・終了。`gameState` を見る)、4 断った (何も送っていない)。

## 命令

1 行ずつです。どの命令にも `--help` があり、[参照](docs/REFERENCE.ja.md#使い方)に命令ごとの節があります。

| 分類 | 命令 |
|---|---|
| 時間 | `status` (日付・速度・MOD。`luaLoad`: load・loadstring・setfenv があるか)、`speed N` (UI の 4 倍より上。ゲームの見積もりが上限)、`pause`、`calendar-speed [0.25]` (本体のカレンダーのスライダー、0.25x〜4x。読む・変える)、`run --days / --months / --until` (そのあと止める)、`steps N` (シミュレーションの歩み、debug の命令)、`poll` (MOD が読む間隔) |
| ゲーム | `launch` / `restart` (`--load SAVE` か `--new ...`)、`quit`、`load SAVE` (`--add` / `--remove` / `--param`)、`save NAME`、`saves`、`info SAVE` (その MOD と設定)、`newgame` (メインメニューから)、`state` (ゲームのログから。メニューでも使える)、`company` |
| 読む | `entities`、`stations` (`--catchment`)、`lines` (`--problems`)、`depots`、`vehicles` (`--state`)、`models`、`persons`、`industry-workers`、`industry-stocks`、`finance`、`running-costs`、`around` (ある点の周りの物)、`lanes`、`parcels`、`water`、`reach` (その場所へ行けるか)、`stock list` |
| 建てる (試験用の地図) | `build` (建物。`--remove`)、`fit` (建物を置ける場所)、`road` (まっすぐ・曲がった 1 本。`--batch`)、`lights --off`、`terrain`、`town` (と `town connections` / `connect` / `develop` / `size`)、`connect` (2 つの端の間の線路・道路。Track Connector を使う) |
| 車両・所持金・路線 | `buy`、`duplicate`、`replace`、`sell`、`money`、`line create / update / delete`、`rename` |
| GUI | `window` (entity の窓を開く)、`event` (react のイベント)、`tool` (音楽・カレンダー・通知)、`camera`、`build-tool`、`script-event`、`frame` (Steam の録画からの静止画、Linux)、`pointer` (既定で切) |
| 自分の MOD の命令 | `mod --list`、`mod <modId> <命令> [JSON]` (MOD が `remote_probe_ext.lua` で出す命令) |
| ログとファイル | `log`、`keep-log`、`clean`、`restore-profile` |
| 複数のクライアントで使う | `--owner`、`coop`、`config`、`modhub` (メインメニューからのマイ MOD と mod.io へのアップロード) |

### 自分の MOD の命令

MOD は自分の命令を足せます。命令の表を返す `content/remote_probe_ext.lua` を MOD に入れ、
`tf3ctl.py mod my_mod <命令> '{"key": "value"}'` で呼びます。`examples/remote_probe_ext_sample/` が丸ごとの見本の MOD
です。ファイルの形は[ほかの MOD の命令](docs/REFERENCE.ja.md#ほかの-mod-の命令-mod)に。

## 設定ファイル

`tools/tf3ctl.py` は `$TF3CTL_CONFIG`、無ければ `$XDG_CONFIG_HOME/tf3ctl/config.json`、無ければ
`~/.config/tf3ctl/config.json` を読みます。**ファイルが無ければ既定**で、1 人が 1 つのゲームで使う形に合っています:

| キー | 既定 | 入れる・決めると |
|---|---|---|
| `ownerCheck` | 切 | ゲームを変える命令は、その `--owner` が起動したゲームにだけ届く |
| `coop` | 切 | `coop start` / `end`: 人と 1 つのクライアントでゲームを共有する (`ownerCheck` が要る) |
| `testSavePrefixes` | `["probe-"]` | 試験用のセーブとみなす名前 |
| `testSaveDigitFirst` | 切 | 数字 1 文字で始まる名前 (`3-probe`) も試験用のセーブ |
| `pointer` | 切 | `pointer` の命令 |
| `modhub.*` | 空 | `modhub validate` / `publish` が取れるフォルダ |

キーの全部は `tools/config.example.json` にあります。読めないファイルがあると、`config` 以外の命令は全部止まり、`config` が
何が悪いかを答えます。詳しくは[設定ファイル](docs/REFERENCE.ja.md#設定ファイル)。

## 安全上の注意

ツールやエージェントを自分のゲームに向ける前に読んでください。

- **試験用のセーブで使う。** ロードすると保存していない進行は失われます。いくつかの命令は、プレイヤーにはできない形で
  セーブの中身を変えます (`stock set`・`steps`・`money`・`town develop`・`company init` など)。読み込んだセーブが試験用かを
  確認するのは、そのうちのわずかだけです。答えに `saveNote` が付きます。
- **`save` は黙って上書きします。** 名前を確認しないので、同じ名前のセーブは問い合わせなしに置き換わります。先に `saves`
  を見て、自分の新しい名前 (例 `probe-...`) を使ってください。
- **オートセーブが、ほかのオートセーブを押し出します。** ゲームが残すオートセーブは、全部のセーブの名前を合わせて数に
  上限があります。試しのゲームのオートセーブも数に入るので、検証を続けると、自分が遊んでいるゲームのオートセーブが
  押し出されます。試しの間はオートセーブの間隔を長くし (`<Steam>/userdata/<Steam の ID>/3493540/local/settings.lua` の
  `autosaveIntervalMinutes`。ゲームを閉じているときに変える。残す数は `autosaveKeepNumber`)、終わったら戻すのをおすすめします。
- **クリックもキーも送らない。** ツールはマウスのクリックもキーも送りません。UI が要る確認 (スクロール・ボタン) は、
  MOD に試験用の命令かイベントを足して、`mod` か `event` で送ってください。
- **止めるとき**は `quit` と `restart --no-kill` を使います。何も付けない `restart` と `quit --kill` は、終わらないゲームを
  SIGKILL します (保存していない進行は失われます)。
- **新しいゲームはメインメニューから** (`launch --new`、`restart --new`)。ゲームの途中から始めると落ちたので、ゲームの中では
  `newgame` は `--list` / `--dry-run` だけを取ります。
- **速度**はゲーム自身の見積もりが上限です。超えるとフレームが長くなり、音が途切れます。
- **`--wait-for-start`** は人が「ゲーム開始」を押すのを待ちます。その間は `quit` も効きません。

ゲームの癖、ゲームが落ちた並び、ゲーム内で確認したこと・まだのことの日付つきの記録は[既知の振る舞い](docs/KNOWN_BEHAVIOR.ja.md)に
あります。

## AI エージェント向け

[AGENTS.md](AGENTS.md) (英語) はコーディングエージェント (Claude Code、Codex など) 向けです。答えの読み方、最初の一周、
守る決まりが書いてあります。エージェントにはこれを読ませてください。

## MCP サーバー

`tools/tf3ctl_mcp.py` は、同じ命令を MCP (Model Context Protocol) のツールとして見せます。MCP のサーバーを使える
クライアント向けです。stdio の薄い包みで、ツール 1 つが `tf3ctl.py` の命令を 1 回動かし、JSON の答え・終了コード・
stderr を返します。ツールの一覧は `tf3ctl.py` 自身のオプションから作り、tf3ctl の検査 (owner、試験用のセーブ、coop、
設定ファイル) はコマンドラインと同じく効きます。Python 3.8 以上、標準ライブラリだけです。Claude Code と Codex は
`tf3ctl.py` をそのまま使うこともできます。どちらでも [AGENTS.md](AGENTS.md) の決まりは同じです。

```
claude mcp add tf3ctl -- python3 /path/to/tools/tf3ctl_mcp.py --owner my-agent
```

- `--owner` (なければ `$TF3CTL_OWNER`) を毎回の命令に付けます。`--tf3ctl PATH` で別の写しのツールを動かします。
- ツールの名前は命令の `-` と空白を `_` にしたものです: `keep_log`、`stock_set`、`town_develop`。引数は長いオプションから
  `--` を取ったものです (`dry_run: true`、`add: ["my_mod"]`)。
- 外したもの: `pointer` (この機械のポインタを動かす) と `modhub publish` / `publish-clear` (アップロードは人の手順)。
  `--other-owner-ok` も出していません。人が起動したゲームでは、その人と `coop start` で。`vehicles` / `persons` の
  `every` には `count` が要ります。
- 呼び出しは 1 つずつです。長い呼び出し (`run`) の間はほかを待たせ、クライアントからの取り消しでは止まりません。
- 呼び出しは、命令自身の `--timeout` の値のぶんだけ待ちます。長い命令 (`launch`、`run`) では、クライアントのツールの
  時間切れを延ばす必要があるかもしれません (Claude Code: 環境変数 `MCP_TOOL_TIMEOUT`、ミリ秒)。

## ほかの文書

- [docs/REFERENCE.ja.md](docs/REFERENCE.ja.md): 全部の命令、設定ファイル、MOD の設定、環境変数、テスト、実装メモ。
- [docs/KNOWN_BEHAVIOR.ja.md](docs/KNOWN_BEHAVIOR.ja.md): 安全上の注意の全文、ゲーム内で確認したこと、ゲームの振る舞いのメモ。
- [CHANGELOG.md](CHANGELOG.md) (英語)。
- テスト (ゲームは要りません。GitHub から clone したもので。release の zip には `tests/` がありません): `luajit tests/run.lua` と `python3 -m unittest discover -s tests`。

## 不具合・質問

GitHub の issue でお知らせください: https://github.com/hummer98/tpf3-remote-probe/issues 。どの命令で、何が返ったか (JSON)、
ゲームのログの `[remote_probe]` の行を添えてください。

## ライセンス

MIT。[LICENSE](LICENSE.txt) を見てください。

Track Connector (`ethan_track_connector`) は別の作者の MOD です。このリポジトリには含まれず、このリポジトリの MIT
ライセンスの対象外で、このプロジェクトとの関係もありません。`connect` は、プレイヤーが自分で入れたものを読み込むだけです。
