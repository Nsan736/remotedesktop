# RemoteDesk

同じ Wi-Fi 内の Windows PC を iPad から操作する、低遅延・タッチ操作重視のリモートデスクトップです。

- ホスト (Windows): `host/host.py` が Desktop Duplication (ddagrab) + NVENC で画面を H.264 にエンコードし、TCP で配信します。マウス・キーボードは SendInput で注入します。
- クライアント (iPad): `ios/` の Swift アプリが VideoToolbox でハードウェアデコードして表示し、タッチをマウス操作に変換します。
- ビルド: GitHub Actions (`.github/workflows/build-ios.yml`) で未署名 IPA を作り、AltStore / LiveContainer でインストールします。

## ホストの準備 (Windows)

必要なもの: Python 3.10 以上、ffmpeg (NVENC 対応ビルド)。

```powershell
winget install Gyan.FFmpeg
```

起動:

```powershell
cd host
python host.py
```

初回はファイアウォールの許可ダイアログが出るので「プライベートネットワーク」で許可してください。手動で開ける場合は TCP 47000 と UDP 47001 です。

`host/config.json` で調整できます。

| キー | 意味 | 既定値 |
| --- | --- | --- |
| port | 接続用 TCP ポート | 47000 |
| pin | 接続 PIN (空なら無し) | "" |
| monitor | 配信するモニタ番号 (0 が主) | 0 |
| fps | フレームレート | 60 |
| bitrate_mbps | ビットレート (Mbps) | 20 |
| encoder | auto / h264_nvenc / h264_amf / h264_qsv / libx264 | auto |
| scale_width | 配信解像度の幅 (0 で等倍) | 0 |
| gop | キーフレーム間隔 (フレーム数) | 60 |
| max_backlog_frames | 送信待ちがこれを超えたらフレームを捨てる | 3 |

遅延を最優先するなら fps 60 / scale_width 0 のまま、Wi-Fi が弱いときは bitrate_mbps を 10 前後、scale_width を 1600 などに下げてください。

## クライアントのビルド (GitHub Actions)

1. このリポジトリを GitHub に push します。
2. Actions タブの「Build iOS IPA」を実行 (push でも自動実行) します。
3. Artifacts の `RemoteDesk-ipa` をダウンロードし、中の `RemoteDesk.ipa` を AltStore または LiveContainer に入れます。

ローカルで Xcode を使う場合は `brew install xcodegen` 後に `ios/` で `xcodegen generate` すると `RemoteDesk.xcodeproj` ができます。

## 使い方

1. iPad と PC を同じ Wi-Fi につなぎ、PC で `host.py` を起動します。
2. アプリを開くと PC が自動で一覧に出るのでタップします。出ない場合は IP を手入力します。初回は「ローカルネットワーク」の許可が求められます。

### タッチモード (既定)

| 操作 | 動作 |
| --- | --- |
| タップ | 左クリック |
| ドラッグ | 左ドラッグ (ウィンドウ移動、範囲選択など) |
| 長押し | 右クリック |
| 2本指タップ | 右クリック |
| 2本指ドラッグ | スクロール |
| ピンチ | 画面の拡大 (iPad 側のみ) |
| 3本指ドラッグ | 拡大中の表示位置を移動 |
| 2本指ダブルタップ | 拡大をリセット |
| 3本指タップ | ツールバーの表示切替 |

### トラックパッドモード

ツールバーの手のアイコンで切り替えます。1本指でカーソル移動、タップでクリック、タップ直後にドラッグで左ドラッグ。2本指スクロール・右クリックはタッチモードと同じです。

### キーボード

ツールバーのキーボードアイコンで iPad のキーボードを出します。キーボード上部のバーに Esc / Tab / Ctrl / Alt / Shift / Win / 矢印 / F1〜F12 などがあります。Ctrl などの修飾キーは 1 回タップで次の 1 キーに効き (青)、2 回タップで固定 (橙)、3 回目で解除です。Bluetooth キーボードを繋いだ場合はキーがそのまま Windows に送られるので、日本語入力は Windows 側の IME で行います。

ツールバーは掴んで好きな位置に動かせます。表示は「fps / 往復遅延 ms / 受信 Mb/s」です。

## プロトコル

TCP 上の単純なフレーミング `[type:u8][length:u32 LE][payload]` です。

| 方向 | type | 内容 |
| --- | --- | --- |
| host → iPad | 1 | H.264 アクセスユニット (先頭 4 バイトはフラグ、bit0 = キーフレーム) |
| host → iPad | 2 | pong (ping のエコー) |
| host → iPad | 3 | JSON 情報 (width, height, fps, encoder) |
| iPad → host | 10 | hello JSON (pin) |
| iPad → host | 11 | 絶対マウス移動 (x, y: u16 0..65535) |
| iPad → host | 12 | 相対マウス移動 (dx, dy: i16) |
| iPad → host | 13 | ボタン (button u8: 0 左 1 右 2 中, down u8) |
| iPad → host | 14 | ホイール (dy, dx: i16、120 で 1 ノッチ) |
| iPad → host | 15 | キー (vk u16, down u8) |
| iPad → host | 16 | 文字列 (UTF-8、Unicode 入力として注入) |
| iPad → host | 17 | ping (u64) |

## 制限事項

- 音声は転送しません。
- 同時接続は 1 台までです (新しい接続が来ると前の接続を切ります)。
- 暗号化はしていません。PIN は簡易な認証なので、信頼できる Wi-Fi でのみ使ってください。
- ゲームなど Raw Input を使うアプリでは SendInput の相対移動しか受け付けない場合があります。その場合はトラックパッドモードにしてください。
