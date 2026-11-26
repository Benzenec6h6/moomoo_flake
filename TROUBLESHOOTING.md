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
  4. 古い内蔵 FreeType による OpenType（.otf）パース不能と非同期スキャンによるレースコンディション

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
  - ※注意: ホストのフォントディレクトリ（`--ro-bind /etc/fonts`）を丸ごと渡すと、Nerd Fonts や特殊な OpenType フォントが混入して古い FreeType が再クラッシュするため、FHS 側で必要なフォントのみに限定することが必須。

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

### フェーズ 5: フォント設定の再クラッシュ（google-fonts 混入と `makeFontsConf` の罠）
- **現象:**
  - `bwrap: Can't mount on symlink destination /etc/fonts` が出て先に進めない。
  - `--tmpfs /etc/fonts` を削除すると起動はするが、ログイン画面が出たあとすぐに落ちる。
- **原因の特定:**
  1. **`/etc/fonts` は `buildFHSEnv` が構築する FHS ルート内では symlink。** bwrap は symlink の上に mount できないため `--tmpfs /etc/fonts` は失敗する。
  2. **`deps` に残っていた `google-fonts` が `/usr/share/fonts` に約 9,900 個のフォントを供給していた。** うち可変フォント（`Gantari[wght].ttf` など）が 6,487 件。同梱の古い FreeType（`libftstdui.so`）が再びクラッシュする要因になっていた。
  3. **`makeFontsConf` は指定外のデフォルトディレクトリも `<dir>` として暗黙に出力していた。**
     ```xml
     <dir prefix="xdg">fonts</dir>
     <dir>/usr/share/fonts</dir>
     ...
     ```
     `FONTCONFIG_FILE` を設定しても、`/usr/share/fonts` 経由で google-fonts が裏口から読まれ続けていた。
- **解決策:**
  - `makeFontsConf` を廃止し、`pkgs.writeText` で最小限の `fonts.conf` を自前定義。
  - `deps` から `google-fonts` を完全削除。

---

### フェーズ 6: OpenType（.otf）による並行フォントスキャン死と rofi 連携の確立
- **現象:**
  - フォントを `noto-fonts-cjk-sans` 等に絞ったはずが、「たまにログイン成功するが、高確率でログイン画面表示直後にクラッシュレポート（Abnormal Time...）が出て即死する」という不安定な挙動が継続。
  - 端末から `nix run .` では起動できても、アプリケーションランチャー（rofi）から起動すると同様にクラッシュする。
  - また、起動できた場合でもフォントの描画速度が異常にもたついていた。
- **coredumpctl によるスタックトレース追跡:**
  ```text
  Stack trace of thread 8399:
    #0  0x00007276465e18d7 n/a (/opt/moomoo/libftstdui.so + 0xbe18d7)
    #1  0x00007276449a3845 FcFreeTypeQueryAll (libfontconfig.so.1 + 0x20845)
    #2  0x000072764499c5ea FcFileScanConfig (libfontconfig.so.1 + 0x195ea)
    #3  0x000072764499cb7c FcDirScanConfig (libfontconfig.so.1 + 0x19b7c)
    #4  0x000072764499cd84 FcDirCacheScan (libfontconfig.so.1 + 0x19d84)
    ...
    #11 0x000072762db0ecad fc_thread_func (libpangoft2-1.0.so.0 + 0xecad)
    #12 0x0000727647b326ee g_thread_proxy (libglib-2.0.so.0)
  ```
- **原因の特定:**
  1. **非同期スキャンによるレースコンディションの罠:**
    - クラッシュしていたのはメインスレッドではなく、Pango / Fontconfig のワーカースレッド（fc_thread_func）。
    - メイン画面の構築と裏側のフォントファイルスキャンが並行して走るため、スキャンが問題のフォントに到達するタイミングによって「たまにログインできる」「起動直後に死ぬ」という確率的（タイミング依存）な挙動を起こしていた。

  2. **古い内蔵 FreeType の OpenType（.otf）非互換:**
    - noto-fonts-cjk-sans および serif は OpenType（.otf）形式 であり、巨大な CFF2 / CID テーブルを抱えている。
    - Moomoo 内蔵の古い FreeType が、キャッシュ未生成状態からの初回パース（FcFreeTypeQueryAll）時にこの複雑な OpenType テーブルを解読できず、メモリ破壊を起こしてセグフォしていた。
    - また、フォント表示のもたつきも、この古い FreeType が膨大なグリフのパースとフォールバック探索に CPU を浪費していたことが直接の原因だった。

  3. **.desktop の相対パス呼び出しによる環境差分:**
    - makeDesktopItem の exec = "moomoo %U" と相対指定していたため、rofi 経由で叩かれた際にログインシェルの $PATH が渡らず、意図したラッパーバイナリが正しく実行できていなかった。

- **解決策:**
  1. **OpenType を完全追放し、純粋な TrueType（.ttf）のみに統一:**
    - noto-fonts-cjk を廃止し、最もシンプルかつ互換性の高い ipaexfont（IPAexフォント: .ttf） を採用。英数記号も純粋な TrueType である dejavu_fonts のみに限定。

  2. **.desktop の Exec を Nix store 絶対パスに固定:**
    - makeDesktopItem に渡すコマンドを ${moomooBin}/bin/moomoo %U に変更し、ランチャー経由でも 100% 確実にサンドボックスラッパーが実行されるようにした。

- **結果:**
  - 裏スレッドの FcFreeTypeQueryAll によるセグフォが根絶され、100 発 100 中でログインに成功するようになった。
  - 探索フォント数が数ファイル（IPAex 2 種 + DejaVu）に激減したことで、フォントの表示速度が劇的に高速化（爆速化） した。
  - rofi 経由からの起動も完全に安定稼働を確認。

---

## 3. 恒久的な対応（構成の確立）

元の /opt/moomoo/Launch は read-only であるため、pkgs.writeShellScript を用いて Nix 的に自己完結した専用ランチャースクリプトを定義し、buildFHSEnv の runScript に設定した。
最終的なランチャースクリプトの仕様
```Bash
export MOOMOO_HOME="/opt/moomoo"
export LD_LIBRARY_PATH="/opt/moomoo:/opt/moomoo/lib:/opt/moomoo/plugins/platforms:$LD_LIBRARY_PATH"
export QT_PLUGIN_PATH="/opt/moomoo/plugins:/opt/moomoo/plugins/platforms:$QT_PLUGIN_PATH"
export FONTCONFIG_FILE="${fontsConf}"          # writeText で生成した自前の fonts.conf
export LD_PRELOAD="${pkgs.mimalloc}/lib/libmimalloc.so:$LD_PRELOAD" # glibc 2.44 対策
cd "/opt/moomoo"
exec "./moomoo" "$@"
```

**最終的なフォント設定とマウント設定（flake.nix）**

OpenType（.otf）を完全に排除し、安全な TrueType（.ttf）のみを直接 Nix store から読み込む。
```Nix
fontsConf = pkgs.writeText "fonts.conf" ''
  <?xml version="1.0"?>
  <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
  <fontconfig>
    <description>Crash-Proof TrueType Fonts for Moomoo</description>

    <!-- 純粋な TrueType (.ttf) のみ指定（OpenType は絶対に入れない） -->
    <dir>${pkgs.ipaexfont}/share/fonts/truetype</dir>
    <dir>${pkgs.dejavu_fonts}/share/fonts/truetype</dir>
    <cachedir>/tmp/fontconfig-cache</cachedir>

    <alias>
      <family>sans-serif</family>
      <prefer>
        <family>IPAexGothic</family>
        <family>DejaVu Sans</family>
      </prefer>
    </alias>
    <alias>
      <family>serif</family>
      <prefer>
        <family>IPAexMincho</family>
        <family>DejaVu Serif</family>
      </prefer>
    </alias>
    <alias>
      <family>monospace</family>
      <prefer>
        <family>DejaVu Sans Mono</family>
        <family>IPAexGothic</family>
      </prefer>
    </alias>
  </fontconfig>
'';

fhsProfile = import ./profile.nix {inherit pkgs fontsConf;};

commonBwrapArgs = [
  "--dir /opt"
  "--bind ${moomooApp}/opt/moomoo /opt/moomoo"
  "--bind-try /run/current-system/sw/lib/locale/locale-archive /etc/locale-archive"
  "--ro-bind-try ${pkgs.tzdata}/share/zoneinfo /usr/share/zoneinfo"
  "--dev-bind /dev/shm /dev/shm"  # CEF 描画用共有メモリ
];
# deps には google-fonts や noto-fonts は含めず、ipaexfont, dejavu_fonts を使用
```

**最終的な .desktop 連携構成（flake.nix）**
```Nix

packages.${system} = let
  moomooBin = pkgs.writeShellScriptBin "moomoo" ''
    exec ${fhsEnv}/bin/moomoo-fhs "$@"
  '';
in {
  default = pkgs.symlinkJoin {
    name = "moomoo";
    paths = [
      moomooBin
      (pkgs.makeDesktopItem {
        name = "moomoo";
        desktopName = "moomoo";
        comment = "Stock Trading Platform";
        # rofi対策：Nix store の絶対パスを焼き込む
        exec = "${moomooBin}/bin/moomoo %U";
        icon = "${moomooApp}/opt/moomoo/app.png";
        categories = ["Office" "Finance"];
      })
    ];
  };
};
```
- **profile.nix の環境変数:**
```Nix
{pkgs, fontsConf}: let
  envVars = {
    LANG = "ja_JP.UTF-8";
    LC_ALL = "ja_JP.UTF-8";
    TZ = "Asia/Tokyo";
    TZDIR = "${pkgs.tzdata}/share/zoneinfo"; # 取引クラッシュ防止の二重保険
    LOCALE_ARCHIVE = "/etc/locale-archive";
    SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";
    FONTCONFIG_FILE = "${fontsConf}";
    XDG_DATA_DIRS = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:$XDG_DATA_DIRS";
  };
  # ...
```
---

## 4. 教訓とノウハウ（NixOS で古い商用バイナリを動かす鉄則）

- **ログを吐かないバイナリには strace と coredumpctl**
  - 標準出力を握り潰すバイナリでも、glibc の致命的エラー出力（writev(2, ...)）やカーネルシグナル（tgkill）は strace を欺けない。
  - coredumpctl info のスタックトレースを見れば、落ちたスレッドの関数名（FcFreeTypeQueryAll など）から真犯人のサブシステム（フォント、ネットワーク、グラフィック）を特定可能。

- **「たまに落ちる / たまに起動する」は並行スレッドを疑え**
  - メインスレッドではなく、バックグラウンドのワーカースレッド（fc_thread_func やロガー、IPC）が非同期でリソースを舐めている場合、処理の到達タイミングによるレースコンディションが発生する。

- **古い FreeType には OpenType（.otf）を読ませるな**
  - 古い内蔵 FreeType は、現代の巨大な OpenType や可変フォント（Variable Fonts）のテーブル構造に対応できず、パース時にセグフォを起こす。
  - クラシックで単純な TrueType（.ttf、IPAex フォントや DejaVu） に絞るのが最強の安全策。
  - フォント数を数ファイルに絞ることで、フォールバック探索が最短化され、文字描画のレスポンスが劇的に高速化する という絶大なメリットもある。

- **pkgs.makeFontsConf の暗黙パス混入に注意**
  - makeFontsConf は指定外のデフォルトパス（/usr/share/fonts や ~/.nix-profile）を <dir> として強制追加する。コンテナ内でフォントを厳密に分離・限定したい場合は、pkgs.writeText で自前の最小 fonts.conf を書くのが鉄則。

- **ランチャー（rofi など）向けの .desktop は Exec に絶対パスを埋め込む**
  - .desktop に exec = "app %U" と相対指定すると、GUI セッション起動時にログインシェルの $PATH が反映されず、意図しないバイナリが叩かれたり起動失敗する。
  - Nix では ${binPackage}/bin/app のように store 絶対パスを焼き込むことで、起動元による環境差異を 100% 排除できる。

- **glibc 更新に伴う free(): invalid pointer には LD_PRELOAD=libmimalloc.so**
  - 古いバイナリが新しい glibc のヒープ破壊検知で死ぬ場合、アロケータを mimalloc や jemalloc にすり替えるのが最も副作用の少ない銀の弾丸となる。

