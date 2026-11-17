# Remote Probe for Transport Fever 3

[English README](README.md)

Transport Fever 3 の MOD (`hummer_remote_probe`) と、コマンドラインのツール (`tools/tf3ctl.py`) の組です。ゲームの外の
スクリプトから、動いているゲームを操作できます。速度を UI の上限 4 倍より上げる、指定日まで進めて止める、セーブのロードと
保存 (他の MOD や MOD の設定を変えて)、メインメニューからの新しいゲーム、ウィンドウを開く、車両の売買、路線づくり、
ゲームのログを読むこと。

人がキーボードの前にいなくても MOD を確かめるために作りました。試験用のセーブを設定を変えてロードし、数か月進めて止め、
ログを読む、を繰り返す使い方です。人がシェルから使っても、試験のスクリプトや AI エージェントから使ってもかまいません。

**試験用のセーブで使ってください。** コマンドで別のセーブをロードでき (保存していない進行は失われる)、会社の所持金を変え、
車両を売り買いできます。

## 仕組み

ゲームの GUI の Lua には、ソケットもファイル操作 (`io`) もありません。使えるのは `app.saveUserdata` /
`app.loadUserdata` で、ゲームの userdata フォルダに Lua のファイルを書き、読むことです。MOD の GUI スクリプト
(`content/remote.script.lua`、`guiUpdateScript`) は、このファイルを郵便受けとして使います。

```
tf3ctl.py  --書く-->  <userdata>/recordings/remote_probe__cmd_<stamp>.lua   { id, cmd, args }
MOD        --0.25〜2 秒ごとに読み、コマンドを実行して、書く-->
                       <userdata>/recordings/remote_probe__res_<id>.lua     { id, json = "..." }
tf3ctl.py  --答えを読み、JSON を出力し、古いファイルを消す
```

`<userdata>` は `<Steam>/userdata/<Steam の ID>/3493540/local` です。MOD はロードのたびに `remote_probe__hello_*`
のファイル (自分は誰か、ゲームの状態、MOD の設定) も書き、ツールはそれでフォルダを見つけ、新しいロードに気づきます。
`recordings` にファイルが残らなければ `keyframes`、最後に `mod_presets` を使います。ファイルの形式は
`content/remote.script.lua` の冒頭にあります。

いくつかのコマンドは GUI の react の状態を要します (ウィンドウを開く、イベントを送る、車両の店と同じ処理)。そのために
MOD は速度ボタンのレシピを、同じボタンと小さな表示に差し替え、依頼を GUI の保存データでそのレシピに渡します。
そのため、`window`・`event`・`tool` と、車両・路線のコマンドの `--via gui` では、**ゲーム画面に速度ボタンが出ている**
必要があります (出ていなければ、60 秒後に「no word from the speed control」のエラーになります)。

メインメニューには、まだゲームのスクリプトがありません。そこで、ゲームを `--script hummer_remote_probe::/startup.lua`
付きで起動すると、同じコマンド処理がメニューで動きます (status・saves・info・load・newgame・poll・quit だけ)。
`tf3ctl.py launch` と `restart` がこれを行います。

## 必要なもの

- Steam 版の Transport Fever 3 (build 40444 で試験)、Linux。ツールは `fcntl` と Linux のプロセス一覧を使うので、
  このままでは Windows で動きません。
- Python 3.8 以上と、`PATH` 上の `luajit` (ツールは MOD の Lua のファイルを luajit で読みます)。
- 任意: `frame` に `ffmpeg` と Steam のバックグラウンド録画。`screenshot --preview` に ImageMagick。

## 導入

1. このリポジトリのフォルダを、ゲームのローカルの MOD フォルダに写します。例:
   `<Steam>/userdata/<Steam の ID>/3493540/local/mods/hummer_remote_probe_1/` (その中に `mod.json`)。
2. ゲームで、セーブに「Remote Probe」を有効にしてロードします。または、ツールでゲームを起動します (下の `launch`)。
3. 答えるか確かめます:

```
python3 tools/tf3ctl.py status
```

ゲームのログに `[remote_probe] ready` が出ます。

## 使い方

どのコマンドも JSON のオブジェクトを 1 つ出力します。終了コード: 0 成功、1 ゲームがエラーを返した、2 応答なしか
ツールのエラー、3 ゲームが今いる場所では答えられない (メニュー、ロード中、probe のないメインメニュー、終了。
`gameState` が示す)。

### 時間と速度

```
python3 tools/tf3ctl.py status                        # 日付、速度、実測の倍率、MOD とその設定
python3 tools/tf3ctl.py speed 16                      # UI の 4 倍を超える (上限あり、「安全上の注意」)。0 で停止
python3 tools/tf3ctl.py pause
python3 tools/tf3ctl.py run --months 2 --speed 16     # --days N / --until YYYY-MM-DD も。その後は速度 0
python3 tools/tf3ctl.py poll --idle 5 --active 0.5    # コマンドファイルを読む間隔 (次のロードまで)
```

### セーブと新しいゲーム

```
python3 tools/tf3ctl.py saves
python3 tools/tf3ctl.py info my-save                  # セーブの MOD と MOD の設定
python3 tools/tf3ctl.py load my-save --param example_mod:difficulty=3 --dry-run   # 計画だけを見る
python3 tools/tf3ctl.py load my-save --param example_mod:difficulty=3 [--add MOD] [--remove MOD] [--set-mods a,b]
python3 tools/tf3ctl.py save my-save-after            # 同じ名前のセーブは上書き
python3 tools/tf3ctl.py newgame --list                # 気候と地形生成器 (ゲーム中でも安全)
```

`--param mod:key=index` の index は、その MOD の `mod.json` にある設定の `values` の 1 始まりの番号です (MOD
プリセットと同じ形)。本体の設定は `:key=index`。この MOD は常に有効のまま残ります (外すと誰も答えなくなるため)。

### ゲームの起動・終了・再起動

```
python3 tools/tf3ctl.py launch [--load SAVE | --new ...]   # ゲームが動いていないとき
python3 tools/tf3ctl.py restart --load my-save [--param ...]
python3 tools/tf3ctl.py restart --new --year 1900 --size small --add example_mod
python3 tools/tf3ctl.py quit [--kill]
python3 tools/tf3ctl.py state                         # in_game / menu / loading / main_menu / starting / closed / crashed
```

`launch` は `steam -applaunch 3493540 --script hummer_remote_probe::/startup.lua` を実行し、probe がメインメニューで
答えるまで待ってから、そこでセーブをロードするか新しいゲームを始めます。`restart` は先に終了し、終わらなければ既定で
SIGKILL します (`--no-kill` で諦める。「安全上の注意」)。新しいゲームの指定: `--climate` (既定 temperate)、`--size`
(tiny 16x16、small 32x32 (既定)、medium 44x44、large 56x56、veryLarge 64x64、または WxH)、`--year` (既定 1900)、
`--seed`、`--generator` (既定: 本体の新規ゲーム画面と同じ選び方の先頭)、`--no-towns`、`--no-industries`、MOD の指定は
`load` と同じ。メインメニューには「今のゲーム」が無いので、MOD はこの MOD と `--add` / `--set-mods` で指定したものに
なります。ack の plan で確かめてください。

### ゲームを見る

```
python3 tools/tf3ctl.py log --grep remote_probe --tail 40   # ゲームの stdout.txt
python3 tools/tf3ctl.py entities --kind town --grep ems     # ID と名前: town・line・vehicle・station・industry
python3 tools/tf3ctl.py window --town Emsworth --focus      # そのウィンドウを開き、カメラを寄せる (--close-all)
python3 tools/tf3ctl.py frame --out shot.png [--crop 1150x170+2690+1450]   # UI 込みの画面 (Steam の録画から)
python3 tools/tf3ctl.py tool music [--close]                # ツールとして開く本体のウィンドウ: music・calendar・notifications
python3 tools/tf3ctl.py event example_window.show --param '{"page": 2}'   # 任意の react イベントを送る
```

### 車両・所持金・路線

```
python3 tools/tf3ctl.py depots [--grep bus]
python3 tools/tf3ctl.py vehicles [--line 21]
python3 tools/tf3ctl.py buy --model bus_1900 --depot 301 [--line 21] [--count 2] [--via gui|cmd]
python3 tools/tf3ctl.py duplicate --vehicle 601 [--depot D] [--line L]
python3 tools/tf3ctl.py replace --vehicle 601 --model bus_1920
python3 tools/tf3ctl.py sell --vehicle 601
python3 tools/tf3ctl.py money --set 10000000 | --add -5000
python3 tools/tf3ctl.py stations [--name cent] [--near 11 --radius 800]
python3 tools/tf3ctl.py lines [--name probe]
python3 tools/tf3ctl.py line create --stops Central,42 [--name "[probe] A"] [--cargo coal] [--via gui|cmd]
python3 tools/tf3ctl.py line update 21 [--stops 41,42,43] [--name N] [--cargo C]
python3 tools/tf3ctl.py line delete 21 [--sell-vehicles]
```

車両の返事には、前後の残高、払った額、部品ごとの店の価格 (`metadata.cost`。送る前と返事のときに読む)、部品ごとの
`purchaseTime`、車両の残存価値が入ります。車両の価格を変える MOD を確かめるのに足ります。一時停止して使ってください。
そうしないと、運賃や維持費も差に入ります (ゲームの時間が動いたら `warning` が付きます)。

### 複数のクライアント

ツールは複数同時に動かせます (長い `run` と `status` など)。コマンドファイルは 1 つなので、ロックで順に書きます。
複数の人やスクリプトが 1 つのゲームを共有するときは、それぞれ `--owner NAME` (または `TF3CTL_OWNER`) で名前を付けます。
名前は `status` (`run.owner`、`lastAction`) に出ます。別の送り主が 10 分以内にゲームを変えていたら、ゲームを変える
コマンド (`load`・`run`・`speed`・`save`・`buy`・`line` など) の前に stderr へ警告が出ます。拒否はしません
(誰がゲームを使うかは、クライアント同士で決めます)。例外は `quit --kill` で、別の送り主が 10 分以内に使ったゲームは、`--force` が無ければ SIGKILL しません。

### 環境変数

- `TF3_REMOTE_DIR`: 交換フォルダ (既定: Steam の userdata のうち、hello ファイルが一番新しいもの。
  `~/.local/share/Steam`、`~/.steam/steam`、Flatpak の Steam を探す)。
- `TF3_LOG`: ゲームのログ (既定: 交換フォルダの隣の `crash_dump/stdout.txt`)。
- `TF3_STEAM`: Steam を起動するコマンド (既定 `steam`)。
- `LUAJIT`: luajit の実行ファイル。
- `TF3CTL_OWNER`: `--owner` の既定値。

## MOD の設定

| 設定 | 値 | |
|---|---|---|
| 普段の確認間隔 | 1 / **2** / 5 / 10 秒 | しばらくコマンドが来ていないときに、コマンドファイルを読む間隔 (1 回の読み込みに数ミリ秒) |
| コマンド直後と run 中の確認間隔 | 0.1 / **0.25** / 0.5 / 1 秒 | コマンドを受けてから 2 分間と `run` の実行中 |
| ログの量 | 最小 / **コマンドごと** / 詳細 | ゲームのログの `[remote_probe]` の行 |
| 速度ボタンの横に表示 | **表示する** / 表示しない | 速度ボタンにない速度と `run` の実行中に、例えば `×16 実測×3.2 →2045-07-03` |

設定の文言と速度の表示は、英語と日本語です (`strings.json`)。ゲームの言語で切り替わり、ほかの言語では英語になります。
ゲームの MOD 一覧に出る名前・概要・説明・表紙は `_metadata/modinfo.json` と `_metadata/0.png` から読まれます。そこは
どの言語でも同じ文が出るので、英語と日本語を両方入れています。

## 安全上の注意

- **`newgame` はゲームの途中からは使えません。** 本体の `StartGame` はゲームが動いていないことを前提にしていて、
  TF3 が落ちました (2026-11-15)。セーブの中で安全なのは `newgame --list` と `--dry-run` だけです (`--unsafe` で送れますが
  落ちます)。新しいゲームは、メインメニューから `restart --new` か `launch --new` で始めます。
- **車両の価格の試験には `--via gui` (既定) を使ってください。** `--via cmd` はエンジンのコマンドだけを送り、
  `purchaseTime` を 0 のままにします。エンジンは補わないので、車両は「ゲームの開始時に買った」扱いになり、値下がり
  しきった残りの価値だけを払います (ある試験で、店の価格 48441 に対して払ったのは 261)。cmd の経路は、`autoLoadConfig`
  を区画ごとに 1 つずつ入れて送る必要もあります。空のまま送るとエンジンのアサーション (`UpdateConfigFromModelIds`) に
  当たり、`pcall` でも止められずにゲームごと落ちました (2026-11-16)。MOD はこれを直してありますが、`buy` と `line`
  の cmd 経路はエンジンの構造を自前で組み立てます。まず小さいセーブで試してください。
- **速度には上限があります。** ゲーム自身の見積もり (`getEstimatedMaximumGameSpeed`。まだ分からなければ 4) までに
  抑えます。それを超えるとシミュレーションが追いつかず、フレームが長くなり、音が途切れました (見積もり x5-6 の
  セーブで x8)。`run` は 2 秒ごとに見積もりを見直します。`--force` で指定どおりに送ります。
- **どのウィンドウもツールとして開けるわけではありません。** 通知の一覧のレシピは、本体のボタンが渡す引数を要する
  ので、ただツールとして積むと nil の呼び出しに当たり、GUI が読み直されました (2026-11-17)。そのため
  `tool notifications` は、代わりに本体のイベント `openNotificationLog` / `closeNotificationLog` を送ります。
  `tool --module` で他のモジュールを指す前に、その本体のボタンが何を渡しているかを確かめてください。
- **`quit --kill` と `restart` は、終わらないゲームを SIGKILL します。** 保存していない進行は失われます
  (`restart --no-kill` で諦める)。別の `--owner` が 10 分以内に変えたゲームは、`--force` が無ければどちらも殺しません。
- **ロードすると、保存していない進行は失われます。** ロードは「ゲーム開始」ボタンを待たずに始まります (本体のロード
  画面はボタンを待つ。`--wait-for-start` でその動きにする)。
- `line delete` は、車両のいる路線を `--sell-vehicles` が無ければ断ります。本体のミッションと保護された entity の
  確認は省いています (試験用のセーブ向けのため)。
- `money` は「その他」の仕訳として帳簿に残り、収支の表やグラフに出ます。
- `buy` は、年代の外のモデルも買えます (店の可否の確認は通しません)。

## ゲーム内で確かめたこと

確認済み (build 40444、2026-11-15〜2026-11-17):

- `status` が答える。一時停止中も答える (速度 0 でも GUI スクリプトは回る)。コマンドファイルを読むだけではログは
  増えず、コマンドごとに 1 行。ESC メニューとゲーム中のロード画面では止まる。
- 速度 8 / 16 / 64 は受け付けるが、中くらいのセーブでは平均 x3 前後で頭打ち (1 秒ごとの最大は x12.7)。CPU 律速。
- `info` の MOD の設定は、MOD プリセットと同じ形。
- `load` (`--param` 付きも。相手の MOD が変えた設定を受け取った) は 33 秒で完了し、ボタン待ちなしで始まった。
  ロードしたゲームは速度 0 で始まる。`save` (2.5 秒)。`run --until` は指定日で止まる。
- メニューの probe を使った `launch` / `restart`。メインメニューからの `newgame` (1900 年、temperate、32x32)。
- `buy --via cmd` と `depots` の返事の形。gui 経路の以前の版は、店の価格で買った。
- `frame`。

まだ確かめていないこと:

- 今の形 (速度ボタンのレシピで動く) の `buy`・`duplicate`・`replace`・`sell` の `--via gui` と、一時停止中にその
  レシピが回るか。
- `money`: ゲーム内で残高が変わるか、仕訳がセーブに残るか。
- 路線のコマンドのうち、最初の試験より先のもの (小さいセーブで `stations`・`stations --near`・`lines` と、停車駅 2 つの
  `line create --via gui` は動いた): `line update`・`line delete`・`--cargo`・`buy --line` と `--via cmd` の経路。まず
  小さいセーブで試してください。詳しくは「実装メモ」。
- `window` と `event` でウィンドウが開くか、速度の表示の位置と見た目、`tool` が `pop` でウィンドウを閉じるか。
- `app.quit` が確認ダイアログなしでゲームを終えるか。

## テスト

```
luajit tests/run.lua                                   # MOD: 純粋な処理と、本物のスクリプトを偽のゲームの上で
python3 -m unittest discover -s tests -p 'test_*.py'   # tf3ctl.py: 偽のゲームと本物のファイルで端から端まで
```

どちらもゲームは要りません。

## メモ

- **交換フォルダ。** `recordings` を最初に使います。本体は `mod_presets` の全ファイルを MOD プリセットとして並べる
  (拡張子で絞らない) ので、そこに置いたファイルがプレイヤーのプリセット一覧に出ました。本体の GUI は `recordings` も
  `keyframes` も一覧にしません (どちらもデバッグ用のカメラツールが使う)。`saveUserdata` はファイルを上書きしないので、
  答えは毎回新しい名前で書き、ツールが古いものを消します。`clean` は probe のファイルを全部消します (ゲームが動いて
  いなければ、今のロードの分も)。
- **返事。** どのコマンドにも、返事は必ず 1 回です。例外: 待っている間にロードや新しいゲームでスクリプトが入れ替わると、
  返事は来ず、ツールの時間切れで終わります。非同期のもの (車両、路線、所持金) は、60 秒でそこまでの内容を返して終わり
  ます (ツールは 90 秒待つ)。`state` は MOD が要りません (ゲームのログとプロセスを読む)。返事のリストは、空でも `[]`
  で書きます。
- **受け取り。** コマンドが拾われず、ゲームが (ログから見て) ゲーム中でなければ、ツールは 3 秒で終了コード 3 を返し、
  コマンドを取り下げます。ESC メニューやダイアログはログに出ないので、30 秒後に「応答なし」になります。
- **`run`** は、日付が 20 秒進まなければ `stalled` で終わります。ツールが途中で抜けたとき (時間切れ、Ctrl-C) は
  速度 0 にします。返事は停止コマンドのコールバックを待ちます (来なければ 2 秒後に `stopConfirmed: false`)。
- **`save`。** 保存のコールバックは成否を返さないので、保存後に一覧に載っていれば `ok` です。`overwrote` は同じ名前の
  セーブがあったかを示します。
- **status。** `modParams` には有効な MOD が全部並ぶ (設定の無いものは `{}`) ので、`--add` / `--remove` が効いたかが
  分かります。有効な MOD の一覧を実行中に読む API はありません。
- **メインメニュー。** mod.io の準備ができる前に React の外からロードや新しいゲームを始めると、本体のメインメニューが
  レシピの本体でダイアログの分岐に入り (`GetApi() must not be called in the recipe itself`)、メニューの UI が読み
  直されました (ロードは続いた。2026-11-16)。そのためメニューの probe は、mod.io の準備を最長 30 秒待ちます
  (`restrictedModeAllowed=false` の間。メニューが出てから 2〜3 秒。または MOD のダウンロード中)。ログには
  `waits: mod.io is not ready` / `waited N s for mod.io` と出ます。待っている間に来た 2 本目のロードや新しいゲームは
  断ります (`still waiting`)。メニューからの新しいゲームの町名は、気候の既定です (temperate と subarctic は欧州)。
  名前のリストは `StartGameParams` にありません。人が手でセーブをロードしたときは、ゲームの時間が読めるようになった
  時点でメニューの probe は止まり、ゲームの中の probe に替わります。
- **`--script`** (2026-11-16 にゲームのバイナリで見つけた) は、リソースのパス (`<mod>::/<file>`) を取ります。ディスクの
  パスや、本体の `_content.json` に載っていないファイルは「not cached」で、ゲームが終わります。`startup.lua` の
  読み込みに失敗しても、ゲームはメニューの probe なしで続きます。
- **`quit`。** probe は返事を書いた次のフレームで `app.quit` を呼びます (保存中なら保存の後)。SIGTERM はゲームの
  終了メニューを開くだけでした (2026-11-16)。`restart` は、ゲームが終わってから 5 秒おいて起動します (直後は Steam が
  まだ動いているとみなすことがある)。ゲームのメインスレッドの名前は「Main Thread」なので、
  `pgrep -x TransportFever3` では見つかりません。ツールはコマンドラインで探します。
- **速度の表示。** 速度ボタンは 0/1/2/4 だけで、それ以外の速度ではどれも選ばれません。MOD は
  `react-replacement-config` で `game_bar_widgets.GameSpeedControl` を差し替え、本体のレシピをそのまま描き
  (`CallOriginalRecipe`)、その横に表示を足します。先に差し替えた MOD (Time Warp、mod.io 6453396 の 8x/16x ボタン)
  があれば、本体のボタンの代わりにそれを描くので両立します。右の欄の幅はどちらも CSS で決めるので、後に読まれた方の
  幅になります。モジュールの表を実行時に入れ替える GW Faster Game Speed とは、どちらかしか効きません。レシピの本体と
  その step では、ゲームの API を呼びません。react はそれらをワーカースレッドでも動かし、そこで
  `api.util.getApplicationTime` を呼ぶと、ロードのたびに TF3 が SIGSEGV で落ちました (2026-11-15)。ゲームの呼び出しは
  メインスレッドで動く `react.enqueueJoin` の中だけです。
- **`frame`** は、Steam のバックグラウンド録画 (`userdata/<id>/gamerecordings/video/bg_3493540_*`) の書き終わった
  最新の断片から、最後のコマを ffmpeg で取り出します。UI 込み、数秒遅れ、録画の解像度で、窓の前面化もキー送信も要り
  ません。録画フォルダは、最後に断片を書いた時刻で選びます (フォルダの mtime ではない。Steam は止まった録画の古い断片を
  消すので、そのフォルダの mtime が新しくなり、81 分前に止まった録画を選んだことがある)。`screenshot`
  (`api.gui.camera.takeScreenshot`) は、試すとファイルができませんでした (写真モード用とみられる)。
- **`window`** は、本体の統計や路線のウィンドウと同じく `react.fireEvent(nil, "selectEntity", {entity})` で開きます。
  イベントは react の中からしか送れないので、GUI スクリプトが依頼を GUI の保存データ (`api.gui.game.setGuiSaveData`、
  ゲームが MOD ごとに C++ で持つ) に書き、速度ボタンのレシピが `react.enqueueJoin` で読みます。両者で共有した Lua の表
  は、レシピに届きませんでした (別の Lua 状態のため)。前のゲームの依頼はロードのときに捨てるので、ロード直後に送った
  依頼は時間切れになることがあります。
- **`event`** は、react のイベント名と、引数として平らな値だけの JSON オブジェクトを取ります。`event` と `tool` の
  返事は「依頼を書いた」までで、ウィンドウが開いたかは `frame` かログで見ます。
- **`tool`** は、本体のボタンと同じく、モジュールのツールをゲームのツールスタックに積みます
  (`gameCtx.toolStack:get():getApi().push(tool, nil, {gameCtx})`)。開けるのはモジュールが返すツールだけです: music
  (`/gui/music_player/music_player.tl`)、calendar (`game_bar_widgets.CalendarEditorTool`)。統計は `statistics.tl`
  の中の local なので開けません。`--module` と `--field` で他のモジュールを指せます。

## 実装メモ

### 車両 (`buy`・`duplicate`・`replace`・`sell`・`depots`・`vehicles`)

- `--via gui` (既定) は、本体の `vehicle_react_util.HandleVehicleChanges` を呼びます (車両の店と複製ボタンが使う)。
  purchaseTime の無い部品に今のゲーム時刻を入れ、autoload を入れてから `makeVehicleBuyCmd` / `ReplaceCmd` /
  `SellCmd` を送ります。部品は本体の `vehicle_util.makePart` で作ります。このモジュールは GUI スクリプトの Lua 状態では
  読めない (`react.RegisterRecipe` が `react.lua:298: table index is nil` で落ちる。2026-11-16) ので、依頼は GUI の
  保存データで速度ボタンのレシピに渡し、レシピが join の中で実行して (`content/vehicle_configs.lua` の `performGui`)、
  自分のキー (`hummer_remote_probe.vehicles`) に報告を書きます。成否はエンジンの状態 (増えた・変わった・消えた車両)
  で決めるので、報告が無くても返事は来ます (`notes` に「no report」)。モジュールが読めなければエラーで、黙って cmd には
  しません。
- このレシピは店のウィンドウの react 状態とは別なので、モジュールのインスタンスが同じかは分かりません。ファイルを
  差し替える MOD や `metadata.cost` を書き換える MOD の変更は届きます。実行時にモジュールの表を書き換える MOD の変更は
  届かないことがあります。
- `--via cmd` はエンジンのコマンドだけを送り、`purchaseTime` は 0 です (「安全上の注意」)。
- 返事: `via`、`balanceBefore` / `balanceAfter` (`getPlayersBalance`、結果から 3 フレーム後に読む)、`spent` (売却は
  負)、`gameTimeBefore` / `gameTimeAfter`、`storeParts` (部品ごとのモデル id・ファイル名、送る前と返事のときの価格と
  priceScale)、`storePriceTotal` (店と同じく部品の price の和 × 台数。price が負でもそのまま、注意付き)、`sentParts`、
  `vehicles` (読み直した部品・purchaseTime・maintenanceState・`partPrice`・路線・車庫・`depreciatedValue`)、`notes`。
  buy と replace は `model`、replace と sell は `before`、duplicate は `source`、buy と duplicate は `vehicleIds` も
  付きます。`--line` を付けると、車両が路線に載るまで待ち、`setLine` を返します。
- `buy` は `--depot` が必須です (店は車庫から開いたときだけ車庫を決める)。台数は 1-20。`--line` の先頭の停車駅は
  0 番。`duplicate` は本体の複製と同じく config を写し、部品を purchaseTime 0・maintenanceState 1 にします。車庫と
  路線の既定は `findBestLineAndDepotForVehicle`。
- gui の `replace` と `sell` は本体がコールバックを取らないので、毎フレーム車両を見ます。replace は、部品が送った
  ものと同じになったか、前と変わったら完了です (`matchesSent` でどちらか分かる)。新しい部品が前と同じときは、推測せず
  `ok: false, uncertain: true` を返します。
- `depots` は自社の車庫だけです (路線管理と同じ `requireOwnedByPlayer`)。位置は返しません (読む API が見つからな
  かった)。種類 (road / tram / rail / water / air) は transport modes から決めます。`carrier` はある試験で 49 件すべて
  OTHER だった (本体も transport modes を見る) ので、`carrier` / `carrierRaw` は参考です。メンテナンス用の建物も出ます
  (`maintenancePool`)。
- レシピが最初に保存データを読んだときに残っていた依頼は、前のゲームの残りとして実行しません。GUI スクリプトも
  ロードのたびに空にします。実行済みの依頼と報告はモジュールの変数に持つので、速度ボタンが描き直されても失いません。
  報告は新しい 10 件だけ残します。
- 未確認: `getPlayersBalance` / `getDepreciatedValue` / `getPartPrice` が GUI 状態で使えるか、`makeVehicleBuyCmd`
  のコールバックの第 1 引数、売却直後に `getComponent` が nil を返すか、`transportModesToCarriers` が GUI 状態で使えるか。

### 所持金

`money --set N` / `--add N` は、本体のサンドボックスの所持金編集と同じく、`api.type.JournalEntry` (amount = 差、
time = -1、category OTHER) を `makeJournalBookAssetCmd` で送ります。所持金が無限 (`getPlayersBalance` が nil) なら
エラーです。金額は整数に丸め、2^53-1 を超えるものは断ります。返事は `balanceBefore` / `balanceAfter`、`amount`、
`callback`。`--set` で、その間に運賃などが入れば `notes` に「set not reached」が付きます (一時停止で使う)。

### 路線 (`stations`・`lines`・`line`)

ゲーム内では全部未確認です。駅を建てるコマンドはありません。

- `stations` は、自社と持ち主のない駅グループを返します (本体の駅の統計と同じ `isOwnedByPlayerOrNotOwned`):
  `id`、`name`、`stations`、`terminals`、`carriers`、`owner`、`lines`、`position` (最初の駅の bounding volume の中心)。
  `--name` は名前の部分一致 (大文字小文字を問わない)。`--near <entity> --radius <m>` (既定 1000 m) は、bounding volume
  を持つ entity からの水平距離で絞り、`distance` を付けます。
- `lines` は自社の路線を返します: 停車駅 (駅グループ、駅とホーム、0 始まり)、車両、乗り物の種類、`customFilters`、
  `loads` (どこかの停車駅で積む貨物)、`vehicleCargo` (路線の車両が積める貨物)。
- `line create --stops A,B,...` は駅グループを順に、id (駅の entity ならそのグループ) か名前で取ります (完全一致を
  先に、なければ一意な部分一致。複数に当たれば候補付きでエラー。カンマを含む名前は id で)。ホームは自動で割り当て
  ます。名前の既定は本体の `makeLineName` (gui) か「Line N」(cmd)。
- `line update <line>` は `--stops` (停車駅の並びを置き換える)・`--name` (`makeEntitySetNameCmd`)・`--cargo` の
  どれかを取ります。同じ駅グループの停車駅は、本体と同じく設定を引き継ぎます。ホームの無い停車駅があるときは、本体と
  同じく全停車駅を割り当て直す (`allowTerminalChanges = true`) ので、元のホームも変わりえます。gui では本体の
  `autoLoadConfig` が積み荷も振り直します (customFilters の路線を除く)。並べ替えだけならホームは変わりません。
  経由点 (waypoint) は消えます。gui でレシピの報告が届かないときは、停車駅が頼んだ並びになり、かつ前と変わったことで
  完了とみなすので、`--cargo` だけの変更や並びが同じ変更は 60 秒で時間切れになります。
- `line delete <line>` は、先に車両を売り (`--sell-vehicles` のときだけ)、売却が成功してから `makeLineDestroyCmd`
  を送ります。
- `--cargo <id か名前>` は、本体の貨物フィルターと同じく、全停車駅でその貨物だけを積む設定にします (その貨物の
  `load` を true、`maxLoad` を 1、`customFilters = true`)。ホームがその種類 (旅客か貨物) の積み降ろしをどちらも扱わない
  停車駅があれば、何も送らずエラーです。`buy --cargo` はありません。本体の店は車両ごとに貨物を選ばず、何を積むかは
  路線の停車駅の設定で決まるためです。
- `--via gui` (既定) は、路線管理と同じく本体の `line_util.tl` で組み立てます (`makeNewStop`、`autoLoadConfig`、
  `autoAssignTerminals`、`makeLineColor`)。車両と同じく速度ボタンのレシピで動き、報告のキーは
  `hummer_remote_probe.lines`。`--via cmd` は `Line.Stop` を自前で組み、ホームを `lineSystem.getBestLineAssignment`
  で決めます (見つからなければ本体と同じく 0/0 にして notes に書く)。積み荷は旅客駅なら旅客、それ以外は `--cargo`
  だけ。待ち時間は、鉄道を含まない道路か路面電車の駅は 30 秒、他は 60 秒。
- 送る前に確かめること (どちらの経路も): 停車駅が 2 つ以上、隣り合う停車駅 (最後と最初も) が同じグループでない、
  どのグループも自社か持ち主なしで駅とホームがある、全停車駅に共通の乗り物の種類がある。組み立てた後、全停車駅の駅と
  ホームが実在すること。どれかに当たれば何も送りません。本体は駅の無いグループに -1 を送りうるが、エンジンの
  アサーションに当たるおそれがあるためです。`load` / `maxLoad` は、本体と同じく貨物の種類ごとに 1 つずつ作ります。
- 返事: `ok`、`action`、`via`、`line`、`name`、`stops`、`vehicles`、`carriers`、`loads`、`customFilters` (読み直した
  値)、`sentStops` / `sentName`、`notes`、`failures`。update は `before`、delete は `removed`・`before`・`soldVehicles`。
  停車駅の並びや名前が頼んだものと違えば `ok` は false です。
- 未確認 (おそれの大きい順): cmd での `Line.Stop` の組み立て (`api.type.Line.Stop.new()` の既定値、`stopConfig` /
  `alternativeTerminals` / `waypoints` に Lua の表を入れてよいか、`api.type.Line.new(line)` で写せるか)、`--cargo` の
  `StopConfig.new(stop.stopConfig)` での写し、エンジンが他の乗り物のホームを割り当てたとき、`makeLineCreateCmd` の
  コールバックの路線の entity、車両のいる路線の削除 (MOD は本体の順、売ってから消す、を守る)、町の entity が `--near`
  用の bounding volume を持つか (持たなければ産業か駅を使う)、使う駅と路線の system が GUI 状態で使えるか、報告のキーに
  書けるか (書けなければログに「line report not written」)。

## ライセンス

MIT。[LICENSE](LICENSE) を見てください。
