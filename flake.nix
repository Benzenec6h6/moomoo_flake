{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      sources = pkgs.callPackage ./_sources/generated.nix { };
      
      moomoo-deb = sources.moomoo.src; 

    in {
      packages.${system} = {
        default = pkgs.stdenv.mkDerivation {
          name = "moomoo-desktop-deb";
          src = moomoo-deb;
          dontUnpack = true;
          installPhase = ''
            # $out をディレクトリとして作成し、その中に配置する
            mkdir -p $out/share/moomoo
            cp $src $out/share/moomoo/moomoo.deb
          '';
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ pkgs.distrobox pkgs.podman ];

        # 環境変数として.debのパスを渡す
        shellHook = ''
          # パッケージ内のファイルパスを指すように変更
          export MOOMOO_DEB_PATH="${self.packages.${system}.default}/share/moomoo/moomoo.deb"
          
          echo "=== Moomoo Deployment Shell (nvfetcher version) ==="
          echo "deb path: $MOOMOO_DEB_PATH"
          echo "1. distrobox enter moomoo -- sudo apt install -y $MOOMOO_DEB_PATH"
        '';
      };
    };
}