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
          installPhase = "cp $src $out";
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ pkgs.distrobox pkgs.podman ];

        # 環境変数として.debのパスを渡す
        shellHook = ''
          export MOOMOO_DEB_PATH="${self.packages.${system}.default}"
          
          echo "=== Moomoo Deployment Shell (nvfetcher version) ==="
          echo "deb path: $MOOMOO_DEB_PATH"
          echo "1. distrobox enter moomoo -- sudo apt install -y $MOOMOO_DEB_PATH"
        '';
      };
    };
}