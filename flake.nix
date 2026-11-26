{
  description = "Moomoo Desktop Client";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      localSystem = system;
      config.allowUnfree = true;
    };

    sources = pkgs.callPackage ./_sources/generated.nix {};

    # debをNix storeに展開
    moomooApp = pkgs.stdenv.mkDerivation {
      name = "moomoo-app-${sources.moomoo.version}";
      src = sources.moomoo.src;
      nativeBuildInputs = [pkgs.dpkg];
      dontUnpack = true;
      installPhase = ''
        dpkg-deb -x $src $out
      '';
    };

    fhsProfile = import ./profile.nix {inherit pkgs fontsConf;};

    # Nixpkgs公式の fonts.conf 自動生成（FreeTypeセグフォ回避）
    fontsConf = pkgs.writeText "fonts.conf" ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <dir>${pkgs.noto-fonts-cjk-sans}/share/fonts</dir>
        <dir>${pkgs.noto-fonts-cjk-serif}/share/fonts</dir>
        <dir>${pkgs.dejavu_fonts}/share/fonts</dir>
        <cachedir>/tmp/fontconfig-cache</cachedir>

        <!-- 最低限の別名(これがないと sans-serif 指定で解決できない場合がある) -->
        <alias>
          <family>sans-serif</family>
          <prefer>
            <family>Noto Sans CJK JP</family>
            <family>DejaVu Sans</family>
          </prefer>
        </alias>
        <alias>
          <family>serif</family>
          <prefer>
            <family>Noto Serif CJK JP</family>
            <family>DejaVu Serif</family>
          </prefer>
        </alias>
        <alias>
          <family>monospace</family>
          <prefer>
            <family>DejaVu Sans Mono</family>
          </prefer>
        </alias>
      </fontconfig>
    '';

    # 自前のカスタムLaunchスクリプト（mimalloc注入と環境変数）
    launchScript = pkgs.writeShellScript "moomoo-launch" ''
      export MOOMOO_HOME="/opt/moomoo"
      export LD_LIBRARY_PATH="/opt/moomoo:/opt/moomoo/lib:/opt/moomoo/plugins/platforms:$LD_LIBRARY_PATH"
      export QT_PLUGIN_PATH="/opt/moomoo/plugins:/opt/moomoo/plugins/platforms:$QT_PLUGIN_PATH"
      export FONTCONFIG_FILE="${fontsConf}"
      export LD_PRELOAD="${pkgs.mimalloc}/lib/libmimalloc.so:$LD_PRELOAD"
      cd "/opt/moomoo"
      exec "./moomoo" "$@"
    '';

    commonBwrapArgs = [
      "--dir /opt"
      "--bind ${moomooApp}/opt/moomoo /opt/moomoo"
      #"--tmpfs /etc/fonts"
      "--bind-try /run/current-system/sw/lib/locale/locale-archive /etc/locale-archive"
      "--ro-bind-try ${pkgs.tzdata}/share/zoneinfo /usr/share/zoneinfo"
    ];

    deps = pkgs: (with pkgs; [
      mimalloc
      libGL
      gtk3
      cairo
      pango
      atk
      gdk-pixbuf
      glib
      dbus
      systemd
      libsecret
      nss
      nspr
      libdrm
      libgbm
      libwebp
      libpng
      libjpeg
      giflib
      librsvg
      mesa
      qt5.qtimageformats
      libxcb
      libx11
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxrandr
      libxrender
      libxtst
      libxscrnsaver
      libxkbcommon
      libxcb-wm
      libxcb-image
      libxcb-keysyms
      libxcb-render-util
      libpulseaudio
      alsa-lib
      at-spi2-atk
      cups
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      dejavu_fonts
      tzdata
      libsm
      libice
      zstd
      expat
      fontconfig
      libuuid
      zlib
      sqlite
      cacert
      libxcrypt-legacy
      python3
    ]);

    fhsEnv = pkgs.buildFHSEnv {
      name = "moomoo-fhs";
      targetPkgs = deps;
      extraBwrapArgs = commonBwrapArgs;
      profile = fhsProfile;
      # 自作の完璧なラッパースクリプトを指定！
      runScript = "${launchScript}";
    };
  in {
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
            # Nix store内の絶対パスを指定
            exec = "${moomooBin}/bin/moomoo %U";
            icon = "${moomooApp}/opt/moomoo/app.png";
            categories = ["Office" "Finance"];
          })
        ];
      };
    };

    devShells.${system}.default =
      (pkgs.buildFHSEnv {
        name = "moomoo-fhs-dev";
        targetPkgs = deps;
        extraBwrapArgs = commonBwrapArgs;
        profile = fhsProfile;
        runScript = "bash --login";
      }).env;

    apps.${system}.default = {
      type = "app";
      program = "${self.packages.${system}.default}/bin/moomoo";
    };
  };
}
