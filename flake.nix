{
  description = "Moomoo Desktop Client";
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

      # debをNix storeに展開
      moomooApp = pkgs.stdenv.mkDerivation {
        name = "moomoo-app-${sources.moomoo.version}";
        src = sources.moomoo.src;
        nativeBuildInputs = [ pkgs.dpkg ];
        dontUnpack = true;
        installPhase = ''
          dpkg-deb -x $src $out
        '';
      };

      fhsProfile = import ./profile.nix { inherit pkgs; };

      commonBwrapArgs = [
        "--tmpfs /opt"
        "--dir /opt"
        "--tmpfs /etc"
        "--dir /etc"
        "--bind /etc/profile /etc/profile"
        "--bind /etc/bashrc /etc/bashrc"
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
        libGL gtk3 cairo pango atk gdk-pixbuf glib dbus systemd
        libsecret nss nspr libdrm libgbm libwebp libpng libjpeg
        giflib librsvg mesa qt5.qtimageformats
        libxcb libx11 libxcomposite libxcursor libxdamage libxext
        libxfixes libxi libxrandr libxrender libxtst libxscrnsaver
        libxkbcommon libxcb-wm libxcb-image libxcb-keysyms libxcb-render-util
        libpulseaudio alsa-lib at-spi2-atk cups
        google-fonts noto-fonts-cjk-sans noto-fonts-cjk-serif
        tzdata libsm libice zstd expat fontconfig freetype
        libuuid zlib sqlite cacert libxcrypt-legacy python3
      ]);

      fhsEnv = pkgs.buildFHSEnv {
        name = "moomoo-fhs";
        targetPkgs = deps;
        extraBwrapArgs = commonBwrapArgs;
        profile = fhsProfile;
        runScript = "/opt/moomoo/Launch";
      };

    in {
      # NixOSのinputsから参照するための主要output
      packages.${system} = {
        default = pkgs.symlinkJoin {
          name = "moomoo";
          paths = [
            # 起動バイナリ
            (pkgs.writeShellScriptBin "moomoo" ''
              exec ${fhsEnv}/bin/moomoo-fhs "$@"
            '')
            # desktopファイルとアイコン
            (pkgs.makeDesktopItem {
              name = "moomoo";
              desktopName = "moomoo";
              comment = "Stock Trading Platform";
              exec = "moomoo %U";
              icon = "${moomooApp}/opt/moomoo/app.png";
              categories = [ "Finance" ];
            })
          ];
        };
      };

      # デバッグ用
      devShells.${system}.default = (pkgs.buildFHSEnv {
        name = "moomoo-fhs-dev";
        targetPkgs = deps;
        extraBwrapArgs = commonBwrapArgs;
        profile = fhsProfile;
        runScript = "bash";
      }).env;

      # nix run github:yourname/moomoo-flake で直接起動
      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/moomoo";
      };
    };
}
