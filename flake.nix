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

    fhsProfile = import ./profile.nix {inherit pkgs;};

    # Nixpkgs公式の fonts.conf 自動生成（FreeTypeセグフォ回避）
    fontsConf = pkgs.makeFontsConf {
      fontDirectories = [
        pkgs.google-fonts
        pkgs.noto-fonts-cjk-sans
        pkgs.noto-fonts-cjk-serif
        pkgs.dejavu_fonts
      ];
    };

    # 自前のカスタムLaunchスクリプト（mimalloc注入と環境変数）
    launchScript = pkgs.writeShellScript "moomoo-launch" ''
      export MOOMOO_HOME="/opt/moomoo"
      export LD_LIBRARY_PATH="/opt/moomoo:/opt/moomoo/lib:/opt/moomoo/plugins/platforms:$LD_LIBRARY_PATH"
      export QT_PLUGIN_PATH="/opt/moomoo/plugins:/opt/moomoo/plugins/platforms:$QT_PLUGIN_PATH"
      export FONTCONFIG_FILE="${fontsConf}"
      export LD_PRELOAD="/lib/libmimalloc.so:$LD_PRELOAD"
      cd "/opt/moomoo"
      exec "./moomoo" "$@"
    '';

    # profileを踏み潰していたバインドと余計なフォントバインドを排除した安全な設定
    commonBwrapArgs = [
      "--tmpfs /opt"
      "--dir /opt"
      "--tmpfs /etc"
      "--dir /etc"
      "--bind /run/current-system/sw/lib/locale/locale-archive /etc/locale-archive"
      "--bind ${moomooApp}/opt/moomoo /opt/moomoo"
      "--dev-bind /dev /dev"
      "--bind /proc /proc"
      "--bind /sys /sys"
      "--bind /etc/static/localtime /etc/localtime"
      "--bind /etc/ssl /etc/ssl"
      "--bind /etc/static/ssl /etc/static/ssl"
      "--bind ${pkgs.tzdata}/share/zoneinfo /usr/share/zoneinfo"
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
      google-fonts
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
    packages.${system} = {
      default = pkgs.symlinkJoin {
        name = "moomoo";
        paths = [
          (pkgs.writeShellScriptBin "moomoo" ''
            exec ${fhsEnv}/bin/moomoo-fhs "$@"
          '')
          (pkgs.makeDesktopItem {
            name = "moomoo";
            desktopName = "moomoo";
            comment = "Stock Trading Platform";
            exec = "moomoo %U";
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
