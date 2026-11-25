# Remote Probe: 既知の振る舞い・安全上の注意・確認の記録

[English](KNOWN_BEHAVIOR.md) · [README](../README.ja.md) · [命令の参照](REFERENCE.ja.md) · [AI エージェント向け (英語)](../AGENTS.md)

ゲームの癖、ゲームが落ちた並び、限界、ゲーム内で確認したこと・まだのことの日付つきの記録です。README から中身を
変えずに移しました。本文が指す節のうち、ここに無いもの (「使い方」「設定ファイル」「実装メモ」、各命令の節など) は
[REFERENCE.ja.md](REFERENCE.ja.md) にあります。

## 安全上の注意

- **`newgame` はゲームの途中からは使えません。** 本体の `StartGame` はゲームが動いていないことを前提にしていて、
  TF3 が落ちました (2026-11-15)。セーブの中で通るのは `newgame --list` と `--dry-run` だけです (始めるのはツールも MOD も
  断ります)。新しいゲームは、メインメニューから `restart --new` か `launch --new` で始めます。
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
  `tool --module` で他のモジュールを指す前に、その本体のボタンが何を渡しているかを確認してください。
- **`quit --kill` と `restart` は、終わらないゲームを SIGKILL します。** 保存していない進行は失われます
  (`restart --no-kill` で諦める)。別の `--owner` が 10 分以内に変えたゲームは、`--force` が無ければどちらも殺しません。
- **ロードすると、保存していない進行は失われます。** ロードは「ゲーム開始」ボタンを待たずに始まります (本体のロード
  画面はボタンを待つ。`--wait-for-start` でその動きにする)。`--wait-for-start` を付けると、人がボタンを押すまで
  読み込みの画面で止まり、その間 MOD は命令を受けられません (`quit` もできない。ツールはボタンを押さない)。人が
  その場にいるときだけ使ってください。待っている間はツールが stderr にそのことを出し、押した後の答えには `note` が
  入ります。ロードの待ちが時間切れになったときは、ボタン待ちのはずだと出ます。
- `line delete` は、車両のいる路線を `--sell-vehicles` が無ければ断ります。本体のミッションと保護された entity の
  確認は省いています (試験用のセーブ向けのため)。
- `stock set`・`steps` とほかの debug の命令は、どのセーブにも届きます。読み込んだセーブが試験用かを確認するのは
  `road --ignore-errors`・`lights --off`・`running-costs` の書き込み・`eval --write` だけです。ほかの命令も試験用のセーブで使って
  ください。答えに `saveNote` が付きます (セーブの中身が変わり、保存すると変更が残る)。
- `money` は「その他」の仕訳として帳簿に残り、収支の表やグラフに出ます。
- `buy` は、年代の外のモデルも買えます (店の可否の確認は通しません)。

## ゲーム内で確認したこと

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
- `calendar-speed` (2026-11-25、平らな試験用の地図): 1 日の初期の長さは 4000 ms (1x)。0.25 で 16000 ms になり、
  そのあと日付はゲーム時間 40 秒で 2 日進んだ (1x では 10 日)。0 で日付が止まった。1 で 4000 ms に戻った。

まだ確認していないこと:

- 今の形 (速度ボタンのレシピで動く) の `buy`・`duplicate`・`replace`・`sell` の `--via gui` と、一時停止中にその
  レシピが回るか。
- `money`: ゲーム内で残高が変わるか、仕訳がセーブに残るか。
- 路線のコマンドのうち、最初の試験より先のもの (小さいセーブで `stations`・`stations --near`・`lines` と、停車駅 2 つの
  `line create --via gui` は動いた): `line update`・`line delete`・`--cargo`・`buy --line` と `--via cmd` の経路。まず
  小さいセーブで試してください。詳しくは「実装メモ」。
- `window` と `event` でウィンドウが開くか、速度の表示の位置と見た目、`tool` が `pop` でウィンドウを閉じるか。
- ゲーム内の ×8 / ×16 のボタン: 本体のボタンの横での見た目と幅、光るボタン、指定される速度。
- `calendar-speed`: 変えた値が「Weather and Time」の窓の「Calendar Speed」のスライダーに出るか。
- `app.quit` が確認ダイアログなしでゲームを終えるか。
- `connect` は全部。危ない順の一覧は「実装メモ」の「接続」。
- `build` は全部 (「建物を1つ地図に置く」を参照)。 `road` も全部 (「まっすぐな道路を1本」を参照)。
- gui で買った車両を MOD が自分で路線に送ることと、断られたときの理由。`lines --problems`。`stations --catchment`。
- `terrain`・`terrain --probe-api`・`newgame --editor` は全部 (「長方形の範囲の地面」を参照)。
- `town` は全部 (「町を1つ」を参照)。
- `town connections` と `town connect` は全部 (「町のつながり」を参照)。
- `company` と `company init` は全部 (「セーブと新しいゲーム」の会社の成長)。
- `stock` と `steps` は全部 (「在庫とシミュレーションの歩み」を参照)。試験用のセーブ向け。
- `parcels` は全部 (読むだけ、「道路の脇の町の建物の区画」を参照)。
- `lanes` と `around --lanes` は全部 (読むだけ、「道路の車線」を参照)。
- `around` は全部 (読むだけ、「ある点の周りにある物」を参照)。`build` / `road` の `hits`・`--remove-buildings`・
  `--join-streets`・`joins`。`build --dry-run --engine-check` と `fit` は全部。
- `persons` は全部 (読むだけ): 住民のコンポーネントと旅客の集計が GUI のスクリプトで読めるか。
- `reach` と `persons --town` / `--destination` は全部 (読むだけ、「その場所へ行けるか」を参照)。
- `modhub publish` の更新 (「MOD を上げる」を参照)。`modhub status`・`validate`・最初のアップロードは 2026-11-22 に
  確認済み。

## ゲームスクリプトから送る提案（MOD の script event）

2026-11-26 にゲーム内で確認。

- ゲームスクリプトの `handleEvent` から、`api.cmd.sendCommand(api.cmd.make.buildProposal(...)` /
  `makeWorldBuildProposalCmd(...), callback)` を送れる。callback も呼ばれる。バニラの路上の停留所（`small_old.con`）
  は、`replaceSegment` と `SimpleStreetProposal.EdgeObject` を使って、この形で置けた。答えの `resultEntities`
  は空だった。
- 在庫（OUTPUT の `stockList`）を持つ subconstruction を入れた edge object の `.con` を、同じ形で送ると、ゲームが
  ネイティブのクラッシュで落ちた。Lua のエラーは出ない。在庫が原因かどうかは、切り分けていない。
- 道路の外に置く建設物（`build` で置く）には、駅と、在庫だけの subconstruction（産業なし）を同居させられる。その
  在庫の量は、ゲームスクリプトから書ける。
- `build --no-owner` で建てた建設物の口に、`road --from-node` で道路をつないだ。その駅を通る路線は作れたが、車両を
  路線に入れると "Unkown"（原文のまま）で断られた。絵では、口に進入禁止の印が出ていた。原因は分かっていない。

## メモ

- **交換フォルダ。** `recordings` を最初に使います。本体は `mod_presets` の全ファイルを MOD プリセットとして並べる
  (拡張子で絞らない) ので、そこに置いたファイルがプレイヤーのプリセット一覧に出ました。本体の GUI は `recordings` も
  `keyframes` も一覧にしません (どちらもデバッグ用のカメラツールが使う)。`saveUserdata` はファイルを上書きしないので、
  答えは毎回新しい名前で書き、ツールが古いものを消します。`clean` は probe のファイルを全部消します (ロードが動いて
  いないとき、つまりゲームが終わった・落ちた・メインメニュー・起動中のときは、今のロードの hello とコマンドファイルも)。
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
  消すので、そのフォルダの mtime が新しくなり、81 分前に止まった録画を選んだことがある)。ゲーム自身の
  `takeScreenshot` は、試すとファイルができなかったので (写真モード用とみられる)、`screenshot` 命令は外しました。
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
