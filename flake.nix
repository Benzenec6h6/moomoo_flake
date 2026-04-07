{
  description = "Moomoo Desktop Client (autoPatchelf version)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      sources = pkgs.callPackage ./_sources/generated.nix { };

      # buildFHSEnv の deps からそのまま移植
      # ※一部、ライブラリとして必要なものを整理
      moomooDeps = with pkgs; [
        libGL gtk3 cairo pango atk gdk-pixbuf glib dbus systemd
        libsecret nss nspr libdrm libgbm libwebp libpng libjpeg
        giflib librsvg mesa qt5.qtimageformats
        libxcb libx11 libxcomposite libxcursor libxdamage libxext
        libxfixes libxi libxrandr libxrender libxtst libxscrnsaver
        libxkbcommon libxcb-wm libxcb-image libxcb-keysyms libxcb-render-util
        libpulseaudio alsa-lib at-spi2-atk cups
        tzdata libsm libice zstd expat fontconfig freetype
        libuuid zlib sqlite libxcrypt-legacy python3
        stdenv.cc.cc.lib
      ];

    in {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "moomoo";
        version = sources.moomoo.version;
        src = sources.moomoo.src;

        nativeBuildInputs = [
          pkgs.dpkg
          pkgs.autoPatchelfHook
          pkgs.makeWrapper
        ];

        buildInputs = moomooDeps;

        # --- autoPatchelf の挙動調整 ---
        # FHS版で不要だった(含めていなかった)ものは、ここで無視を宣言してビルドを通す
        autoPatchelfIgnoreMissingDeps = [
          "libssl.so.1.1"
          "libcrypto.so.1.1"
          "libffi.so.6"
          "libncursesw.so.5"
          "libtinfo.so.5"
          "libpanelw.so.5"
          "libdb-5.3.so"
          "libgdbm.so.5"
          "libtk8.6.so"
          "libtcl8.6.so"
          "libreadline.so.7"
          "libtiff.so.5"
          "libgstgl-1.0.so.0"
          "libgstapp-1.0.so.0"
          "libgstpbutils-1.0.so.0"
          "libgstaudio-1.0.so.0"
          "libgstvideo-1.0.so.0"
          "libgstbase-1.0.so.0"
          "libgstreamer-1.0.so.0"
        ];

        # 手動で makeWrapper を行うため、Nixの自動Qtラップを無効化
        dontWrapQtApps = true;

        unpackPhase = ''
          dpkg-deb -x $src .
        '';

        installPhase = ''
          mkdir -p $out/opt/moomoo $out/bin
          cp -r opt/moomoo/* $out/opt/moomoo/

          # アイコン配置
          mkdir -p $out/share/icons/hicolor/256x256/apps
          cp $out/opt/moomoo/app.png $out/share/icons/hicolor/256x256/apps/moomoo.png
        '';

        preFixup = ''
          # 権限付与により autoPatchelf が内部バイナリを処理できるようにする
          find $out/opt/moomoo -name "*.so*" -exec chmod +x {} +
          chmod +x $out/opt/moomoo/moomoo
          chmod +x $out/opt/moomoo/CrashReporter
          chmod +x $out/opt/moomoo/FTWeb
        '';

        postFixup = ''
          # 実行スクリプトの作成
          # FHS版の profile.nix と Launch の挙動を再現
          makeWrapper $out/opt/moomoo/moomoo $out/bin/moomoo \
            --run "cd $out/opt/moomoo" \
            --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath moomooDeps}:$out/opt/moomoo" \
            --set QT_PLUGIN_PATH "$out/opt/moomoo/plugins" \
            --set LANG "ja_JP.UTF-8" \
            --set LC_ALL "ja_JP.UTF-8" \
            --set TZ "Asia/Tokyo" \
            --set SSL_CERT_FILE "/etc/ssl/certs/ca-bundle.crt" \
            --set XDG_DATA_DIRS "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS" \
            --add-flags "--no-sandbox"

          # Desktopファイルの作成
          mkdir -p $out/share/applications
          cp ${pkgs.makeDesktopItem {
            name = "moomoo";
            desktopName = "moomoo";
            comment = "Stock Trading Platform";
            exec = "moomoo %U";
            icon = "moomoo";
            categories = [ "Finance" ];
          }}/share/applications/* $out/share/applications/
        '';
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/moomoo";
      };
    };
}
