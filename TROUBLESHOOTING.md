# Moomoo Desktop Client トラブルシューティング & デバッグ記録

長年 NixOS（`buildFHSEnv` + Bubblewrap）上で稼働していた Moomoo（.deb パッケージ由来のバイナリ）が、`nixos-unstable` のシステム更新に伴い突如起動不能・ログイン後クラッシュを起こした問題の調査と完全解決の記録。

---

## 1. 全体像とアーキテクチャの背景

- **対象:** Moomoo Desktop Client (Debian / Ubuntu 向け x86_64 ELF バイナリ群)
- **基盤技術:** 
  - GUI: Qt5 + 独自レンダラー（TGFX / PAG）
  - ブラウザエンジン: CEF (Chromium Embedded Framework, `libcef.so`)
  - 実行基盤: NixOS `buildFHSEnv` (Bubblewrap による名前空間サンドボックス)
- **破綻の根本原因:**
  1. `nixos-unstable` における **glibc 2.44** への更新（メモリ保護・ヒープ整合性チェックの大幅な厳格化）
  2. Nixpkgs におけるパッケージ構造・命名変更（`xorg` スコープの廃止、Fontconfig パッケージ構成変更）
  3. サンドボックス内での環境変数およびホスト設定ファイルの上書き競合

---

## 2. 発生した障害と解決のタイムライン

### フェーズ 1: 起動直後の完全沈黙（GUI初期化の失敗）
- **現象:** バイナリを実行してもウィンドウが立ち上がらず、ログも出ずに即座にプロンプトに戻る。
- **原因の特定:**
  - 本体バイナリ（`moomoo`）の `ldd` ではエラーが出ないが、Qt の画面描画プラグイン `libqxcb.so`（動的に `dlopen` される）に欠落があった。
  - `ldd ./plugins/platforms/libqxcb.so` を実行したところ、`libX11-xcb`, `libxcb-icccm`, `libxkbcommon-x11` などが `not found` となり全滅していた。
- **解決策:**
  - 最新の Nixpkgs 命名規則（`xorg.` をつけないフラットな命名）に従い、`libxcb-wm`, `libxcb-image`, `libxkbcommon` などの依存を `deps` に追加。
  - `LD_LIBRARY_PATH` に `/opt/moomoo` 配下の内部パスを通した。

---

### フェーズ 2: ログイン直後の強制終了（`SIGSEGV` / セグフォ）
- **現象:** ログイン画面までは起動するが、資格情報を入力してログインボタンを押した瞬間に `Segmentation fault (core dumped)` で落ちる。
- **GDB と coredumpctl による解析:**
  - コアダンプのスタックトレース:
    ```text
    #0 0x00007ffff798c4ab __strcmp_avx2 (libc.so.6)
    #1 0x00007fffe30b0bbb n/a (/opt/moomoo/libftstdui.so + 0xab0bbb)
    ```
  - GDB でレジスタを確認:
    - `$rdi = 0x0 (NULL)`
    - `$rsi = "interpreter-version"`
  - `libftstdui.so` を `objdump` で逆アセンブルした結果、FreeType の内部関数 `tt_property_get` であることが判明。TrueType のインタープリタバージョンを取得する処理で、第1引数に `NULL` を渡したため `strcmp(NULL, "interpreter-version")` で即死していた。
- **原因の特定:**
  - サンドボックス内で `fc-list` を叩いたところ、先頭に以下の致命的エラーが発生していた:
    ```text
    Fontconfig error: Cannot load default config file: No such file: (null)
    ```
  - `profile.nix` の `FONTCONFIG_FILE` パスが切れており、かつ `commonBwrapArgs` の `--tmpfs /etc` によってホストのフォント設定も消滅していたため、フォントエンジンが完全な飢餓状態になり `NULL` を返していた。
- **解決策:**
  - Nixpkgs 公式のフォントジェネレータ `pkgs.makeFontsConf` を使って純粋な `fonts.conf` を生成し、`FONTCONFIG_FILE` に設定。
  - ※注意: ホストのフォントディレクトリ（`--ro-bind /etc/fonts`）を丸ごと渡すと、Nerd Fonts や特殊な OpenType フォントが混入して古い FreeType が再クラッシュするため、FHS 側で必要なフォント（Noto, DejaVu）のみに限定することが必須。

---

### フェーズ 3: サンドボックス内の環境変数消失の罠
- **現象:** `profile.nix` を修正したにもかかわらず、FHS シェル内で `echo $FONTCONFIG_FILE` が空文字のままになり設定が反映されない。
- **原因の特定:**
  1. `devShells` の `runScript = "bash"` は「非ログインシェル」として立ち上がるため、`/etc/profile` を読み込まない仕様だった。
  2. `commonBwrapArgs` 内に `--bind /etc/profile /etc/profile` が存在したため、ホストの NixOS の profile がマウントされ、`profile.nix` で生成された設定が上書き抹殺されていた。
- **解決策:**
  - `commonBwrapArgs` から `--bind /etc/profile` および `--bind /etc/bashrc` を削除。
  - デバッグシェルを `runScript = "bash --login"` に変更。

---

### フェーズ 4: ログイン後のヒープ破壊アボート（`SIGABRT`）
- **現象:** フォントのセグフォを解消した結果、ログイン後に今度は `Aborted (core dumped)` で終了するようになった。
- **strace によるカーネル追跡:**
  - アプリ自身が標準エラー出力を握り潰していたため、カーネルシステムコールを直接傍受:
    ```bash
    strace -f -s 512 -o /tmp/trace.log ./moomoo
    grep -A 2 "writev(2," /tmp/trace.log
    ```
  - 炙り出された断末魔のメッセージ:
    ```text
    writev(2, [{iov_base="free(): invalid pointer", iov_len=23}, ...])
    tgkill(..., SIGABRT)
    ```
  - スタックトレース:
    ```text
    #4 malloc_printerr ( "free(): invalid pointer" )
    #6 pcre2_match_8 (libpcre2-8.so.0)
    #7 /opt/moomoo/libf3cbasis.so
    ```
- **原因の特定:**
  - ログイン成功後、WebKit/CEF レンダラーが起動し、メイン通信データの検証のため PCRE2（正規表現）が稼働。
  - Moomoo 側の古いアロケータ（または PCRE2 の構造体不整合）が管理するポインタを解放しようとした際、**glibc 2.44 の厳格なメモリ保護機能（`malloc_printerr`）** が「管轄外の不正ポインタ」と判定し、強制自決（Abort）させていた。
- **解決策（特効薬）:**
  - **`mimalloc` の注入（`LD_PRELOAD`）**
  - アロケータを `libmimalloc.so` に差し替えることで、glibc の過剰なポインタ検証をバイパス。`free(): invalid pointer` によるクラッシュを完全に回避することに成功。

---

## 3. 恒久的な対応（構成の確立）

元の `/opt/moomoo/Launch` は read-only であるため、`pkgs.writeShellScript` を用いて Nix 的に自己完結した専用ランチャースクリプトを定義し、`buildFHSEnv` の `runScript` に設定した。

### 最終的なランチャースクリプトの仕様
```bash
export MOOMOO_HOME="/opt/moomoo"
export LD_LIBRARY_PATH="/opt/moomoo:/opt/moomoo/lib:/opt/moomoo/plugins/platforms:$LD_LIBRARY_PATH"
export QT_PLUGIN_PATH="/opt/moomoo/plugins:/opt/moomoo/plugins/platforms:$QT_PLUGIN_PATH"
export FONTCONFIG_FILE="${fontsConf}"          # makeFontsConf で生成したパス
export LD_PRELOAD="/lib/libmimalloc.so:$LD_PRELOAD" # glibc 2.44 対策
cd "/opt/moomoo"
exec "./moomoo" "$@"

リポジトリにそのままコミットして保存できるよう、Markdown形式（TROUBLESHOOTING.md） で詳細なデバッグメモを作成しました。

今回の複合的な問題（Qt、FreeType、Fontconfig、Bashの挙動、glibc 2.44のアロケータ衝突）と、それをどうやってコマンドで炙り出し解決したのかを技術録として体系的に残しています。
Markdown

# Moomoo Desktop Client トラブルシューティング & デバッグ記録

長年 NixOS（`buildFHSEnv` + Bubblewrap）上で稼働していた Moomoo（.deb パッケージ由来のバイナリ）が、`nixos-unstable` のシステム更新に伴い突如起動不能・ログイン後クラッシュを起こした問題の調査と完全解決の記録。

---

## 1. 全体像とアーキテクチャの背景

- **対象:** Moomoo Desktop Client (Debian / Ubuntu 向け x86_64 ELF バイナリ群)
- **基盤技術:** 
  - GUI: Qt5 + 独自レンダラー（TGFX / PAG）
  - ブラウザエンジン: CEF (Chromium Embedded Framework, `libcef.so`)
  - 実行基盤: NixOS `buildFHSEnv` (Bubblewrap による名前空間サンドボックス)
- **破綻の根本原因:**
  1. `nixos-unstable` における **glibc 2.44** への更新（メモリ保護・ヒープ整合性チェックの大幅な厳格化）
  2. Nixpkgs におけるパッケージ構造・命名変更（`xorg` スコープの廃止、Fontconfig パッケージ構成変更）
  3. サンドボックス内での環境変数およびホスト設定ファイルの上書き競合

---

## 2. 発生した障害と解決のタイムライン

### フェーズ 1: 起動直後の完全沈黙（GUI初期化の失敗）
- **現象:** バイナリを実行してもウィンドウが立ち上がらず、ログも出ずに即座にプロンプトに戻る。
- **原因の特定:**
  - 本体バイナリ（`moomoo`）の `ldd` ではエラーが出ないが、Qt の画面描画プラグイン `libqxcb.so`（動的に `dlopen` される）に欠落があった。
  - `ldd ./plugins/platforms/libqxcb.so` を実行したところ、`libX11-xcb`, `libxcb-icccm`, `libxkbcommon-x11` などが `not found` となり全滅していた。
- **解決策:**
  - 最新の Nixpkgs 命名規則（`xorg.` をつけないフラットな命名）に従い、`libxcb-wm`, `libxcb-image`, `libxkbcommon` などの依存を `deps` に追加。
  - `LD_LIBRARY_PATH` に `/opt/moomoo` 配下の内部パスを通した。

---

### フェーズ 2: ログイン直後の強制終了（`SIGSEGV` / セグフォ）
- **現象:** ログイン画面までは起動するが、資格情報を入力してログインボタンを押した瞬間に `Segmentation fault (core dumped)` で落ちる。
- **GDB と coredumpctl による解析:**
  - コアダンプのスタックトレース:
    ```text
    #0 0x00007ffff798c4ab __strcmp_avx2 (libc.so.6)
    #1 0x00007fffe30b0bbb n/a (/opt/moomoo/libftstdui.so + 0xab0bbb)
    ```
  - GDB でレジスタを確認:
    - `$rdi = 0x0 (NULL)`
    - `$rsi = "interpreter-version"`
  - `libftstdui.so` を `objdump` で逆アセンブルした結果、FreeType の内部関数 `tt_property_get` であることが判明。TrueType のインタープリタバージョンを取得する処理で、第1引数に `NULL` を渡したため `strcmp(NULL, "interpreter-version")` で即死していた。
- **原因の特定:**
  - サンドボックス内で `fc-list` を叩いたところ、先頭に以下の致命的エラーが発生していた:
    ```text
    Fontconfig error: Cannot load default config file: No such file: (null)
    ```
  - `profile.nix` の `FONTCONFIG_FILE` パスが切れており、かつ `commonBwrapArgs` の `--tmpfs /etc` によってホストのフォント設定も消滅していたため、フォントエンジンが完全な飢餓状態になり `NULL` を返していた。
- **解決策:**
  - Nixpkgs 公式のフォントジェネレータ `pkgs.makeFontsConf` を使って純粋な `fonts.conf` を生成し、`FONTCONFIG_FILE` に設定。
  - ※注意: ホストのフォントディレクトリ（`--ro-bind /etc/fonts`）を丸ごと渡すと、Nerd Fonts や特殊な OpenType フォントが混入して古い FreeType が再クラッシュするため、FHS 側で必要なフォント（Noto, DejaVu）のみに限定することが必須。

---

### フェーズ 3: サンドボックス内の環境変数消失の罠
- **現象:** `profile.nix` を修正したにもかかわらず、FHS シェル内で `echo $FONTCONFIG_FILE` が空文字のままになり設定が反映されない。
- **原因の特定:**
  1. `devShells` の `runScript = "bash"` は「非ログインシェル」として立ち上がるため、`/etc/profile` を読み込まない仕様だった。
  2. `commonBwrapArgs` 内に `--bind /etc/profile /etc/profile` が存在したため、ホストの NixOS の profile がマウントされ、`profile.nix` で生成された設定が上書き抹殺されていた。
- **解決策:**
  - `commonBwrapArgs` から `--bind /etc/profile` および `--bind /etc/bashrc` を削除。
  - デバッグシェルを `runScript = "bash --login"` に変更。

---

### フェーズ 4: ログイン後のヒープ破壊アボート（`SIGABRT`）
- **現象:** フォントのセグフォを解消した結果、ログイン後に今度は `Aborted (core dumped)` で終了するようになった。
- **strace によるカーネル追跡:**
  - アプリ自身が標準エラー出力を握り潰していたため、カーネルシステムコールを直接傍受:
    ```bash
    strace -f -s 512 -o /tmp/trace.log ./moomoo
    grep -A 2 "writev(2," /tmp/trace.log
    ```
  - 炙り出された断末魔のメッセージ:
    ```text
    writev(2, [{iov_base="free(): invalid pointer", iov_len=23}, ...])
    tgkill(..., SIGABRT)
    ```
  - スタックトレース:
    ```text
    #4 malloc_printerr ( "free(): invalid pointer" )
    #6 pcre2_match_8 (libpcre2-8.so.0)
    #7 /opt/moomoo/libf3cbasis.so
    ```
- **原因の特定:**
  - ログイン成功後、WebKit/CEF レンダラーが起動し、メイン通信データの検証のため PCRE2（正規表現）が稼働。
  - Moomoo 側の古いアロケータ（または PCRE2 の構造体不整合）が管理するポインタを解放しようとした際、**glibc 2.44 の厳格なメモリ保護機能（`malloc_printerr`）** が「管轄外の不正ポインタ」と判定し、強制自決（Abort）させていた。
- **解決策（特効薬）:**
  - **`mimalloc` の注入（`LD_PRELOAD`）**
  - アロケータを `libmimalloc.so` に差し替えることで、glibc の過剰なポインタ検証をバイパス。`free(): invalid pointer` によるクラッシュを完全に回避することに成功。

---

## 3. 恒久的な対応（構成の確立）

元の `/opt/moomoo/Launch` は read-only であるため、`pkgs.writeShellScript` を用いて Nix 的に自己完結した専用ランチャースクリプトを定義し、`buildFHSEnv` の `runScript` に設定した。

### 最終的なランチャースクリプトの仕様
```bash
export MOOMOO_HOME="/opt/moomoo"
export LD_LIBRARY_PATH="/opt/moomoo:/opt/moomoo/lib:/opt/moomoo/plugins/platforms:$LD_LIBRARY_PATH"
export QT_PLUGIN_PATH="/opt/moomoo/plugins:/opt/moomoo/plugins/platforms:$QT_PLUGIN_PATH"
export FONTCONFIG_FILE="${fontsConf}"          # makeFontsConf で生成したパス
export LD_PRELOAD="/lib/libmimalloc.so:$LD_PRELOAD" # glibc 2.44 対策
cd "/opt/moomoo"
exec "./moomoo" "$@"

---

## 4. 教訓とノウハウ（NixOS で古い商用バイナリを動かす鉄則）

- **ログを吐かないバイナリには strace と coredumpctl**
  - 標準出力を握り潰すバイナリでも、glibc の致命的エラー出力（writev(2, ...)）やカーネルシグナル（tgkill）は strace を欺けない。
  - coredumpctl info および GDB（レジスタ値 $rdi, $rsi の確認）を使えば、落ちた関数の引数（比較しようとした文字列など）まで特定可能。

- glibc 更新に伴う free(): invalid pointer には LD_PRELOAD=libmimalloc.so
  - 古いバイナリが新しい glibc のヒープ破壊検知で死ぬ場合、アロケータを mimalloc や jemalloc にすり替えるのが最も副作用の少ない銀の弾丸となる。

- **FHS 内でのフォント管理**
  - ホストの /etc/fonts を無秩序にバインドすると、互換性のないフォント（OTF やビットマップ、Nerd Fonts）を読み込んで FreeType がセグフォを起こす。pkgs.makeFontsConf で最小限のフォント集合（Noto CJK, DejaVu）を純粋に定義するのが最も堅牢。

- **buildFHSEnv のマウント優先度**
  - --bind /etc/profile /etc/profile などを安易に設定すると、profile 引数で生成した初期化処理が丸ごと踏み潰されるため注意が必要。
