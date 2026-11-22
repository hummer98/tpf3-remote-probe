# Remote Probe for Transport Fever 3

[English README](README.md)

Transport Fever 3 の MOD (`hummer_remote_probe`) と、コマンドラインのツール (`tools/tf3ctl.py`) の組です。ゲームの外の
スクリプトから、動いているゲームを操作できます。速度を UI の上限 4 倍より上げる、指定日まで進めて止める、セーブのロードと
保存 (他の MOD や MOD の設定を変えて)、メインメニューからの新しいゲーム、ウィンドウを開く、車両の売買、路線づくり、
2 つの端の間に線路や道路を引くこと (Track Connector MOD を使う)、ゲームのログを読むこと。

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
MOD は速度ボタンのレシピを、同じボタンと ×8 / ×16 のボタンと小さな表示に差し替え、依頼を GUI の保存データでそのレシピに渡します。
そのため、`window`・`event`・`tool` と、車両・路線のコマンドの `--via gui` では、**ゲーム画面に速度ボタンが出ている**
必要があります (出ていなければ、`window`・`event`・`tool` は 10 秒後に `"relayed": false` の、車両・路線は 60 秒後に
「no word from the speed control」のエラーになります)。

メインメニューには、まだゲームのスクリプトがありません。そこで、ゲームを `--script hummer_remote_probe::/startup.lua`
付きで起動すると、同じコマンド処理がメニューで動きます (status・saves・info・load・newgame・poll・quit だけ)。
`tf3ctl.py launch` と `restart` がこれを行います。

## 必要なもの

- Steam 版の Transport Fever 3 (build 40444 で試験)、Linux。ツールは `fcntl` と Linux のプロセス一覧を使うので、
  このままでは Windows で動きません。
- Python 3.8 以上と、`PATH` 上の `luajit` (ツールは MOD の Lua のファイルを luajit で読みます)。
- 任意: `frame` に `ffmpeg` と Steam のバックグラウンド録画。`screenshot --preview` に ImageMagick。
- 任意: `connect` に Track Connector MOD (mod.io、modId `ethan_track_connector`、revision 3 / v1.3 に合わせて作成、ゲーム内ではまだ動かしていない)。セーブで
  有効にしておきます。
- Time Warp (mod.io 6453396、modId `mobarzik_faster_game_speed`) とは一緒に使えません。どちらも同じ速度ボタンを
  置き換えるためです。`mod.json` の `incompatibilities` に載せてあるので、両方を有効にするとゲームが警告します。
  それでも両方を有効にした場合は、Time Warp のボタンと横の表示が出て、この MOD の ×8 / ×16 は出ません。

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
`gameState` が示す)、4 断った: 動いているゲームはこの `--owner` のものではない (何も送っていない。「ゲームを変えるのは起動した owner だけ」)。

### 時間と速度

```
python3 tools/tf3ctl.py status                        # 日付、速度、実測の倍率、MOD とその設定
python3 tools/tf3ctl.py speed 16                      # UI の 4 倍を超える (上限あり、「安全上の注意」)。0 で停止
python3 tools/tf3ctl.py pause
python3 tools/tf3ctl.py run --months 2 --speed 16     # --days N / --until YYYY-MM-DD も。その後は速度 0
python3 tools/tf3ctl.py poll --idle 5 --active 0.5    # コマンドファイルを読む間隔 (次のロードまで)
```

ゲームの画面では、本体の ⏸ ▶ ▶▶ ▶▶▶ (0/1/2/4) の右に、同じ見た目の ×8 と ×16 のボタンを足します。いまの速度の
ボタンが、本体のボタンと同じように光ります。×8 / ×16 のボタンは、その速度をそのまま指定します。ゲームの見積もりの
上限より上でも止めません (`speed` は上限で止めますが、ボタンはプレイヤーが自分で選ぶものなので)。本体のボタンを
押せば、本体の速度に戻ります。横の表示 (`×16 実測×3.2`) は、本体のボタンにない 8 と 16 でも今までどおり出ます。

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
なります。ack の plan で確かめてください。
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
終了コード 1 になります (ゲームは止まったままです)。別の道具が `profile.lua` の写しを持つなら、`TF3CTL_OTHER_BACKUPS`
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
python3 tools/tf3ctl.py entities --kind town --grep ems     # ID と名前: town・line・vehicle・station・industry
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

`camera` の返事は、動かした後に読み直した値です。数は先に確かめます。NaN・無限大・1e6 を超える中心・1〜1e5 の外の
距離・±2π を超える angle・±π/2 を超える pitch は断ります。`--entity` は entity があるかを確かめます。メインメニューでは断ります。

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
選ばれるかは、まだ確かめていません。

配置の予告とツールチップは、マウスの下に建設案ができたときだけ出ます。なので、ゲームのポインタが 3D の画面の上にある必要があります。
`pointer FX,FY` で、人の手なしにそこへ置けます。ゲームの窓に X11 の合成イベント `EnterNotify` と `MotionNotify` を送ります
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
`purchaseTime`、車両の残存価値が入ります。車両の価格を変える MOD を確かめるのに足ります。一時停止して使ってください。
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
  上書きします。`connect` は建てる前と後に、状態が自分の端と経路のままかを確かめ、違えばエラーで終わります。送った設定はその状態に残り、
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
```

**テスト用のセーブで使います。** `build` は建物 (`.con`: 車庫、駅、アセット、産業、別の MOD の建物) を1つ、クリックも
キーも使わずに置きます。`ConstructionEntity` を1つ入れた `SimpleProposal` を、プローブの GUI スクリプトから
`api.cmd.makeWorldBuildProposalCmd` でエンジンに送ります (MOD が自分の道具で建てるのと同じ道)。エンジンはプレイヤーが
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
- 答え: `entity` (できた建物)、`construction` (`fileName`、`name`、`depots`、`stations`、`industries`、`ends`: 建物自身の
  道路・線路の空いた端と位置。`connect --from` の候補。`connectable`: `road` でつなげる所。`road` を参照)、`cost` (エンジンの値)、`balanceBefore` / `balanceAfter` /
  `spent`、`errors`、`warnings`、`collisions` (邪魔をしている id)、送った `params`、`at` (使った z と `zFrom`)。断られた
  ときは `ok: false` で、エンジンの文言が `error` に入ります。
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
  断ります。港のモジュールのスクリプトは `mod.metadata.platform` を確かめずに読むためです。空の `modules` も断ります。答えの `params.modules` には、スロット・名前・variant・metadata と updateScript を
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
python3 tools/tf3ctl.py road --inspect-node 4077     # 読むだけ: 1つの node について road が読むもの
```

- 2点 (x,y[,z]、メートル。z が無ければ地形の高さ) の間に、まっすぐな道路を1本、クリック無しで建てます。
  `SimpleStreetProposal` (新しい edge 1本と新しい node。番号は `type.d.tl` のとおり -1 から下へ) を
  `api.cmd.makeWorldBuildProposalCmd` で送ります。`build` が建物を送るのと同じ形です (同じ context: 何も壊さない、
  エラーを無視しない)。ゲームを変えるので、テスト用のセーブでだけ使ってください。
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
  (`streetConnectorSystem.getConstructionEntityForNode` が 0 以上か、そこに建物の凍結の edge がある) には、**交差点の
  設定に触らずに**つなぎます (外しも作り直しもしない。Overpass Builder は建物の node でこれを断っています)。端には
  `construction`、`nodeConfigKept: true`、`pieces` が付き、答えに `caution` が付きます。建物の凍結の node (口の内側の端)
  は、dry-run も含めて、送る前に断ります。
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
  種類 NORMAL (`typeIndex` -1: 橋もトンネルも無し)、会社の `PlayerOwned` を付け、両端の tangent は2点を結ぶ線 (まっすぐ) です。
- 答え: `from` / `to` (つないだときは `node` と `snapped`、ほかは `zFrom`)、`template`、`year`、`length`、`edges` /
  `nodes` (結果の新しい entity)、`edge`、`node0` / `node1`、`cost`、`spent`、断られたときはエンジンの `errors`・`warnings`・
  `collisions`。結果に id が無いとき、30 秒たってもコールバックが来ないときは、2点の間の道路を探します。探すときは、送る前からあった道路を除きます。建てたと言われたのに新しい
  道路が見つからないときは `warning` を付けます。template や `BaseEdgeType` / `RoadType` の enum が読めないときは、
  何も送らずに断ります。
- `--dry-run` は何も送らず、エンジンにも聞きません。プローブが確かめた計画だけを返します (`checked: false`、
  `engineCheck: "not asked (use --engine-check)"`)。ほかの dry-run と同じく、安全に使えます。
- `--dry-run --engine-check` (`--engine-check` は `--dry-run` と一緒にだけ使う): 建てるときに送るのと同じ proposal
  (設定も含む) も作り、
  `api.engine.util.proposal.makeProposalData` (proposal だけ、だめなら context も渡す) でエンジンに聞きます。
  呼ぶのは guiUpdate の中で、レシピの本体では呼びません。答えは `checked: true`、`engineCheck` (使った形)、`buildable`、
  エンジンの `cost`・`errors`・`warnings`・`collisions`・`critical`、`balance`。エンジンが断るものは `ok: false` で、文言が
  `error` に入ります。`makeProposalData` が無いか、どちらの形でもエラーになるときは、プローブの計画だけを返します
  (`checked: false`、`engineCheck: "not available: ..."`)。エンジンの評価は pcall で守れないネイティブのコードを通る
  (そこで assertion が出るとゲームが終わる) ので、tf3ctl はこれをゲームを変える命令に数えます。統括から時間をもらって、
  テスト用のセーブでだけ使ってください。
- `--inspect-node ID` (読むだけ、ほかの引数と一緒には使わない): node の位置、`streetSegments` (それぞれの道路の `edge`、
  `node0` / `node1`、`street`、`construction`)、`constructionForNode` (getConstructionEntityForNode)、`construction`
  (見つけた建物、`frozen`、`by`) と `constructionFrozenNodes` / `constructionFrozenEdges`、`nodeConfig` (無ければ
  `false`。あれば `laneConnections`・`crosswalks`・`trafficLightStates`・`doubleSlipSwitch`)、`octree`
  (`findEntitiesInCircle` が 1・5・20 m の中で当たる道路と、それぞれがその node で終わるか。最大 40 本)、`road`
  (その node を端にしたとき road がすること)。
- 長さは 1 m から 2000 m まで。水の上や谷を渡るには橋が要りますが、これは橋を建てません (エンジンが断るか、地形に沿うか:
  未確認)。
- 使い道: 港の歩行者用接続路だけでは、港は道路網につながりません。その横に、港の道路の空いた端から町の道路まで道路を
  通すとつながります (プレイヤーが建てるのと同じ)。
- **ゲーム内では未確認** (2026-11-22 に書いたもの): 特に、`api.type.NodeAndEntity` / `SegmentAndEntity` / `PlayerOwned`
  がその名前で届くか (`api.type.Proposal.*` も試す)、初期のままの `streetEdge` で足りるか、建物の node を、設定に
  触らずに端としてエンジンが受け付け、そこで新しい道路のレーンをつなぐか (2026-11-23 に書いた。それまで伐採場の外側の端と
  内側の端は断られた)、guiUpdate で makeProposalData が Overpass Builder の道具と同じように答えるか、コールバックの entity に何が入るか、node が本当に octree に無いか、新しい道路が横切る町の道路が
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

### 町を1か所で育てる (`town develop`・`town size`: 試験用のセーブだけ)

```sh
python3 tools/tf3ctl.py town develop --at 120,-40 --count 30 [--streets] [--upgrade] [--radius 250] [--dry-run]
python3 tools/tf3ctl.py town size --entity 801 --factors 2,1.5,1 [--update-all] [--dry-run]
```

- **試験用のセーブだけで使ってください。** プレイヤーには置けない建物を足します。港や駅の円に、`steps` で何年も
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

### 在庫とシミュレーションの歩み (`stock`・`steps`: debug の命令、試験用のセーブだけ)

```sh
python3 tools/tf3ctl.py stock list --entity 51                       # 読むだけ
python3 tools/tf3ctl.py stock set --entity 51 --stock 0 --amount 100 [--cargo COAL] [--dry-run]
python3 tools/tf3ctl.py stock set --entity 601 --stock -1 --amount 30 --cargo <cargo>   # 車両の積み荷
python3 tools/tf3ctl.py speed 0                                      # 先に一時停止
python3 tools/tf3ctl.py steps 500 [--dry-run] [--allow-running]
```

- **試験用のセーブだけで使ってください。** ゲームの debug の命令 (`api.cmd.debug`) を送り、プレイヤーにはできない形で
  ゲームを変えます (貨物が湧く、時計と関係なくシミュレーションが進む)。試験用の地図での待ち時間 (港の在庫が貯まる、
  車両が満載で着く、町が育つ) を短くするためのものです。ゲームを変える命令として、ほかのクライアントに警告が出ます
  (dry run も)。
- `stock list` は、本体の debug パネルと同じ読み方で在庫の一覧を読みます: entity の `STOCK_LIST` コンポーネント、
  0 から数える stock の番号 (`stock set --stock` に渡す番号)、stock ごとの `type`・`cargoType`・`cargo` (貨物の種類の
  名前)・`capacity`・`count` (`getStockCount`)・`cargoTypes` (その stock が受ける貨物の種類ごとの名前と `count`)。
  entity そのものに `STOCK_LIST` が無い産業・町の建物・倉庫は、その `stockList` の entity をたどります (`via`)。
  車両には在庫の一覧が無いので、`kind` が `vehicle` になり、積める貨物の種類ごとの `cargo` (`capacity`・`count`)
  が出ます (乗客は本体のパネルと同じく外し、断ります)。決めるのは `--stock -1 --cargo NAME`。`--cargo` には
  `stock list` の `cargo` をそのまま渡します。id は `industry-stocks`・`stations`・`vehicles` で分かります。
- `stock set` は `api.cmd.debug.makeStockSetCargoAmountCmd(在庫の一覧の entity, stock, amount[, cargo])` を送ります
  (cargo は指定したときだけ。本体のパネルも在庫の一覧の stock には付けない)。送る前に断るもの: 一覧に無い stock の
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
  ない (家、働き口の無い産業) ときは `found` が false で `why` が付きます。construction はその産業・町の建物・駅を、
  町の建物はその PersonCapacity の entity も探します (`candidates`)。建物の町 (産業なら construction に一番近い町)
  が分かれば `townProblems` (`api.engine.util.town.getTownProblems`: `problem` と相手の町 `with`) も付きます。
- `--town T`: 町の建物 (`townBuildingSystem.getTown2BuildingMap`、5000 まで読む) を種類ごとに (`byKind`)、店と
  働き口の行き先を数え (`counts`: `walk`・`drive`・`lines`・`none`)、`--limit` 件を届かないものから並べます。
  `notTarget` は住宅でないのに行き先でない建物の数。`problems` は上と同じ。
- `--from A --to B`: 道があるか。`api.engine.util.pathfinding.findPathNodeToNode` に `TransportMode.PERSON` (`walk`)
  と `CAR` (`drive`) を渡し、mode ごとに1回探します。端は entity か点: 建物そのものの `PERSON_CAPACITY` の
  `personNodes` (歩き) / `vehicleNodes` (車)、行き先なら `edgeWalk` / `edgeDrive` の node、
  駅なら terminal (歩きは `personNodes`、車は `vehicleNodeId`)、ほかは位置または点から `--radius` m (初期設定 40、
  500 まで) の中の網の node (`findTransportNetworkNodesInCircle`)。端ごとに 32 node まで。`paths` の mode ごとに:
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
  には、駅の terminal の node どうしでは何も返らなかったとある)、大きな地図での1回の探索の時間。

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
  `MODHUB_VALIDATE_FOLDERS` (content/remote_core.lua) にあるフォルダだけです。自分の MOD に合わせて直してください。
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
mod.io に MOD があるときだけボタンの名前を「Update」にします。この道具は、どちらのつもりかを推し量りません。新しい
MOD のページや公開にした MOD はゲームからは戻せないので、次のどれか1つでも外れると何も送りません。

- フォルダが、publish の受け付ける2つの一覧の両方にある。`tools/tf3ctl.py` と `content/remote_core.lua` の
  `MODHUB_PUBLISH_FOLDERS` (validate の一覧とは別)。自分の MOD に合わせて両方を直してください。mod.io に上げ済みの
  フォルダは、`MODHUB_PUBLISHED_IDS` (両方のファイル) で mod.io の id にも結び付けてある: `--first-upload` は断り、
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
  `--changelog` は 50000 以下 (道具の歯止め。mod.io は上限を書いていない)。name・summary・description が空でなく、`tags` は
  あれば文字列のリスト。`--dry-run` は各項目の長さと上限を返す (`local.metadata`)。
- 「送った」の印 (下) が無い。
- 更新のときだけ: `mod.json` の `revision` が整数で、そのページに前に上げたものより大きい。前の版は、
  `publish_history.jsonl` (下) がそのフォルダとその mod.io の id について記録した `revision` のうち一番大きいもの
  (mod.io が受け取ったもの: 成功・部分的なエラー・fileid が遅れた場合)。履歴に無いとき (履歴が revision を残す前の
  アップロード) は、`--previous-revision N` で今 mod.io にある revision を渡す。最初のアップロードでは断り、履歴に
  revision があるときはそれと同じでなければ断る。
- `--version X.Y.Z` (付けなくてもよい。最初のアップロードでも更新でも): 頭に 0 の付かない整数で、Y と Z は 0〜99、
  `mod.json` の `revision` を X*10000 + Y*100 + Z と読んだものと同じ (revision 10003 なら 1.0.3 だけ、revision 1 なら
  0.0.1 だけ)。MOD も、道具が送る revision とあらためて比べる。MOD の dry-run が送らないと答えたとき (ゲームに入って
  いる remote_probe が古く、無視した) は、道具がアップロードを断る。
- `--update-metadata` (付けなくてもよい。更新のときだけ。`--first-upload` と一緒なら断る): 下の `updateMetadata` を参照。
  MOD の dry-run が、頼んだのと違う `updateMetadata` を送ると答えたとき (ゲームに入っている remote_probe が古く、いつも
  true を送る) は、道具がアップロードを断る。
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
道具はまず同じ dry-run を回し (そこで断られれば何も残らない)、それから **「送った」の印**
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

`updateMetadata` だけはページと違います。ページはどちらも true です (初期値。新規の MOD では欄は押せない)。この道具は、
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

### 複数のクライアント

ツールは複数同時に動かせます (長い `run` と `status` など)。コマンドファイルは 1 つなので、ロックで順に書きます。
複数の人やスクリプトが 1 つのゲームを共有するときは、それぞれ `--owner NAME` (または `TF3CTL_OWNER`) で名前を付けます。
名前は `status` (`run.owner`、`lastAction`) に出ます。別の送り主が 10 分以内にゲームを変えていたら、ゲームを変える
コマンド (`load`・`run`・`speed`・`save`・`buy`・`line` など) の前に stderr へ警告が出ます。`quit --kill` は、別の送り主が 10 分以内に使ったゲームを、`--force` が無ければ SIGKILL しません。

### ゲームを変えるのは起動した owner だけ

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
そのプロセス ID を小さなファイルに残します。tf3ctl 自身がゲームを変えるコマンドの前に読みます (上)。同じマシンの別の道具も
読めます (たとえば、ゲームが動いている間ゲームを変えるコマンドを止める見張りが、これを読んで、起動した owner の quit だけは通す)。人が Steam から起動したゲームにはありません。

- 場所: `$XDG_RUNTIME_DIR/tf3ctl/launched.json`。`XDG_RUNTIME_DIR` が無ければ `/tmp/tf3ctl-<uid>/launched.json`。
  フォルダは 0700、ファイルは 0600。同じフォルダの一時ファイルに書いてから置き換えるので、読む側が書きかけを見ることはありません。
- 形: JSON 1 つ。`{"v": 1, "owner": "<owner>", "pid": <ゲームの pid>, "started_at": <epoch 秒>, "cmd": "launch"}`
  (`restart` でも `cmd` は `launch`。`started_at` は probe が答えた時刻)。
- 書く: `launch` / `restart` で、probe がメインメニューで答えたあと (`--load` / `--new` の前)。pid は動いている
  `TransportFever3` のプロセス (複数あれば一番新しいもの)。owner が無ければ書かず、前のファイルを消します。
- 消す: ゲームが止まったのを tf3ctl が見たとき。`quit` (`--kill` も、動いていなかったときも)、`restart` の中の quit、
  ゲームが動いていないときの `launch`、起動の途中か、そのあとの `--load` / `--new` (単独の `load` / `newgame` も) の途中でゲームが終わったとき。
- `launch` / `restart` / `quit` の答えの `launchedFile` に、何をしたかが出ます。書けない・消せないときは stderr に
  警告を出すだけです。残ったファイル (クラッシュ、手で終了したとき) はそれだけで信じず、読む側で pid が生きていてゲームか確認してください。`/tmp` のときは、フォルダとファイルが自分のもので 0700 / 0600 かも確認してください (`/tmp/tf3ctl-<uid>` は誰でも先に作れます)。

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
- `TF3CTL_OTHER_BACKUPS`: 別の道具による `profile.lua` の控え (ファイルかフォルダ)。`:` で区切る (`--lang` を参照)。
- `XDG_STATE_HOME`: `modhub publish` の印の置き場所 (`tf3ctl/publish_pending.json`。既定 `~/.local/state`)。

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
  画面はボタンを待つ。`--wait-for-start` でその動きにする)。`--wait-for-start` を付けると、人がボタンを押すまで
  読み込みの画面で止まり、その間 MOD は命令を受けられません (`quit` もできない。道具はボタンを押さない)。人が
  その場にいるときだけ使ってください。待っている間は道具が stderr にそのことを出し、押した後の答えには `note` が
  入ります。ロードの待ちが時間切れになったときは、ボタン待ちのはずだと出ます。
- `line delete` は、車両のいる路線を `--sell-vehicles` が無ければ断ります。本体のミッションと保護された entity の
  確認は省いています (試験用のセーブ向けのため)。
- `stock set` と `steps` はゲームの debug の命令です。試験用のセーブだけで使ってください (試験用のセーブと
  プレイヤーのセーブを見分ける仕組みはありません。ゲーム内では未確認)。
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
- ゲーム内の ×8 / ×16 のボタン: 本体のボタンの横での見た目と幅、光るボタン、指定される速度。
- `app.quit` が確認ダイアログなしでゲームを終えるか。
- `connect` は全部。危ない順の一覧は「実装メモ」の「接続」。
- `build` は全部 (「建物を1つ地図に置く」を参照)。 `road` も全部 (「まっすぐな道路を1本」を参照)。
- gui で買った車両を MOD が自分で路線に送ることと、断られたときの理由。`lines --problems`。`stations --catchment`。
- `terrain`・`terrain --probe-api`・`newgame --editor` は全部 (「長方形の範囲の地面」を参照)。
- `town` は全部 (「町を1つ」を参照)。
- `stock` と `steps` は全部 (「在庫とシミュレーションの歩み」を参照)。試験用のセーブだけで使う。
- `parcels` は全部 (読むだけ、「道路の脇の町の建物の区画」を参照)。
- `persons` は全部 (読むだけ): 住民のコンポーネントと旅客の集計が GUI のスクリプトで読めるか。
- `reach` と `persons --town` / `--destination` は全部 (読むだけ、「その場所へ行けるか」を参照)。
- `modhub publish` の更新 (「MOD を上げる」を参照)。`modhub status`・`validate`・最初のアップロードは 2026-11-22 に
  確認済み。

## テスト

```
luajit tests/run.lua                                   # MOD: 純粋な処理と、本物のスクリプトを偽のゲームの上で
python3 -m unittest discover -s tests -p 'test_*.py'   # tf3ctl.py: 偽のゲームと本物のファイルで端から端まで
```

どちらもゲームは要りません。`tests/fake_tc.lua` は、このテストのために書いた Track Connector の代わりです。`connect` が
頼る部分 (モジュールの関数、ゲームスクリプトのイベントと状態) の動きをまねたもので、その MOD のコードは含まず、動いている
本物と突き合わせてもいません。

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
- **速度ボタンと表示。** 本体の速度ボタンは 0/1/2/4 だけで、それ以外の速度ではどれも選ばれません。MOD は
  `react-replacement-config` (order 500) で `game_bar_widgets.GameSpeedControl` を差し替え、本体のレシピをそのまま描き
  (`CallOriginalRecipe`)、その横に ×8 と ×16 のボタンの組、さらに表示を足します。足した組は、本体のボタンと同じ
  `gameSpeedHelper.getSpeed()` で光り、押すと本体のボタンと同じく `onValueChange` の中で
  `api.cmd.makeGameSetSpeedCmd` を送ります。helper の `setSpeed` は `api.gui.game.getEstimatedMaximumGameSpeed()` で
  止めるので通しません。helper は次の step で `GAME_SPEED` コンポーネントから新しい速度を拾います。ただし本体の
  一時停止キーは helper を通して再開するので、16 倍を一時停止から再開すると、本体のボタンと同じく上限で止まります。
  本体のアイコンは 4 倍までしかないので、ボタンは文字 (`×8`、`×16`) で、本体の組の横の別の組です。この MOD より
  先に (order が小さく) 差し替えた MOD があれば、本体のボタンと ×8 / ×16 の組の代わりにそれを描き、その横に表示を
  足します。Time Warp (mod.io 6453396) は同じレシピを自前の 8x/16x ボタンに差し替え (order 10)、同じ CSS の幅を
  決めるので、欄の幅は後に読まれたスタイルシートだけで決まります。そのため `incompatibilities` に載せています
  (ゲームは警告しますが、そのまま進めることもできます)。モジュールの表を実行時に入れ替える
  GW Faster Game Speed とは、どちらかしか効きません。ゲームバーや `game.tl` を丸ごと写しで置き換える MOD
  (Upkeep Inspector、Buy Industries) も `game_bar_widgets.GameSpeedControl` と同じ `GameSpeedHelper` を使うので、
  そこでも差し替えが効きます。UI Overhaul は速度ボタンに触れません。レシピの本体とその step では、ゲームの API を
  呼びません。react はそれらをワーカースレッドでも動かし、そこで `api.util.getApplicationTime` を呼ぶと、ロードの
  たびに TF3 が SIGSEGV で落ちました (2026-11-15)。ゲームの呼び出しは、メインスレッドで動く `react.enqueueJoin` と、
  ボタンの `onValueChange` の中だけです。
- **`frame`** は、Steam のバックグラウンド録画 (`userdata/<id>/gamerecordings/video/bg_3493540_*`) の書き終わった
  最新の断片から、最後のコマを ffmpeg で取り出します。UI 込み、数秒遅れ、録画の解像度で、窓の前面化もキー送信も要り
  ません。録画フォルダは、最後に断片を書いた時刻で選びます (フォルダの mtime ではない。Steam は止まった録画の古い断片を
  消すので、そのフォルダの mtime が新しくなり、81 分前に止まった録画を選んだことがある)。`screenshot`
  (`api.gui.camera.takeScreenshot`) は、試すとファイルができませんでした (写真モード用とみられる)。
- **`window`** は、本体の統計や路線のウィンドウと同じく `react.fireEvent(nil, "selectEntity", {entity})` で開きます。
  イベントは react の中からしか送れないので、GUI スクリプトが依頼を GUI の保存データ (`api.gui.game.setGuiSaveData`、
  ゲームが MOD ごとに C++ で持つ) に書き、速度ボタンのレシピが `react.enqueueJoin` で読みます。両者で共有した Lua の表
  は、レシピに届きませんでした (別の Lua 状態のため)。前のゲームの依頼はロードのときに捨てるので、ロード直後に送った
  依頼は「took it as old; not run」(古いものとして実行しなかった) の返事になることがあります。返事は `event` と同じく
  レシピを待ちます。
  `--manager` を付けると (路線を `--line 名前` か `--entity ID` で。自社の路線だけ)、代わりに
  `openVehicleManager` を `{openWithLineEntity = 路線}` で送ります。路線の窓の「路線管理」ボタンと統計の路線の行と
  同じ道で、管理の窓が次のステップでその路線を選びます。ゲーム内ではまだ確認していません。
- **`event`** は、react のイベント名と、引数として平らな値だけの JSON オブジェクトを取ります。`window`・`event`・`tool` と
  `build-tool` のイベントは GUI の保存データの列 (`opens`) に入り、レシピが 1 回の読み取り (0.5 秒ごと) に 1 つずつ、
  古い順に送ります。2026-11-22 までは枠が 1 つだけで、同じ秒に送った 2 つのイベントのうち後のほうしか送られませんでした。
  返事は、レシピがイベントを送ってそれを (`<mod>.open` に) 書いてから返り、`"relayed": true` と `relayedInSec`
  (0.5〜1 秒ほど。前に待っている依頼 1 つにつき 0.5 秒のびる) が入ります。続けて送るスクリプトは、その順に届きます。次のときは返事がエラーになります:
  レシピの `fireEvent` が失敗した (`"relayed": true`、「relayed, but ...」)、レシピが 10 秒のうちに受け取らなかった
  (`"relayed": false`。画面にゲームが無い、ESC メニューやダイアログ、別の MOD の速度ボタンが代わりにある。その依頼は
  捨て、あとから送ることはありません。10 秒は列に入れたときから数えるので、一度に待てるのは 19 個ほど)、
レシピが最初に読む前から残っていた (ロード)。ロードのときに待っている依頼には返事が来ず、tf3ctl が 20 秒後に
「no answer」で終わります。「relayed」は送ったという意味で、
  受け手が動いたかではありません。ウィンドウが開いたかは `frame` かログで見ます。
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
  assertion で落ちる)。端は経路を送る直前にもう一度確かめます。
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

## ライセンス

MIT。[LICENSE](LICENSE) を見てください。

Track Connector (`ethan_track_connector`) は別の作者の MOD です。このリポジトリには含まれず、このリポジトリの MIT
ライセンスの対象外で、このプロジェクトとの関係もありません。`connect` は、プレイヤーが自分で入れたものを読み込むだけです。
