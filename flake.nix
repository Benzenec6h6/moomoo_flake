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

      moomooDeps = with pkgs; [
        libGL gtk3 cairo pango atk gdk-pixbuf glib dbus systemd
        libsecret nss nspr libdrm libgbm libwebp libpng libjpeg
        giflib librsvg mesa qt5.qtimageformats
        libxcb libx11 libxcomposite libxcursor libxdamage libxext
        libxfixes libxi libxrandr libxrender libxtst libxscrnsaver
        libxkbcommon libxcb-wm libxcb-image libxcb-keysyms libxcb-render-util
        libpulseaudio alsa-lib at-spi2-atk cups
        cacert
        google-fonts noto-fonts-cjk-sans noto-fonts-cjk-serif
        tzdata libsm libice zstd expat fontconfig freetype
        libuuid zlib sqlite libxcrypt-legacy python3
        stdenv.cc.cc.lib
        #openssl  # SSL通信に必要
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

        dontWrapQtApps = true;

        unpackPhase = ''
          dpkg-deb -x $src .
        '';

        installPhase = ''
          mkdir -p $out/opt/moomoo $out/bin
          cp -r opt/moomoo/* $out/opt/moomoo/

          mkdir -p $out/share/icons/hicolor/256x256/apps
          cp $out/opt/moomoo/app.png $out/share/icons/hicolor/256x256/apps/moomoo.png
        '';

        preFixup = ''
          find $out/opt/moomoo -name "*.so*" -exec chmod +x {} +
          chmod +x $out/opt/moomoo/moomoo
          chmod +x $out/opt/moomoo/CrashReporter
          chmod +x $out/opt/moomoo/FTWeb
        '';

        postFixup = ''
          makeWrapper $out/opt/moomoo/moomoo $out/bin/moomoo \
            --run "cd $out/opt/moomoo" \
            --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath moomooDeps}:$out/opt/moomoo" \
            --set QT_PLUGIN_PATH "$out/opt/moomoo/plugins" \
            --set LANG "ja_JP.UTF-8" \
            --set LC_ALL "ja_JP.UTF-8" \
            --set TZDIR "${pkgs.tzdata}/share/zoneinfo" \
            --set TZ "Asia/Tokyo" \
            --set SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
            --set CURL_CA_BUNDLE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
            --set NIX_SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
            --set FONTCONFIG_FILE "${pkgs.fontconfig.out}/etc/fonts/fonts.conf" \
            --set XDG_DATA_DIRS "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}" \
            --add-flags "--no-sandbox"

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
