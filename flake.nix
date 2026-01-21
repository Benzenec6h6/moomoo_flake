{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      sources = pkgs.callPackage ./_sources/generated.nix { };
      
      # 手元のファイルを使う場合はこちら
      localDeb = ./moomoo_desktop_16.1.14618_amd64.deb;
      # nvfetcherで取得したファイルを使う場合は sources.moomoo.src
      moomoo-deb = localDeb; 

    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ pkgs.distrobox pkgs.podman ];

        # 環境変数として.debのパスを渡す
        shellHook = ''
          export MOOMOO_DEB_PATH="${moomoo-deb}"
          
          echo "=== Moomoo Deployment Shell ==="
          echo "1. Run: distrobox create -n moomoo -i ubuntu:22.04"
          echo "2. Run: distrobox enter moomoo -- sudo apt update"
          echo "3. Run: distrobox enter moomoo -- sudo apt install -y $MOOMOO_DEB_PATH"
          echo "4. Run: distrobox enter moomoo -- distrobox-export --app moomoo"
        '';
      };
    };
}