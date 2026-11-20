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
必要があります (出ていなければ、60 秒後に「no word from the speed control」のエラーになります)。

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
`gameState` が示す)。

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
```

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
(速度ボタンは 0.5 秒ごとに読み、最新の 1 つしか持たないので 1.5 秒あけます)。まず `setMenuFilter` にその建物のタグ
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

このイベントは、速度ボタンの依頼枠 1 つを `window`・`event`・`tool` と共有します。1.5 秒の間や解除の直前にそれらを送ると、
どちらかが上書きされます。`build-tool` が済んでから送ってください。

### 車両・所持金・路線

```
python3 tools/tf3ctl.py depots [--grep bus]
python3 tools/tf3ctl.py vehicles [--line 21]
python3 tools/tf3ctl.py vehicles --entity 601,602 --state [--since 120000]
python3 tools/tf3ctl.py models [--grep trillium] [--carrier water] [--limit 200]
python3 tools/tf3ctl.py buy --model bus_1900 --depot 301 [--line 21] [--count 2] [--via gui|cmd]
python3 tools/tf3ctl.py duplicate --vehicle 601 [--depot D] [--line L]
python3 tools/tf3ctl.py replace --vehicle 601 --model bus_1920
python3 tools/tf3ctl.py sell --vehicle 601
python3 tools/tf3ctl.py money --set 10000000 | --add -5000
python3 tools/tf3ctl.py stations [--name cent] [--near 11 --radius 800]
python3 tools/tf3ctl.py lines [--name probe]
python3 tools/tf3ctl.py line create --stops Central,42 [--name "[probe] A"] [--cargo coal] [--via gui|cmd]
python3 tools/tf3ctl.py line update 21 [--stops 41,42,43] [--name N] [--cargo C]
python3 tools/tf3ctl.py line create --stops 47,48 --terminals 0:2,0:1 [--load-mode all,available]
python3 tools/tf3ctl.py line update 23 [--terminals 0:2,0:1] [--load-mode any]
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
  ホームの空いている端の集まりとして扱い、互いにいちばん向き合う端の組を使います。
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
- `TF3_PROFILE`: `--lang` で変えるゲームの `profile.lua` (既定: 交換フォルダの隣、無ければ Steam の userdata のうち
  一番新しいもの)。控えは同じ場所に `.tf3ctl-backup` を足した名前。
- `TF3_GAME_DIR`: ゲームのインストール先。`--lang` で選べる言語を見るため (既定: userdata のある Steam の
  `steamapps/common/Transport Fever 3`)。
- `TF3CTL_OTHER_BACKUPS`: 別の道具による `profile.lua` の控え (ファイルかフォルダ)。`:` で区切る (`--lang` を参照)。

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
  `platforms` は全部のホームの一覧です (読むだけ。`--terminals` を選ぶため): `station` と `terminal` (路線の停車駅と
  同じ 0 始まり)、`stationEntity`、`tag` (バニラの港ではモジュールのマス `1000 * coordI + coordJ`。modules.script.lua)、
  `position` (車両が止まる所。ホームの最初の vehicle edge を `transport.calcPosition` で。本体が経由点の位置を出すのと
  同じ)、`cargoLoad` / `cargoUnload` / `passengersLoad` / `passengersUnload`、`cargoTransferSpeeds` (それぞれ `length`
  と `loadSpeedModifier`)、`carriers` (`getCarriers(group, station, terminal)`)、`transportModes` (有効なものの名前。
  バニラの大型船着場は SHIP と SMALL_SHIP、小型船着場は SMALL_SHIP だけ)、`capacity`。読めない項目は出しません (nil)。
  桟橋の terminal は vehicle node から作られるので、`position` は出ないことがあります (未確認)。
- `lines` は自社の路線を返します: 停車駅 (駅グループ、駅とホーム、0 始まり、`loadMode`: 0 available、1 満載
  (どれか)、2 満載 (全部))、車両、乗り物の種類、`customFilters`、`loads` (どこかの停車駅で積む貨物)、`vehicleCargo`
  (路線の車両が積める貨物)。
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
