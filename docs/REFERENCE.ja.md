# Remote Probe: 命令の参照

[English](REFERENCE.md) · [README](../README.ja.md) · [既知の振る舞いと確認の記録](KNOWN_BEHAVIOR.ja.md) · [AI エージェント向け (英語)](../AGENTS.md)

`tools/tf3ctl.py` と MOD の詳しい参照です。README から中身を変えずに移しました。本文が「安全上の注意」「ゲーム内で
確認したこと」「メモ」を指すときは [KNOWN_BEHAVIOR.ja.md](KNOWN_BEHAVIOR.ja.md) に、ほかの節はこのファイルにあります。

Transport Fever 3 の MOD (`hummer_remote_probe`) と、コマンドラインのツール (`tools/tf3ctl.py`) の組です。ゲームの外の
スクリプトから、動いているゲームを操作できます。速度を UI の上限 4 倍より上げる、指定日まで進めて止める、セーブのロードと
保存 (他の MOD や MOD の設定を変えて)、メインメニューからの新しいゲーム、ウィンドウを開く、車両の売買、路線づくり、
2 つの端の間に線路や道路を引くこと (Track Connector MOD を使う)、ゲームのログを読むこと。

人がキーボードの前にいなくても MOD を確認するために作りました。試験用のセーブを設定を変えてロードし、数か月進めて止め、
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
MOD は速度ボタンのレシピを、同じボタンと ×8 / ×16 のボタンと小さな表示に差し替え、依頼を GUI の保存データでそのレシピに渡します。
そのため、`window`・`event`・`tool` と、車両・路線のコマンドの `--via gui` では、**ゲーム画面に速度ボタンが出ている**
必要があります (出ていなければ、`window`・`event`・`tool` は 10 秒後に `"relayed": false` の、車両・路線は 60 秒後に
「no word from the speed control」のエラーになります)。

メインメニューには、まだゲームのスクリプトがありません。そこで、ゲームを `--script hummer_remote_probe::/startup.lua`
付きで起動すると、同じコマンド処理がメニューで動きます (status・saves・info・load・newgame・poll・quit だけ)。
`tf3ctl.py launch` と `restart` がこれを行います。

## 必要なもの

- Steam 版の Transport Fever 3 (build 40444 で試験)、Linux。
- Windows: 最小限の対応だけで、**Windows の実機では確認していません**。パス・ロック・プロセス一覧 (`tasklist`)・
  コマンドラインは Windows 向けにも組んであるので、`launch`・`status`・読む命令は動くはずです。動かないところは
  issue か pull request で知らせてください。`frame` と `pointer` は Linux だけです: `frame` は Steam の録画を
  Linux の Steam のフォルダ (`~/.local/share/Steam`、`~/.steam/steam`) だけで探し、`pointer` は X11 のイベントを
  送ります。設定ファイルは Windows でも `~/.config/tf3ctl/config.json` です (`%LOCALAPPDATA%` の下ではありません)。
  起動の記録は、Windows では `%LOCALAPPDATA%\tf3ctl` に置きます。
- Python 3.8 以上と、`PATH` 上の `luajit` (ツールは MOD の Lua のファイルを luajit で読みます)。
- 任意: `frame` に `ffmpeg` と Steam のバックグラウンド録画。
- 任意: `connect` に Track Connector MOD (mod.io、modId `ethan_track_connector`、revision 3 / v1.3 に合わせて作成、ゲーム内ではまだ動かしていない)。セーブで
  有効にしておきます。
- Time Warp (mod.io 6453396、modId `mobarzik_faster_game_speed`) とは一緒に使えません。どちらも同じ速度ボタンを
  置き換えるためです。`mod.json` の `incompatibilities` に載せてあるので、両方を有効にするとゲームが警告します。
  それでも両方を有効にした場合は、Time Warp のボタンと横の表示が出て、この MOD の ×8 / ×16 は出ません。

## 導入

1. このリポジトリを、ゲームのローカルの MOD フォルダに clone します (または写します。[README の入れ方](../README.ja.md#入れ方))。例:
   `<Steam>/userdata/<Steam の ID>/3493540/local/mods/hummer_remote_probe_1/` (その中に `mod.json`)。
   mod.io で購読したなら、そこには `tools/` がありません。ツールを GitHub から取り、MOD のフォルダの外に置きます
   (README の入れ方)。下の `tools/` はその写しの中です。
2. ゲームで、セーブに「Remote Probe」を有効にしてロードします。または、ツールでゲームを起動します (下の `launch`)。
3. 答えるか確認します:

```
python3 tools/tf3ctl.py status
```

ゲームのログに `[remote_probe] ready` が出ます。

## 使い方

どのコマンドも JSON のオブジェクトを 1 つ出力します。終了コード: 0 成功、1 ゲームがエラーを返した、2 応答なし・
ツールのエラー・読めない設定ファイル (「設定ファイル」)、3 ゲームが今いる場所では答えられない (メニュー、ロード中、probe のないメインメニュー、終了。
`gameState` が示す)、4 断った (何も送っていない): 動いているゲームはこの `--owner` のものではない (「ゲームを変えるのは起動した owner だけ」)、
試験用セーブかを確認する命令 (`road --ignore-errors`・`lights --off`・`running-costs` の書き込み・`eval --write`) を別のセーブに
送ろうとした、設定ファイルで入れていない命令 (「設定ファイル」)、札が `reads` でない命令への `mod ... --read-only`
(`"refused": "not-read-only"`)。

### 時間と速度

```
python3 tools/tf3ctl.py status                        # 日付、速度、実測の倍率、MOD とその設定
python3 tools/tf3ctl.py speed 8                       # UI の 4 倍を超える (ゲームの見積もりまで)。0 で停止
python3 tools/tf3ctl.py pause
python3 tools/tf3ctl.py calendar-speed                # カレンダーの速度を読む (本体の 0.25x〜4x のスライダー)
python3 tools/tf3ctl.py calendar-speed 0.25           # 変える: 0 (日付が止まる)、0.25、0.5、1、2、4
python3 tools/tf3ctl.py calendar-speed --millis-per-day 8000   # エンジンの値そのものでも
python3 tools/tf3ctl.py run --months 2 --speed 4      # --days N / --until YYYY-MM-DD も。その後は速度 0
python3 tools/tf3ctl.py poll --idle 5 --active 0.5    # コマンドファイルを読む間隔 (次のロードまで)
```

`speed` と `run --speed` は、ゲーム自身の見積もり (`getEstimatedMaximumGameSpeed`、「安全上の注意」) を上限にします。
それより大きい数を指定しても、見積もりの速度になります。見積もりの高さはセーブによって違います。

`status` は `luaLoad` も答えます: `gui` と `gs` のそれぞれに、その Lua の状態で `type()` が読んだ `load`・`loadstring`・
`setfenv` (GUI のもの、ゲームスクリプトのものは設定 `gameScript` が on のときだけ、スクリプトが自分の state に書いたもの。
読んでいないとき (off。前の回がセーブに残した値は出さない・メインメニュー・スクリプトがまだ動いていない) は `"unread"`、
その状態で名前を読むとエラーになったときは `"raised"`)。2026-11-26 に書いた。ゲーム内では未確認。

ゲームの画面では、本体の ⏸ ▶ ▶▶ ▶▶▶ (0/1/2/4) の右に、同じ見た目の ×8 と ×16 のボタンを足します。いまの速度の
ボタンが、本体のボタンと同じように光ります。×8 / ×16 のボタンは、その速度をそのまま指定します。ゲームの見積もりの
上限より上でも止めません (`speed` は上限で止めますが、ボタンはプレイヤーが自分で選ぶものなので)。本体のボタンを
押せば、本体の速度に戻ります。横の表示 (`×8 実測×3.2`) は、本体のボタンにない 8 と 16 でも今までどおり出ます。

`calendar-speed` は、本体のカレンダーの速度のスライダー (「Weather and Time」の窓の「Calendar Speed」の札の、停止・0.25x・0.5x・1x・2x・4x) です。
上のシミュレーションの速度とは別のものです。エンジンは `GAME_SPEED.millisPerDay` として持ちます。カレンダーの
1 日が続くゲーム時間 (ミリ秒) で、0 なら日付が止まります。倍率は、本体のスライダーと同じく
`round(getDefaultDayDuration() / 倍率)` で変えます。0.25 なら 1 日が 4 倍長くなり、車両は同じ速さで走ったまま、
日付がゆっくり進みます。値を付けなければ読むだけで、何も送りません。答えには `calendar` (`millisPerDay`、
`defaultDayMs`、`factor`、スライダーの表示と同じ `text`、スライダーの段のどれかかの `step`、`paused`) と `steps`
が入ります。値を付けると `makeGameSetCalendarSpeedCmd` を送り、ゲームが新しい値になったところで `before`・
`after`・`sent`・`requested` を答えます (エンジンが断ったとき、5 秒のうちに変わらないときはエラー)。倍率は
スライダーの段のどれかだけです。`--millis-per-day` は 0 か、100〜3600000 の整数です。変えるのは `speed` と同じく
ゲームを変える命令に数えます (送り主の検査、共同作業の間は `--user-asked` が要る)。`run` は止めませんが、
カレンダーが 0 だと、日付を目指す run はいつまでも着きません。

### セーブと新しいゲーム

```
python3 tools/tf3ctl.py saves
python3 tools/tf3ctl.py info my-save                  # セーブの MOD と MOD の設定
python3 tools/tf3ctl.py load my-save --param example_mod:difficulty=3 --dry-run   # 計画だけを見る
python3 tools/tf3ctl.py load my-save --param example_mod:difficulty=3 [--add MOD] [--remove MOD] [--set-mods a,b]
python3 tools/tf3ctl.py save my-save-after            # 同じ名前のセーブは上書き
python3 tools/tf3ctl.py newgame --list                # 気候と地形生成器 (ゲーム中でも安全)
python3 tools/tf3ctl.py launch --new --editor --size tiny --no-towns --no-industries   # マップエディタ
```

`--editor` (`newgame` か `launch` / `restart --new` に付ける) は、ゲームの代わりにマップエディタを開きます。
`StartGameParams.isMapEditor = true` で、ほかは新しいゲームと同じ。地図は作ったときの MOD を持つので、MOD は入っている
公式のもの (`ug_*`) と probe だけで、動いているゲームのものは使いません (`--add` / `--remove` は効きます)。設定はそれぞれの
初期値。`status` は `mapEditor` を答えます (`gui`: `api.gui.game.isMapEditor()`、`modParams`: 本体の `isMapEditor`)。
**ゲーム内では未確認** (2026-11-22 に書いたもの): この形でエディタが開くか、エディタの中で probe が答えるか。

新しいゲームの町と産業の置き方は、本体の新しいゲームのページと同じく、本体の設定
(`locations.towns.frequency`・`locations.towns.populationDensity`・`locations.industry.initialIndustryDensity`、
1 始まりの段、初期設定 3) から決めます: `townFrequency`・`populationDensity`・`industryDensity` を本体の
`difficulty_util.getScale` で求めます (初期設定で 0.4・1.0・1.0)。`--param :locations.towns.frequency=5` もメニューと
同じように効きます。`difficulty_util` を読めないときは MOD の中の同じ表の写し (本体のビルド 40444) を使い、答えに
`warnings` を付けます (ツールも表示します)。本体の設定が無いときはメニューの初期設定とみなし、範囲の外の段は本体の
`getScale` と同じく 1.0 (時刻と雲は最初の値) にします。どちらも警告を付けます。始めの時刻と雲は、
メニューと同じく `gameTimeConfig.timeOfDayMode` と `weatherConfig.dynamicWeather` から決め、初期設定では 14 時・晴れ
です (2026-11-23 より前は、いつも 12 時で、密度はエンジンの `Locations.new()` の値のままでした)。`newgame --dry-run`
の計画に出ます: `locations` (`locationsConfig` として送る値)・`startLevels`・`locationsSource` (`difficulty_util` か
`copy`)・`timeOfDaySeconds`・`cloudCoverage`。

本体の会社の成長 (会社のランク・特典・運賃の倍率) は、ゲームが始まったときの町の人口から始まります。始まりの出来事
`initNewGameFromMap` で本体の会社のスクリプトがそれを `basePopulation` に入れ、company_growth はそれが 0 の間は何も
しません。町の人口が無い始まり (`--no-towns`、平らな土台に後から町を置いたもの) では `basePopulation` が 0 のままで、
ランクが無く (左下の会社のボタンが「実績」と出る)、運賃の倍率も無く、`company_growth.script` が運賃のたびにエラーを
出します (companyState が nil のとき)。後から町を置いても変わりません。2026-11-23 の計測: 町を生成した `newgame` のゲームでは何も送らずに
`basePopulation` 793、10 日でランクが出た。`--no-towns` では 0 で、町を置いて 20 日たってもランクは出なかった。新しい
ゲーム (マップエディタでないもの) のあと、ツールが `company init` (下) を送り、その答えを `companyInit` に入れます。始まり
で `basePopulation` が入っていれば何も送らず、町の人口が無ければそう答えます (`noPopulation`: 町を置いてから
`company init`)。`--no-company-init` で送りません。失敗しても警告だけで、ゲームは始まったままです。

```
python3 tools/tf3ctl.py company                       # 読むだけ: 本体の会社の成長の状態と、足りないもの
python3 tools/tf3ctl.py company init [--dry-run] [--force]   # 試験用のセーブ向け: 始まりの出来事をもう一度送る
```

- `company` は `::/game_mechanics/company/company.gs` の状態 (`basePopulation`・`version`・`companies`) と
  `company_progression.gs` の状態 (`growth.initialized`、プレイヤーの `level`・`potentialLevel`・`experience`・
  `ticketPriceMultiplier`)、本体の数え方の今の町の人口 (`worldPopulation`)、`rankButton` (`rank` か `achievements`:
  会社のボタンに出るもの。経験が 0 より多い記録があるときだけランク)、1 行の `diagnosis` を答えます。
- `company init` は、`company.gs` に `basePopulation` が無いとき、または 0 で今の町に人口があるときに
  `api.cmd.makeScriptingSendEventCmd("", "", "initNewGameFromMap", {})` を送ります。`--force` はいつでも送ります。
  それ以外は送らずに理由を答えます (`reason`。`alreadyInitialized`、両方 0 なら `noPopulation`)。送ったあとは、出来事が
  動いたと分かる読み (`basePopulation` が新しく入る、または company_growth のプレイヤーの記録が空になる) を最長 15 秒
  待ち、`before`・`after`、`expectedBasePopulation` (町の人口)、`basePopulationMatches` (差が 10 % 以内) を答えます。
  会社のレベルは company_growth が自分の update で作るので、数日進めてから `company` で見ます (`growth.initialized` が
  true、`growth.player.level`、`rankButton` が `rank`)。答えの `check` にもそう出ます (`basePopulationMatches` は、
  出来事が今の町を数えたことしか示しません)。置いたばかりの町では `basePopulation` が小さく決まり、ランクが早く
  上がります。マップエディタとミッションでは断ります。
- 本体ではこの出来事で会社の成長と町の評価の控え・補助金・通知も初めからになり、ゲームの速度が 1 になり (本体の新しい
  ゲームの始まりと同じ)、ようこその印も立ちます。ほかの MOD のスクリプトも受けることがあるので、試験用のセーブで
  使います (読み込んでいるセーブを tf3ctl は確認しません)。待ちきれずに終わった送信のあとは、`--force` なしの次の送信を断ります (その出来事があとで動くことがあり、
  二度目で会社の成長がまた初めからになるため)。
- **ゲーム内では未確認** (2026-11-23 に書いたもの): 送った出来事がスクリプトに届くか (スクリプトは出来事の名前で
  受け取りを登録し、本体のどれもこの名前を登録していない)、止めているときにも処理されるか。

`--param mod:key=index` の index は、その MOD の `mod.json` にある設定の `values` の 1 始まりの番号です (MOD
プリセットと同じ形)。本体の設定は `:key=index`。この MOD は常に有効のまま残ります (外すと誰も答えなくなるため)。

### ゲームの起動・終了・再起動

```
python3 tools/tf3ctl.py launch [--load SAVE | --new ...]   # ゲームが動いていないとき
python3 tools/tf3ctl.py restart --load my-save [--param ...]
python3 tools/tf3ctl.py restart --new --year 1900 --size small --add example_mod
python3 tools/tf3ctl.py restart --lang de --load my-save   # この起動だけドイツ語で (launch にも --lang)
python3 tools/tf3ctl.py quit [--kill]
python3 tools/tf3ctl.py state                         # in_game / menu / loading / main_menu / starting / closed / crashed
python3 tools/tf3ctl.py restore-profile               # --lang の控えから profile.lua を今戻す
```

`launch` は `steam -applaunch 3493540 --script hummer_remote_probe::/startup.lua` を実行し、probe がメインメニューで
答えるまで待ってから、そこでセーブをロードするか新しいゲームを始めます。`restart` は先に終了し、終わらなければ既定で
SIGKILL します (`--no-kill` で諦める。「安全上の注意」)。新しいゲームの指定: `--climate` (既定 temperate)、`--size`
(tiny 16x16、small 32x32 (既定)、medium 44x44、large 56x56、veryLarge 64x64、または WxH)、`--year` (既定 1900)、
`--seed`、`--generator` (既定: 本体の新規ゲーム画面と同じ選び方の先頭)、`--no-towns`、`--no-industries`、MOD の指定は
`load` と同じ。メインメニューには「今のゲーム」が無いので、MOD はこの MOD と `--add` / `--set-mods` で指定したものに
なります。ack の plan で確認してください。
新しいゲームは、本体のチュートリアルをオフにして始めます (`:guideSystemConfig.tutorial=1`)。進める人がいないためです。
`--tutorial` を付けると本体の既定 (オン) のまま、`--param :guideSystemConfig.tutorial=N` を明示すればそれが優先です。
`newgame` コマンドも同じです。

`--lang CODE` は、ゲームを別の言語で起動します (`de`、`en`、`ja` など。`pt_BR`、`zh_CN`、`zh_TW` も。インストールの
`base/strings` に無いコードは断ります。インストールが見つからないときは、本体の13言語に無いコードを断ります)。例えば、
MOD の文が英語に落ちるかを見るためです。ゲームは言語を `profile.lua` (`language = { code = "ja", ... }`。userdata の
`local` フォルダの `settings.lua` の隣) からだけ読み、起動の引数で変える方法は見つかりませんでした。そこで、ゲームが
動いていないあいだに、`profile.lua` を隣の `profile.lua.tf3ctl-backup` へ写し (その控えが無いときだけ。最初の控えが
元の値)、そのコードだけを変えます。戻すときもコードだけです。いまのファイルのコードを控えにある元のコードに置き換え、
ファイルがそのコードになったら控えを消します。ゲームは動いているあいだに `profile.lua` を書き直すので、そのあいだに
ゲームやプレイヤーが変えたもの (最後のゲーム、ほかの設定) は、控えが何日も残ったあとでも消えません。戻すのは、`quit`
でゲームが終わったあと、次の `launch` / `restart` の前 (落ちたゲームは控えを残します。`--lang` が無ければ、その起動は
元の言語)、`restore-profile` のときです。ゲームが動いているあいだは触りません。ファイルか控えに `language = {` の
ブロックがちょうど1つでないとき、また戻したコードが合わないときは、控えを残してエラーにします。控えがあるあいだは、
`state` と `status` に `profileBackup` が出ます。控えを取る・書き換える・戻すは `profile.lua.tf3ctl-lock` (ファイルの
隣に残ります) のロックの中で行うので、2つの tf3ctl が同時に動いても、書き換えたファイルを元として控えることはありません。
`restart` が quit のあとで戻す・書き換えるのに失敗したときは、`quit` と同じく quit の結果と `profileError` を出して
終了コード 1 になります (ゲームは止まったままです)。別のツールが `profile.lua` の写しを持つなら、`TF3CTL_OTHER_BACKUPS`
にその場所を書いてください。それがあるあいだは (フォルダは中にファイルがあるときだけ) `--lang` も戻すことも断るので、
写しは作ったのと逆の順で戻ります。扱っていないこと: tf3ctl を通らずにゲームが終わったあと (落ちた、ゲームのメニュー
から終えた) に Steam から起動すると、`--lang` の言語のまま始まります。次の tf3ctl の `launch` / `restart` / `quit`
か `restore-profile` で戻ります。

### ゲームを見る

ゲームは起動のたびに `crash_dump/stdout.txt` を書き直すので、前の回のログ (落ちた・kill した・終えた) は、次に起動すると
消えます。そこで `launch` と `restart` は、起動の前にそれを `crash_dump/logs/stdout-<ログの時刻 (UTC)>.txt` へ写し、
新しい 20 個を残します (返事の `launch.keptLog`)。Steam から手で起動するときは写されないので、その前に `keep-log`
を実行してください。

```
python3 tools/tf3ctl.py log --grep remote_probe --tail 40   # ゲームの stdout.txt
python3 tools/tf3ctl.py keep-log [--list]                   # stdout.txt を今 crash_dump/logs へ写す。写しの一覧
python3 tools/tf3ctl.py clean                               # 交換フォルダから probe のファイルを消す (答え: removed、gameState)
python3 tools/tf3ctl.py entities --kind town --grep ems     # ID と名前: town・line・vehicle・station・industry・warehouse
python3 tools/tf3ctl.py entities --kind warehouse           # 読むだけ: WAREHOUSE の entity ごとに construction・stockList・stocks・capacity
python3 tools/tf3ctl.py industry-workers [--entity 51]      # 読むだけ: 定員・そこを行き先にする住民の数・直近の到着 (workers のスクリプト)・生産性・最寄りの町
python3 tools/tf3ctl.py industry-stocks [--entity 51] [--grep mine] [--all-params]  # 読むだけ: 在庫の口 (貨物・上限・量)・rules (ブースター)・生産性・construction の .con と params (hummer_aom_upg_*。--all-params は --entity と一緒に)
python3 tools/tf3ctl.py window --town Emsworth --focus      # そのウィンドウを開き、カメラを寄せる (--close-all)
python3 tools/tf3ctl.py window --line "Bus 1" --manager    # その路線を路線管理で開く (路線の窓の「路線管理」ボタンと同じ)
python3 tools/tf3ctl.py frame --out shot.png [--crop 1150x170+2690+1450]   # UI 込みの画面 (Steam の録画から)
python3 tools/tf3ctl.py tool music [--close]                # ツールとして開く本体のウィンドウ: music・calendar・notifications
python3 tools/tf3ctl.py event example_window.show --param '{"page": 2}'   # 任意の react イベントを送る
python3 tools/tf3ctl.py script-event example_mod.apply --id example_mod --param '{"step": 2}'   # ゲームスクリプトのイベントを、MOD のボタンと同じように送る
python3 tools/tf3ctl.py rename "Chesham" --entity 48064   # 駅・路線・車両・車庫の名前を、ゲームの窓と同じように変える
python3 tools/tf3ctl.py camera                              # x・y・distance・angle・pitch・heightAboveTerrain
python3 tools/tf3ctl.py camera --set 1200,-800,600         # x,y[,distance[,angle[,pitch]]]。渡さない値は今のまま
python3 tools/tf3ctl.py camera --entity 12345              # または --focus x,y,z [--distance d]
python3 tools/tf3ctl.py build-tool --res depots/road/road_depot/road_depot.con [--template N] [--seconds 60]   # (--close)
python3 tools/tf3ctl.py build-tool --menu rail [--res ...]   # 先にツールバーと同じメニューのイベント (road・rail・water など)
python3 tools/tf3ctl.py pointer 0.5,0.47 [--px]          # ゲームの中のポインタだけを動かす。窓の中の割合で指定
```

`camera` の返事は、動かした後に読み直した値です。数は先に確認します。NaN・無限大・1e6 を超える中心・1〜1e5 の外の
距離・±2π を超える angle・±π/2 を超える pitch は断ります。`--entity` は entity があるかを確認します。メインメニューでは断ります。

**フリーカメラ** (`camera --free`・`--eye` / `--look`・`--mouse`。ゲームではまだ確認していません)。ふだんのカメラが行かない所、
たとえば地面の下のトンネルの中を見るためのものです。

```
python3 tools/tf3ctl.py camera --free on                                  # 本体の目のボタンと同じ。そのツールをツールのスタックに積む
python3 tools/tf3ctl.py camera --free on --eye 1200,-800,-12 --look 1260,-800,-14   # 切り替えてから目を置く
python3 tools/tf3ctl.py camera --eye 1200,-800,-12 --look 1260,-800,-14 --method focus  # 目だけを動かす
python3 tools/tf3ctl.py camera --free off                                 # ふだんのカメラに戻す
```

- `--free on|off` は速度ボタン経由です (ツールのスタックはそこにしかありません)。本体の目のボタンと ESC と同じく、本体の
  `free_cam_options.FreeCamTool` を積む・外します。もう有効なとき (そのツールが一番上) の 2 回目の `on` は何も積みません。
  `--via toggle` は代わりに `api.gui.camera.toggleFreeCamera()` だけを呼びます。このときの状態は probe の見込みで、
  見込みの上ですでにそうなっている切り替えは送りません。
- 目を置く API はありません。`--eye` と `--look` を、中心 (見る点)・距離・angle・pitch に直し、`--method data`
  (`setCameraData`。高さなし)・`focus` (`focusPosition`。高さあり)・`both` (既定。前者のあと後者) で送ります。ゲームが angle と
  pitch をどちら向きに取るかは分からないので、返事で目を読み直します: `camera.eye` (`getEye`)・`camera.center` (`getCenter`)・
  `eyeOff` (頼んだ目と読んだ目の距離)。カメラはすぐ (`cameraAtOnce`) と 0.3 秒後 (`camera`) に読みます。
- 返事の `freeCam`: `on`、`source` (ツールのスタックの一番上を読めたら `toolStack`、ほかは `estimated`)、`action` (`pushed`・
  `popped`・`toggled`・`none`)、`activeBefore` / `activeAfter`。フリーカメラが有効かを読む API はありません。引数の無い
  `camera` は、最後の見込みを `camera.freeCam` に返します。積む・外すの直後に読んだスタックがそれと食い違うとき (スタックが
  1 フレーム遅れて反映するかもしれない) は、`source` を `estimated` にし、読んだ値を `stackNote` に書きます。
- 2 つのやり方を混ぜないでください: toggle はツールをスタックに積まないので、あとの `--free off` (ツール) は外す物が無く、
  toggle で入れたフリーカメラは ESC で抜けられないかもしれません (確認していません)。見込みが無いとき (読み込みのあと一度も
  送っていない) の `--free off --via toggle` は、フリーカメラを入れてしまうかもしれないので断ります。
- 共同作業の間は、`--mouse attach` の前にユーザーと決めてください (ユーザーのマウスをフリーカメラに取ります)。
- `--mouse attach|detach`: `isFreeCameraMouseAttached` が違うと言うときだけ `toggleFreeCameraMouseAttachment` を呼びます。
- 柵は `camera --set` と同じです (ゲームを変える側。共同作業の間も通る)。`--set`・`--entity`・`--focus`・`--distance` とは
  一緒に使えません。メインメニューでは断ります。速度ボタンが画面に無いと、`--free` は動かず (10 秒後に返事)、目も置きません。
- ゲームではまだ確認していないこと: この方法で目が地面の下に入れるか、`setCameraData` / `focusPosition` がフリーカメラの目を
  動かすか、angle と pitch の符号。

`build-tool` は、建設メニューの 1 つの建物の配置ツールを開きます。本体のイベント 2 つを、速度ボタン経由で順に送ります
(次を送る前にメニューが開くよう、1.5 秒あけます)。まず `setMenuFilter` にその建物のタグ
(`resName`、`--template` 付きなら `resName@N`) を送ってメニューにそれだけを出し、次に `constructionMenuSelectTabForConstruction`
でタブを開き、最初の品目を選ばせます。戻し方:

- `--seconds` 秒後 (既定 60、上限 600) に MOD 自身がフィルタを空に戻します。tf3ctl が途中で死んでも、メニューが 1 つの建物のままにはなりません。
- `build-tool --close` ですぐ戻します。
- ゲームのロードや終了でも戻ります (フィルタは GUI の状態で、セーブに残りません)。

resName は実在する必要があります (`api.res.constructionRep`)。その年に使えない建物は一覧に出ません。MODULES のタブ (dynamic) は
対象外です。

**ゲームで試した結果 (2026-11-18): フィルタと選択のイベントだけでは配置ツールが開きませんでした** (道路の車庫。ログには
建設メニューの項目が見つからないと出て、絞り込んだメニューは空でした)。開いたのはツールバーと同じイベントです。`--menu rail` は
`openRail` を送ります (鉄道のボタンと同じ)。鉄道メニューが開き、最初の品目の駅舎がそのまま配置ツールになります。`--menu` だけなら
このイベントだけを送り、戻すフィルタはありません。`--res` も渡すと、1.5 秒ずつあけてフィルタと選択が続きます。それで指定の建物が
選ばれるかは、まだ確認していません。

配置の予告とツールチップは、マウスの下に建設案ができたときだけ出ます。なので、ゲームのポインタが 3D の画面の上にある必要があります。
`pointer FX,FY` で、人の手なしにそこへ置けます。設定ファイルに `"pointer": true` が無いと使えません (断って終了コード 4、
「設定ファイル」を参照)。Linux (X11) だけです。ゲームの窓に X11 の合成イベント `EnterNotify` と `MotionNotify` を送ります
(ctypes で libX11 を使います。TF3 は XWayland で動いています)。ゲームの中のポインタと予告は動き、本物のポインタは動きません。
ボタンやキーのイベントは決して送りません。表紙の撮り方: `camera --set` で場所を写し、`build-tool --menu rail`、`pointer 0.5,0.47`、
`frame`。メニューは、セーブを読み直して (保存せずに) 片付けます。会社のお金が 0 だと、ツールチップはコストの代わりに資金不足と出ます。

このイベントは `window`・`event`・`tool` と同じ列に入るので (下の `event` を参照)、上書きはされません。ただし 1.5 秒の間に
それらを送ると、`build-tool` のイベントの間に割り込み、メニューを閉じることがあります。`build-tool` が済んでから送ってください。

### 車両・所持金・路線

```
python3 tools/tf3ctl.py depots [--grep bus]
python3 tools/tf3ctl.py vehicles [--line 21]
python3 tools/tf3ctl.py vehicles --entity 601,602 --state [--since 120000]
python3 tools/tf3ctl.py vehicles --entity 601 --state --at-terminal --every 2 --count 300   # gameTime 付きの JSON Lines
python3 tools/tf3ctl.py persons --vehicle 601 [--limit 200] [--every 5 --count 120]   # または --line 21
python3 tools/tf3ctl.py models [--grep trillium] [--carrier water] [--limit 200]
python3 tools/tf3ctl.py models --mu [shinkansen]   # 読むだけ: 編成 (.mu.lua) の一覧と buy に渡す名前
python3 tools/tf3ctl.py buy --model bus_1900 --depot 301 [--line 21] [--count 2] [--via gui|cmd]
python3 tools/tf3ctl.py buy --model shinkansen_0s.mu.lua --depot 302 [--line 21] [--count 2]   # 編成 (multiple unit)
python3 tools/tf3ctl.py duplicate --vehicle 601 [--depot D] [--line L]
python3 tools/tf3ctl.py replace --vehicle 601 --model bus_1920
python3 tools/tf3ctl.py sell --vehicle 601
python3 tools/tf3ctl.py money --set 10000000 | --add -5000
python3 tools/tf3ctl.py stations [--name cent] [--near 11 --radius 800]
python3 tools/tf3ctl.py stations --catchment 47   # 駅 (かグループ) の範囲: 町の建物、産業
python3 tools/tf3ctl.py stations --catchment 47 --paths 5   # となぜか: 円、近い家、歩き
python3 tools/tf3ctl.py lines [--name probe]
python3 tools/tf3ctl.py lines --problems [--line 23]   # 経路の問題、ホームの transportModes、路線の mode の和
python3 tools/tf3ctl.py line create --stops Central,42 [--name "[probe] A"] [--cargo coal] [--via gui|cmd]
python3 tools/tf3ctl.py line update 21 [--stops 41,42,43] [--name N] [--cargo C]
python3 tools/tf3ctl.py line create --stops 47,48 --terminals 0:2,0:1 [--load-mode all,available]
python3 tools/tf3ctl.py line update 23 [--terminals 0:2,0:1] [--load-mode any]
python3 tools/tf3ctl.py line update 23 --force-unload 0,1   # 停車駅ごと: 合う入力の在庫が満杯でも降ろす
python3 tools/tf3ctl.py line delete 21 [--sell-vehicles]
```

車両の返事には、前後の残高、払った額、部品ごとの店の価格 (`metadata.cost`。送る前と返事のときに読む)、部品ごとの
`purchaseTime`、車両の残存価値が入ります。車両の価格を変える MOD を確認するのに足ります。一時停止して使ってください。
そうしないと、運賃や維持費も差に入ります (ゲームの時間が動いたら `warning` が付きます)。

### 2 つの端の間の線路と道路 (`connect`)

```
python3 tools/tf3ctl.py connect --from 5123 --to Harbour                 # 経路を計画して試算するだけ。何も建てない
python3 tools/tf3ctl.py connect --from 5123 --to 5200 --build            # 建てる
python3 tools/tf3ctl.py connect --from 801 --to 802 --road [--template ::/infrastructure/street/country/country_old_medium.street_template]
python3 tools/tf3ctl.py connect --from A --to B [--track standard|high_speed|simple|<template> --electric]
    [--slope 3 --radius 250] [--no-bridges] [--no-tunnels] [--build [--clear]] [--timeout 300]
```

`connect` には Track Connector MOD (mod.io) が要り、セーブで有効にしておきます (その
ゲームスクリプトは、MOD を有効にしてセーブをロードしたときに加わります)。probe はその MOD の planner と proposal の
モジュールを実行時に読み込み、そのツールが送るのと同じイベントをゲームスクリプトに送ります。その MOD のファイルはここには
含みません。それ以外 (端を探す、planner が使う地図、planner の結果をゲームスクリプトが受け取る経路の形にする、結果を読む)
は probe 自身のコードで、それらのモジュールの関数と、ゲームスクリプトのイベントと状態に合わせて書いています。MOD が無ければ
`connect` はそう書いたエラーを返し、他のコマンドは今までどおり動きます。

- 端 (`--from`、`--to`): 空いている端の node の id (線路の piece がちょうど 1 本で道路が無い node。`--road` なら道路の
  piece が 1 本で線路が無い node)。または駅グループ、駅、駅の construction (id か、駅グループの名前の一部)。駅は、その
  ホームの空いている端の集まりとして扱い、互いにいちばん向き合う端の組を使います。車庫の entity id (`depots` が並べるもの)
  は、その construction の空いている端 (`getConstructionEntityForDepot`。凍結の node は除く) の集まりです。1 つならそれを
  使い、2 つ以上なら候補を並べて断り (node を1つ指定する)、無ければ断ります (線路がもう本線につながっているかもしれない:
  `depots` の `joinedEnds`)。
- 既定値は Track Connector の設定の既定値と同じです: 線路は 2.5 % と半径 300 m、道路は 6 % と 100 m (道路の種類に造れる最大の勾配が
  書いてあれば、それより急な指定はその値に下げる)。橋とトンネルは使える。`--template` の無い道路は、Track Connector の道路ツールと同じく、始点の道路の種類と
  車線をそのまま使います。ただし、その種類が construction の入口の道 (`street/constructions/`。産業、駅、車庫が持つもので、
  プレイヤーの道路のメニューには無い) か、ゲームの年に建てられない種類 (その `availability`) なら、本体の中と小の田舎道
  (新、旧の順) のうち、その年に建てられる最初のものを、始点の道路の車線は写さずに使い、notes にそう書きます。
- `--template` で渡した道路の種類が、そういう入口の道か、ゲームの年に建てられない種類なら、何も送る前に断ります。線路の
  種類が年代の外のときは notes に書くだけです (スクリプトから建てるときにゲームが断るかは未確認)。返事にはゲームの `year` が入ります。
- `--build` なしの返事は、計画と試算です: `route` (`points`、`pieces`、`pieceKinds`、`length`、`straight`、`bridge`、
  `tunnel` (m)、`steepestPercent`、`maxCut`、`maxFill`)、`plan` (秒、フレーム数、いちばん長いフレーム、探索の手数、地図の
  読み取りで見つけたもの)、`preview` (Track Connector の判定: `ok`、`short`、`summary`)、`estimate` (`cost`、`errors`、
  `problem`、`blockers`。町の建物をどかせば建つときは `clear`、`clearCost`、`clearCount`)、`buildable`、送った
  `settings`、`from` / `to` (node、位置、駅の空いている端)。`ok` は `buildable` と同じで、建たない理由は `error` に入ります。
  費用の無い拒否 (ゲームの「建設不可」で $0) は、ゲームが値段をつける前に経路を断ったということです。notes にそう書き、
  Track Connector が数秒後に、断られた piece をログに出します。
- `--build` では、試算が通るとき (または `--clear` で、じゃまな町の建物をどかせるとき) に、Track Connector の
  ゲームスクリプトが建てます。`build` には Track Connector の結果 (`tc`)、`balanceBefore`、`balanceAfter`、`spent` (残高の
  差。建てた後で別の MOD が上乗せした費用も入る)、`estimatedCost`、`beyondEstimate`、`newEdges` / `newNodes` (建てる前には
  無かった、経路沿いの piece と node)、`joined` (両端に新しい piece がつながったか) が入ります。会社が払えない建設は
  Track Connector が断ります。一時停止して使ってください。そうしないと運賃や維持費も `spent` に入ります (`warning`)。
- まず経路沿いの土地を読み (1 フレームに数ブロックずつ)、それから経路を計画します。合わせて数秒から数分かかります。ツールは進み具合を stderr に出し、`--timeout` (既定 120 秒) に 30 秒を足しただけ
  待ちます。`connect` は一度に 1 つだけです。
- Track Connector の状態は全員で 1 つです。`connect` の最中にプレイヤーがそのツールを使うと (逆も)、選んだ端と経路を
  上書きします。`connect` は建てる前と後に、状態が自分の端と経路のままかを確認し、違えばエラーで終わります。送った設定はその状態に残り、
  Track Connector の線路ツールは次にそこから始まります (道路ツールは state の設定を読みません)。
- 後でセーブから Track Connector を外すとき: その `severityRemove` は Warning です。建てたものは本体の種類の普通の線路や
  道路なので残ります (`--track` / `--template` で別の MOD の種類を使ったら、その MOD が要ります)。Track Connector の
  ゲームスクリプトの状態はセーブに残ります。

### 建物を1つ地図に置く (`build`)

```
python3 tools/tf3ctl.py build --res road_bridge_ramp::/road_bridge_ramp/ramp.con --at 1200,800        # 地形の上に
python3 tools/tf3ctl.py build --res road_bridge_ramp::/road_bridge_ramp/ramp.con --at=-300,450,82 --angle 1.5708 \
    --params '{"rbr_height": 8, "rbr_length": 120}' [--name "Ramp A"] [--seed 3] [--dry-run]
python3 tools/tf3ctl.py build --remove 51234[,51240]      # プローブが建てたものを取り除く
python3 tools/tf3ctl.py build --remove-all                # この読み込みのあとに建てたもの全部
python3 tools/tf3ctl.py build --res <resName> --at 2600,3400,20 --dry-run --engine-check --collision-detail   # ProposalData を丸ごと
```

**試験用のセーブで使います** (セーブは確認しません)。`build` は建物 (`.con`: 車庫、駅、アセット、産業、別の MOD の建物) を1つ、クリックも
キーも使わずに置きます。`ConstructionEntity` を1つ入れた `SimpleProposal` を、プローブの GUI スクリプトから
`api.cmd.makeWorldBuildProposalCmd` でエンジンに送ります (MOD が自分のツールで建てるのと同じ道)。エンジンはプレイヤーが
建てるときと同じく調べます (衝突・地形・所持金)。断られた建物は建ちません (`ignoreErrors` は切ってあります)。
プレイヤーや町のものを壊して建てることはしません。

- `--res`: 建物のリソース名。MOD の `content/<dir>/x.con.lua` は `<modId>::/<dir>/x.con`、本体のものは `::/` で始まります
  (`depots/...con.lua` は `::/depots/...con` としても探します)。ゲームが知らない名前は何も送らずに断り、似た名前
  (同じファイル名か、同じ MOD のもの) を 12 個まで挙げます。
- `--at x,y[,z]` はメートル (x が負なら `--at=-300,450`)。z が無ければ、そこの地形の高さ
  (`api.engine.terrain.getHeightAt`) を使います。そのあとは建物自身の地形合わせで、プレイヤーが置くときと同じく地面を
  均したり削ったりします。水の下では、その高さは水面でなく水底です。**水の上の建物 (造船所・港) には z を渡してください。**
  `--angle` は鉛直軸まわりのラジアン。
- `--params`: 建物の初期設定の値 (各 param の `numbers[defaultIndex]`、本体の建設メニューの始めの値と同じ) に重ねる
  JSON オブジェクト。値は param の値そのもので、一覧の index ではありません。`numbers` のある param はその数のどれか
  (8 m なら `"rbr_height": 8`)、`numbers` の無い param は index を渡します (それがその値です)。`seed` は指定が無ければ 1
  (`--seed` か `--params` で変えられる) なので、同じ置き方は毎回同じ見た目になります。プローブは params に印
  `remote_probe_build = 1` を足します (`--remove` を参照)。建物の updateFn はこのキーを知らないので、使いません。
- 答え: `entity` (できた建物)、`construction` (`fileName`、`name`、`depots`、`stations`、`industries`、`stockLists`: その下の在庫の一覧
  (`entity`・`kind`・`stockList`。倉庫なら WAREHOUSE を持つ subconstruction)、`ends`: 建物自身の
  道路・線路の空いた端と位置。`connect --from` の候補。`connectable`: `road` でつなげる所。`road` を参照)、`cost` (エンジンの値)、`balanceBefore` / `balanceAfter` /
  `spent`、`errors`、`warnings`、`collisions` (邪魔をしている id)、送った `params`、`at` (使った z と `zFrom`)。断られた
  ときは `ok: false` で、エンジンの文言が `error` に入ります。
- 断られた理由 (`build` と `road`。建てるときも、dry-run の engine-check も): エンジンの `errorState.messages`
  (ProposalData、`type.d.tl`)、無ければ `infos` か `warnings` (その名前を付けて)、どれも無ければ `no message (...)` と、
  読んだ欄を `errorStateRead` に書きます (例 `resultProposalData.errorState: critical true, messages 0, warnings 0,
  infos 0`、`errorState: none`)。文言の無いまま断られた build と road は、同じ proposal をもう一度エンジンに聞き
  (`makeProposalData`、2つの context。何も送らない)、その文言を使います (`recheck`。そちらが建てられると言ったときは
  `recheckNote`)。さらに tf3ctl が、命令の間にゲームのログに出た `ProposalData error: ...` の行 (Simulation Thread が書く) を
  `proposalLog` に足し、答えに文言が無かったときは、その文を `error` に入れます (`errorFrom: "game log"`)。2026-11-23 の
  計測: 地図の端の水の上に置いた建造物は、コールバックに文言が無いまま断られ、ログには `ProposalData error: 陸上に配置`
  が出ていました。衝突 (`衝突`) は文言つきで返っていました。同じ秒にほかの MOD の proposal が行を書くこともあります
  (`proposalLogNote`)。
- `--dry-run --engine-check` は、建てるときと同じ提案をエンジンに聞き、何も建てません (`makeProposalData`。`road` と
  同じ。ゲームを変える側に数えます)。`buildable`・`verdict`・`errors`・`collisions` と `hits`・`cost`、それに `footprint`:
  その場所で建造物が占める箱 (エンジンの `toAddData` の bounding volume から点を引いたもの: `x0`・`y0`・`x1`・`y1`・
  `height`。世界の軸にそろった箱) を返します。`fit` はこの箱を使います。
- `--dry-run --engine-check` は、エンジンに2つの context で聞きます: proposal だけ (エンジン自身の context。GUI の
  スレッドで動くと分かっている形) と、build と同じ Context (player、`gatherFields`、`gatherBuildings`、`cleanupStreetGraph`
  を build が送るとおりに) を付けた形です。判定は build の context のものを使い、エンジン自身の context だけが断ったときは
  そちら (厳しいほう) を使います。`engineCheck` は使った形、`engineContexts` に両方 (`own`・`build`。それぞれ `verdict`・
  `critical`・`errors`・`warnings`・`infos`・`collisions` の数・`cost`、その形がエラーになったときは `raised`)、食い違ったときは
  `contextsDisagree: true` と `contextsNote` が付きます。わけ: エンジン自身の context は、build が衝突した畑を取り除く扱いに
  し、build が断られた水の上を建てられると答えました (2026-11-23)。Context の形が GUI のスレッドで build と同じに判定するかは
  **ゲーム内では未確認**です。その形がエラーになるときは、前と同じくエンジン自身の context の判定です (`engineContext`、`caution`)。
- `--dry-run --engine-check` (`build` と `road`。`fit` の候補の確認も) は、`critical` が立たずに `errorState.infos` だけが
  あるときも断りとして扱います: `buildable: false`、`verdict: "refused"`、`infosRefusal: true` で、`error` に infos の文と
  `(errorState.infos, critical not set: ...)` が入ります。`critical` はエンジンが立てていないので付きません。文言ではなく欄で決めます
  (文言はゲームの言語で変わるため)。2026-11-23 の計測: 水の上に置いた道路の車庫は、2つの context とも `critical false`
  で、infos に `陸上に配置`、collisions 6 でしたが、本番の build は断られました (その `errorState` も同じ。ログに
  `ProposalData error: 陸上に配置`)。前の回では `海岸線に配置` も同じでした。建てられるのに infos が付く例はまだ見ていません。
  もし出たら、建てられる所を断ると答えることになります。`fit` は、確認の答えが buildable でも infos があれば (前の版の
  MOD の答え)、その場所を採りません。
- `critical` が立たずに `errorState.messages` (確認の答えの `errors`) があるときも、同じく断りとして扱います:
  `buildable: false`、`verdict: "refused"`、`errorsRefusal: true` で、`error` にその文と
  `(errorState.messages, critical not set: ...)` が入ります。`critical` は付きません。わけ: build は ignoreErrors なしで
  送られ (`road --ignore-errors` のほかは全部)、エンジンが critical でないエラーを越えて建てるのは、それがあるときだけです。
  2026-11-26 の計測: 道路の node と直前に建てた道路に重なる道路の車庫は、確認で `critical false`、messages に `衝突` で、
  本番の build は2回とも `衝突` で断られました。この版の前は、確認も `fit` も、そこを `buildable` と答えていました。`fit` は、
  確認の答えが buildable でも messages があれば (前の版の MOD の答え)、その場所を採りません。このため
  `road --ignore-errors --dry-run` は、そういうエラーがあると `ok: false` を返します (答えは強制しない場合の判定)。
  断られた本番の build の答えにも `errorsRefusal` が残ります。答えは今も2つの context の厳しい方なので、`road` の
  `--remove-buildings` の dry run は、エンジン自身の context (建物を取り除かない) だけにそういう messages があるときも
  断りになることがあります (`build` の `--join-streets` と `--remove-buildings` は `--dry-run` と一緒に使えません)。
  ゲーム内で確認 (2026-11-26、1.1.1): その車庫の場所は、2つの context とも `衝突` と `errorsRefusal` で断られ、`fit` は
  そこを飛ばして次の場所を選び、そこは建ちました。建設物に重なる道路は、dry run も本番も同じく断られ、`--ignore-errors`
  では建ちました。町の家を通る道路は、`--remove-buildings` で dry run も本番も同じく `衝突` で断られました (断りすぎは
  見られません)。
- `--collision-detail` (`build` と `road`。建てるときか、`--dry-run --engine-check` と一緒に。初期設定では出しません。
  答えが大きくなるため): エンジンの `ProposalData` を丸ごと `collisionDetail` に写します。欄はゲームの型
  (`api/tealdef/api/type.d.tl` の `ProposalData`) が名前を挙げるとおり: `collisionInfo` (`collisionEntities[].entity`・
  `autoRemovalEntity2models`・`buildingEntities`・`removableModules`)、`errorState`、`old2new`、`toAddData`
  (`boundingVolume.bbox` を `x0`..`z1` で、`subconstructionDatas`)、`parallelProposal`、`terrainPreviewHeightMod*`、`entity2tn`
  (網ごとのリストの長さだけ)、`tpNetLinkProposal`、`costs`。map は `[{key, value}]` の形です (キーが entity の id のため)。
  `from` はどの ProposalData か (建てたときのコールバックの `resultProposalData`、または確認の形)。読むとエラーになる欄は
  `unread` にエラーつきで、nil の欄は `absent` に入ります。40 個を超えるリスト、10 段を超える入れ子、4000 個を超える値は
  切り、`truncated`・`valuesCut` に書きます。型に無いキーは `unlisted` (表のキー、userdata の metatable のキー) に、衝突の
  記録の上で読めた推測の名前は `guessed` に入ります。hits があるときは `overlaps` に、邪魔をしている箱とこちらの箱
  (`build`: 新しい建造物の箱、`road`: 区間の両端。幅なし) の重なりを書きます: 軸ごとの `overlap` (`[lo, hi]`)、または離れて
  いる距離 `gap` (m)、`meet`、高さが分からないときは `noZ`。箱は世界の軸にそろった箱です: T 型の橋脚の箱は足元から梁まで
  あるので、`meet` は箱が重なることで、どの模型が当たるかではありません。旗を付けると、建てられるが衝突の相手を挙げる
  dry-run にも `hits` が付き、`road --ignore-errors` の本番では、検査を外さなかった場合の詳しい情報が `unforced.collisionDetail`
  に入ります。旗を付けないときの答えは前と同じです。ゲームの型では
  `CollisionInfo.EntityData` は `entity` だけで、こちらのどの部品が、どの高さで当たるかはありません。エンジンが本当に何を
  返すかは**ゲーム内では未確認**です (2026-11-24 に書いた)。
- `--dry-run` は何も建てず、エンジンにも**聞きません** (`road --dry-run --engine-check` は聞きます。`makeProposalData` は
  `engine/util.d.tl:939` では `Proposal` 用ですが、GUI のスレッドでは `SimpleProposal` を受けます。建物のほうはまだ
  聞いていません)。プローブが確認するのは、名前・送る params・高さと、
  点から 30 m の中の建物 (`near`。箱で見るだけの大まかなもの) です。答えは `checked: false` で、`buildable` はありません。
  エンジンが受け付けるか (衝突・地形・所持金) は、建てたときにしか分かりません。
- `--remove` で取り除けるのは、プローブが建てたものだけです: この読み込みのあとに建てたもので、その id の下にエンジンが
  まだ同じファイルを同じ場所に持っているもの (こちらの建物が手で壊されるなどして消え、エンジンが id を別のものに
  使い回したときは断ります)。または、読み込みのあとなら、名前が `probe-build` で始まり (初期設定の名前は
  `probe-build N`)、**かつ** params にプローブの印があるもの。`--name` で別の名前を付けたものは、建てた読み込みの間だけ
  取り除けます。条件に合わない id が1つでもあれば、全体を断ります。`--remove-all` は、この読み込みで建てて建てたときの
  ままのものを取り除きます。それ以外は取り除かずに一覧から外し、`forgotten` に挙げます。
- 30 秒たってもエンジンから答えが来ないときは、点から 60 m の中で名前 (1つずつ別の `probe-build N`) とファイルで探し、
  見つかれば建ったものとして答えます (`why` にそう書きます)。見つからなければ、何を探せばよいかをエラーに書きます。
  あとで現れたら、その名前と印が付いているので、`build --remove <id>` で取り除けます。
- エンジンは「成功」と答えて何も建てないことがあります (2026-11-22 に計測: 港の建物のスクリプトが自分の検査で失敗し、ログに
  `Error during construction update` が出た)。建物が読み戻せたとき (結果の entities の中か、点の近くで名前で) だけ ok にし、
  それ以外は `ok: false` で `error` に理由を書きます。tf3ctl は終了コード 1 で終わり、命令の間にゲームのログに出た Main Thread
  のエラー (最初の 10 件) を `logErrors` に添えます。建っていて費用が 0 (cost も spent も 0、費用なしの MOD) のときは ok のまま、
  `warnings` に1行足します。
- 衝突で断られたときは、邪魔をしている物も答えに入ります: `hits` に、`collisions` の id ごとに1件ずつ、`around` と
  同じ形 (`kind`・`name`・家ならその町・`x` / `y`・`box`・`sizeX` / `sizeY`・`--at` からの `dist`。建造物なら `mouths`)
  で入ります。エンジンにもう無い id は `kind: "gone"` です。
- `construction.at` は、置いた位置と向き (`angle`、transf から) です。`ends` と `connectable` のそれぞれに `local`
  (`dx`・`dy`・`dz`: 建造物の向きに合わせた座標。dx は建造物の x の向き) が付くので、どこに置いても、道路の出入り口が
  建造物のどこにあるか分かります。`mouth` には `joined` (建造物の固定の区間でない道路がその node に付いている: つながった
  道路、または自分の自由な腕) と `joinedPieces` が付きます。建てたあとの `joins` は、道路の出入り口ごとに `node`・
  `wasThere` (その node が建てる前から道路のものだった: 建造物が既存の node を使った)・`nodesHere` (0.5 m 以内の別の道路の
  node: 一つにならず横に並んだ node) です。「建てる前から」の node は、`--at` から 150 m 以内の道路の node です。
- `--remove-buildings`: Context の `gatherBuildings` を有効にし、邪魔な町の建物を取り除いて建てます (プレイヤーのツールと
  同じ)。エンジンが挙げたもの (`CollisionInfo.buildingEntities`) を `buildingsInWay` に出します。`--join-streets`:
  Context の `cleanupStreetGraph` を有効にします。道路の端を既存の道路の node にちょうど重ねたとき、一つの node になるかを
  見るためのものです (`joins`)。どちらもゲームを変えるので、試験用のセーブで使ってください (セーブは確認しません)。`--dry-run` とは一緒に
  使えません (dry-run はエンジンに何も聞かないので、断ります)。**ゲーム内では未確認**
  (2026-11-23 に書いたもの): エンジンがどう扱うか。答えにも `contextNote` で書きます。
- ゲームを変えるコマンドです (`line`・`connect` と同じ)。ほかのクライアントにはいつもの警告が出ます。1つずつ
  建ててください (それぞれエンジンの答えを 30 秒まで待ちます)。
- **ゲーム内では未確認** (2026-11-22 に書いたもの): とくに、初期設定の params・印・名前・`autoFillSlots` を送ったとおりに
  エンジンが受け取るか、`ends` と印が読めるか、dry run の `near`。

#### モジュール式の建物 (港)・産業・水 (`water`)

```
python3 tools/tf3ctl.py water --at 1500,-300                     # 読むだけ: 水面の高さ、水か陸か、地形の高さ
python3 tools/tf3ctl.py water --grid 1000,-800,2000,200,50       # 400 点まで: ~ (水) と . (陸) の行
python3 tools/tf3ctl.py build --res ::/stations/water/harbor_modular.con --at 1500,-300,5 --dry-run \
    --params '{"modules": {"120001": {"name": "<モジュールの resName>"}, "120002": {"name": "<モジュールの resName>", "variant": 1}}}'
python3 tools/tf3ctl.py build --res <産業の resName> --at 800,600 --no-owner   # 会社のものにしない (産業)
```

- `params.modules` は `{スロット id: {name, variant, metadata, updateScript}}` で、モジュール式の建物の updateFn が読む形です
  (`construction_util_serialized.d.tl` の `ModuleUpdateFnParams.modules : {integer : Module}`)。JSON オブジェクトのキーは
  文字列なので、プローブは送る前に `"120001"` を整数 120001 にします。文字列のキーのモジュールはどのスロットにも
  乗らないためです。`variant` は指定が無ければ 0。スロット id は建物 (その updateFn のスロット) によって決まり、
  プローブは計算しません。
- モジュールを渡したときは `autoFillSlots` を切ります (渡したモジュールだけが乗ります。AoM のイチゴ農場と同じ)。
  `params.modules` が無ければ今までどおりで、`autoFillSlots` は入ったままです。
- 各モジュールの `name` は先に `api.res.moduleRep.find` で探します。ゲームが知らない名前が1つでもあれば、何も送らずに
  全体を断り、似た名前 (同じファイル名か、同じフォルダのもの) を挙げます。
- `metadata` か `updateScript` が無いモジュールには、`moduleRep.get` のそのモジュールの値をそのまま入れます。エンジンが
  自分で埋める場合も同じ値になります。`--no-fill-modules` を付けると、渡したとおりに送ります (ある MOD の料金所は
  `name` と `variant` だけを送ります。`metadata` 無しで送ったモジュールは `moduleWarnings` に挙げます)。埋める設定のとき、
  metadata が渡されず読めもしない (moduleRep.get が失敗した・`asTable` の無いエンジンの値) モジュールがあれば、全体を
  断ります。港のモジュールのスクリプトは `mod.metadata.platform` を確認せずに読むためです。空の `modules` も断ります。答えの `params.modules` には、スロット・名前・variant・metadata と updateScript を
  送ったか・何を埋めたか (`filled`) が入ります。
- 建てたあと、駅を持つ建物 (港) の答えには `terminals` (全部の駅の terminal の数、`STATION.terminals`) と
  `stationTerminals` が入ります。0 のときは、モジュールがスロットに乗っていないかもしれない、という `warning` が付きます。
- `--no-owner` は `playerEntity` を -1 にして、会社のものにせずに建てます (AoM が産業を建てるのと同じ)。指定が無ければ
  会社のものです。(コマンドの前の `--owner` は、ほかのコマンドと同じく、クライアントの名前です。)
- `water` は読むだけです (ほかのクライアントに警告は出ません)。`waterLevel` (ワールドの `TERRAIN.waterLevel`) と、点ごとの
  `onWater` (`api.engine.terrain.isOnWater`)・`height` (`getHeightAt`。水の下では水底)・`depth` (水の上で、水面から地形の
  高さを引いたもの) を返します。`--grid x0,y0,x1,y1,step` は箱の中を step メートル (0.1 m 以上) ごとに 400 点まで調べ、`rows`
  (y0 から上へ y ごとに1行、各行は x0 から: `~` 水、`.` 陸、`?` 読めない) と、数の `water` / `land` を足します。
  isOnWater は `isValidCoordinate` で地図の中と分かった点にだけ聞きます。外の点は `onWater` が null、`offMap` が true
  (行では `?`) です。`build --dry-run` の答えにも、その点の `waterLevel` と `onWater` が入ります。水の上の建物には z (`water` の水面の高さ) を
  渡してください。
- **ゲーム内では未確認** (2026-11-22 に書いたもの): 港のモジュールが送ったとおりスロットに乗るか、terminal の数、
  埋めた metadata、`--no-owner`、`water` の値。

### まっすぐな道路を1本 (`road`)

```
python3 tools/tf3ctl.py road --from 1500,-300 --to 1620,-300 [--type town_new_small] [--snap 5] [--dry-run]
python3 tools/tf3ctl.py road --from 1500,-300 --to 1620,-300 --dry-run --engine-check   # エンジンに聞く (ゲームを変える側)
python3 tools/tf3ctl.py road --from 1500,-300 --to 1620,-260 --align-to-edge from [--align-edge 9010] [--tangent-to 1,0]
python3 tools/tf3ctl.py road --from 2564,2400,110 --to 2636,2400,110 --snap 1 --bridge concrete [--dry-run --engine-check]
python3 tools/tf3ctl.py road --from-node 4077 [--from 1504.5,-300] --to 1620,-300 [--dry-run]   # node 4077 につなぐ
python3 tools/tf3ctl.py road --inspect-node 4077     # 読むだけ: 1つの node について road が読むもの
python3 tools/tf3ctl.py lights --node 4077 --off [--dry-run]   # 試験用のセーブだけ (tf3ctl が確認します): 交差点の信号を外す
python3 tools/tf3ctl.py lanes --edge 9010            # 読むだけ: edge の車線 (「道路の車線」を参照)
```

- 2点 (x,y[,z]、メートル。z が無ければ地形の高さ) の間に、まっすぐな道路を1本、クリック無しで建てます。
  `SimpleStreetProposal` (新しい edge 1本と新しい node。番号は `type.d.tl` のとおり -1 から下へ) を
  `api.cmd.makeWorldBuildProposalCmd` で送ります。`build` が建物を送るのと同じ形です (同じ context: 何も壊さない、
  エラーを無視しない)。ゲームを変えるので、試験用のセーブで使ってください (確認するのは `--ignore-errors` のときだけ)。
- `--bridge RES` は、その種類の橋として道路を建てます。RES は `api.res.bridgeTypeRep` の resName (MOD のものは
  `<modId>::/infrastructure/bridge/<名前>.bridge`) か、バニラの橋のファイル名 (`concrete` なら
  `::/infrastructure/bridge/concrete.bridge`)。edge の種類 `BRIDGE` と、その種類の番号 (`bridgeTypeRep.find`) を
  `typeIndex` に入れて送ります。ゲームの橋の edge もこの2つで橋を持っています (`BaseEdge.type` / `typeIndex`)。
  プレイヤーの道路のツールは橋の種類をツールの側で選んでいるので、proposal のふつうの edge をエンジンが高さを見て橋に変える
  ことは無いと見て (ゲーム内では未確認)、ここで入れます。ゲームが知らない種類は、そこにある名前の一部を添えて断ります。carriers が読めて
  `ROAD` が無い種類も断ります。どちらも何も送りません (dry-run も)。答えの `bridge`: `name`、`id`、`carriers`、
  `carriesRoad` (読めなければ `carriersNote`)、`availability` / `available` (書くだけで断らない)、建てたあとは `built`
  (新しい edge の種類と `typeIndex` の読み返し、`asSent`)。空中の道路は、`--from` / `--to` の z で端の高さを決めるか、
  そこにある道路の node につなぎます (`--snap`、3次元で測る)。`--bridge` が無ければ、これまでどおりふつうの edge
  (`NORMAL`、`typeIndex` -1) です。ゲーム内では未確認 (柱・橋台・地面に近い橋): 絵で見てください。
- `--from-node ID` / `--to-node ID` (2026-11-26 に書いた): その端を、既存の道路の node に entity id で
  つなぎます (`road --inspect-node` や `lanes` で分かる id)。そのままつなぎ、snap しません。それだけなら端はその node の
  点です (そのときは `--from` / `--to` を書かなくてよい)。`--from` / `--to` も書くと、node につないだまま、道路の端は
  その点になります: edge の `node0` がその node、`position0` がその点 (to の端は `node1` / `position1`)。プレイヤーが
  広い道路の車線の脇に細い道路をつないだ形を読んだとき、`position0` が `node0` から 4.5 m ずれていました。z が無ければ
  node の高さ。地図の上で node から 12 m より遠い点は、何も送らずに断ります (dry-run も)。両端が同じ node でも断ります。
  答えの `from` / `to` に `position` (その点。`zFrom` は `given` か `node`) と `endOffset` (点 − node: `x`・`y`・`z`・
  地図の上の `flat`・`length`) が付き、`offsetNote` がそれを書きます。道路の長さと向きは、点と点の間で決めます。
  **ゲームで確認済み (2026-11-26):** 4 車線の道路の端の node から 4.5〜6.25 m 脇に端を置いた道路 1 本は建ちました
  (対面の 2 車線と一方通行の道路)。同じ node に 2 本目のそういう道路は、1 つの提案でも、1 本目のあとでも
  「建設不可」で断られました (critical。`collisionEntities` は空。`--ignore-errors` の dry-run でも同じ)。2 本目を
  node の点そのものから出すと、並べて建ち、`reach --mode drive` はその 2 本を通る行きと帰りの道を見つけました
  (一方通行に逆らう向きは無し)。**まだ確認していないこと** [推測]: 何 m まで受けるか、ずれを車線に対して
  どちら向きにすべきか。まず `--dry-run --engine-check` で試してください。`--batch` の道路でも同じです。
- 端から `--snap` メートル (初期設定 5、最大 20、0 ならつながない。3次元で測るので、点の上にある橋の node は使わない)
  以内に道路の端の node があれば、その node を端にして、そこで道路につなぎます。点の近くの道路は octree
  (`api.engine.util.octree.findEntitiesInCircle` で BASE_EDGE、無ければ octree system の箱) から探し、道路だけ
  (`roadType` が STREET。種類が読めないものは除く) の `node0` / `node1` を使います。線路の node については聞きません。道路は `--snap` より 25 m 広く探し
  (町の道路の継ぎ目の node を、その真上から snap 3 m で取りこぼした。octree が node の近くでどちらの道路にも当たらなかった)、
  端のうち `--snap` の中のものだけを使います。新しい node になった端には、その訳を `snapNote` に書きます (`--snap` の外で
  いちばん近い道路の node とその距離、または道路が1本も無かったこと)。
  つなぐ node にある道路は、そのあと street system (`streetSystem.getNodeStreetSegments`。答えの
  `piecesFrom: "streetSystem"`) から読みます。それが無いか、エラーになるときだけ、octree の 1 m の中から探します
  (`"octree"`)。産業の T 字では、octree はどれにも当たりませんでした。なければ新しい node です。新しい node が古い node の
  真上 (0.1 m 以内。`--snap 0` のとき) になるときは、エンジンが proposal 全体を断る (Construction Not Possible) ので、
  送る前に断ります。
- 建物の道路: `build` の答えの `construction.connectable` に、道路 (または線路: `track: true`。線路の車庫など、`connect`
  用) をつなげる所を並べます。それぞれ `node`、`x` / `y` / `z`、`track`、`edges` (そこにある同じ種類の piece の数)、道路の
  node なら `nodeConfig` があります。`kind: "mouth"` は凍結の道路の開いた端 (`frozenEdges` の
  node のうち `frozenNodes` に無いもの。産業の道路の口はここで、自由な腕2本と T 字になる)、`kind: "arm"` は口から出る自由な
  道路の先の端 (`from`: 口、`via`: その道路)。`ends` (凍結の道路の端) には腕が出ません。建物の node
  (`streetConnectorSystem.getConstructionEntityForNode` が 0 以上か、そこに建物の凍結の edge がある。駅・車庫・産業の口)
  には、町の node と同じようにつなぎます: 交差点の設定を外し、元のつながりと新しい道路の分 (下) で作り直します。元の
  つながりが空で、そこにすでに道路が2本以上ある (産業の T 字) ときは、その道路どうしのつながりも書きます。端には
  `construction`、`constructionFile`、`pieces`、`laneRules` が付き、答えに `caution` が付きます。
  以前の版は設定をそのまま残していました (`nodeConfigKept: true`。今は返しません)。そうしてつないだバスターミナルの口は
  レーンのつながりが空のままで、進入禁止の印が出て、そこを通る路線に車両を入れられませんでした。2026-11-26 に
  ゲーム内で確認したのは、バスターミナル2つの口と道路の車庫の口です: エンジンはエラー無しで建て (`--engine-check` の dry-run
  も)、あとで読んだ口のレーンのつながりは4本 (入ってくる車線から出ていく車線へ。歩道へは無し)、2つのターミナルを結ぶ
  路線は `noPath` が無く、バスを入れられて、両方の停留所をまわりました。ゲーム内で未確認: 産業の口 (T 字)、あとで建物を
  アップグレード・置き換えたとき、歩行者が歩けるか。
  建物の凍結の node (口の内側の端) と、`CONSTRUCTION` を読めない建物の node は、dry-run も含めて、送る前に断ります。
- 交差点の設定 (`BaseNodeConfig`。`nodeConfigsToAdd` / `nodeConfigsToRemove` で送る): 新しい node にはそれぞれ設定を付け
  (行き止まり: レーンのつながり無し)、つないだ node は元のつながりを残して、新しい道路の分を足します。足すのは新しい道路と
  そこにあるほかの道路の間だけで、node が2本になり、レーンの数が同じならレーンごとにまっすぐ、それ以外は入ってくる
  道路 (トラム) のレーンを出ていく道路 (トラム) のレーン全部へ。レーンの番号は、道路の `laneConfigs` 全部 (歩道も) を
  node から外へ数えます。これで、この命令の道路どうしを続けたり、枝を出したりできます。答えの `newNodeConfigs` は新しい
  node の設定の読み返し、`nodeConfigs` は送った設定の数、端の `laneRules` はそこで足したつながりの数です。信号のある node、
  元のつながりがレーンを別の数え方で数えている node、レーンや設定が読めないときは、dry-run も含めて何も送らずに断ります。
  設定の記録が作れないときも何も送らずに断りますが、これは build のときにしか分かりません。
- 設定の無い node (設定を付けずにスクリプトが建てた道路。2026-11-23 より前のこの命令の道路も) にはつなぎません。`--snap`
  の中で次に近い node を使い (`passedOver` に外した node)、無ければ何も送らずに断ります。2本つながったその node へ道路を
  つないだ直後にゲームが落ちました (2026-11-23: `Engine.h:322 GetComponentDataIndex`、BaseNodeConfig)。設定があるかどうか
  読めないときも、dry-run を含めて断ります。
- `--type` は street template の resName か、バニラの道路のファイル名 (`town_new_small`、`country_old_medium`。バニラの
  town・country・highway の下で探す)。線路の種類と、ゲームの年に作れないものは断ります。指定が無ければ、その年の
  バニラの中くらいの町の道路 (1940 年までは old、それから new)。道路には template の `laneConfigs` と `streetStyle`、
  種類 NORMAL (`typeIndex` -1: 橋もトンネルも無し)、会社の `PlayerOwned` を付け、両端の tangent は2点を結ぶ線 (まっすぐ) です (向きを渡したときは次のとおり)。
- 曲がった道路: `--tangent-from DX,DY` / `--tangent-to DX,DY` は、from の端から出る向きと、to の端に入る向きです
  (向きだけ。どちらも from -> to の進む向きなので、東へまっすぐなら両端とも `1,0`)。`--align-to-edge from|to|both`
  は、つないだ端 (`--snap` の中の道路の node) で、そこにある道路の向きにそろえます。向きは、その道路が node の先へ
  そのまま伸びる向き (行き止まりなら、その道のまっすぐ先) で、`BASE_EDGE` のその端の tangent (node1 なら `tangent1`、
  node0 なら `tangent0` を逆に) から、読めなければ道路の弦から取ります。node の道路が1本ならそれに、2本以上なら
  `--align-edge ID` で選んだものにそろえ、選ばなければ断ります (端ごとに1回ずつ。id はそれがある端で使い、そろえる端の
  どれにも無い id は断ります)。新しい node の端には、そろえる道路が無いので断ります。同じ端に `--tangent-*` と
  `--align-to-edge` を両方付けると断り、別の端なら一緒に使えます。送るのは3次のエルミート曲線で、tangent の長さは
  地図の上で弦の長さ (よく使う長さ。まっすぐなら弦そのもの)、高さは弦の上がり分全部 (高さは今までどおり一様に
  変わる) です。負の dx は `=` で書きます (`--tangent-to=-1,0`)。長さ 0 の向き、地図の上で 1 m 未満の両端、from -> to の線から 90 度より大きく曲がる端 (曲線が端の後ろ
  へ回り込む) は、dry-run も含めて送る前に断ります。
- 答え (dry-run も) には `tangent0` / `tangent1` (送る値。mm に丸める)、`curved`、曲線なら `turnOffChord` (`from` /
  `to`、度) が付きます。つないだ端には `kinks` (その node の道路ごとに `edge`、`kinkDeg`: その道路が node の先へ伸びる
  向きと、新しい道路が node から出る向きの角度。0 ならまっすぐ。`wayFrom`: `tangent` か `chord`)、`kinkDeg` (そろえた
  道路の、または1本だけの道路の値)、`--align-to-edge` なら `alignedTo` (`edge`、`from`) が付きます。まっすぐな道路の
  `kinkDeg` で、弦がどれだけ折れて入るかが分かります。`length` (と上限の 2000 m) は曲線でも弦の長さで、曲線そのものはそれより長くなります。
  **ゲーム内では未確認** (2026-11-23 に書いたもの): エンジンがこの曲線を受け付けるか (折れたまっすぐの道路より断られ
  にくいか)、弦の長さの tangent で円にどれだけ近いか。
- 答え: `from` / `to` (つないだときは `node` と `snapped`、ほかは `zFrom`)、`template`、`year`、`length`、`edges` /
  `nodes` (結果の新しい entity)、`edge`、`node0` / `node1`、`cost`、`spent`、断られたときはエンジンの `errors`・`warnings`・
  `collisions`。結果に id が無いとき、30 秒たってもコールバックが来ないときは、2点の間の道路を探します。探すときは、送る前からあった道路を除きます。建てたと言われたのに新しい
  道路が見つからないときは `warning` を付けます。template や `BaseEdgeType` / `RoadType` の enum が読めないときは、
  何も送らずに断ります。
- `--dry-run` は何も送らず、エンジンにも聞きません。プローブが確認した計画だけを返します (`checked: false`、
  `engineCheck: "not asked (use --engine-check)"`)。ほかの dry-run と同じく、安全に使えます。
- `--dry-run --engine-check` (`--engine-check` は `--dry-run` と一緒にだけ使う): 建てるときに送るのと同じ proposal
  (設定も含む) も作り、
  `api.engine.util.proposal.makeProposalData` (proposal だけと、build の context を付けた形。`build` と同じ) でエンジンに聞きます。
  呼ぶのは guiUpdate の中で、レシピの本体では呼びません。答えは `checked: true`、`engineCheck` (使った形)、`buildable`、
  エンジンの `cost`・`errors`・`warnings`・`collisions`・`critical`、`balance`。エンジンが断るものは `ok: false` で、文言が
  `error` に入ります。`makeProposalData` が無いか、どちらの形でもエラーになるときは、プローブの計画だけを返します
  (`checked: false`、`engineCheck: "not available: ..."`)。エンジンの評価は pcall で守れないネイティブのコードを通る
  (そこで assertion が出るとゲームが終わる) ので、tf3ctl はこれをゲームを変える命令に数えます。ゲームの時間をもらって、
  試験用のセーブで使ってください (セーブは確認しません)。
  `verdict` は `buildable`・`buildable with warnings`・`refused` のどれかです (`engineContexts`・`contextsDisagree` は `build` と同じ)。proposal だけの形しか答えないときは、エンジンは build の
  context ではなく、自分の context で判定します (どちらかは `engineContext`)。その context は畑を取り除くので、道に畑がある
  ときは警告 (「3 個の畑が取り除かれます」) だけになりますが、`--remove-fields` の無い build ではその畑と衝突します
  (2026-11-23、伐採場のそばの道路)。そのときは答えに `caution` が付きます。
- `--remove-fields`: 道にある畑を取り除いて建てます。build の context で畑を集めます (`gatherFields`。Track Connector と
  同じ。建物は集めない)。エンジンが畑を取り除いて建てます。畑以外 (建物・線路・ほかの建造物) は、今までどおり断り
  ます。これを付けずに衝突で断られた道路には `hint` が付きます。ゲームを変えるので、試験用のセーブで使ってください (セーブは確認しません)。
  **ゲーム内では未確認** (2026-11-23 に書いたもの): 取り除かれるのが畑だけか (建物・線路・産業の一部は断られるか)、
  伐採場のそばで邪魔をしていた entity が畑だったか、エンジン自身の context が畑を集めるか (警告からの見立て)。答えにも
  `removeFieldsNote` で書きます。`--remove-fields` を付けた dry-run の `caution` は、畑以外の警告なら本番で衝突しうる、と
  言います。
- `--remove-buildings`: Context の `gatherBuildings` を有効にします (邪魔な町の建物を取り除く。プレイヤーのツールと同じ)。
  試験用のセーブ向け (セーブは確認しません)。ゲーム内では未確認。dry-run の engine-check がエンジン自身の context で判定したとき
  (`engineContext`) はこれが効いていないので、`removeBuildingsNote` で「hits の町の建物は本番では取り除かれうる」と言います。衝突で断られたとき (建てるとき、dry-run の engine-check) は、`build` と
  同じく `hits` に邪魔な物が入ります。
- `--ignore-errors` (**試験用のセーブだけ。エンジンの検査を外します**): `makeWorldBuildProposalCmd` の `ignoreErrors` を
  有効にして送り、エンジンに誤りを無視して建てさせます。ゲームの API (`api/tealdef/api/cmd.d.tl`) には「critical でない
  誤りでも建てる」とあるので、`critical` の誤りでは断られることがあります。送る前に、同じ提案をエンジンに聞きます
  (`makeProposalData`、`--dry-run --engine-check` と同じ)。答えの `unforced` に、これを付けなかったら断られた理由
  (`refused`・`verdict`・`critical`・`errors`・`warnings`・`infos`・`collisions`・`collisionEntities`・`hits`)、`unforcedContexts` に
  2つの context、check が critical と言ったときは `unforcedCritical` に注意が入ります。ほかに `ignoreErrors: true`・
  `ignoredErrors: true` (強制で送ったという印。無視する誤りがあったかは `unforced.refused`)・`testSave`・`ignoreErrorsNote` が付き、建てば普通の road と同じく `edge`・`edges`・`nodes` が入ります。
  読み込まれているセーブ (ゲームのログから読む) が試験用の名前 (設定ファイルの `testSavePrefixes`。初期設定は
  `probe-*`) でないとき、また動いているゲームに共同作業 (coop) の印があるとき (有効・期限切れ・壊れた印の
  どれでも) は、tf3ctl が断ります (終了コード 4、`"refused": "ignore-errors"`、何も送らない)。新しいゲームにはまだセーブの
  名前が無いので、先に試験用の名前で保存し、そのセーブを読み込んでから使ってください。MOD の側でもセーブの名前
  (tf3ctl が送る) を確認し、`road` 以外の命令に付いた `ignoreErrors` は断ります。probe 自身の検査は外しません: 交差点の
  設定 (junction set-up) の無い node・信号のある node・設定を読めない node への接続は、これまでどおり断ります (設定の無い
  node につないでゲームが落ちたことがあるため)。建物 (construction) の node (設定を作り直す端。強制のときはゲーム内で未確認) へは、
  強制ではつなぎません。`--dry-run` と一緒なら、エンジンに聞くだけで何も建てません
  (`--engine-check` が付いた扱い)。答えは強制しなかった場合の判定で、`ignoredErrors: false` です。**ゲーム内では未確認**
  (2026-11-24 に書いたもの): 衝突する道路をエンジンが建てるか、車が通るか、セーブとロードのあとも壊れないか。
  **強制で建てたあとの保存**: 動いているゲームに強制の建設 (`--dry-run` でないもの) を1回でも送ると、起動の記録
  (`launched.json`) に `"forced": true` と `"forcedCount"` が付き、それからの `save` は `probe-force-` で始まる名前
  (例 `save probe-force-junction`) にだけ通ります。ほかの名前は断ります (終了コード 4、`"refused": "forced-save"`、何も
  送らない)。`--other-owner-ok`・`--user-asked` を付けても同じです。エンジンの検査を外して建てた状態を、試験の土台や
  ユーザーのセーブに残さないためです。`status` の `forced` (`text`・`textJa`) にも出ます。印はそのゲームの起動かぎりで、
  次の `launch` / `restart` で書かれる記録には付きません。動いているゲームの起動の記録が無いとき (Steam から起動した
  ゲーム) は、印を残せないので強制の建設を断ります。`probe-force-*` のセーブ (前の起動で強制して保存したもの) を読み込んだ
  ときも、保存は `probe-force-*` の名前にだけ通ります。防げないこと: ゲーム自身のオートセーブ (10 分ごと) は、強制した
  状態をオートセーブの枠に書きます。そのオートセーブを読み込むと、どの名前にも保存できます。
- `--batch FILE` (複数の道路を **1 つの** 提案で送る。2026-11-24 に書いたもの、**ゲーム内では未確認**): 全部の道路を
  1 つの SimpleProposal に入れ、エンジンにまとめて判定させ、まとめて建てます (1 本ずつ送ると 2 本目だけ断られる形が、
  まとめると通るかもしれない: 4 車線の道路の端から一方通行の道路を 2 本出すとき)。FILE は JSON の配列で、16 本まで。
  それぞれはこの命令の引数の名前で書いた object です (`from`・`to`・`type`・`bridge`・`snap`・`tangent-from`・
  `tangent-to`・`align-to-edge`・`align-edge`。MOD の名前 `tangentFrom` なども読みます。点は `"x,y[,z]"` か
  `[x, y, z]`)。node を共有するには `from-node` / `to-node` を使います: 既存の道路の node の entity id (そのまま
  つなぐ。snap しない。同じ端に `from` / `to` も書くと、端はその点になり node の脇につながる。12 m まで。上の
  `--from-node` と `--from` と同じ。1 つの node に 1 本はゲームで建った)、または新しい node の名前 `"@a"` (複数の道路で共有する
  新しい node。snap しない。点は少なくとも 1 つの端で書き、書いた端どうしは 0.01 m 以内で同じであること。1 つの端に
  しか出てこない名前は断ります)。`--dry-run`・`--engine-check`・`--remove-fields`・`--remove-buildings`・
  `--ignore-errors`・`--collision-detail` は提案全体のものとしてコマンドラインに書き、1 本のときと同じ意味・同じ柵です (命令の名前は
  `road` のまま送るので、`--ignore-errors` は試験用のセーブだけで coop の間は断る、強制の印、probe 自身の交差点の
  設定の検査、が同じく効きます)。`--batch` と一緒の `--from`・`--to` など 1 本ぶんの引数は断ります。空の配列・17 本
  以上・JSON でないファイル・知らない key・誤った値は、何も送らずに断ります。名前を付けずに同じ点に置いた 2 つの新しい
  端 (1 つの名前を付けてください)、同じ 2 つの node の間の 2 本、既存の node の上の名前つきの node、道路の node でない
  id の端も断ります。同じ batch の道路どうしが交わる・重なる形 (1 つの node から 0° 近くで 2 本出すなど) はここでは
  確認しないので、先に `--dry-run --engine-check` で試してください。
  新しい entity の番号は 1 本のときと同じ決め方です: 新しい node が -1, -2, ... (端の順: 1 本目の from、1 本目の to、
  2 本目の from、...)、そのあとに道路。1 本だけの batch は `road` とまったく同じ提案になります。複数の道路が共有する
  node には、交差点の設定を 1 つだけ付けます: 既存の node は元の接続に新しい道路の接続 (既存の道路へ・新しい道路
  どうし) を足したもの、新しい node は新しい道路どうしの接続 (2 本なら車線ごとにまっすぐ、3 本以上なら交差点)。
  答え: `batch: true`、1 つの提案の `errors`・`critical`・`warnings`・`collisions`・`hits`、`pieces` (道路ごとの
  `from` / `to`・`template`・`length`・tangent と曲がりの角、建てば `edge`・`node0`・`node1`。共有した端には
  `sharedBy`)、`proposal` (提案の `nodes` を id で。`name` と、その node を書いた端 `ends`。それと `edges`)、建てた
  `edges` / `nodes`、`pieceEdges` (道路ごとの edge、順に)、`namedNodes` (名前ごとの、建った node)。`--collision-detail` を付けると、`collisionDetail` は 1 つの
  提案のもの (1 本のときと同じ形) で、その `overlaps` は道路ごとの両端の箱と比べます: `mine` が道路の番号です。
- `--inspect-node ID` (読むだけ、ほかの引数と一緒には使わない): node の位置、`streetSegments` (それぞれの道路の `edge`、
  `node0` / `node1`、`street`、`construction`)、`constructionForNode` (getConstructionEntityForNode)、`construction`
  (見つけた建物、`frozen`、`by`) と `constructionFrozenNodes` / `constructionFrozenEdges`、`nodeConfig` (無ければ
  `false`。あれば `laneConnections`・`crosswalks`・`trafficLightStates`・`doubleSlipSwitch`・`trafficLightPreference`
  (`YES` / `NO` / `AUTO`。ゲームの enum で読む。数は `trafficLightPreferenceValue`)・`trafficLightType`)、`octree`
  (`findEntitiesInCircle` が 1・5・20 m の中で当たる道路と、それぞれがその node で終わるか。最大 40 本)、`road`
  (その node を端にしたとき road がすること)。
- road は信号のある node にはつなぎません (信号の段階が車線を名指ししていて、作り直せないため)。`lights --node ID --off`
  で、先に交差点の信号を外せます。node の窓の2つのボタンを1つの提案にまとめて送ります: 「なし」
  (`trafficLightPreference` を NO) と「デフォルトにリセット」(信号の段階 `states` を空に。road は段階の有無で断り、「なし」
  だけでは段階が残るため)。交差点の設定にある信号の config を `clone` で写し (種類はそのまま)、
  `createTrafficLightProposal` を `makeWorldBuildProposalCmd(proposal, nil, false, true)` で送ります。
  - **試験用のセーブだけで、coop の間は使えません**: `road --ignore-errors` と同じ決まりで tf3ctl が断ります
    (終了コード 4、`"refused": "lights"`、何も送らない)。MOD もセーブの名前をもう一度確認します。持ち主の検査も
    通します (`--dry-run` も)。
  - 送る前に断るもの: 道路が 2 本以下の node (node の窓が信号を出すのは 3 本以上が集まる所だけ)、建物の node、
    交差点の設定の無い node。すでに NO で段階も無い node には何も送りません (`changed: false`)。
  - 答え: `before` と `after` (読み直した `trafficLightPreference`・`trafficLightStates`・`trafficLightType`)、
    `off` (読み直して NO で段階が 0)、`changed`。`--dry-run` は提案を作ってエンジンに聞くだけ (makeProposalData。窓と同じく Context なし):
    `verdict`。何も送りません。
  - **ゲーム内では未確認** (2026-11-24 に書いたもの): エンジンが NO と空の段階をそのまま保つか (段階を作り直さないか)、
    そのあと road がその node につなげるか。信じる前に `road --inspect-node` で見てください。
- 長さは 1 m から 2000 m まで。水の上や谷を渡るには橋が要りますが、これは橋を建てません (エンジンが断るか、地形に沿うか:
  未確認)。
- 使い道: 港の歩行者用接続路だけでは、港は道路網につながりません。その横に、港の道路の空いた端から町の道路まで道路を
  通すとつながります (プレイヤーが建てるのと同じ)。
- **ゲーム内では未確認** (2026-11-22 に書いたもの): 特に、`api.type.NodeAndEntity` / `SegmentAndEntity` / `PlayerOwned`
  がその名前で届くか (`api.type.Proposal.*` も試す)、初期のままの `streetEdge` で足りるか、産業の口で、建物の node の
  設定を新しい道路のレーンのつながりで作り直したとき、エンジンがそれを受け付け、車両が通るか (バスターミナルと道路の
  車庫の口では 2026-11-26 に確認した: 受け付け、ターミナルを通る路線をバスが走った。以前の版のように設定をそのまま残すと、
  ターミナルの口のつながりは空のままだった。伐採場の内側の端は断る)、guiUpdate で makeProposalData が Overpass Builder のツールと同じように答えるか、コールバックの entity に何が入るか、node が本当に octree に無いか、新しい道路が横切る町の道路が
  どうなるか (proposal に交差の node は入れていない: エンジンが足すか、断るか、重ねるか)。

### 長方形の範囲の地面 (`terrain`)

```
python3 tools/tf3ctl.py terrain --probe-api                         # 読むだけ: それぞれの Lua の状態にある関数
python3 tools/tf3ctl.py terrain --rect 0,0,500,300 --flat 40 --dry-run
python3 tools/tf3ctl.py terrain --rect 0,0,500,300 --flat 40 [--blend 16]
python3 tools/tf3ctl.py terrain --rect=-500,0,500,300 --slope-x 5 --base 40     # x0 で 40 m、x1 へ 5 % 上がる
python3 tools/tf3ctl.py terrain --rect 0,0,300,800 --slope-y -10 --base 120 [--via auto|update|gui] [--in-game]
```

- 長方形 (m、1 辺 1024 まで) の中の地面の高さを置き換えます。決まった高さの平地か、x か y の向きに一様な勾配の
  斜面 (`--base` は x0 / y0 の辺の高さ)。範囲の外は今のまま。マップエディタの中 (`api.gui.game.isMapEditor()`)
  でだけ送ります。エディタの外では、`--in-game` を付けたとき (テスト用の新しいゲーム) だけ通します (普通のゲームで
  置き換えが効くかは分かっていない)。dry run は何も送らないので、どこでも使えます。ゲームを変えるコマンドとして、
  ほかのクライアントに警告が出ます (dry run も)。
- 地図の大きさ: heightmap を丸ごと Lua の表に写すので、格子の点が 450 万を超える地図は断ります (写す前に地形の
  bounding box から数える。small の地図 32 x 32 タイルは 420 万点)。
- やり方: マップエディタの生成・取り込みと同じく、地図まるごとを1つのコマンドで。`makeMapFromGame(true, false,
  false, false)` で町なしの写しを取り (町の入った地図は `terrain_util::ReplaceTerrain` の assertion で落ちる)、
  写した表の中の範囲の格子点 (4 m ごと、地図の最小の角から添字 `j * w + i + 1`) を変え、表を丸ごと代入し
  (`GameMap.heightmap` は読むたびに写しを返すので、1 つずつ書くと消える。代入する先は UTG と同じく
  `api.type.Map.new` で作った写し)、エディタの中でだけ本体のエディタと同じく `setMapSeedText` と
  `reloadMaterialIndexManagerPipeline` を呼んでから、`makeWorldReplaceTerrainCmd(map,
  baseConfig.terrain, "", world, keepAssets = true)` を送ります。木と岩は残します (新しい地面の上でどうなるかは不明)。
- 境: 初期設定では、範囲の内側 16 m (小さい範囲では短い辺の 1/4) で新しい高さを古い高さに混ぜます。辺の上の点は
  高さがそのまま、16 m 内側から新しい高さになるので、まわりと段差になりません。`--blend 0` で辺に段差を付けます。
- 断って何も送らない場合: 範囲か、そのまわり 8 m に、道路・線路の区間、ノード、建物 (construction)、町の建物、産業が
  ある (octree で探す)、または町の bounding box が 200 m 以内に来る。答えの `blockers` に並べます。頼む高さは
  -99 〜 3170 m の中。
- 2 つの道 (`via`): `gui` は速度ボタンのレシピ (その join。本体のエディタと地形の MOD が同じ関数を react の中からだけ
  呼んでいる所) で動かします。`auto` (初期設定) は `gui` です。`update` は guiUpdate の状態で、書いたときだけ。`terrain --probe-api` は、`makeMapFromGame`・`Map.new`・`makeWorldReplaceTerrainCmd`・`mapgen.createTowns`・
  `setMapSeedText`・`reloadMaterialIndexManagerPipeline` などがそれぞれの状態にあるかを、どれも呼ばずに答えます (読むだけ)。
- 答え: `via`、`functionsUpdate` / `functionsGui`、`rect`、`grid` (最初と最後の格子点、`nx`・`ny`・`points`)、`mapPoints`、`inGame`、`target`
  (頼んだ高さの最小と最大)、`before` / `written` (範囲の中の最小と最大)、`changed`、`waterLevel`、`sent`、`success`
  (callback)、置き換えのあとは `samples` (全部が新しい高さになる部分の真ん中と角を `getHeightAt` で読み直したもの) と
  `readBackOk`、`mapEditor`。断ったときは `error`。
- **ゲーム内では未確認** (2026-11-22 に書いたもの): guiUpdate の状態にこれらの関数があるか、マップエディタの外で
  置き換えが効くか (見た例はどれもエディタの中)、範囲の中の木と町の土地がどうなるか、読み直しの値。

### 町を1つ (`town`)

```
python3 tools/tf3ctl.py town --at 1200,-300 --name "Harbourside" --dry-run
python3 tools/tf3ctl.py town --at 1200,-300 --name "Harbourside" [--size 1.5] [--capacity 300]
python3 tools/tf3ctl.py town --at=-800,400 --name "Quayside" --needs com:fish,ind:planks [--via auto|update|gui] [--in-game]
python3 tools/tf3ctl.py town --at 0,0 --name "Plain" --no-needs
```

- 地図の1点に町を1つ置きます。マップエディタの町の窓と取り込みと同じやり方です (`map_editor.tl` の `makeTowns`)。
  `GameMap.Town` を1つ (`api.type.Map.Town.new()`: `pos`・`name`・`sizeFactors`・`landUse2CargoNeeds`・
  `existing = -1`) `api.engine.mapgen.createTowns("remote_probe", { town })` に渡し、返った `TownInfo` 1つ
  (`toAdd`) を `api.cmd.makeTownCreateCmd({ info })` で送ります。マップエディタの中 (`api.gui.game.isMapEditor()`)
  でだけ送ります。エディタの外では、`--in-game` を付けたとき (テスト用の新しいゲーム) だけ通します (見た例は、本体の
  エディタも町の MOD も、どれもエディタの中)。ゲームを変えるコマンドとして、ほかのクライアントに警告が出ます (dry run も)。
- `--size` は各地区の大きさの係数 (`sizeFactors = { f, f, f }`、0.1 〜 2.5、初期設定は本体の取り込みと同じ 1。
  Real World Map Importer は 500 人で 0.5、5000 人で 1)。`--capacity N` は、エンジンの `initialLandUseCapacities`
  を、割合を保ったまま地区あたり平均 N (1 〜 1000) に直します (Advanced Town Placement と同じ。その町は 500 ほどまで)。付けなければ、その場所に
  エンジンが出した値をそのまま送ります。
- 最初の需要: スクリプトで作った町には、ゲームが最初の需要を付けず、需要が無いと町は品物を求めないまま
  (Real World Map Importer の更新履歴)。初期設定では、経済の一番下の段 (tier 0) から、店に1つ・工業に1つ
  (貨物の種類があるもので、名前の順で最初のもの)。`--needs com:fish,ind:planks` で名前を指定できます (土地の使い方
  `res`・`com`・`ind`、それぞれ 3 つまで、経済の category の名前)。`--no-needs` で付けません。
  2 回に分けて渡します: `landUse2CargoNeeds` として (`LandUseType` ごとに category の名前と重み 1。本体の取り込みと
  Advanced Town Placement の渡し方)。作った町の `TOWN` コンポーネントに、作成の callback から数フレームあとで
  それが見えなければ、`api.cmd.makeTownUpdateCargoNeedsCmd(town, { {住宅の id}, {商業の id}, {工業の id} }, true)`
  を貨物の種類の id で送り (Real World Map Importer と同じ)、もう一度読み直します。
- 置けない場所 (道路・建物・水・荒れ地) の扱いはエンジンに任せます: `createTowns` が出したエラーはそのまま返します。
  初期の容量が 0, 0, 0 の案は断ります (Advanced Town Placement もこういう場所を外す)。エンジンが作成を断ったとき
  (callback) もエラー。`createTowns` が消す町として挙げたもの (`toRemove`。エディタは先に消す) は数えるだけで
  (`toRemoveIgnored`)、このコマンドは町を消しません。`createTowns` は渡したリストを地図の町の全部と見るらしく
  (本体の取り込みは残す町を足して渡す)、`toRemoveIgnored` は今ある町の数になることが多く、エンジンの案はそれらの
  場所を空けないかもしれません。ほかの町から十分離して置いてください。地図の外の点 (`isValidCoordinate`) は断り、
  確認できないときは警告にします。
- `--dry-run` は何も送りません。エディタの中か `--in-game` のときは `createTowns` に案だけを聞き (コマンドは送らない。
  答えの `proposal`)、それ以外では引数と需要だけを確認します。
- 2 つの道 (`via`) は `terrain` と同じ: `gui` (と初期設定の `auto`) は速度ボタンのレシピ (その join)、`update` は
  guiUpdate の状態で、書いたときだけ。需要のコマンドは guiUpdate の状態から送ります。その状態に
  `makeTownUpdateCargoNeedsCmd` が無ければ、町は需要なしで作り、答えにそう出します (`needsSet`・`warnings`。
  `functionsUpdate` にも出る)。成功と言われたのに新しい町が見つからないときはエラーです。
- 答え: `via`・`mapEditor`・`inGame`・`at`・`name`・`size`・`capacity`・`needs` (土地の使い方ごとの名前)・
  `needIds` (地区ごとの貨物の種類の id)・`proposal` (TownInfo の `name`・`position`・`initialLandUseCapacities`・
  `scaledCapacities`・`capacityScalingFactor`・`majorStreetAngle`)・`sent`・`success`・`entity` (コマンドのあとに
  増えた町の id。いくつもあれば名前で選ぶ)・`townName`・`position` (bounding box の真ん中)・`population`
  (`industry-workers` と同じく `getTown2personCapacitiesMap` から。建物はゲームの数日のうちに建つので、最初は少ない)・
  `personCapacities`・`needsRead` (読み直した地区ごとの貨物の種類の id)・`needsSet`・`needsMet`・`warnings`。
  断ったときは `error`。
- **ゲーム内では未確認** (2026-11-22 に書いたもの): guiUpdate の状態やレシピにこれらの関数があるか、マップエディタの
  外で効くか、`landUse2CargoNeeds` が効くか、需要のコマンド、道路や建物のある場所にエンジンがどう答えるか、
  作った直後の人口。

### 町のつながり (`town connections`・`town connect`: 試験用のセーブ向け)

```
python3 tools/tf3ctl.py town connections [--entity 801] [--index-base 0|1]   # 読むだけ
python3 tools/tf3ctl.py town connect --auto [--entity 801,802] [--dry-run]
python3 tools/tf3ctl.py town connect --build [--entity 801,802] [--pairs 801:802] [--default] [--no-keep] [--dry-run]
```

- エンジンにあるもの (api の型と本体のマップエディタの Connections のタブ、2026-11-23 に読んだ): つながりは町と町の間で、
  町と産業の間ではありません。地図の `townConnections` (`api.engine.terrain.makeMapFromGame(false, true, false, false)`
  から。エディタと同じ読み方) は、地図の町の一覧の番号の組です。産業の町は一番近い町です (産業の construction の
  `streetConnectorSystem.getConstructionClosestTown`)。
- `town connections` は町ごとに (`id`・`name`・`mapIndex`・`connectedTowns`・`industries`: その町が一番近い産業)、
  `industriesWithoutTown`、生の `connections` とそれが指す町、`indexBase` (0 か 1: エンジンが町に振る番号の始まり。
  地図の組から分かるとき) を答えます。
- `town connect --auto` は `api.cmd.makeTownAutoDetectConnectionsCmd(町)` を送ります (エディタの「Auto-detect connections」:
  今ある道路でのつながりを見つける。何も建てません)。
- `town connect --build` は `api.cmd.makeTownConnectWithIndustriesCmd(町, つながり, keep)` を送ります (エディタの
  「Generate」): つながった町の間と、**すべての**産業へ道路を作ります。産業の一覧は渡せません。つながりは地図のものに、
  `--default` でエンジンの初期のつながり (エディタの「Propose Default Connections」)、`--pairs` (町の id) を足し、送る町に合わせて
  番号を振り直します。keep は入り、`--no-keep` で今ある道路のつながりを消します。地図から番号の始まりが分からない
  ときは `--index-base 0|1` が要ります (`town connections` と `--auto` も、答えの組を町に直すために受けます)。
  `--entity`・`--default`・`--pairs` のどれも無いときは、地図の町と組をそのまま送るので (`asMap`、エディタと同じ)、
  番号の始まりは要りません。
- どちらも `before`・`after` (`town connections` と同じ形) を答え、エンジンの callback を最長 120 秒待ちます。
- **ゲーム内では未確認** (2026-11-23 に書いたもの): マップエディタの外のゲームで動くか、番号の振り方、`--build` が
  今ある道路に何をするか。

### 町を1か所で育てる (`town develop`・`town size`: 試験用のセーブ向け)

```sh
python3 tools/tf3ctl.py town develop --at 120,-40 --count 30 [--streets] [--upgrade] [--radius 250] [--dry-run]
python3 tools/tf3ctl.py town size --entity 801 --factors 2,1.5,1 [--update-all] [--dry-run]
```

- **試験用のセーブで使ってください。** 読み込んでいるセーブを tf3ctl は確認しません。答えに `saveNote` が付きます。
  プレイヤーには置けない建物を足します。港や駅の円に、`steps` で何年も
  進めずに住宅や店を置くためのものです。ゲームを変える命令として、ほかのクライアントに警告が出ます (dry run も)。
  オプションは語のあとに書きます (`town develop --dry-run ...`)。語の前に普通の `town` のオプションがあると断るので、
  そこに書いた `--dry-run` が落ちることはありません。
- `town develop` は `api.cmd.makeTownDevelopAtCmd(api.type.Vec2f.new(x, y), streets, upgrade)` を `--count` 回
  (1〜200、初期設定 1)、1つずつ送ります。次の命令は、前の命令の callback の1フレームあとです。型の説明は「新しい建物か
  道路の区間が、その位置に足される」。`--streets` は道路も、`--upgrade` は建物の格上げ (どちらも初期設定は false)。
- `town size` は `api.cmd.makeTownUpdateSizeCmd(town, { 住宅, 商業, 工業 }, updateAll)` を送ります。町の size factor
  (それぞれ 0〜5。新しい町は 1) で、バニラの町の成長のスクリプトが送るのと同じ形です。`--update-all` は全部の建物を
  目標の容量まで上げます。町はエンジンにある、`TOWN` の component を持つものだけです。バニラの町の成長のスクリプトは、
  町が育つと町自身の factor から大きさを送り直す (上げるだけ) ので、それより低くした factor はまた上げられることが
  あります。
- 数え方: 全部の町の建物 (`townBuildingSystem.getTown2BuildingMap`)。種類はそれぞれの `PERSON_CAPACITY` の type
  (`LandUseType`) で、`stations --catchment` と同じ数え方です: `buildings`・`residential`・`commercial`・
  `industrial`・`unknownKind`・種類ごとの `capacity`。`town develop` は、全部の町の合計 (`total`) と、bounding box の
  真ん中がその点から `--radius` (初期設定 250 m、港の円) の中にある建物 (`near`) の `before`・`after`・`delta`、
  数が変わった町の一覧 `towns` (id と名前) を答えます。`town size` は、その町の `before`・`after`・`delta` と、
  `townBefore`・`townAfter` (`sizeFactors`・`initialLandUseCapacities`・`developmentActive`・`personCapacities`)。
  数えるのは最後の callback の5フレームあとで、それより後に建つ建物は入りません。
- 答えにはほかに `sent`・`succeeded`・`failed`・`failures` (index・success・engineResult、最初の 20 件)・
  `engineResult` (最初の callback が返したもの)・`waitedSec`・`functions` (関数があるか)。`--dry-run` は何も送らず、
  数だけを答えます (develop は全部の町)。ゲームに無い (nil の) 関数は呼びません。命令を作る・送るときのエラー、
  30 秒 callback が来ないとき、全部の命令が断られたとき (`success` が false) はエラーです。`town develop` と
  `town size` は1つずつで、動いている間の次の命令は断ります。
- **ゲーム内では未確認** (2026-11-22 に書いたもの): guiUpdate の状態にこれらの関数があり、ゲームの中でエンジンが受けるか、
  develop がどこにどれだけの速さで建てるか、`--update-all` がすぐに建てるか。

### 在庫とシミュレーションの歩み (`stock`・`steps`: debug の命令、試験用のセーブ向け)

```sh
python3 tools/tf3ctl.py stock list --entity 51                       # 読むだけ
python3 tools/tf3ctl.py stock set --entity 51 --stock 0 --amount 100 [--cargo COAL] [--dry-run]
python3 tools/tf3ctl.py stock set --entity 601 --stock -1 --amount 30 --cargo <cargo>   # 車両の積み荷
python3 tools/tf3ctl.py speed 0                                      # 先に一時停止
python3 tools/tf3ctl.py steps 500 [--dry-run] [--allow-running]
```

- **試験用のセーブで使ってください。** 読み込んでいるセーブを tf3ctl は確認しません。答えに `saveNote` が付きます。
  ゲームの debug の命令 (`api.cmd.debug`) を送り、プレイヤーにはできない形で
  ゲームを変えます (貨物が湧く、時計と関係なくシミュレーションが進む)。試験用の地図での待ち時間 (港の在庫が貯まる、
  車両が満載で着く、町が育つ) を短くするためのものです。ゲームを変える命令として、ほかのクライアントに警告が出ます
  (dry run も)。
- `stock list` は、本体の debug パネルと同じ読み方で在庫の一覧を読みます: entity の `STOCK_LIST` コンポーネント、
  0 から数える stock の番号 (`stock set --stock` に渡す番号)、stock ごとの `type`・`cargoType`・`cargo` (貨物の種類の
  名前)・`capacity`・`count` (`getStockCount`)・`cargoTypes` (その stock が受ける貨物の種類ごとの名前と `count`)。
  entity そのものに `STOCK_LIST` が無い産業・町の建物・倉庫は、その `stockList` の entity をたどります (`via`)。その
  entity が持ち主そのものでもかまいません (ゲームでは、倉庫の WAREHOUSE の entity が自分の在庫の一覧だった。2026-11-23 に計測)。
  construction (`build` が答える id。倉庫のものなど) は、その subconstruction のうち在庫の一覧を持つ倉庫・産業・町の
  建物 1 つをたどります (`via` は `CONSTRUCTION>WAREHOUSE`、`owner`・`construction` も出す)。本体が倉庫の
  construction から窓を開くときと同じく subconstruction からたどります (本体は最初の 1 つを取りますが、ここでは推し量らず、
  2 つ以上あれば名前を挙げて断ります)。subconstruction に無ければ、`WAREHOUSE.construction` がその construction を指す倉庫を
  探します (ゲームでは、倉庫の construction の subconstructions に倉庫が入っていなかった。2026-11-23)。それでも無ければエラーにします。倉庫
  (`warehouse.con`) の在庫は全部 1 つの一覧にあります: 汎用のモジュールの分は混合の stock 1 つ (1 つ 500 を足したもの)、
  専用のモジュール (bulk・liquid・flatbed・goods) は 1 つずつ stock になります。capacity が 0 の stock は入らないので、
  stock 0 が混合になるのは汎用のモジュールがあるときだけです。番号は `stock list` で見てください。モジュールの無い倉庫には stock がありません。
  車両には在庫の一覧が無いので、`kind` が `vehicle` になり、積める貨物の種類ごとの `cargo` (`capacity`・`count`)
  が出ます (乗客は本体のパネルと同じく外し、断ります)。決めるのは `--stock -1 --cargo NAME`。**車両は路線に付けてから**:
  路線のない車両に積み荷を入れるとゲームが落ちたので (エンジンの assert `transportVehicle.line.GetId() >= 0`、船 2 隻、
  2026-11-24)、`stock set` は `--dry-run` でも送る前に断ります (`stock list` に車両の `line` が出ます)。路線に付けた船ではこれまで落ちていません。船以外は測っていません。`--cargo` には
  `stock list` の `cargo` をそのまま渡します。id は `industry-stocks`・`stations`・`entities --kind warehouse`
  (または `build` の答え)・`vehicles` で分かります。`window --warehouse NAME` は、`entities --kind warehouse` に出る名前で
  倉庫の窓を開きます。**ゲーム内では未確認**: 倉庫の在庫の一覧 (本体のソースから読んだもの。計測はまだ)、倉庫の WAREHOUSE
  の entity に選べる名前があるか。
- `stock set` は `api.cmd.debug.makeStockSetCargoAmountCmd(在庫の一覧の entity, stock, amount[, cargo])` を送ります
  (cargo は指定したときだけ。本体のパネルも在庫の一覧の stock には付けない)。**混合の stock** (`cargoType` が -1。倉庫の
  汎用の stock など) に貨物を指定したときは、stock を **-1** にして貨物の名前と組で送ります (`sentStock` が -1、`form`)。
  本体のパネルが車両の積み荷を貨物ごとに決めるときと同じ形です。stock の番号のまま送ると、エンジンは名前を見ませんでした
  (穀物を指定してレンガが入った。2026-11-23)。貨物が1種類の stock と、`--cargo` なしの混合の stock は、これまでどおり
  stock の番号で送ります。**計測** (2026-11-23、倉庫の混合の stock): stock -1 の形でも何も入りませんでした (穀物を指定して、
  穀物 0、ほかの貨物も 0、`steps 5` のあとも 0)。エンジンは success を返しました。混合の stock に種類を選んで入れる道は、
  デバッグの命令にはありません。それでも送ります (産業や駅の混合の stock は測っていない) が、答えに `warning` を付け、
  数が前のままならエラーにします (下)。`--cargo` なしなら、混合の stock の番号で既定の貨物が入ります。送る前と後に一覧の
  数を全部読み、ほかに動いた数を `elsewhere` に挙げます。そのどれかが頼んだ量ちょうどになり、頼んだ所には入っていなければ、
  エンジンが別の所に入れたので、ok にせずエラーにします。エンジンが success と言ったのに、頼んだ所の数が前のまま
  (頼んだ量とは違う) なら、何も入らなかったのでエラーです (「nothing went in」。混合の stock ならそのことも書く)。車両の積み荷は
  warning (「reads back」) のままです (読み戻せるまでの時間を測っていない)。それ以外の動き (動いているゲームの生産・搬入) は warning です。送る前に断るもの: 一覧に無い stock の
  番号、stock の capacity (車両ならその貨物の capacity、ほかは 100000。混合の stock ではほかの貨物と合わせて) を超える量、乗客、stock や車両が受けない貨物、
  エンジンに無い entity。答え: `before`、`after` (callback の数フレーム後に読む)、`success`、`engineResult` (callback が
  返したもの)、`stockList` (送った先の entity)。`--dry-run` は何も送らず、`before` と `functionPresent` を答えます。
- `steps N` (1〜10000) は `api.cmd.debug.makeGamePerformSimulationStepsCmd(N)` を送ります。1 歩はゲームの時間で
  200 なので、20 歩でゲームの 1 日です。1000 歩は約 15 秒かかりました (2026-11-22 に一時停止中、小さな試験用のセーブで計測)。エンジンの
  callback は全部の歩数が進む前に来る (歩数は何フレームにも分かれて進む) ので、答えは `updateCount` が N 増えるか、
  `gameTime` が N × 200 進むまで待ちます (どちらで決まったかは `doneBy`)。待つのは最長 `waitSec` (N / 10000 × 200 秒、
  最低 30 秒。tf3ctl はさらに 30 秒待つ) です。答え: `before` と `after` (`gameTime`・`updateCount`・`tickCount`・
  `date`)、`gameTimeDelta`、`updateCountDelta`、`gameTimePerStep`、`callbackSec`、`waitedSec`、`timedOut`、
  `stepsPerSec`、`speedup`、`success`、`engineResult`。時間切れはエラーで (`timedOut` が true)、それまでに進んだ分を
  入れます。エンジンは残りの歩数をそのまま進めるので、それがまだ進んでいるかもしれない間 (と、別の `steps` が待って
  いる間) の `steps` は、終わるまで断ります。
- **先に一時停止してください** (`speed 0`)。ゲームが進んでいると、同じ数字がひとりでに進むので、待ちが早く終わり、
  差が歩数の分ではなくなります。ゲームが進んでいるときの `steps` は断ります (`--dry-run` は断らず `warning` を付けます)。`--allow-running` を付けると送り、
  答えに `warning` が付きます。
- ゲームに無い (nil の) debug の関数は呼びません。答えにそう出ます (`functionPresent` が false、`sent` が false)。
  エンジンが断ったとき (`success` が false)、命令を作る・送るときのエラー、30 秒 (`steps` は `waitSec`) callback が
  来ないときはエラーで、エンジンが文を返したときはそのまま入れます。
- **ゲーム内で確認済み** (2026-11-22、一時停止中): 製品版は `steps` を実行します。1 歩はゲームの時間で 200
  (`steps 1` / `10` で 200 / 2000、update count 1 / 10)。1000 歩は、早い callback のあと約 15 秒かけて進みました。
  **ゲーム内では未確認**: 待つようにした答えそのもの、`stock set`、駅が自分の在庫の一覧を持つか。

### 車両の型の運行経費 (`running-costs`) と財務の行 (`finance`)

```sh
python3 tools/tf3ctl.py running-costs --model bus_1900                 # 読むだけ
python3 tools/tf3ctl.py running-costs --model bus_1900 --scale-running 2 [--set-maintenance 1.5] [--where gui]
python3 tools/tf3ctl.py running-costs --model 101 --set runningCostScale=2 --scale maintenanceScale=3
python3 tools/tf3ctl.py finance [--since GAMETIME] [--vehicles 601,602] [--columns 4]   # 読むだけ
```

ゲームの途中で書き換えた運行経費を、エンジンが請求に使うかを測るためのものです (同じ道で書き換えた購入価格は、
支払い・店の表示・売却額に効いた。2026-11-16 に試験用の MOD で計測)。

- 書かない `running-costs` は、型の `metadata.cost` (`price`・`priceScale`) と `metadata.maintenance`
  (`lifespan`・`runningCosts`・`runningCostScale`・`maintenanceScale`・`topSpeedMaintenanceFactorPenaltyPerLevel`)
  を GUI の Lua の状態から読み (`view`)、その型の部品を持つ会社の車両 (`vehicles`、`--limit` 台まで、初期設定 20。
  `vehicleCount` は全部の数) と、車両ごとにエンジンが出す年あたりの運行費 (`getRunningCost`、車両の窓の表示と同じ)
  を返します。`--model` は id かファイル名の一部 (`models --grep` で一覧)。読む命令なので、いつでも通ります。
- **書く形 (`--set-running X`・`--scale-running K`・`--set-maintenance Y`・`--scale-maintenance K`・`--set
  FIELD=X`・`--scale FIELD=K`。FIELD は `runningCosts`・`runningCostScale`・`maintenanceScale`) は試験用のセーブだけ**
  で、`road --ignore-errors` と同じ決まりです: 読み込んだセーブが試験用の名前であること (名前の無い新しいゲームは
  `save probe-NAME` のあと `load probe-NAME`)、動いているゲームに coop の印が無いこと、owner の検査 (ゲームを変える
  命令)。MOD の側でもセーブの名前をもう一度確認します。型には整備費の額そのものは無く `maintenanceScale` だけなので、
  `--*-maintenance` はそれを書きます。
- 欄はその場で書き (`modelRep.get(id).metadata.maintenance.<欄> = 値`)、読み直します。`--where script` (初期設定)
  はゲームスクリプトで書きます (試験用の MOD が価格を書いたのと同じ)。MOD の設定 **ゲームスクリプトの命令** をオンに
  する必要があります: `launch` / `load` に `--param hummer_remote_probe:gameScript=2`。オフ (初期設定) のとき、
  この MOD のゲームスクリプトはどのイベントにも登録せず、状態も持ちません。
  `--where gui` は GUI の Lua の状態で書き、(設定がオンなら) ゲームスクリプトがその型を読み直します (ゲームではまだ
  試していない道です。シミュレーションが型を読んでいる間に、そこで書いて安全かは分かっていません)。
- `load` (と `launch` / `restart --load`) は、試験用でないセーブに `--param hummer_remote_probe:gameScript=2` を
  付けると断ります。人のセーブを、ゲームスクリプトが受け付ける状態で読み込まないためです (新しいゲームには付けられます)。
- 答えには `before` (`gui`、ゲームスクリプトで書いたときは `script` も)、`writes` (欄ごとに `from`・`to`・`ok`・
  エンジンのエラーの文言そのままの `error`・`readBack`・`stuck`)、`after` (`script`・`gui`)、`vehiclesBefore` と
  `vehiclesAfter` (車両ごとの `runningCostPerYear`)、`wroteIn`・`testSave`・`gameTime` が入ります。値が入らなかった
  欄があれば `ok` は false。ゲームスクリプトは 15 秒以内に自分の状態で答えます。答えが無ければそう書きます
  (ゲームスクリプトで書いたときは、ログを見る: `log --grep "game script"`)。
- 書いた値はその起動のあいだだけ続きます。読み込むたびに型は読み直されます。
- `finance` は、本体の財務の窓と同じ読み方で財務の表を読みます (`computeFinanceTable`、`--columns` 列、年は
  `header`)。輸送手段ごとの行 (`type`・`maintenance`・`construction`・`values`) と、列ごとの合計 `vehicleRunning`
  (`MAINTENANCE` / `VEHICLE` の行: 車両の運行費) と `vehicleMaintenance` (`MAINTENANCE` / `VEHICLE_MAINTENANCE`)。
  `sameAs` は、行が前の輸送手段のものと同じもの (ゲームでは TRAM が ROAD の行を返した)。`fleet` は会社の全車両の
  `[since, gameTime]` の `calculateBalance` (運行と収入の記帳。`running` は `Maintenance.VEHICLE` だけ、`maintenance`
  は `VEHICLE_MAINTENANCE`、`all`)。`--vehicles` で車両ごとにも出します。`--since` が無ければ 1 年の 12 分の 1 前
  から。額はエンジンの記帳のまま (費用は負)。ゲームではまだ確認していません。

### 道路の脇の町の建物の区画 (`parcels`、読むだけ)

```sh
python3 tools/tf3ctl.py parcels --edge 9010 [--no-list]          # 道路の1区間: 左右それぞれの区画
python3 tools/tf3ctl.py parcels --rect=-100,0,400,300 [--list]    # 範囲の中の道路の区間を全部 (1辺 2000 m まで)
```

- 読むだけです (ほかのクライアントに警告は出ず、何も送りません)。町の建物は区画 (parcel) に建ち、エンジンは区画を
  道路の区間 (edge) ごとに左右に分けて持っています。`parcels` はそれを区画のシステムに聞きます:
  `api.engine.system.parcelSystem.getSegment2ParcelData()` を1回 (区間 -> `ParcelData`、区画の entity の左右の一覧)。
  この表に無い区間には区画がありません: `inParcelMap` が false、左右とも 0。表が読めないときだけ
  `getParcelData(edge)` を、道路 (street) の区間についてだけ聞きます (`source` にどちらかが出ます)。
- 区間ごとに: `street` (`BASE_EDGE_STREET` がある)、`node0` / `node1`、`from` / `to` と `length` (m、上から見た長さ)、
  `inConstruction` と `construction` (`streetConnectorSystem.getConstructionEntityForEdge`)、`fields` (読めた
  `ParcelData` の欄の名前。tealdef では `leftEntities` と `rightParcels`。`leftParcels`・`rightEntities` も読みます)、
  そして `left` / `right`: `count`、`built` (町の建物が建っている区画の数、
  `townBuildingSystem.getParcel2BuildingMap` から)、`area` (m²)、`--no-list` でなければ `parcels`: 区画ごとの `id`・
  `building`・`left`・`streetSegment`・`curveParam`・`offset` と、`x` / `y` / `z` (面の点の平均) と `area` (面を上から
  見た面積)。これらは区画の `PARCEL` コンポーネントから読み、`api.type.ComponentType.PARCEL` があるときだけです
  (`parcelComponent`)。`sideMismatch` は、区画自身の `left` が入っている一覧と食い違う数です (欄の名前が正しければ 0)。
- `--rect x0,y0,x1,y1`: octree で範囲の周りから見つけた道路の区間のうち、端か真ん中が範囲に入るもの (範囲を横切る
  だけの区間と線路は入りません)。番号順、`--list` が無ければ数だけ、一覧は 400 区間まで (`truncated`)、`totals`
  (`edges`・`withParcels`・`left`・`right`・`built`・`inConstruction`)。`--edge` に渡す番号もここで分かります。町の中心で `--list` を付けると、答えが大きくなることがあります。
- `ParcelData` に上の欄の名前がどれも無い区間には、0 と 0 の代わりに `unreadParcelData` (そのキー、または表示の文字列) が
  付きます。`totals.unreadParcelData` はその数です。2つの表は、`--edge` 1本でも命令ごとに全部読みます。
- entity でない番号、道路の区間でない番号は断ります。エンジンの呼び出しはすべて pcall の中で、エンジンが「ある」と
  言った entity についてだけ聞きます。
- **ゲーム内では未確認** (2026-11-23 に書いた): 表と `PARCEL` コンポーネントが GUI のスクリプトで読めるか、欄の名前、
  値。

### ある点の周りにある物 (`around`、読むだけ)

```sh
python3 tools/tf3ctl.py around --at 1200,800 [--radius 100] [--kinds town_building,street,field] [--limit 200]
```

- 読むだけです (ほかのクライアントに警告は出ず、何も送りません)。円を囲む正方形で octree を1回たどり
  (`octreeSystem.findIntersectingEntities`)、渡された entity と箱を1つずつ見て、`--radius` 以内 (箱まで、道路・線路は
  線から幅の半分を引いた距離) のものを残します。近い順に `--limit` 件まで (初期設定 200、最大 2000。超えたら `truncated`、
  全部の数は `total`)。種類ごとの数 `counts`、octree が渡した数 `scanned` (10000 まで。超えたら `scanTruncated` と
  `dropped`)、かかった時間 `ms` (`octree`・`classify`・`total`、ゲームの中での時間。`api.type.Clock` で測る。アプリの時間は
  1フレームの間ずっと同じなので、前はいつも 0 だった)。ゲームの GUI の1フレームの中で
  回るので、2 秒で打ち切ります (`timeTruncated`。見た数は `looked`)。`--radius` は 2000 m まで。
- 1件ごと: `id`・`kind`・`name`・`x` / `y` / `z` (箱の中心)・`box` (`x0`・`y0`・`z0`・`x1`・`y1`・`z1`)・`sizeX` / `sizeY` /
  `height`・`dist`。種類 (最初に見つかった component で決める): `street` / `track` (`BASE_EDGE` の roadType。`template`・
  `from` / `to`・属する `construction`・`halfWidth`)、`node`、`town_building` (`TOWN_BUILDING`: `town`・`townName`・
  `construction`。その construction も `building` 付きで。`building/...` のファイルの建造物も)、`station` / `depot` /
  `industry` / `construction` (`CONSTRUCTION` の駅・車庫・産業で分ける。`fileName`。1回の答えで 50 件まで、`place`・
  `ends`・`mouths` を `build` の答えと同じ形で、`local` 付きで)、`field` (`FIELD`)、`town` (`TOWN`: 箱は町全体)、`asset`
  (`ASSET_GROUP`: 木・岩)、`model`、`moving` (車両・人・動物)、`map` (道路・線路・町を除き、縦横とも 2000 m 以上の箱。大きさだけで決め、元の種類は
  `mapOf`。ゲームでは種類 other の entity 2 が 14,336 m 四方だった。2026-11-23)、`other`。`--kinds` でいくつかに絞れます
  (`all` で全部)。初期設定は `node`・`moving`・`map` 以外の全部です。`ms` がフレームの中でも進む時計になったので、2 秒の打ち切りも効くようになりました。
- 箱は octree の bounding volume で、**軸にそろった箱**です。斜めに置いた駅や斜めの道路は、実物より大きく出ます。道路と
  線路の幅 (`halfWidth`、6 m と 3 m) は**推測**です。octree に入っていない物は出ません (木の asset group が入っていなければ、
  木も出ません)。
- **ゲーム内では未確認** (2026-11-23 に書いたもの): octree にどの entity が入っているか、町の建物の箱が `TOWN_BUILDING`
  の entity にあるか construction にあるか、大きな地図でかかる時間。
- `--lanes`: 出した `street` と `track` に、`lanes --edge` と同じ形の `lanes` を付けます (transport network は除く)。近い順に
  100 件まで、2 秒まで (残りは `lanesSkipped`、時間で切れたら `lanesTimeTruncated`)。答えに `lanesRead` (読めた本数)・
  `lanesNote`・`ms.lanes`。

### 道路の車線 (`lanes`、読むだけ)

```sh
python3 tools/tf3ctl.py lanes --edge 9010[,9011,...] [--no-network]
```

- 読むだけです (ほかのクライアントに警告は出ず、何も送りません)。道路・線路の edge を id で 20 本まで
  (`around --kinds street`・`road --inspect-node` で分かる)。聞いた順に1本ずつ答え、読めないものは `error`
  (その entity が無い、`BASE_EDGE` が無い)。1本でも読めれば `ok`。`read` / `asked`。
- edge ごと: `edge`、`roadType` (`STREET` / `TRACK`)、`edgeType` (`NORMAL` / `BRIDGE` / `TUNNEL`)、`streetType` (道路の
  テンプレート、`BASE_EDGE` の roadTemplate)、`roadStyle`、`node0` / `node1`、`from` / `to`、`chord` (両端の間の直線の m)、
  `distance` (`BASE_EDGE` の値をそのまま)、`width` (全車線の幅)、`laneCount`、`tramTrackType` (車線から決める。
  `ELECTRIC_TRAM` のある車線があれば `ELECTRIC`、無くて `TRAM` があれば `YES`、どちらも無ければ `NO`。どれかの車線の mode が
  名前に読めなければ `unknown`)、`tramLanes`、`busLanes` (`BUS` があり `CAR` が無い車線) と `hasBusLane`、`roadLanes`、
  `vehicleLanes`、`sidewalks` (車線の番号)。`street`: `BASE_EDGE_STREET` にある `streetType`・`tramTrackType`・`hasBus`
  (TF2 の欄。TF3 の tealdef には無い)。その `tramTrackType` が車線からのものと違えば `tramMismatch`。
- edge ごとに、ほかに (2026-11-26 に書いた): `tangent0` / `tangent1` (`BASE_EDGE` の値。どちらも `node0` から `node1` の
  向き)、`node0Position` / `node1Position` (node そのものの点、`BASE_NODE`。読めない node のものは書かない)、
  `endOffset0` / `endOffset1`: `from` (`position0`) と `to` (`position1`) から node の点を引いたもの (`x`・`y`・`z`・
  地図の上の `flat`・`length`)。道路の端は node の脇にあることがあります (広い道路の車線の脇につないだ細い道路: 4.5 m)。
  `road --from-node ID --from x,y` でそういう端を建てます。ずれが車線に対してどちら向きかは、ゲーム内では未確認です。
- 車線ごと (`lanes`、`BASE_EDGE` の `laneConfigs`、32 本まで): `index` (`node0` から `node1` を見て一番左が 1。type.d.tl の
  とおり左から右)、`atNode0` / `atNode1` (`road --inspect-node` の `laneConnections` がそれぞれの端で使う 0 始まりの番号:
  `index - 1` と `laneCount - index`)、`vehicleIndex` (乗り物の mode を持つ車線の中で左から何本目) と `outer` (その最初か
  最後)、`side` (`left` / `middle` / `right`。幅だけで決め、真ん中から車線の幅の 1/4 以内なら `middle`)、`centre`・`left`・
  `right` (edge の真ん中からの m、offset を足したもの、右が +)、
  `forward` と `direction` (`node0->node1` か `node1->node0`)、`modes` (transport mode の名前: `PERSON`・`CARGO`・`CAR`・
  `BUS`・`TRUCK`・`TRAM`・`ELECTRIC_TRAM`・`TRAIN` など)、`modeKeys` (読んだままのキー。名前は type.d.tl の 16 個を `enum[名前]` で引く。名前の無いキーがあれば `unnamed`、64 個を
  超えたら `modesTruncated`)、`speed` (m/s) と `speedKmh`、
  `width`、`offset`、`height`。
- `network` (`--no-network` を付けないとき): その edge の `TRANSPORT_NETWORK` の edges をエンジンの順に (64 本まで、
  全部の数は `networkCount`): `index` (0 から)・`modes`・`speedLimit`・`length`・`width`・`geometry`・`offset` (cubic offset
  spline のもの)。ここでは車線と突き合わせません。
- `centre` は**計算したもの**です。幅を左から右に並べ、車線の `offset` を足します。バニラのテンプレートの offset は小さな
  ずらし (town_new_medium_tram_electrified: 歩道 0.15 / -0.15、トラムの車線 -0.5 / 0.5) なので、右が + というのはその数から
  の推測です (`side` には使いません)。幅がそろわないときは、`side` を車線の番号だけで決め、m は出しません。2 本の edge が
  端どうし (node1 と node0) でつながるなら左右はそのまま、node1 どうしなら片方の左がもう片方の右です。
- **ゲーム内では未確認** (2026-11-23 に書いたもの): ゲームの `laneConfigs` がテンプレートの順と offset のままか、
  `transportModes` のキーが enum の値か (`modeKeys`。歩道が `CARGO,PERSON` と読めれば合っている)、transport network の
  edges が車線ごとにどうなっているか。

### 建造物を置ける場所 (`fit`)

```sh
python3 tools/tf3ctl.py fit --res depots/road/road_depot/road_depot.con --at 1200,800 [--radius 100] [--angle 1.5708]
python3 tools/tf3ctl.py fit --res road_depot --at 1200,800 --mouth 0,-35 [--link 8,40] [--link-edge] [--houses 5]   # つなぐ道路つき
python3 tools/tf3ctl.py fit --res <駅の .con> --at 1200,800 --mouth 0,-12 --track --houses 5 [--catchment 150]
python3 tools/tf3ctl.py fit --res x.con --at 1200,800 --size 20,30 --check 0      # 読むだけ: エンジンに聞かない
```

- 何も建てません。大きさは `--size W,D[,X,Y]` (建造物の向きでの箱)。無ければ、その点に向きを付けずに置いたときの
  エンジンの箱を使います (`build --dry-run --engine-check` を1回)。次に、円とそこへ届きうる範囲で `around` を1回読み、
  ここで探します (tools/tf3ctl.py の `fit_search`。ゲームなしでテストする純粋な関数)。点から外へ候補を並べ
  (`--step` ごとの格子、初期設定 4 m)、向きごとに (`--angle`、無ければ 4 方向)、回した箱が、around の箱 (町・木・node・
  動く物・map と、縦横とも 2000 m 以上の箱は除く。地図そのものの箱が、前は全部の候補の邪魔をしていた。2026-11-23) から 0.5 m、道路と線路の線から幅の半分だけ離れていれば残します。`--mouth DX,DY` (建造物の向きでの
  道路の出入り口。build の答えの `connectable` の mouth、または `around` の `mouths` の `local`。道路の車庫は 0,-35、
  2026-11-23 に計測) を付けると、出入り口から短いまっすぐな道路 1 本で、建造物に属さない道路につなげる位置だけを
  試します。出入り口を道路の node には重ねません (道路の車庫の出入り口を行き止まりの node に重ねると、同じ所に node が
  2 つになり、`--join-streets` の有無にかかわらず「建設不可」だった。2026-11-23)。つなぐ道路は、出入り口のある箱の面から
  まっすぐ外へ (出入り口が箱の外にあるときは、はみ出している側の面)、出入り口から道路の中心線まで `--link MIN,MAX` m
  (初期設定 8,40)。道路の node で終わる形を、そこのどの区間とも 60 度以上離れる向きで (行き止まりなら、まっすぐ先から
  120 度まで。30 度だと 2 本の道路の幅が node から 16 m ほど重なる)、15 度ごとの向きで、点に近い順に試します。
  `--link-edge` を付けると、node の候補のあとに、区間の途中で終わる形 (区間と 45 度以上で交わり、端から 4 m 以上) も
  試します。初期設定では試しません: `road` は node にしかつながないので、区間の途中に新しい node ができます (ゲーム内では
  未確認)。`--angle` を付けると、その向きにちょうどなる区間だけです。つなぐ道路は、幅の半分 (つなぐ先の道路の幅。
  3 m 以上) と 0.5 m を、ほかの箱と区間から離します。`--track` なら、これまでどおり出入り口を線路の区間の端に重ねます
  (その端の区間は、そこで箱に触れてかまいません)。`--mouth` が無ければ、これまでどおりです。around が同じ建造物を
  近くに挙げていれば、その出入り口を `mouthHint` に出します。`--houses N`: 箱の中心から `--catchment` (初期設定 150 m) 以内に町の建物が N 戸以上。
- そのあと、よい順に `--check` 件 (初期設定 3、0 なら聞かない) をエンジンに聞きます (`build --dry-run --engine-check`。
  ゲームを変える側に数えるので、先にゲームの時間をもらってください)。最初に建てられると言われたものが答えです:
  `place` (`x`・`y`・`angle`・点からの `offset`・`centre`・`houses`・`roadDist`・`--mouth` なら `link`、`--mouth --track`
  なら `joinAt`)、`build` (建てるコマンド)、`--mouth` なら `link` (`from`: 出入り口、`to`、`length`、`on`: node か edge、
  `pieces`) と `road` (`road --from=... --to=... --snap 3`。build のあとに打つ。from は出入り口の新しい node につながる。
  道路そのものはエンジンに聞いていない)、`refusedFirst` (エンジンが断った候補と `hits`)。エンジンが警告つきで建てられると言った候補と、町の建物を
  取り除くと言った候補は採りません。その答えはエンジン自身の context でのもので、本番の build は畑も建物も集めない
  ためです (道路で 2026-11-23 にそうして断られた)。`errorState.infos` だけがある候補も断られたと数えます (`build` を参照。
  そういう build は断られる、2026-11-23)。`critical` が立たずに `errorState.messages` がある候補も同じです (`build` を参照。
  2026-11-26 に `衝突` で断られた)。エンジンに聞けなかったときは、断られたとは数えずに止まります
  (`checked: false`)。空きが無ければ `ok: false`・「no free place」と、`blockers` (いちばん多くの候補を邪魔した物:
  id・種類・名前・位置・数)。空いていても家が足りなかった候補の数は `tooFewHouses` です。試す候補は 200000 個までです
  (それぞれ近くの物とだけ比べます。家 1600 戸の町で 85000 個がおよそ 2 秒)。途中で止まったときは `complete` が false
  になり、`searched` (どこまで外へ探したか) が付き、誤りの文もその距離で書きます。格子の点は 100 万個まで
  (`--radius` / `--step`)。`--check 0` は、探した一番の候補を確認せずに返します (`checked: false`)。
- 箱は octree のもの (軸にそろった箱。斜めの物は大きく出る) で、幅は推測です。探すのは候補を絞るためで、決めるのは
  エンジンの確認です。水際 (港) は見ていません。
- **ゲーム内で確認済み** (2026-11-23): `--mouth` なしで町の近くに道路の車庫を探し、返った `build` で 1 回で建った。
  **ゲーム内では未確認**: `--mouth` のつなぐ道路と `road` (node に重ねて断られたあと、2026-11-23 に書いたもの)。

### その場所へ行けるか (`reach`、読むだけ)

```sh
python3 tools/tf3ctl.py reach --api                       # エンジンの関数があるかだけを見る (何も呼ばない)
python3 tools/tf3ctl.py reach --target 51                 # 産業・町の建物・駅・construction
python3 tools/tf3ctl.py reach --town 11 [--limit 20]      # 町の行き先の集計と、町の問題
python3 tools/tf3ctl.py reach --problems                  # 全部の町の問題 (Disconnected、Overlength)
python3 tools/tf3ctl.py reach --from 4100 --to 51 [--mode walk|drive|lines|all] [--radius 40]
python3 tools/tf3ctl.py reach --from=-120,880 --to 51 --mode walk   # 端に点 x,y も使える
python3 tools/tf3ctl.py persons --town 11 [--limit 2000]  # 町の住民と、それぞれが届く行き先の数
python3 tools/tf3ctl.py persons --destination 51          # その産業を行き先に持つ人 (働き手)
```

- 読むだけです (ほかのクライアントに警告は出ず、何も送りません)。町の人が働き先へ行かない理由を調べるために作りました。
- `--target E`: エンジンの行き先の一覧 `api.engine.util.pathfinding.getTargetsByLandUse()` (命令ごとに1回。地図の
  行き先が全部入っているので、全部読むのは聞かれたものだけ)。答えの `entries` は、その entity が入っている一覧ごとに
  1つ: `isReachableWalk`・`isReachableDrive`・`isReachableLines`、`capacity`・`freeCapacity`・`destinationWeight`、
  `edgeWalk` / `edgeDrive` (`entity`・`index`: 行き先へ通じる網の edge)、`landUseKey` (一覧そのもののキー) と
  `landUseGuess`。`counts`。`landUse` (その entity の `PERSON_CAPACITY` の種類。推測の当否はこれで見る)。行き先で
  ない (家、働き口の無い産業) ときは `found` が false で `why` が付きます。答えは番号だけでなく pairs でも読みます
  (0 から始まる表、名前をキーにした表も読める)。行き先が1つも読めなかったときは `targetsRead` が false、`found` は
  null (「行き先でない」とは言わない) で、`raw` に来たものの形 (型、`#`、最初のキー、数段下まで) が付きます。
  `reach --town` では `targetsWhy` にそう書き、`notTarget` は出しません。`read` は読み方 (`targets` か `top`、続いて
  `index`・`pairs`、番号でしか読めない `targets` の2つ組なら `index1` / `index0`、一覧に包まれていない entries なら
  `flat`。`targets` は名前で、だめなら getter として、それでもだめなら metatable から読み、`raw.probe` / `raw.fieldProbe`
  にそれぞれの読みの結果 (型と userdata の表示、nil、またはエラー) が出ます。`__index` が2つ組を2つの値で返すときは
  `targets/values` (`probe.indexCall` にその並び)。何も来ないときは、次に見るために `probe.other_*` にほかの名前と
  番号での読みの結果が出ます)、`targetLists[].read` は一覧ごとの読み方です。読めない
  一覧が1つでもあると、見つからなかった entity の `found` も null にします。construction はその産業・町の建物・駅を、
  町の建物はその PersonCapacity の entity も探します (`candidates`)。建物の町 (産業なら construction に一番近い町)
  が分かれば `townProblems` (`api.engine.util.town.getTownProblems`: `problem` と相手の町 `with`) も付きます。
- `--town T`: 町の建物 (`townBuildingSystem.getTown2BuildingMap`、5000 まで読む) を種類ごとに (`byKind`)、店と
  働き口の行き先を数え (`counts`: `walk`・`drive`・`lines`・`none`)、`--limit` 件を届かないものから並べます。
  `notTarget` は住宅でないのに行き先でない建物の数。`problems` は上と同じ。
- `--from A --to B`: 道があるか。`api.engine.util.pathfinding.findPathNodeToNode` に `TransportMode.PERSON` (`walk`)
  と `CAR` (`drive`) を渡し、mode ごとに1回探します。端は entity か点: 建物そのものの `PERSON_CAPACITY` の
  `personNodes` (歩き) / `vehicleNodes` (車)、行き先なら `edgeWalk` / `edgeDrive` の node、
  駅なら terminal (歩きは `personNodes`、車は `vehicleNodeId`)、道路・線路の区間 (`BASE_EDGE`) なら、その区間自身の
  網の edge のうち、その mode が通るものの `conns` (`from.edge` に `node0` / `node1`)、交差点 (`BASE_NODE`) も同じ
  (自分の網の edge が無い交差点は、その網の node。mode は見ていない: `modesUnread`)、ほかは位置または点から `--radius` m
  (初期設定 40、500 まで) の中の網の node (`findTransportNetworkNodesInCircle`)。端ごとに 32 node まで。区間と交差点は
  円を使わないので、`--radius` で答えは変わりません (その mode の車線が無い区間は `found` が null で `why`。
  その mode の車線はあるが端の node が読めない場合とは、`why` を分けて書きます)。両方の端が円から持つ node と、
  片方の端が 40 m より大きい円から持つ node は、円が重なっていることしか言わないので、円から持った端から外し
  (両方とも円なら両方から。`sharedNode`、`droppedFrom` / `droppedTo`)、残りで探します (`fromNodes` / `toNodes` は
  探した node の数)。外して端が空になったときだけ、探さずに `found` は null、`trivial: true`、`why` を付けます
  (`--radius` を小さくして試す)。40 m より大きい円でこうして見つかった経路は、点の場所ではなく、円の中の相手の
  すぐ隣 (相手につながった区間) の node から始まっていることがあります (`wideNote`)。両方の端が自分で持つ node
  (区間・駅・行き先) を共有するとき (半径によらない) と、片方が自分で持つ node が相手の 40 m 以下の円にあるときは、
  `found: true`・`sameNode: true` で、`sameNodeFrom` / `sameNodeTo` にそれぞれの端がどこから持ったか (`circle`・
  `edge`・`node`・`terminal`・`target`・`personCapacity`) が出ます。円は平面 (点と半径だけで、高さが無い) なので、
  橋のそばや下の点の円は、40 m でも、上と下の両方の node を含みます。円から取った端は違う高さから始まることが
  あります (円を使った探索には `circleNote` が付く)。確実にするには、端に道路の区間の id を指定します。`paths` の mode ごとに:
  `found` (端に node が無いときは null で `why`)、`edges`、`pieces` (経路の網の entity の数、最初の 50 が
  `pieceIds`)、`ms`、node をどこから取ったか (`fromFrom` / `toFrom`)。見つからなかったときは、この探し方でそもそも
  道が見つかるとゲームで分かるまで `unverified: true` が付きます (まず、つながっていると分かっている2点で試す)。
  100 ms 以上かかった探索はログに出ます。費用はエンジンが返しません。路線の経路探しは
  呼べる口が無いので、`lines` は行き先の `isReachableLines` だけです (`--mode lines` は探しません)。
- `persons --town T` は、町の住宅を家にしている人 (建物ごとの `getSimPersonsForDestination`)、`persons
  --destination E` は E を行き先に持つ人 (E に `PERSON_CAPACITY` が要る) を並べます。`persons` の各人に
  `reachable` (`walkDrive`・`lines`: エンジンの `landUse2ReachableWalkDrive` / `landUse2ReachableLines`、土地利用
  ごとに届く行き先の数) が付き、`summary.reach` は一覧の位置ごとに、1つでも届く人の数を数えます (`none`: どちらでも
  何にも届かない人)。
- **ゲーム内では未確認** (2026-11-23 に書いた): `getTargetsByLandUse` と `getTownProblems` が GUI のスクリプトにあるか
  (`reach --api` で分かる)、`getTargetsByLandUse` の答えの形、どの一覧がどの土地利用か (一覧は2つ: 商業・工業と推測)
  と `reachable` の2つの数も同じ、`findPathNodeToNode` がこの node どうしで歩きの道を見つけるか (別の MOD の覚え書き
  には、駅の terminal の node どうしでは何も返らなかったとある)、大きな地図での1回の探索の時間。区間と交差点について
  (2026-11-24 に書いた): ゲームでの網の edge と `conns` の中身 (区間の車線が交差点の網の node で終わり、つながった
  2つの区間が node を共有するのか、探索でだけつながるのか)、`transportModes` が `pairs` で読めるか。

### メインメニューからのマイMOD (`modhub`)

```
python3 tools/tf3ctl.py modhub status [--folder my_mod_1] [--wait 30]   # 読むだけ
python3 tools/tf3ctl.py modhub validate my_mod_1 [--timeout 300] [--messages 50]
python3 tools/tf3ctl.py modhub publish my_mod_1 --public yes|no --changelog "..." --first-upload [--version X.Y.Z] [--dry-run] [--timeout 900]
python3 tools/tf3ctl.py modhub publish my_mod_1 --public yes|no --changelog "..." [--previous-revision N] [--version X.Y.Z] [--update-metadata] [--dry-run]   # 更新
python3 tools/tf3ctl.py modhub publish-clear --yes
```

本体の「MODハブ > マイMOD」のページは、`<user data>/staging_area/<フォルダ>/` の MOD を一覧にし、C++ の物
`api.type.modhub.ModPublishHelper` を通して検証とアップロードをします (ボタンはそのメソッドを直接呼び、イベントは
送りません)。メインメニュー (`launch` / `restart` で起動し、セーブを読む前) で、probe は自分の分を1つ作ります。
`status` と `validate` は読む側だけを使い、`publish` (下) が唯一のアップロードで、狭い範囲に絞っています。staging の MOD を
変えるほかのメソッド (`setRemoteModId`・`refreshMod`・絵の設定など) と、`api.modhub` の書き込み (サブスクライブ・評価・
報告・ログインとログアウトなど) はどこからも呼ばず、テストでそれを確認しています。`publish`・`abortPublish`・
`PublishSettings` が `content/remote_modhub.lua` の印の付いた1か所にしか無いことも、テストで確認しています。セーブの中では、
3つのコマンドとも断ります。

- `status` は、`ModPublishHelper.new` が作れたか (作れなければゲームのエラーの文をそのまま)、`hasPrivilegedApis()`、
  backend、mod.io の状態 (初期化・起動時の確認が済んだか・busy / uploading・ログインの有無を true / false で。名前は
  返さない)、そして staging の MOD ごとに、フォルダ・id の value・題・`state` (Sync・Ready・Publishing・HasResult)・
  `modhubId` (有効か・値。前に上げた mod.io の id)・`modhubDetails` (mod.io にある中身: found・`visible`・題・版) と、
  ページが新規として上げるか、更新か、mod.io の MOD が消えたと警告するか (`upload`: new / update / remoteMissing) を
  返します。mod.io の準備と、staging の MOD が Sync を抜けるのを最大 `--wait` 秒待ち (`--folder` を付けたときはその
  フォルダの MOD だけ)、それから分かったことを返します (`timedOut` に何を待っていたかが出ます)。
- `validate FOLDER` は、ページの「再検証」のボタンと同じく helper の `validate` を呼び、終わるまで毎フレーム `update()` を
  呼び、結果をページと同じ数え方で返します (`text`、Critical / Error / Warning の件数、先頭のメッセージ)。
  `criticalPc`・`criticalConsole`・`levelPc`・`levelConsole` も返します。進み具合は 15 秒ごとに stderr へ。mod.io の準備を
  最大 30 秒、MOD が Sync を抜けるのを最大 60 秒待ちます。Publishing か HasResult の MOD (アップロードが持っている) には
  触りません。helper がまだ知らない MOD は、ページと同じく Sync とみなします。`--timeout` はこれらの待ちも含めた
  コマンド全体の上限で、過ぎると動いている検証を止めます (`abortValidation`。ページを閉じたときと同じ)。受け付けるのは
  設定ファイルの `modhub.validateFolders` にあるフォルダだけです (初期設定は空)。
- helper を作ると、ゲームは staging の MOD を mod.io と同期します。mod.io への読む要求で、書き込みはしません。
- helper は、mod.io の準備ができてから最初の modhub のコマンドで1度だけ作ります。`ModPublishHelper.new` が失敗すると、
  probe はそのエラーを覚えて、メインメニューにいる間は作り直しません。あとの modhub のコマンドは全部同じエラーを
  返します。やり直すには、ゲームを起動し直してください。
- `validate` はゲームを変えるコマンドとして数えます (`--owner` の警告)。検証を数分動かし、その MOD で動いている検証
  (人がマイMOD のページで始めたものなど) を止めるためです。動いている間はマイMOD を開かないでください。ページは
  自分の helper を作ります。
- `status` と `validate` はゲーム内で動きました (2026-11-22)。「privileged api, not available to mods」の印があっても
  メニューの probe は `ModPublishHelper` を作れ、staging の MOD の id は `StagingArea,<フォルダ>` と読め、新規の MOD は
  Ready で `modhubId` が無効でした。ほかの staging の MOD が数分 Sync のままのことがあり、`status` は `--folder` が
  無いと全部を待ちます。

#### MOD を上げる (`modhub publish`)

`publish FOLDER` は、ページの「アップロード」「更新」のボタンと同じく staging の MOD を mod.io に上げます。
**最初のアップロード** (`--first-upload` を付ける。新しい MOD のページを作る) か、前に上げた mod.io のページの
**更新** (`--first-upload` を付けない) のどちらかです。ページはどちらも同じ呼び出し (`ModPublishHelper.publish`) で、
mod.io に MOD があるときだけボタンの名前を「Update」にします。このツールは、どちらのつもりかを推し量りません。新しい
MOD のページや公開にした MOD はゲームからは戻せないので、次のどれか1つでも外れると何も送りません。

- フォルダが、設定ファイルの `modhub.publishFolders` にある (validate の一覧とは別。初期設定は空。tf3ctl が命令と
  一緒に送るので、MOD も同じ一覧で確認する)。mod.io に上げ済みの
  フォルダは、`modhub.publishedIds` で mod.io の id にも結び付けてある: `--first-upload` は断り、
  更新は fileid のファイルがその id のときだけ送る (fileid のファイルが消えると新規に見えてしまうため)。
- `--public yes|no` (既定値なし) と、空でない `--changelog` が付いている。
- staging のフォルダの `_metadata/mod.io_fileid.txt` (最初のアップロードのあとゲームが mod.io の id を書くファイルで、
  次のアップロードが同じページの更新になるのはこれのため): `--first-upload` のときは**無い**こと (あると2つ目のページが
  できる)。`--first-upload` が無いときは**あり**、id が1つ書いてあること (無いと更新のつもりで新しいページができる)。
  この2つの取り違えは、何かを送る前に断ります。
- `_metadata/0.png` があり、PNG で、512x288 以上・8 MB 以下 (mod.io の決まり。無いとページも断る「No valid cover image
  found」)。
- `_metadata/modinfo.json` があり、項目が上限に収まる (バイトでなく文字数で数える)。`name` (mod.io の名前) は 50 以下、
  `summary` は 250 以下 (mod.io の上限。長い名前は、mod.io がアップロードを始めてから断る「code 13009」)。`description` と
  `--changelog` は 50000 以下 (ツールの歯止め。mod.io は上限を書いていない)。name・summary・description が空でなく、`tags` は
  あれば文字列のリスト。`--dry-run` は各項目の長さと上限を返す (`local.metadata`)。
- 「送った」の印 (下) が無い。
- 更新のときだけ: `mod.json` の `revision` が整数で、そのページに前に上げたものより大きい。前の版は、
  `publish_history.jsonl` (下) がそのフォルダとその mod.io の id について記録した `revision` のうち一番大きいもの
  (mod.io が受け取ったもの: 成功・部分的なエラー・fileid が遅れた場合)。履歴に無いとき (履歴が revision を残す前の
  アップロード) は、`--previous-revision N` で今 mod.io にある revision を渡す。最初のアップロードでは断り、履歴に
  revision があるときはそれと同じでなければ断る。
- `--version X.Y.Z` (付けなくてもよい。最初のアップロードでも更新でも): 頭に 0 の付かない整数で、Y と Z は 0〜99、
  `mod.json` の `revision` を X*10000 + Y*100 + Z と読んだものと同じ (revision 10003 なら 1.0.3 だけ、revision 1 なら
  0.0.1 だけ)。MOD も、ツールが送る revision とあらためて比べる。MOD の dry-run が送らないと答えたとき (ゲームに入って
  いる remote_probe が古く、無視した) は、ツールがアップロードを断る。
- `--update-metadata` (付けなくてもよい。更新のときだけ。`--first-upload` と一緒なら断る): 下の `updateMetadata` を参照。
  MOD の dry-run が、頼んだのと違う `updateMetadata` を送ると答えたとき (ゲームに入っている remote_probe が古く、いつも
  true を送る) は、ツールがアップロードを断る。
- ゲームの中で、最初のアップロード: MOD が Ready、`modhubId` が無効で mod.io に中身が無い (新規)。更新: MOD が Ready、
  `modhubId` が fileid のファイルの id で、mod.io にその MOD の中身がある (無いとページは「mod.io で消された、新しく
  作る」と出すので断る)。mod.io で公開の MOD に `--public no` は断る (そのときページの「Set Public」の欄は押せない。
  非公開の MOD は非公開のままでも公開にしてもよい)。どちらも: mod.io が初期化済みで、アップロードを
  許し、busy でも uploading でもない。ログインしている (していなければ `requiredUserAction: "login"` を返して止まる。
  ページならログインの窓を出す所)。手元のカバーの絵がある。
- 新しく回した検証 (ページがボタンを押せるようにする前と同じく、先に回す) に critical が無く、`levelPc`・`levelConsole`
  のどちらも Error・Critical でない。そのときページは人に「Proceed Anyway」を聞くが、ここでは答えない。
- ゲームの1回の起動でアップロードは1回だけ。

`--dry-run` は、検証を含めて上の全部を通し、送るはずの設定を返します。`publish` は呼びません。更新のときは、答えに
`update` も入ります: mod.io の id (`modioId`)、上げる名前 (`name`、modinfo.json の) と今 mod.io にある名前・公開か・版
(`modioTitle`・`modioVisible`・`modioVersion`)、新しい revision と前の revision (`revision`・`previousRevision`・
`previousFrom`: 履歴か `--previous-revision` か)、変更欄。どの答えにも `updateMetadata` (true / false: modinfo.json の
name・summary・description を送るか) と、`updateMetadataNote` か、`--update-metadata` を付けた更新なら
`updateMetadataWarning` が入ります (mod.io のページの説明文が上書きされるので、あとで入れ直す、という注意)。
`--update-metadata` が無いときの注意は、modinfo.json の name が mod.io の題と違えば、それも書きます (題は変わらない)。
`--version` のときは、MOD が送る `additionalMetadata`
(`{"version": "X.Y.Z"}`) も入ります。`--dry-run` が無いときも、
ツールはまず同じ dry-run を回し (そこで断られれば何も残らない)、それから **「送った」の印**
`$XDG_STATE_HOME/tf3ctl/publish_pending.json` (無ければ `~/.local/state/tf3ctl/`。フォルダ・owner・時刻・公開か・最初か更新か・mod.io の id・updateMetadata・revision・version) を書き、
そのあとでアップロードを送ります。印があるあいだは、どの publish も断ります。印が消えるのは、(1) アップロードが部分的な
エラー無しで成功し、ゲームが返した mod.io の id と同じ中身の fileid のファイルが (60 秒以内に) できたとき (更新ではファイルが前から
あるので、ゲームの答えをその id と比べるだけ。ゲームが別の mod.io の id を返した更新は成功とせず、印は残る)、(2) 人が
mod.io のアカウントの MOD を見てから `modhub publish-clear --yes` を実行したとき (動いているゲームが Publishing と答える
あいだは断る)、の2つだけです。ほかの終わり方 (失敗・部分的なエラー・印のあとでの拒否・時間切れ・ゲームが落ちた) では
残ります。送ったアップロードは、成否にかかわらず、印の隣の `publish_history.jsonl` に1行ずつ残します (時刻・owner・
フォルダ・公開か・最初か更新か・updateMetadata・revision・version (`--version`。無ければ null)・結果・mod.io の id・fileid)。次の更新は、この revision と比べます。印があるあいだと、Publishing のために MOD が quit を断るあいだは、
`quit --kill` と `restart` は `--force` を付けてもゲームを kill しません。**アップロードの途中に、人がメニューから手で
セーブを読んだりゲームを終えたりしないでください。**

設定は、ページがマイMOD のタブの MOD に作るのと同じ形にしています (`mod_manager_react_util.tl`)。新しい
`PublishSettings` に、`setPublic` は `--public` (ページの「Set Public」の欄。初期値は新規の MOD では false、更新では
mod.io での公開の状態)、`updateMetadata` (name・summary・description をまとめた真偽値1つ。API に項目ごとの欄は無い)、
`changeLog` は `--changelog`、
`isSavegame = false`、`issuesConfirmed = false` (「Proceed Anyway」を聞いていない)。`--version` のときは
`additionalMetadata = {version = "X.Y.Z"}` も (API の説明は「アップロードのメタデータに混ぜる自由な追加の情報」。ページは
セーブデータのときだけ使う)。付けないときは additionalMetadata を設定しません。答えに全部入ります。

`updateMetadata` だけはページと違います。ページはどちらも true です (初期値。新規の MOD では欄は押せない)。このツールは、
最初のアップロードでは true (新しいページに要る)、**更新では `--update-metadata` を付けない限り false** を送ります。
true だと、ゲームは mod.io のページの name・summary・description を modinfo.json のもので置き換え、ほかの方法で mod.io に
書いた説明文 (mod.io の API で入れた長い HTML など) が消えるためです。`--update-metadata` は name か summary を変える
ときだけ付け、そのあと説明文を入れ直してください。

`publish` を呼んだあとは、15 秒ごとに進み具合を返し、HasResult を最大 `--timeout` (既定 900 秒、コマンド全体) 待ちます。
結果はゲームが返したとおりに返します。成功なら mod.io の id と部分的なエラー (ページの「Upload Failed」の一覧)、失敗なら
エラーのコード・debug の文・訳の文。そのあと、ページと同じく (失敗ならすぐ、成功なら Ok のボタンで) `abortPublish` を
呼んで結果を片付けます。HasResult の前には決して呼びません。`--timeout` を過ぎても**アップロードは止めません** (ページは
途中のアップロードを止めず、mod.io に何が残るか分からないため)。答えは「結果は分からない」で、印は残り、MOD が
Publishing のあいだは `quit`・`load`・`newgame` を断るので、ゲームが最後まで進められます。そのあとの結果と
`publishedThisLaunch` は `modhub status` で見られます。

- **ゲーム内で確認済み:** 最初のアップロード (2026-11-22)。mod.io が受け取り、fileid のファイルにその id が入った。
  `updateMetadata = true` の更新 (2026-11-23)。mod.io のページの説明文 (API で入れた HTML) が modinfo.json のプレーンな文に
  置き換わった。
- **ゲーム内では未確認:** `updateMetadata = false` の更新 (ページの name・summary・description がそのまま残るのか)。ゲームが `mod.io_fileid.txt` を結果の時点で書くのか、ページの Ok (`abortPublish`) で
  書くのか。`setPublic = false` で mod.io では非公開になるのか。アップロードのあと mod.io の `version` に何が入るのか
  (表示するだけで、比べには使わない)。`--version` (additionalMetadata) が mod.io のファイルの版に入るのか (付けない
  ときは、revision 10003 でゲームが「1.0」を送った)。

### ほかの MOD の命令 (`mod`)

```
python3 tools/tf3ctl.py mod --list                       # 読むだけ: 命令を持つ MOD と、その命令の一覧
python3 tools/tf3ctl.py mod my_mod                       # 読むだけ: その MOD の命令 (無ければその理由)
python3 tools/tf3ctl.py mod my_mod hello '{"who": "me"}' [--timeout 30]   # 1つ呼ぶ: 答えは JSON
python3 tools/tf3ctl.py mod my_mod hello '{"who": "me"}' --read-only      # 札が reads のときだけ呼ぶ
```

`--timeout` は、命令なら 6〜125 秒 (初期設定 30)、一覧なら 5〜600 秒 (初期設定 60) です。外の値は断ります。
`--list` は単独で使います。後ろに MOD の id・命令・JSON があると、何も送らずにエラーで終わります (終了コード 2。
1 つの MOD の命令は `mod my_mod`)。`--read-only` は値を取らない旗で、命令と一緒にだけ使えます。

プローブはバニラの命令を中継します。その上に、MOD が自分の命令を足せます。足すには、ファイルを1つ
`content/remote_probe_ext.lua` (`<modId>::/remote_probe_ext.lua` として require される) に置き、命令の表を返します:

```lua
return {
	api = 1, -- このファイルの形 (このプローブが読むのは 1。新しい形は断る)
	commands = {
		hello = {
			tag = "reads", -- "reads": ゲームを読むだけ。"changes"・無し・ほかの値: ゲームを変える
			description = "the game's date, and the arguments back",
			run = function(args, ctx) -- args: JSON の引数を Lua の表にしたもの (無ければ {})
				return { date = ctx.now().date, args = args } -- 答え: 表か、JSON にできる値
			end,
		},
	},
}
```

`examples/remote_probe_ext_sample/` は、命令が2つある MOD の見本です。`hello` (読むだけ) と `speed` (ゲームを変える:
0〜4、エンジンのコールバックから答える)。フォルダをゲームの MOD のフォルダに `remote_probe_ext_sample_1` として写し、
プローブと一緒にセーブで有効にすると、`mod --list` に出ます。

- **どこで動くか。** プローブは、ゲームの GUI の Lua 状態の `guiUpdate` の中でファイルを require し、そこで `run` を
  1 つずつ呼びます。速度ボタンのレシピの中でしか動かないもの (窓を開く、バニラの車両のモジュール) には、まだ届きません。
  ファイルはロードごとに 1 回だけ require します。ファイルを変えたらロードし直し、新しいファイルを足したらゲームの
  再起動が要ります (ゲームは起動のときに MOD のファイルを読み込む)。
- **`mod --list` は、どの MOD のファイルも動かします。** 命令の一覧を作るために、プローブは見る MOD (下) の
  `remote_probe_ext.lua` を全部 require します。そのため、使うつもりの無い MOD のものでも、ファイルの一番外の
  コードがゲームの GUI の Lua 状態で動きます。1 つの MOD を指定したとき (`mod my_mod`、`mod my_mod hello`) は、
  その MOD のファイルだけを require します。
- **札は MOD の自己申告です。** `tag = "reads"` は MOD の作者が言うことで、プローブは確認しません。
  `reads` の札でゲームを変える命令は、`status` と同じく owner の検査なしで送られます。
- **どの MOD を見るか。** ユーザーのプロファイルが入れたものとして挙げる MOD と、動いているゲームに設定がある MOD。
  公式の MOD (`ug_*`) は見ません。セーブで有効な MOD かどうかは GUI から分かりません。有効でない MOD には require
  できるファイルが無いと見ており、そのときはファイルの無い MOD と同じく一覧から外れます (ゲーム内では未確認。もし
  ゲームがそのファイルを読めるなら、ファイルの一番外のコードがゲームの中で動きます)。`broken` には、ファイルはあるが動かないもの
  (コンパイルできない、エラーを投げる、表を返さない、新しい `api` を求める) が出ます。
- **答え。** `run` は答えを返します。エラーは `nil, "文"` で返します。ツールは
  `{ "ok": true, "mod", "command", "tag", "result": <答え>, "seconds" }` を出します。後から答える (エンジンの
  コールバックから) ときは、`local finish = ctx.defer()` を呼び、あとで `finish(result)` か `finish(nil, "文")` を 1 回
  呼びます。`--timeout` より 5 秒短い時間のうちに来なければ時間切れのエラーになり、その後の `finish` は無視します。
- **エラーは答えになる。** `run` の中の Lua のエラー、`nil` の答え、JSON にできない答え (関数、userdata、自分を含む表、
  NaN、20 段より深い、1,000,000 文字より長い)、無い命令や MOD は、どれも `{ "ok": false, "error", "kind" }` で返り
  (`kind`: `noExt`・`broken`・`noCommand`・`error`・`noAnswer`・`badResult`・`timeout`)、プローブは動き続けます。
  `pcall` で捕まえられないものは MOD の側の責任です: MOD が呼ぶ api の中のエンジンの assertion、終わらない繰り返し。
- **owner の検査。** 札が `reads` の命令は `status` と同じに送ります。それ以外は、まず読むだけの形 (`modRead`) で送り、
  MOD は何も動かさずに断り (`needsChange`)、ツールが `modChange` で送り直します。`modChange` はゲームを変える命令と
  数えます: `"ownerCheck": true` のときは、この `--owner` が起動したゲームにだけ送り (「ゲームを変えるのは起動した owner だけ」)、`coop` の間は
  `event` と同じに通り、`status` の `lastAction` に出ます。
- **`--read-only`。** 札が `reads` の命令だけを動かします。それ以外は、MOD が何も動かさずに `needsChange` と答え、
  ツールは送り直しません: 終了コード 4、`"refused": "not-read-only"`。`mod --list` と同じく owner の検査なしで送ります。
  札は MOD の自己申告のままです (上): `--read-only` は MOD をその申告に縛るだけで、命令が実際に何をするかは確かめません。
- **外のガードのために。** 命令の形だけで (答えを見ずに) 決めるガードが、ゲームを変えない命令として通してよい形は
  次の 2 つです: `mod --list` (単独)、`mod <modId> <命令> [JSON] --read-only` (旗はこの綴りのまま、`mod` の後ろの
  どこでも)。`mod <modId>` (1 つの MOD の一覧) も読むだけですが、この形には入れません: ガードはほかの `mod` の
  命令と同じに止めます。
- **`ctx`。** `mod`・`command`・`id`・`tag`・`owner` (`--owner`)・`timeout`。`log(msg[, level])` (MOD の名前つきでゲームの
  ログに 1 行)、`try(fn)` (fn の値、エラーなら nil)、`call(fn, ...)` (pcall)、`array(t)` (空の表を `[]` と書く)、
  `now()` (ゲームの時刻・日付・速度、`status` と同じ)、`appTime()`・`clock()`、`exists(e)`・`component(e, "NAME")`・
  `name(e)` (ある entity だけ。間違った id で引かない)、`sendCommand(cmd, onDone)` (`api.cmd.sendCommand`、`onDone` は
  pcall の中)、`defer()`。
- ファイルの中で新しいグローバルを作らないでください。MOD のファイルが作ったグローバルを、ゲームはエラーとして記録します。
- **ゲーム内では未確認:** MOD の無いファイルや、セーブで有効でない MOD のファイルの require が、静かに、どんな文で
  失敗するか (プローブは自分の無いファイルのときの文と比べ、"not found" などの語でも見分ける)。ゲームの中で
  プロファイルの入っている MOD が modId で挙がるか (メニューでだけでなく)。見本の MOD そのもの。

### テストの台本 (`test`)

`tf3ctl.py test FILE` は台本を動かします。台本は tf3ctl の命令を並べた JSON のファイルで、命令ごとに答えの確認を付け、
ゲームのログの確認も入れられます。結果を JSON 1 つで出し、全部の段が通れば `0`、どれかの段が落ちれば `5`、台本が
壊れている (そのときは何も送りません) か、ある段に答えが無ければ `2` で終わります。MOD の作者は台本を MOD の横に置き、
直すたびに動かし直せます。答えを人が読まなくても済みます。

```
python3 tools/tf3ctl.py --owner my-tests test examples/test_scenario_sample.json
python3 tools/tf3ctl.py test my_scenario.json --dry-run     # ファイルを見るだけ: 命令を全部読み、何も送らない
python3 tools/tf3ctl.py test my_scenario.json --excerpt 500 # 結果に残す答えの文字数 (初期値 2000)
```

台本の例は英語版の [Test scenarios](REFERENCE.md#test-scenarios-test) にあります。

- **段** は命令 1 つ (`cmd`) か、ログを見ること 1 つ (`log`) です。`cmd` は `tf3ctl.py` のあとの語で、リスト (数は
  語になります) か、シェルと同じに分ける 1 つの文字列です。tf3ctl の `main` そのものを通るので、コマンドラインと同じ
  確認が全部効きます (owner、試験用のセーブだけ、coop、設定ファイル)。台本は確認を足しも外しもしません。ほかのキー:
  `name`、`comment`、`exit` (命令が返すはずの終了コード。初期値 `0`)、`expect` (確認 1 つか、そのリスト)、
  `continueOnFail`。
- **台本では断るもの** (何も送る前に): 確認を飛ばすフラグ (`--force`、`--user-asked`、`--other-owner-ok`、
  `--ignore-errors`。`--flag=...` の形も)、オプションで始まる命令 (`--owner` は `test` のコマンドラインに付け、全部の
  段に渡ります)、`test`、`log` (ログの段を使う)、`pointer`、`modhub publish` と `modhub publish-clear`、
  `coop start` と `launch --coop` (coop は確認を緩めるので、人がユーザーと一緒に始める。`coop end` は通す)、`quit --kill`、`--no-kill` の無い `restart`、
  `window --close-all`、`--count` の無い `--every`。全部の段を先に tf3ctl のパーサーで読むので、命令やオプションの名前の間違いは、最初の段を動かす
  前に台本を壊れた扱いにします。知らないキーも同じです (綴りを間違えた `expect` は、さもないと何も確認しません)。
  空の `steps` も同じです。
- **`expect`**: `{"path": ..., "op": ..., "value": ...}`。`path` は答えの中の場所です: `lines[0].vehicles`、
  `saves[-1].saveName`、`["点の入ったキー"]`。`""` は答え全体 (`--every` では行のリスト)。`op`: `eq`、`ne` (JSON の
  等しさ: `1` と `1.0` は等しく、`true` と `1` は等しくない)、`gt`、`ge`、`lt`、`le` (数どうしか文字列どうし。
  ほかは確認が落ちる)、`exists` (`value` が true (初期値) か false: 無いこと)、`contains` (リストの要素、文字列の
  一部、オブジェクトのキー)、`len` (リスト・文字列・オブジェクトの長さを `cmp` で `value` と比べる。初期値 `eq`)。
  答えに無い path は確認が落ちます (`why`: "no such path in the answer")。台本は壊れた扱いになりません。
- **段が通る** のは、終了コードが `exit` で、確認が全部通ったときです。思っていない `2` か `3` は error
  (答えが無い: ツールかゲームが答えられなかった)、ほかの食い違い (`1` と `4` も) は fail です。最初の fail か error
  で台本は止まります (残りは `skipped`)。段か台本全体に `continueOnFail` が true なら続けます。
- **ログの段** は、台本を始めてからゲームがログに書いたものを見ます (その前の行は見ません): `{"log": {}}` (か
  `true`)。`patterns` (各項目で探す正規表現。項目は `[時刻 - LEVEL - ...]` の行とその下の字下げの行。初期値は
  `ERROR` の行、`Exception type:`、`Lua error`、Lua の `attempt to index / call / perform arithmetic / compare /
  concatenate`)、`ignore` (当たった項目は数えない)、`require` (どれかの項目に無ければならない式)、`max` (許す項目の
  数。初期値 `0`) を付けられます。答えは `matches`、最初の 10 項目 (各 600 文字)、`entriesRead`。台本の中の
  `launch` と `restart` は新しいログを始めるので、それを初めから読みます。ログは段の前ごとに読むので、その最後の
  読み込みのあと、前のゲームが終わるまでに書いた行は見えません。ログの段はどれも始めからの全部を見るので、前のログの段が数えた項目は、
  次のログの段でも数えます。ログが無ければ error です。ログの場所は `log` と
  同じ (`TF3_LOG`、無ければゲームの `crash_dump/stdout.txt`)。
- **結果**: `ok`、`result` (`pass`・`fail`・`error`・`interrupted`。壊れたファイルは `broken` と `error`、
  `--dry-run` は `checked`)、`exitCode`、`passed`・`failed`・`errors`・`skipped`、`durationSec`、`steps`。段ごとに
  `index`、`name`、`status`、`cmd`、`exit`、`expectedExit`、`durationSec`、`checks` (それぞれ `pass`、`actual`、
  落ちたら `why`)、`answer` (`--excerpt` の文字数で切る。切ったら `...` で終わる文字列)、`stderr` (最後の 1000 文字)、
  通らなければ `why`。
- 台本そのものに時間の上限はありません。各命令の待ちと `--timeout` で終わります。Ctrl+C で止まります (終了コード
  `130`)。
- 新しいゲーム (ゲームが止まっているときの `launch --new ...` か `restart --new ... --no-kill`) か試験用のセーブから始め、
  段が建てたもの・変えたものが残らないようにします。[`examples/test_scenario_sample.json`](../examples/test_scenario_sample.json)
  は、小さな新しいゲーム、`build --dry-run` で見る道路の車庫、20 歩、日付とログの見本です。
### ゲームの中で Lua を動かす (`eval`)

設定ファイルに `"eval": true` があるときだけ使えます (初期設定は切。切のときは断り、何も送りません: 終了コード 4、
`"refused": "config"`)。

```
python3 tools/tf3ctl.py eval 'api.engine.getComponent(12345, api.type.ComponentType.NAME)'   # 読むだけ、どのセーブでも
python3 tools/tf3ctl.py eval --file probe.lua [--depth 6] [--max-chars 200000]               # コードをファイルから
python3 tools/tf3ctl.py eval --gs 'api.engine.getComponent(12345, api.type.ComponentType.NAME)'   # ゲームスクリプトの中で
python3 tools/tf3ctl.py eval --write 'CODE' [--gs] [--user-asked]    # すべてのグローバル: 試験用のセーブだけ
```

コードはまず式として (`return CODE`)、だめなら文として compile します (文なら `return x` で値を返します)。
実行は 1 回だけで、場所はゲームの GUI の Lua の状態 (プローブの `guiUpdate`) です。`--gs` ならゲームスクリプトの
状態で動かします。長さは 100,000 文字までです。

- **読むだけ (`eval` だけ)。** コードは、ゲームを書き換える関数を外した環境で動きます。どのセーブにも送れ、ゲームを
  変える命令には数えません (`status` と同じく、owner の検査はありません)。外してあるもの:
  - グローバルの `app`・`game`・`io`・`package`・`debug`・`dofile`・`loadfile`・`loadstring`・`setfenv`・
    `getfenv`・`collectgarbage`・`module`・`rawset`・`rawget`・`rawequal`
  - `api.cmd` と `api.gui`。`api` の下で名前が `set`・`save`・`send`・`add`・`remove`・`delete`・`write`・
    `clear`・`reset`・`apply`・`register`・`unregister`・`subscribe`・`unsubscribe`・`execute`・`enqueue` で
    始まる関数 (たとえば `api.util.setAppConfig`)
  - `os` は `time`・`date`・`clock`・`difftime` だけを残します
  - `_G`・`debug`・`io`・`os`・`package`・`ffi`・`jit` の `require`

  表 (`api`・`string`・`math`・require したモジュール・`getmetatable` のメタテーブル) は読むだけの見え方で
  渡し、書き込むとエラーになります。エンジンの関数 (`api.engine.getComponent`・`api.engine.forEachEntityWithComponent`
  など) は Lua の関数でなく、呼べる表です (`type()` は `"table"`)。その見え方も呼べば本物を呼びます。`api` の下の
  呼べる表には、引数のうち見え方のものを本物の表に戻して渡します (1 段だけ: コードが作った表の中の見え方は
  そのまま)。それがコールバックを呼ぶとき、コードが見え方で見ていた本物の表は、見え方に戻して渡します。Lua の
  関数 (ライブラリの・モジュールの・`api` の下のもの) には、見え方のまま渡します。`api` の下では、上の書き換える名前に当たる
  呼べる表も外します (メタテーブルのある表。メタテーブルの無いただの表、つまり名前空間は残します)。`load` は文字列だけを取り、同じ環境で動かします。`game` (つまり、読むだけで
  なく建てる・変える関数も持つ `game.interface`) は `--write` にだけあります。読むだけなら `api.engine` を使います。
  コードの前に、その状態の `load` が環境を取るかを確認します。取らなければ何も動かしません (`kind: compile`)。
  取らないまま動かすと、コードが本物のグローバルで動いてしまうためです。
- **読むだけで守れないもの。** Lua ではコードを閉じ込めきれません。読むだけの環境が防ぐのは、まっとうなコードが
  うっかり書き込むことです。外へ出ようとするコードは止められません:
  - userdata (エンジンの物: component、ベクトルなど) は本物です。メソッドは確認しないので、ゲームを変える
    メソッドを呼べば動きます。
  - 関数の返す値は本物です (ただし、コードが見え方でしか見ていない表が返ってきたら、その見え方で返します。エンジンが引数の一部を返したときは、見え方を作っていない表なので本物のまま返ります)。モジュールの関数は、モジュール自身の (全部ある) グローバルで動きます。`require` で初めて
    読み込むモジュールの先頭のコードも同じです。
  - 上の一覧に当たらない名前の、書き換える関数は外しません。
  - メタテーブルを隠した (`__metatable` を設定した) Lua の呼べる表は、エンジンのものと見分けられず、引数に本物の表を受け取ります。
- **`--write`。** コードはすべてのグローバル (`game.interface`、`api.cmd` など) のある環境で動きます。
  - 試験用のセーブ (`testSavePrefixes`) を読み込んでいるときだけ送ります。tf3ctl がゲームのログから読み込んだ
    セーブの名前を送り、MOD ももう一度確認します。ほかのセーブでは断ります: 終了コード 4、`"refused": "eval"`。
  - 共同作業 (coop) の間は、試験用のセーブで、coop の相手のクライアントが `--user-asked` を付けたときだけ送ります
    (`"refused": "coop"`)。
  - ゲームを変える命令に数え (owner の検査)、答えに `saveNote` が付きます。コードが何をしたかはツールには
    分からず、保存すると残ります。
  - GUI では、速度ボタンのレシピの中でなく、プローブの `guiUpdate` の中で動きます。レシピの中でしか動かない
    `api.gui` の呼び出し (窓を開くなど) は、ここからだとゲームを落とすことがあります。
- **`--write` は保存しません。** `app.saveGame` と `app.deleteSavegame` は `eval does not save: use tf3ctl save`
  のエラー (実行時のエラー) を出します。できる範囲の手当てです: 本物の `app` には (`require("_G")`、
  `package.loaded`、`debug` から) まだ届き、ゲームのほかの保存の手段も止めません。保存は `tf3ctl save` で。
  ゲームスクリプトには `app` が無いので、そちらでは何も置き換えません。
- **`--gs`。** コードをスクリプトのイベントとしてプローブのゲームスクリプトに送り、その状態で動かします。
  - MOD の設定 gameScript を入にしておく必要があります: `--param hummer_remote_probe:gameScript=2` を付けて
    読み込みます (tf3ctl が許すのは試験用のセーブだけ、`testSavePrefixes`)。入でなければエラーで、何も動かしません。
  - 答えはプローブのスクリプトの状態に書き、GUI が読み取ります。答えは 1 分ほどそこに残るので、その間に保存すると
    セーブに入ります。答えの `gsNote` にもそう書きます。
  - MOD は答えを 15 秒待ちます。`--gs` は 1 度に 1 つです。同じ依頼が 2 度届いても、2 度は動かしません。
  - スクリプトのイベントは手でも送れるので、ゲームスクリプトは依頼をもう一度確認します (`--write` なら試験用の
    セーブの名前)。`script-event` は、これまでどおりプローブのイベントの id を断ります。
- **答え。** `{ "ok": true, "value", "n", "truncated", "print", "printTruncated", "where", "ms" }`:
  - `value`: コードが返した最初の値。2 つ以上なら、全部が `values` に入り、`n` がその数です。`values` の中の
    `nil` は `"<nil>"` です。
  - `where`: `gui` か `script`。`ms`: 動かした時間 (GUI だけ)。
  - `print`: `print` の書いた行 (200 行・20,000 文字まで。超えたら `printTruncated`)。`debugPrint` は値を JSON に
    してそこに書きます。
  - エラーは `{ "ok": false, "kind": "compile" | "runtime", "error", "traceback" }` です (終了コード 1。
    `traceback` はその状態に `debug.traceback` があるとき)。
- **値の書き方。**
  - `--depth` (初期設定 6、1〜16) より深い表は `"<depth limit: table>"` になります。
  - JSON は `--max-chars` (初期設定 200,000、1,000〜1,000,000) で切ります。長い文字列は
    `<truncated: N more chars>` で終わり、リストやオブジェクトのキーの残りは `<truncated>` の印になります。それでも
    大きすぎる値は `"<too large: N chars>"` です。どれも `truncated` を立てます。
  - 自分の中に自分がある表は `"<cycle>"`、関数とスレッドは `"<function>"` / `"<thread>"`、NaN と無限大は
    `"nan"`・`"inf"`・`"-inf"` です。
  - userdata は `pairs` で回せれば回し、だめならリスト (`#`、`[i]`) として、それもだめなら `tostring` で書きます。
    エンジンの component は回せない (`pairs` がエラーになる。ゲームで確認済み) ので `"userdata: 0x..."` で返ります:
    欲しい欄を名前で読んで表に詰めて返してください (例
    `local c = api.engine.getComponent(id, api.type.ComponentType.NAME); return { name = c.name }`)。
  - オブジェクトのキーは文字列で、並べ替えます。同じ文字のキー (`1` と `"1"`) は `"1"` と `"1 (2)"` になります。
  - 答え全体は JSON で 1,000,000 文字までです。超えると `values`、次に `value` が `"<too large: ...>"` になり、
    それでも超えれば `print` を落とします。
  - `--gs` では、空のリストが `{}` で返ることがあります (リストの印はゲームスクリプトの側に残るため)。
  - 表は、上限で切る前に全部を回します (1 つの表で 100,000 項目まで)。書き出す量が少なくても、とても大きい表は
    ゲームのフレームの時間を食います。
- **時間切れはありません。** ゲームの Lua には `debug.sethook` が無いので、終わらないループはゲームを固めます。
  止める手はありません。読むだけの `eval` は人のセーブにも届くので、すぐ終わるコードだけを送ってください。ツールは 45 秒であきらめます (終了コード 2) が、ゲームは固まったままです。api の呼び出しの
  中のエンジンの assertion も捕まえられません。
- **ゲームで確認済み (2026-11-26):** 素の `eval` (つまり、ゲームの `load` は環境を取る)、gameScript を入にした
  `--gs`、`--write` で `app.saveGame` を断ること、component を `pairs` で回せないこと。ゲームではエンジンの関数が
  呼べる表で (`getmetatable` は `false`)、直す前の素の `eval` からは呼べませんでした。直したあとは、素の `eval` から
  `api.engine.forEachEntityWithComponent`・`getComponent` が答え、書き込みは断られ、`api.cmd` はありませんでした
  (同じゲームで確認)。

### 複数のクライアント

ツールは複数同時に動かせます (長い `run` と `status` など)。コマンドファイルは 1 つなので、ロックで順に書きます。
複数の人やスクリプトが 1 つのゲームを共有するときは、それぞれ `--owner NAME` (または `TF3CTL_OWNER`) で名前を付けます。
名前は `status` (`run.owner`、`lastAction`) に出ます。別の送り主が 10 分以内にゲームを変えていたら、ゲームを変える
コマンド (`load`・`run`・`speed`・`save`・`buy`・`line` など) の前に stderr へ警告が出ます。`quit --kill` は、別の送り主が 10 分以内に使ったゲームを、`--force` が無ければ SIGKILL しません。

### ゲームを変えるのは起動した owner だけ

設定ファイルで `"ownerCheck": true` のとき (初期設定は切れていて、ここに書いたことはどれも断りません)。
ゲームが動いている間、ゲームを変えるコマンド (そう数えるもの全部: `save`・`quit`・`load`・`newgame`・`speed`・`run`・
`build`・`line`・`event`・`window`・`modhub validate` / `publish` など。`restart` の中の quit も) は、`launched.json` (下) が
この `--owner` を指し、その pid が動いているゲームのときだけ送ります。そうでなければ、ゲームに何も書かずに断り、終了コード 4 と
`"refused": "owner"` を返します:

- 記録の owner が別の owner (またはコマンドに `--owner` が無い)。
- 記録が無い、または記録の pid が動いているゲームではない: tf3ctl の外、たとえば人が Steam から起動したゲーム。

断られた `quit --kill` と `restart` が SIGKILL に進むことはありません。SIGKILL は quit を送ったプロセスにだけ送ります (その間に起動したゲームには送りません)。
`--load` / `--new` を付けた `launch` / `restart` には `--owner` が要ります。無ければ、何も止めず起動もせずに断ります。記録を書けなかったときは、ゲームをメインメニューに置いたまま、load を送りません。読むだけのコマンド、`--dry-run` / `--list`
(`modhub validate` / `publish` は除く。dry run でも検証が動くため)、引数の無い `camera` は、いつも通します。ゲームがまったく
動いていないときは確認しません (`launch`・`restart` が起動し、`--load` / `--new` も通り、新しい記録は起動した owner を指します)。
クラッシュのあとも走り続けたスクリプトが、その間にほかの人が起動したゲームを変えることは、これでできなくなります。

`--other-owner-ok` (コマンドの前) を付けると、それでも送ります。ほかのクライアントがそのゲームを使ってよいと合意したときだけ
使います。stderr に警告、答えに `otherOwnerOk` (`launchedBy`: 記録の owner、使える記録が無ければ `none`。`why`。`owner`)、
ゲームのログのそのコマンドの行に `(--other-owner-ok: the game of ...)` が出ます (ログの水準 1 でも)。付けたときは、`quit --kill` がそのゲームを kill することもあります。

### 誰がゲームを起動したか (`launched.json`)

owner (`--owner` か `TF3CTL_OWNER`) を付けた `launch` と `restart` は、動いているゲームを起動した owner と
そのプロセス ID を小さなファイルに残します。tf3ctl 自身がゲームを変えるコマンドの前に読みます (上)。同じマシンの別のツールも
読めます (たとえば、ゲームが動いている間ゲームを変えるコマンドを止める見張りが、これを読んで、起動した owner の quit だけは通す)。人が Steam から起動したゲームにはありません。

- 場所: `$XDG_RUNTIME_DIR/tf3ctl/launched.json`。`XDG_RUNTIME_DIR` が無ければ `/tmp/tf3ctl-<uid>/launched.json`。
  フォルダは 0700、ファイルは 0600。同じフォルダの一時ファイルに書いてから置き換えるので、読む側が書きかけを見ることはありません。
- 形: JSON 1 つ。`{"v": 1, "owner": "<owner>", "pid": <ゲームの pid>, "started_at": <epoch 秒>, "cmd": "launch"}`
  (`restart` でも `cmd` は `launch`。`started_at` は probe が答えた時刻)。
- 共同作業の印 (上の `coop`) は、キーを 1 つ足すだけです (ほかは変わりません): `"coop": {"with": "<owner>", "reason": "<文>",
  "since": <epoch 秒>, "until": <epoch 秒>}`。人のセーブでは `"modified": true, "changes": <回数>` も付きます。tf3ctl は `with` を 1 人の名前で書きます。読む側はリストも受けてください。人が起動したゲームでは、`owner` の無い記録になります: `{"v": 1, "pid": ..., "started_at": ..., "cmd": "coop", "coop": {...}}`。キーが無い、pid が動いているゲームでない、のどちらかなら共同作業ではありません。動いているゲームのキーで、`until` を過ぎたものと形が壊れたものは、厳しい側に倒します (下の「期限切れ・形の壊れた印」)。`coop end` はキーだけを消します (記録は残るので、人のゲームでは owner も coop も無い記録になり、無いのと同じに扱います)。ゲームが変更されていたときは、上の段に `"coopChanges": <回数>` を残します。同じゲームでまた `coop start` したとき、変更ありを言い直すためです (印ではないので、読む側は無視してよい)。
- 書く: `launch` / `restart` で、probe がメインメニューで答えたあと (`--load` / `--new` の前)。pid は動いている
  `TransportFever3` のプロセス (複数あれば一番新しいもの)。owner が無ければ書かず、前のファイルを消します。
- 消す: ゲームが止まったのを tf3ctl が見たとき。`quit` (`--kill` も、動いていなかったときも)、`restart` の中の quit、
  ゲームが動いていないときの `launch`、起動の途中か、そのあとの `--load` / `--new` (単独の `load` / `newgame` も) の途中でゲームが終わったとき。
- `launch` / `restart` / `quit` の答えの `launchedFile` に、何をしたかが出ます。書けない・消せないときは stderr に
  警告を出すだけです。残ったファイル (クラッシュ、手で終了したとき) はそれだけで信じず、読む側で pid が生きていてゲームか確認してください。`/tmp` のときは、フォルダとファイルが自分のもので 0700 / 0600 かも確認してください (`/tmp/tf3ctl-<uid>` は誰でも先に作れます)。

### ユーザーと同じゲームを使う (`coop`)

設定ファイルで `"coop": true` のとき (初期設定は切れていて、coop の命令は断ります)。`"ownerCheck": true` も要ります。
上の owner の確認は、ほかのクライアントをゲームから遠ざけます。そのため、ユーザーと一緒に遊ぶゲームにも、クライアントは手を出せません。`coop` はそのためのものです。ユーザーと 1 つのクライアント (その `--owner`) が、しばらくの間、動いているゲームを一緒に使います。

```
tf3ctl.py --owner bob coop start --reason "新しい車庫をユーザーと試す" [--minutes 60]
tf3ctl.py --owner bob launch --load probe-x --coop --reason "..." [--minutes 60]   # 起動・読み込みのあとに共有
tf3ctl.py --owner bob coop end
```

- `coop start` は、この owner が起動したゲームか、人が Steam から起動したゲーム (動いているゲームの記録が無い。記録は owner の無い、共同作業の印だけの形になる) に付けます。ほかの owner のゲームには付けません。ほかのクライアントの印が効いている間も付けません (`--other-owner-ok` でも同じ)。同じ owner がもう一度打つと延長です。`--reason` は必須 (1〜200 字)、`--minutes` は 1〜10080 (7 日)。延長しても、印の変更の回数は引き継ぎます。
- 効いている間、この owner が送れるもの: 読む命令の全部、`camera`、`window` (`--close-all` は除く)、`event`、`build` (と `fit`)、`road`、`stock set`、`money`、`steps`、ほかの MOD の命令 (`mod`。`modChange` で送るもの)。ユーザーのセーブでも同じです。
  MOD の命令 (と `event`) が何をするかは、その MOD 次第です。下の拒否は tf3ctl 自身の命令に効くもので、保存する MOD の命令は止めません。
- `--user-asked` (ユーザーに頼まれたとき) だけ: `speed`、`run`、`pause`、値を付けた `calendar-speed`、試験用のセーブでの `eval --write` (「ゲームの中で Lua を動かす」)。
- `save` は試験用のセーブの名前にだけ (`testSavePrefixes`。`testSaveDigitFirst` なら数字 1 文字で始まる名前 `3-probe` も)。ほかの名前には、`--user-asked` でも保存しません。人のセーブ (その形でない名前、新しいゲーム、分からない) が読み込まれているときは、新しい試験用の名前への保存にも `--user-asked` が要ります。
- ほかは断ります: `quit` (`--kill` も、`restart` の中の quit も)、`load`、`newgame`、`tool`、`buy`、`line`、`terrain`、`town`、`modhub` など。終了コード 4、`"refused": "coop"`、何も送りません。文に理由が出ます。
- 読み込まれているセーブは、ゲームのログから読みます (起動から最後の `Loading game from file` / `Start new game`)。
- 人のセーブで、ゲームを変える命令を MOD が受け取るたびに (`camera`・`window`・`speed`・`calendar-speed`・`save`・dry run は除く)、印に `"modified": true` を付け、`"changes"` を数えます。そのあと `status` と `coop end` が、共同作業で変更されていること、保存すると変更が残ることを出します。`coop end` は続けて、オートセーブには変更後の状態が入っていること、元に戻すには保存せずに名前のついたセーブを読み直すことを出します。文は `text` (英) と `textJa` (日)。
- ほかのクライアントは、これまでどおり断ります (`--other-owner-ok` もこれまでどおり)。
- 終わるのは、ゲームが無くなったとき (記録の pid が動いているゲームでない)、tf3ctl が記録を消したとき (quit)、`coop end` (印だけを消す。権限を減らすだけなので誰が打ってもよい)。`status` の `coop` に出ます (`active`・`with`・`minutesLeft`・`save`・`testSave`・`text` など)。
- 期限切れ・形の壊れた印: `until` に達しても共同作業は終わらず、tf3ctl はそのために印を消したり書き換えたりしません。ユーザーがまだ遊んでいるかもしれないので、厳しい側に倒します (外のゲームの安全装置と同じ)。動いているゲームの印が期限切れ (`until` を過ぎた) か、形が壊れている (`with` が無い・空、`until` が有限の数でない・7 日より先・NaN・Infinity、印がオブジェクトでない) 間は、ゲームを起動した owner も印の `with` のクライアントも、ゲームを変える命令を一切送りません: 終了コード 4、`"refused": "coop-expired"` か `"coop-invalid"`、何も送りません (`--other-owner-ok` でも同じ)。読む命令は通ります。`coop start` (延長する。壊れた印は書き直す。変更の回数は残る) と `coop end` も通ります。ほかのクライアントの扱いは前と同じです。ただし、人が起動したゲームで、形の壊れた印から `with` が読めないときは、誰の共同作業か分からないので、どのクライアントも断ります (`"coop-invalid"`、`--other-owner-ok` でも)。`status` の `coop` に `"expired": true` か `"invalid": true` (と `why`) が付き、`text` と `textJa` に出ます。pid が動いているゲームでない印は、印ではありません (ゲームが終わった)。

### 環境変数

- `TF3_REMOTE_DIR`: 交換フォルダ (既定: Steam の userdata のうち、hello ファイルが一番新しいもの。
  `~/.local/share/Steam`、`~/.steam/steam`、Flatpak の Steam を探す)。
- `TF3_LOG`: ゲームのログ (既定: 交換フォルダの隣の `crash_dump/stdout.txt`)。
- `TF3_STEAM`: Steam を起動するコマンド (既定 `steam`)。
- `LUAJIT`: luajit の実行ファイル。
- `TF3CTL_OWNER`: `--owner` の既定値。
- `TF3_PROFILE`: `--lang` で変えるゲームの `profile.lua` (既定: 交換フォルダの隣、無ければ Steam の userdata のうち
  一番新しいもの)。控えは同じ場所に `.tf3ctl-backup` を足した名前。
- `TF3_GAME_DIR`: ゲームのインストール先。`--lang` で選べる言語を見るため (既定: userdata のある Steam の
  `steamapps/common/Transport Fever 3`)。
- `TF3CTL_OTHER_BACKUPS`: 別のツールによる `profile.lua` の控え (ファイルかフォルダ)。`os.pathsep` で区切る
  (`:`。Windows では `;`) (`--lang` を参照)。
- `TF3_ASSUME_RUNNING`: 空でない値なら、プロセス一覧を見ずにゲームが動いているとみなします。`state` は終了・落ちた
  とは読まず (ログで決める)、メインメニューの hello がゲームのプロセスの起動より新しいかも確認しません。テスト用と、
  プロセス一覧にゲームが出ない環境 (コンテナ、別のマシン) 向けです。owner の検査と coop の印による拒否は、
  これまでどおりゲームのプロセスを探します。プロセス一覧にゲームが出ないと、この 2 つはどの命令も通します
  (`ownerCheck` でも coop でも断りません)。`road --ignore-errors` のあとの強制の印 (保存は `probe-force-*` の名前だけ)
  も同じで、プロセスが見えないと効きません。
- `TF3CTL_CONFIG`、`XDG_CONFIG_HOME`: 設定ファイル (「設定ファイル」を参照)。
- `XDG_STATE_HOME`: `modhub publish` の印の置き場所 (`tf3ctl/publish_pending.json`。既定 `~/.local/state`)。

## 設定ファイル

`tools/tf3ctl.py` は `$TF3CTL_CONFIG`、なければ `$XDG_CONFIG_HOME/tf3ctl/config.json`、なければ
`~/.config/tf3ctl/config.json` を読みます。ファイルがなければ下の項目はすべて切れたままで、1 人が 1 つのゲームを
動かすのに向きます。複数のクライアント・MOD のアップロード・テスト用のツールを使う環境では、要るものだけを入れます。
すべての項目と初期設定と働きは `tools/config.example.json` に、いま効いている値と読んだ場所は `tf3ctl.py config` で
見られます。`status` の答えにも `"config": {"path", "state"}` (`"file"`、またはファイルが無く初期設定の `"none"`) が付きます。

| 項目 | 初期設定 | 入れると / 値 |
|---|---|---|
| `ownerCheck` | `false` | ゲームを変える命令は、その `--owner` が起動したゲームにだけ届く (下記) |
| `coop` | `false` | `coop start` / `end` と `launch --coop`。切れていると断ります (終了コード 4、`"refused": "config"`)。`ownerCheck` が true であることが要ります。`coop` だけを入れたファイルは、読めないファイルとして扱います |
| `testSavePrefixes` | `["probe-"]` | 試験用セーブとみなす名前の前置き。`road --ignore-errors`・`lights --off`・`running-costs` の書き込み・`eval --write` の検査のほか、coop の間に `save` が書ける名前、`--param hummer_remote_probe:gameScript=2` を付けて読み込めるセーブ、coop の命令を人のゲームへの変更として数えるかにも効きます |
| `testSaveDigitFirst` | `false` | 数字 1 文字で始まる名前 (`3-probe`) も試験用セーブにする |
| `pointer` | `false` | `pointer` 命令 |
| `eval` | `false` | `eval` 命令 (動いているゲームに Lua のコードを送る。「ゲームの中で Lua を動かす」) |
| `modhub.validateFolders` / `publishFolders` / `publishedIds` | 空 | `modhub validate` / `publish` が受け付ける staging のフォルダと、mod.io にすでにあるフォルダとその id |

`_` で始まる項目は注釈です。ほかの知らない項目、型の違う値、JSON として読めない中身、`ownerCheck` の無い `coop`、
`TF3CTL_CONFIG` が指す無いファイルは、ファイル全体を読めないものとして扱い、tf3ctl はどの命令も動かしません。
理由を stderr と JSON (`"ok": false`、`"refused": "config-broken"`、`"config": {"path", "state": "broken", "error"}`) に出し、
何も送らずに終了コード 2 で終わります (書き間違いで検査がゆるむことも、気づかれずに動き続けることもありません)。
`tf3ctl.py config` だけは、直すために、読めないときも答えます (`"ok": false`、`"file": {..., "state": "broken", "error"}`、終了コード 2)。
MOD はこのファイルを読めないので、試験用セーブの名前と modhub の一覧は、要る命令ごとに tf3ctl が送り、MOD は
それで確認します (送られなければ `probe-` だけ、modhub のフォルダはなし)。

**デバッグ命令**は、プレイヤーにはできない形でゲームを変えます: `stock set`・`steps`・`money`・`town develop` /
`size` / `connect`・`company init`・`running-costs` の書き込み・`lights --off`・`road --ignore-errors`・
`eval --write`。どれも試験用のセーブ向けですが、読み込んだセーブの名前 (`testSavePrefixes`) を確認するのは
`road --ignore-errors`・`lights --off`・`running-costs` の書き込み (coop の間も断ります) と `eval --write` (coop の
間は `--user-asked` のときだけ) の 4 つだけです。ほかは、デバッグのツールとしてどのセーブにも届きます (owner の
検査はふつうどおり)。答え (dry run を除く) に `saveNote` が付きます: セーブの中身が変わり、保存すると変更が残ります
(`running-costs` は、その起動の間の車両の型。`eval --write` は、コードがしたこと)。

`screenshot` と `newgame --unsafe` は外しました。`screenshot` は写真モードの外ではファイルを書かず (`frame` を
使ってください)、`--unsafe` はゲームを落とすだけでした (新しいゲームはメインメニューから `launch` / `restart --new`
で始めます)。

## MOD の設定

| 設定 | 値 | |
|---|---|---|
| 普段の確認間隔 | 1 / **2** / 5 / 10 秒 | しばらくコマンドが来ていないときに、コマンドファイルを読む間隔 (1 回の読み込みに数ミリ秒) |
| コマンド直後と run 中の確認間隔 | 0.1 / **0.25** / 0.5 / 1 秒 | コマンドを受けてから 2 分間と `run` の実行中 |
| ログの量 | 最小 / **コマンドごと** / 詳細 | ゲームのログの `[remote_probe]` の行 |
| 速度ボタンの横に表示 | **表示する** / 表示しない | 速度ボタンにない速度と `run` の実行中に、例えば `×8 実測×3.2 →2045-07-03` |
| ×8 / ×16 の速度ボタン | **表示する** / 表示しない | バニラの速度ボタンの横に足すボタン。スクリーンショットのときに隠します。隠れるのはボタンだけで、速度の部品は残るので、`window`・`event`・`tool`・`--via gui` はそのまま動きます |
| ゲームスクリプトの命令（試験用のセーブ） | **オフ** / オン | オン: この MOD のゲームスクリプトが `running-costs` の書き込みを受ける (`--param hummer_remote_probe:gameScript=2`) |

設定の文言と速度の表示は、英語と日本語です (`strings.json`)。ゲームの言語で切り替わり、ほかの言語では英語になります。
ゲームの MOD 一覧に出る名前・概要・説明・表紙は `_metadata/modinfo.json` と `_metadata/0.png` から読まれます。そこは
どの言語でも同じ文が出るので、英語と日本語を両方入れています。

## テスト

```
luajit tests/run.lua                                   # MOD: 純粋な処理と、本物のスクリプトを偽のゲームの上で
python3 -m unittest discover -s tests -p 'test_*.py'   # tf3ctl.py: 偽のゲームと本物のファイルで端から端まで
```

どちらもゲームは要りません。`tests/fake_tc.lua` は、このテストのために書いた Track Connector の代わりです。`connect` が
頼る部分 (モジュールの関数、ゲームスクリプトのイベントと状態) の動きをまねたもので、その MOD のコードは含まず、動いている
本物と突き合わせてもいません。

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
- gui で `--line` を付けたとき、買うのは今までどおり本体の店の `HandleVehicleChanges` (purchaseTime・autoload) です
  が、路線は渡しません。買えた車両ごとに、MOD が同じ `makeVehicleSetLineCmd(vehicle, line, 0)` を自分のコールバック付き
  で送ります (本体のコールバックは断られてもログに書くだけで、断られた車両は車庫に残り、返事は時間切れになっていた)。
  断られたらすぐに `ok: false` で返し、`setLine` の車両ごとに `ok: false`、`reason` (路線の窓と同じく
  `getFailedPathReason(vehicle, line, true)` で取った `Failure.Reason` の名前: `NoPath`・`NoSmallShip`・`NoElectric`
  など)、`message` (路線の窓にその理由の文があれば。例「No path for big ships.」)、`position` (経路の切れる位置。
  あれば) を付けます。答えがまだ来ない車両は、60 秒の時間切れまで `pending: true` のままです。`--via cmd` は変えて
  いません (失敗だけで理由なし)。ゲーム内では未確認です。
- 船: 大型船 (mode SHIP) は、どの停車駅でも大型船着場が要ります。エンジンが小型船着場 (SMALL_SHIP だけ) を割り当てると、
  船は断られます (`NoSmallShip`)。船の路線は `line create --terminals` で大型船着場 (`stations` の `platforms` で
  `transportModes` に SHIP があるもの) を指定して作り、`lines --problems` で見てください。
- 編成 (multiple unit): `--model` が `.mu.lua` で終わると (例 `shinkansen_0s.mu.lua`、公式の TGV の MOD の
  `tgv.mu.lua`)、店の編成の行と同じくその編成を買います。ファイルに並ぶ車両を順に全部、`forward = false` の車両は
  向きを逆にし、モデルは `api.res.modelRep.find` で引き、`vehicleGroups = { 両数 }` と `muFileNames = { ファイル名 }`
  の 1 台として送ります (`vehicle_configs.muParts` / `newMuConfig`、`vehicle_store_window.tl` にならう)。名前は
  `api.res.multipleUnitRep.getAll()` の各編成の 2 つの名前 (その値と `getName(id)`) と突き合わせます。全体の一致、
  次に大文字小文字・フォルダ・`.mu.lua` / `.mu` を外した一致 (`shinkansen_0s.mu` でも可)、次にその一意な一部の順
  です。`muFileNames` には店と同じく `getName` の名前を入れ、それが無い編成は断ります。`getAll()` が空なら
  `getAll(true)` を数えてエラーに出し、`models --mu` に `invisible: true` で並べますが、そこからは買いません (店に
  並ばないもの)。当たらないときは、編成の件数、問い合わせの一部を含む名前、最初の 5 件をエラーに出します。読むだけの
  `models --mu [FILTER]` で一覧 (`id`・`fileName`・`getName`・`value` (getAll の値)・`name` (表示名)・`cars`・
  `buyAs` (`--model` に渡す名前。同じファイル名の編成が 2 つあれば全体の名前)) が見られます。FILTER は名前か表示名に
  当てます。送る前にファイル全体を調べ、車両が無い・
  ゲームに無いモデル・車両でないモデルがあればエラーです。gui だけで (`--via cmd` は断ります)、`replace` は編成を
  受けません。返事には `multipleUnit` (`id`・`fileName`・`name`・車両ごとの `modelId`・`name`・`forward` の `parts`)
  が付き、`storeParts` と `storePriceTotal` は全車両の分、`sentParts` と `vehicles[].parts` は向きが逆の部品に
  `reversed: true` を付けます (編成に限らず、どの車両でも)。編成で買った車両には、エンジンが持つ `vehicleGroups` と
  `muFileNames` も付きます。フォルダを除いたファイル名が問い合わせと等しいものは、名前に含むだけのものより優先します。単独のモデルを手で並べた列車 (機関車と客車) は作れません。ゲーム内では未確認です。
- `buy` は `--depot` が必須です (店は車庫から開いたときだけ車庫を決める)。台数は 1-20。`--line` の先頭の停車駅は
  0 番。`duplicate` は本体の複製と同じく config を写し、部品を purchaseTime 0・maintenanceState 1 にします。車庫と
  路線の既定は `findBestLineAndDepotForVehicle`。
- gui の `replace` と `sell` は本体がコールバックを取らないので、毎フレーム車両を見ます。replace は、部品が送った
  ものと同じになったか、前と変わったら完了です (`matchesSent` でどちらか分かる)。新しい部品が前と同じときは、推測せず
  `ok: false, uncertain: true` を返します。
- `models` (読むだけ) は車両のモデル (`metadata.transportVehicle` のあるもの) をファイル名の順に並べます。
  `--grep` (ファイル名か表示名の一部、大文字・小文字は問わない。数字なら id も) と `--carrier` で絞ります。モデルごとに、
  車両の店と同じく読んだ `price` / `priceScale` (`metadata.cost`) と `runningCosts` / `runningCostScale` / `lifespan`
  (`metadata.maintenance`。-1 は読み込みのときに本体の式で埋まり (`model_metadata_util.addCostMetadata`)、そのあと
  難易度の倍率が掛かる (`post_run_util`))、`topSpeed` (m/s。店と同じく陸・空・水の部分から) と `topSpeedKmh`、
  `loadSpeed`、`arrivalDelay` / `departureDelay`、`carrier`、`transportModes` (SHIP / SMALL_SHIP など)、`yearFrom` /
  `yearTo`、`water` (waterVehicle: 速さ・重さ・出力と、`small` = `transportModes` に SMALL_SHIP があるか。.mdl の
  `waterVehicle.type = "SMALL"` は読み込みのときにこれになり、`type` そのものはエンジンの記録に無いので空)、`compartments` (load config ごとの
  積載量と貨物の組)、店と同じ数え方 (区画ごとに、その config の最大) の `capacities` (貨物の種類ごと) と
  `totalCapacity`。`total` は当たった数の全部で、中身は先頭の `--limit` 件 (200、最大 1000) だけです。モデルは MOD の
  スクリプトの読み込みごとに1度だけなめます (0.5 秒を超えたらログに1行)。
- `vehicles --state` は、車両ごとにエンジンが持つ停留所の値を足します: `state` (IN_DEPOT・EN_ROUTE・AT_TERMINAL・
  GOING_TO_DEPOT)、`loadState` (Arrived・Unloading・Loading・WaitForScheduledDeparture・Departing)、`doorsOpen` /
  `doorsTime` (扉が開いた・閉じたゲーム時刻) と `sinceDoors`、`stopIndex` と `stop` (路線の停車駅 `stops[stopIndex + 1]`)、
  `lineStopDepartures` (停車駅ごとの最後の出発)、`sectionTimes`、`timeUntilCloseDoors` / `timeUntilDeparture` /
  `timeUntilNextLoad` / `timeUntilNextUnload`、`loadSpeedModifiers` (積める貨物の種類ごと、`totalPenalty` 付き)、`cargo`
  (積載量と積んでいる数)、`speed`、`runningCostPerYear` (`getRunningCost`、車両の窓と同じ)、`balanceLastYear` (統計の
  車両の表と同じ)、`--since T` のとき `balanceSince`。返事には `gameTime` も付きます。`--entity` は id (カンマ区切り、
  50 まで) で、消えた車両と自社のものでない車両は `missing` に入り、`--line` と違う路線の車両は
  省きます。`--entity` が無いときの `--state` は 50 台まで (`total` は全部の数) です。エンジンが出さない項目は省きます。これらを
  付けなければ返事は前と同じです。港にいた時間は、数秒ごとに読んで出します: AT_TERMINAL の間に
  `stopIndex` と `doorsTime` (扉が開いた時刻) を控え、出たあとの `lastLineStopDeparture` (と `lineStopDepartures` の
  その停車駅の値。JSON の配列の 0 から数えて `stopIndex` 番目) を出発の時刻にします。ゲーム時刻と timeUntil* の単位は
  ゲームで未確認です。
- `vehicles --state` の返事の `gameTime` は、エンジンの `GAME_TIME.gameTime` を、車両を読む前に返事ごとに1度だけ
  読んだものです。返事の中の車両はみな同じフレームの値です (`sinceDoors` もこの時刻から数えます)。`--at-terminal`
  (`--state` と一緒に) は、今 `state` が AT_TERMINAL の車両だけを返します (`total` はその数。`--entity` に入れても
  港にいない車両は、並べず `missing` にも入れません。state が読めない車両は省き、その数を `stateUnknown` に出します。
  空の一覧でも `stateUnknown` が 0 より大きければ「港に誰もいない」ではありません)。`--every SEC --count N` は
  `persons --every` と同じに繰り返します (1回ごとに1行の JSON に `sample` と `unixTime`。止まったときと飛ばした
  予定の扱いも同じ)。港にいる間の積荷を、ゲーム時刻つきで記録できます。**ゲーム内では未確認** (2026-11-22 に
  書いたもの): とくに、ある速度で2回の間に `gameTime` がどれだけ進むか。
- `persons` (読むだけ) は、自社の車両に乗っている住民 (`--vehicle`。車両の窓の乗客の一覧と同じ
  `getVehicle2Cargo2SimEntitesMap`)、または自社の路線に乗っている人と待っている人 (`--line`、
  `simPersonSystem.getSimPersonsForLine`。待っている人も入るかは未確認で、資料には "travelling with the given line"
  とだけある) を id の順に並べます。住民ごとに `happiness` (`SIM_PERSON`。本体は 0.5 未満を
  「不満」とする)、`good` (`isGoodQuality`)、`destinations` (家・買い物・職場)、`targetOrAtEntity`、`where`
  (vehicle / terminal / other)。乗っている人は `atVehicle` (`vehicle`・`part`・`place`・`expectedArrivalTime`) と
  `untilArrival` (見込みの到着時刻 − ゲーム時刻)・`late` (ゲーム時刻が見込みを過ぎた。本体の住民の窓が「幸福度が
  下がっている」とする条件、`sim_person.tl`)、`trip` (路線・`lineStop0` / `lineStop1`)。待っている人は
  `atTerminal` (路線・停車駅・`arrivalTime`・`sinceArrival`、`late` は 2 分を超えて待った。住民の窓のそこでの条件)。
  `--vehicle` のときは `vehicleState` (state・stopIndex・speed) で海の上か港かが分かります。`summary` は並べた人の
  集計 (不満・乗っていて遅れた数・`lateWaiting`、幸福度の平均・最小・最大)、`quality` はエンジンの旅客の集計 (`total`・`bad`・`averageQuality`・`veryBad`) で、車両・
  その路線・路線の停車駅ごと (停車駅の `waiting`、その駅のまとまりの `stationGroupWaiting`) です。本体が「待っている
  旅客」と「不満のある旅客」として出す数です。返事には `gameTime` が付きます。`total` は全員の数で、中身は先頭の
  `--limit` 人 (200、最大 2000) だけです。消えた車両と自社のものでない車両は `missing: true` (エラーにしない)、
  自社のものでない路線はエラーです。`--every SEC` (0.5 以上) で繰り返し、1回ごとに1行の JSON (JSON Lines) に
  `sample` と `unixTime` を足して出します。`--count N` 回か Ctrl-C で止まり、ok でない返事が来ても止まります。
  答えが無かった回は `noAnswer` と `reason` (timeout・notPickedUp・file・other) の行にして続けます (終わりの
  終了コードは 2)。`sample` は予定の何回目かで、1回が `--every` より長くかかったら、過ぎた予定は飛ばし (次の行の
  `skipped`)、まとめて送りません。`summary` は並べた人だけの集計です (`summary.of` が数えた人数、`summary.total` が
  全員の数)。乗っている全員を記録するときは `--limit 2000` を付けてください。`expectedArrivalTime` が負のときは
  見込み無しとして `late` にしません。快適度は返事に無いので、
  `vehicles` / `models` でモデルを比べてください。「0.5 未満」は住民の窓 (`sim_person_eow.script.tl`) に合わせました
  (HUD の顔のアイコンは 0.5 より上を happy とする)。
  乗った時刻はエンジンの記録に無いので、その人が最初に出た回から出してください。**ゲーム内では未確認です:**
  これらのコンポーネントと関数が、本体の窓と同じように GUI のスクリプトで読めるか、`expectedArrivalTime` が
  `gameTime` と同じ単位か (本体は2つを比べ、2 分に 1000 * 2 * 60 を足しているのでミリ秒のはず)、海の上の船で集計がどうなるか。
- `depots` は自社の車庫だけです (路線管理と同じ `requireOwnedByPlayer`)。位置は返しません (読む API が見つからな
  かった)。種類 (road / tram / rail / water / air) は transport modes から決めます。`carrier` はある試験で 49 件すべて
  OTHER だった (本体も transport modes を見る) ので、`carrier` / `carrierRaw` は参考です。メンテナンス用の建物も出ます
  (`maintenancePool`)。
- 車庫ごとに、その construction の端も返します (`streetConnectorSystem.getConstructionEntityForDepot` から、`frozenEdges`
  の node。`frozenNodes` は除く): `construction`、`freeEnds` (piece が 1 本だけの node。`connect` の端になる。`node`、`x` /
  `y` / `z`、`edges`、`track` は線路なら true、道路なら false)、`joinedEnds` (車庫のものでない piece もある node。
  `trackPieces` / `roadPieces` 付き。線路がもう本線につながっている)。construction が見つからない車庫には、代わりに
  `endsWhy` が付きます。
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
  `platforms` は全部のホームの一覧です (読むだけ。`--terminals` を選ぶため): `station` と `terminal` (路線の停車駅と
  同じ 0 始まり)、`stationEntity`、`tag` (バニラの港ではモジュールのマス `1000 * coordI + coordJ`。modules.script.lua)、
  `position` (車両が止まる所。ホームの最初の vehicle edge を `transport.calcPosition` で。本体が経由点の位置を出すのと
  同じ)、`cargoLoad` / `cargoUnload` / `passengersLoad` / `passengersUnload`、`cargoTransferSpeeds` (それぞれ `length`
  と `loadSpeedModifier`)、`carriers` (`getCarriers(group, station, terminal)`)、`transportModes` (有効なものの名前。
  バニラの大型船着場は SHIP と SMALL_SHIP、小型船着場は SMALL_SHIP だけ)、`capacity`。読めない項目は出しません (nil)。
  桟橋の terminal は vehicle node から作られるので、`position` は出ないことがあります (未確認)。
- `stations --catchment <id>` (読むだけ。駅グループか駅1つ) は、その駅の範囲に入っているものを、エンジンが持つとおりに
  返します: 範囲のシステムの `getStationCatchables(station, cargo)` (本体も line_util.tl・cargo_util.tl で同じように
  聞く)。`passengers` (PersonCapacity を持つもの) と `cargo` (StockList を持つもの) のそれぞれに、`entities` (数)、
  `towns` (町ごとの `town`・`name`・`buildings`、`residential` / `commercial` / `industrial` の数と種類ごとの
  `capacity`。種類は建物の PERSON_CAPACITY の type を LandUseType と比べる。本体の町の窓と同じ)、`industries`
  (`id`・`name`。産業そのものの id か、INDUSTRY の stockList から)、`other` (何か分からなかった id)。グループなら
  その駅すべての和。ゲーム内では未確認です: エンジンが返すのがどれか (建物そのもの、その PersonCapacity、その
  StockList の entity。3つとも引く) と、種類の数がその enum と合うか。
  答えには、なぜそれだけを拾うのか (旅客について) も付きます (content/remote_catchment.lua):
  - `diagnosis`: 1行。例 `0 town buildings in the circle (150 m); nearest residential 462 m (312 m outside the
    circle) in Emsworth, ...` (遠すぎる) や `3 town buildings in the circle (150 m: residential 2, commercial 1), 2 not
    in the engine's catchment; on foot 1 of 2 checked have no path to the station` (円の中だが届かない)。
  - `circles` (`station`・`x`・`y`・`radius`・`frame`) と `radiusSource`: エンジンの `STATION.catchmentAreas`
    (範囲を持つモジュールごとに円1つ)。本体は中心をコンストラクションの中の座標で作ります。エンジンがそのまま持つかは
    分かっていないので、読んだままの中心 (`frame: "world"`) と、コンストラクションの `transf` を通した中心
    (`"construction"`) の両方を出し、駅の箱の中心に近いほうを使います (読んだ位置は `readX` / `readY`)。transf が
    読めないときは、駅から半径+1000 m より遠い円を駅のまわりの円として扱います (`"station"`)。エンジンが円を返さない
    ときは `--radius M` の円を使います (`radiusSource` に出ます)。本体の値 (駅のファイル): 鉄道の本屋
    150 / 175 / 200 m (小・中・大。旅客も貨物も)、脇の建物 50 / 60 / 70、階段 100。道路の駅の出入口 175。道路の
    小さな停留所 160。港の旅客の桟橋 150 (25x25) と 250 (50x50・100x50)。港の貨物の桟橋は本体のファイルに値が
    ありません。
  - `near`: 駅にいちばん近い `TOWNS_READ` (4) の町の建物 (位置の読めない町が1つでもあれば全部の町。
    `townsUnplaced`)、最大 1500 棟 (`buildingsRead`・`truncated`・`townsTotal`・`distance` 付きの `towns`・`readMs` (`around` の `ms` と同じく `api.type.Clock` で測る)・
    `buildingsError`・`positionError`)。種類ごとの `nearest` (`building`・`town`・`townName`・円の中心までの `distance`・`outside`: 円の縁から
    外へ何 m か、中ならマイナス)。`inCircle` (`total`・種類ごと・`caught` / `notCaught`: エンジンの旅客の
    catchables に入っているか・`nearRim`: 縁から 10 m 以内)。`notCaught` (建物。円の奥のものから。`rim`: 縁から何 m 内側か・
    `walk`: `path`・`none`・`unknown`・`why`) と `walk` (`checked`・`found`・`noPath`・`unknown`・`unverified`・
    `limit`・`ms`・`maxMs` (いちばん長かった探索)・`truncated`・`control`: 拾われている建物 3 棟までに同じ探索を
    したもの。それも1つも見つからないなら探索は当てにならず、拾われている建物が無いときは「道が無い」は未確認。
    どちらも `diagnosis` に出ます)。旅客のホームが無い駅 (全部のホームの印が読めたとき) は、貨物の catchables と
    比べ (`cargoOnly`)、歩きの探索はしません。歩きの探索は reach のもの
    (`reach --from <建物> --to <駅> --mode walk`) で、`--paths N` 棟まで (初期設定 20、0 でしない)、合わせて 300 ms
    で打ち切ります。円の中かどうかは建物の箱の中心で決めます。エンジンは入口や道から測るかもしれません。
  - ゲーム内では未確認 (2026-11-23): `catchmentAreas` が読めるか、どの座標か、歩きの探索がこの node の間の道を
    見つけるか。
- `lines` は自社の路線を返します: 停車駅 (駅グループ、駅とホーム、0 始まり、`loadMode`: 0 available、1 満載
  (どれか)、2 満載 (全部))、車両、乗り物の種類、`customFilters`、`loads` (どこかの停車駅で積む貨物)、`vehicleCargo`
  (路線の車両が積める貨物)。`--line N` でその路線だけを返します (自社の路線でなければエラー)。停車駅ごとに、
  路線の窓の貨物の設定 (cargo filter) が読むのと同じ `stopConfig` の値も付きます: `forceUnload` (受け入れ先の合う
  入力の在庫に、満杯でも降ろす)、`destroyForConfigChange`、`destroyForRefresh`、`stopLoads`
  (その停車駅で積む貨物の種類と `maxLoad`、積載量に対する割合 0〜1)。停車駅の `minWaitingTime` / `maxWaitingTime` /
  `maxAdditionalWaitingTime` も付きます。エンジンが出さない項目は省きます。**ゲーム内では未確認** (2026-11-22 に
  書いたもの)。
- `lines --problems` (読むだけ) は、路線の窓と同じ読み方で、路線ごとに `problems` を足します: `segments`
  (`getDetailedLineProblems` の区間ごと・停車駅ごとの `noPath`・`incompatibleStop`・`duplicateStop`・`empty`、
  `noPathLocation` (`edgeIndex`・`node`・`nodePosition` と、名前にした `okModes` / `relaxedModes` / `allowedModes`)、
  `noPathToAlternative` / `noPathFromAlternative` (`terminal` と `location`)、本体が問題に数える停車駅には `problem`)、
  `count` (問題のある停車駅の数)、`transportModesUnion` (`getLineTransportModesUnion`)、各停車駅にはそのホームの
  `transportModes`。呼び出しが失敗したら `readError` / `unionError` に出します。ゲーム内では未確認です。特に、区間と
  路線の停車駅の対応 (本体は順に数える) と、`node` の中身。
- `line create --stops A,B,...` は駅グループを順に、id (駅の entity ならそのグループ) か名前で取ります (完全一致を
  先に、なければ一意な部分一致。複数に当たれば候補付きでエラー。カンマを含む名前は id で)。ホームは自動で割り当て
  ます。名前の既定は本体の `makeLineName` (gui) か「Line N」(cmd)。
- `line update <line>` は `--stops` (停車駅の並びを置き換える)・`--name` (`makeEntitySetNameCmd`)・`--cargo` の
  どれかを取ります。同じ駅グループの停車駅は、本体と同じく設定を引き継ぎます。ホームの無い停車駅があるときは、本体と
  同じく全停車駅を割り当て直す (`allowTerminalChanges = true`) ので、元のホームも変わりえます。gui では本体の
  `autoLoadConfig` が積み荷も振り直します (customFilters の路線を除く)。並べ替えだけならホームは変わりません。
  経由点 (waypoint) は消えます。gui でレシピの報告が届かないときは、停車駅が頼んだ並びになり、かつ前と変わったことで
  完了とみなすので、`--cargo` だけの変更や並びが同じ変更は 60 秒で時間切れになります。
- `--terminals S:T,...` (create と update) は、全停車駅のホームを順に指定します: `駅:ホーム`、または駅 0 のホームの
  番号だけ。`stations` の `platforms` と同じ 0 始まり。全部の停車駅に指定するか、どれにもしないかです: 1 つでもホームの
  無い停車駅があると、本体の `autoAssignTerminals` が全停車駅をエンジンの割り当てで置き換える (変更を許して) ので、
  ほかの指定が残らないためです。停車駅より短い・長い指定は断ります。全部に指定すれば、割り当てを頼みません。
  `--stops` なしの update は、その路線の今の停車駅のホームを変えます (経由点は残る)。送る前に: 駅とホームが実在する
  こと (エンジンに聞く前に見る)、その乗り物の種類が読めること、指定したホームに共通の乗り物の種類があること、車両の
  いる路線の update なら、それが路線の種類 (本体の `getLineCarriers` と同じく最初の停車駅のホームの種類) に含まれる
  こと。送る側の Lua の状態でもう一度確認し (gui では本体の `line_util` が読む前に)、組み立てた停車駅が指定のとおりかも
  見ます。確認は乗り物の種類 (carrier) までです: SHIP の船と小型船着場 (SMALL_SHIP) の組は、どちらも WATER なので通ります
  (`stations` の `transportModes` で見る)。update では停車駅の `alternativeTerminals` は残ります (本体の主ホームの変更と
  同じ)。`--terminals` が無ければ何も変わりません (今までどおりエンジンが割り当てる)。
- `--load-mode MODE[,...]` は `Line.Stop.loadMode` を設定します: `available` (0、`LOAD_IF_AVAILABLE`)、`any` (1、
  `FULL_LOAD_ANY`)、`all` (2、`FULL_LOAD_ALL`)。本体の路線の窓にある 3 つです。全停車駅に 1 つか、停車駅ごとに 1 つ。
  `LEGACY_UNLOAD_ONLY` は断ります (本体の窓に無い)。`--stops` なしの update は、今の停車駅に設定します。読み直した
  ホームか loadMode が頼んだものと違えば `ok` は false です。gui でレシピの報告が届かないときは、ホームか loadMode
  だけを変える update は `--cargo` だけのときと同じく時間切れになります。
- `--force-unload 0|1,...` は `Line.Stop.stopConfig.forceUnload` を設定します: 受け入れ先の合う入力の在庫に、満杯でも
  降ろします (入りきらない荷は消える。engine.d.tl。貨物の設定の窓の「Unload Even if Stocks Are Full」と「Unload Only
  if Stocks Have Capacity」)。範囲に合う入力の在庫が無ければ、どちらでも降ろしません。停車駅ごとに順に 0 か 1 を1つずつ。「全部に
  1つ」の形はありません: 停車駅 (`--stops`、無ければ路線の今の停車駅) と数が合わなければ、何も送らずに断ります。
  停車駅の `StopConfig` は写しを作って `forceUnload` だけを変えます (積む設定・`maxLoad`・destroy の2つは残す。本体が
  `line_util` と路線の窓で写すのと同じ `StopConfig.new(old)`)。`customFilters` は変えません。gui では本体の `line_util` を通り
  (経路の `passThroughStopData.stopConfig`。`autoAssignTerminals` がこれを停車駅に写す)、cmd では路線の今の停車駅を
  写して `makeLineUpdateCmd` で送ります。貨物の設定の窓そのものもこの命令で送ります。どちらもお金は動きません。
  読み直した停車駅の `forceUnload` が頼んだものと違えば `ok` は false で、`lines` で停車駅ごとに見られます。gui で
  レシピの報告が届かないときは、`--force-unload` だけの update は `--load-mode` と同じく時間切れになります。
  **ゲーム内では未確認** (2026-11-22 に書いたもの): とくに、何も積まない停車駅で船が満杯の在庫に本当に降ろすか。
- `line delete <line>` は、先に車両を売り (`--sell-vehicles` のときだけ)、売却が成功してから `makeLineDestroyCmd`
  を送ります。
- `--cargo <id か名前>` は、その貨物だけを、その貨物を出す (出荷の在庫がある) 停車駅で積む設定にします。本体と
  同じです (そこで `load` を true、ほかは false、`maxLoad` を 1、`customFilters = true`)。積む設定の停車駅ではその
  貨物を降ろさないため、全停車駅で積むと届きませんでした。出す停車駅が無ければエラーです。本体の `cargo_util` が
  読めないとき (cmd の経路) は、前と同じく全停車駅で積みます。ホームがその種類 (旅客か貨物) の積み降ろしをどちらも扱わない
  停車駅があれば、何も送らずエラーです。`buy --cargo` はありません。本体の店は車両ごとに貨物を選ばず、何を積むかは
  路線の停車駅の設定で決まるためです。
- `--via gui` (既定) は、路線管理と同じく本体の `line_util.tl` で組み立てます (`makeNewStop`、`autoLoadConfig`、
  `autoAssignTerminals`、`makeLineColor`)。車両と同じく速度ボタンのレシピで動き、報告のキーは
  `hummer_remote_probe.lines`。`--via cmd` は `Line.Stop` を自前で組み、ホームを `lineSystem.getBestLineAssignment`
  で決めます (見つからなければ本体と同じく 0/0 にして notes に書く)。積み荷は旅客駅なら旅客、それ以外は `--cargo`
  だけ。待ち時間は、鉄道を含まない道路か路面電車の駅は 30 秒、他は 60 秒。
- 送る前に確認すること (どちらの経路も): 停車駅が 2 つ以上、隣り合う停車駅 (最後と最初も) が同じグループでない、
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
  書けるか (書けなければログに「line report not written」)。`--terminals` / `--load-mode` と `platforms` では:
  `getCarriers` に駅とホームを渡すとそのホームの種類が返るか (本体の `getLineCarriers` はそう使う)、`loadMode` に数を
  入れて効くか (本体の貨物の窓はそうする)、`vehicleEdges` / `TRANSPORT_NETWORK` / `calcPosition` が GUI 状態で読めるか、
  種類の違うホームをエンジンがどう扱うか (送る前に断るので、試したことはない)。

### 接続 (`connect`)

ゲーム内では全部未確認です。仕組み: GUI スクリプトが Track Connector の planner と proposal のモジュール
(`ethan_track_connector::/track_connector/tc_planner.script.tl`、`tc_proposal.script.tl`) を require し、planner 用の
小さな地図 (その `World`) をエンジンから作り、`guiUpdate` で 1 フレームに 15 ms ずつ planner を回し、結果を Track Connector
の `Route` にして、そのツールが送るのと同じイベントをゲームスクリプトに送ります
(`makeScriptingSendEventCmd("", "TrackConnector", ...)`: `tc_settings`、`tc_setFromEnd`、`tc_setToEnd`、`tc_route`、
`tc_estimate`、それから `tc_build`)。試算と建設は Track Connector がします。返事は、そのゲームスクリプトの状態
(`preview`、`estimates[key]`、`builds`、`build`) を `GAME_SCRIPT` component から読みます。

地図は probe 自身のコードで作ります。考え方は Track Connector のツールと同じです (経路のまわりの土地を octree で
読み、建物はふさがった土地、線は交差とする)。地形の高さ (4 m ごとに聞く) と水 (10 m ごと。水の上では水位 + 6.5 m に見せるので、planner は
橋を架ける)、construction と町の建物はふさがった土地、道路と線路の piece は交差。5 m のマスを 200 m のブロックにまとめ、
octree で読みます。エンジンが産業の construction とは別に持つ部分 (`INDUSTRY` か `SUBCONSTRUCTION` があり、`CONSTRUCTION`
の無い entity) もふさがった土地です。planner が探す範囲 (2 つの端を囲む箱と、そのまわり 1.5 km。端の間の距離の 0.6 倍の
ほうが大きければそれ。地図の内側。多くて 3000 個で、端を結ぶ直線に近いものから) のブロックは、計画の前に 1 フレームに 6 つずつ
読み、それ以外は planner が最初に聞いたときに読みます。planner は自分の coroutine の中から聞くので、そうして 3 つ読むごとに、そこで次のフレームまで待ちます (時間ではなく
数で区切る。Linux の `os.clock` は実時間より速く進むため)。coroutine の無い planner は待てないので、1 回の持ち時間で 8 個を
超えたら 1 回だけログに出します。2 つの端の piece と、端が属する construction の piece は交差にしません。その construction
自体はふさがった土地のままです。開けるのは端の口だけです: 端の node から 10 m と、端の向きに外へ広がるくさび形 (node で左右
6 m、外へ 1 m ごとに 0.15 m 広がる)。くさびの長さは 20 m か、端の node が中にある建物をすべて抜けてさらに 10 m (construction
自身の道の端は、その construction の箱の中にある) で、長くて 150 m です。`plan.map` には `endConstructions`、
`leftOutPieces`、`mouths` (`from` / `to`: `length` と、端の node が中にある建物の数 `inside`) が入ります。Track Connector のツールと比べて無いもの: 踏切、交差する道路や線路の高さ (planner は地面の 7.5 m 上と 9.5 m 下と
みなす)、既存の線路や道路に沿って走ること (交差とみなすので、離れて通るか橋で越える)、建設を断られて覚える水域、piece の
途中からの分岐、複線以上、駅のホームの並び、経路の目標。

未確認のこと。危ない順 (はじめのほうはゲームが落ちうる):

- この Lua の GUI スクリプトから Track Connector の Teal のモジュールを require すること、`guiUpdate` から scripting の
  イベントを送ること (Track Connector は両方を自分の GUI スクリプトからしている)。
- `guiUpdate` から planner の coroutine の中でするエンジンの呼び出し: octree、`terrain.getHeightAt` / `isOnWater`、
  octree が返したものの component。street system の呼び出しは node である entity にだけします (それ以外を聞くとエンジンが
  assertion で落ちる)。端は経路を送る直前にもう一度確認します。
- `streetConnectorSystem.getConstructionEntityForStation` (無ければ、駅のまわりでその駅を持つ construction を探す) と、
  道路の piece の `roadTemplate` (読めなければ、ゲームの年の田舎道を使う)。
- `api.engine.util.getYear` (無ければゲーム時間の暦の日付) と、street template の `availability`: どちらかが読めないときは、
  年代で断ることも種類を替えることもしない (notes にそう書く)。産業の入口の道から、産業の敷地を避けて引いた道路を、ゲームが
  そこで受け付けるか。口のくさびの幅が、新しい道路そのものの幅に足りるか。
- 建物の箱の奥にある端: planner の粗い地図 (100 m 以上のマスで、5 点のうち多くがふさがるとそのマスもふさがる) には細い口が
  見えず、出口が無いとみなすことがある。経路が見つからないとき、そういう端を notes に書く (`plan.map.mouths.*.inside` が 1 以上)。
- 一時停止中にゲームスクリプトがイベントを受けるか、どれだけ速いか (待つのは 30 秒)。
- planner の持ち時間: Track Connector は `os.clock` で測り、Linux ではそれがプロセス全体の CPU 時間なので、実時間の 15 ms
  よりずっと短くなり、そのツールより計画が遅くなりうる。その前の地図の読み取りは、時間ではなく 1 フレームのブロック数で
  区切る。混んだ地図で 6 ブロックにどれだけかかるかは未確認。
- 線路の種類: 短い `--track` の名前は Track Connector がテンプレートの名前にし、そのテンプレートが無いと黙って標準の線路に
  する。`connect` はそのときエラーにする。
- 建設の結果: Track Connector は建設コマンドのコールバックで書く。5 秒たっても状態が "nothing happened" のままなら、新しい
  piece が両端につながっていれば建ったとみなす (note にそう書く)。
- `newEdges` / `newNodes` は、建てる前と後の間に経路沿いに増えたもの全部: その間に町が道路を作れば、それも入る。
