# moomoo_flake

A Nix flake for running the [moomoo desktop](https://www.moomoo.com/) client on NixOS,
using `buildFHSEnv` + `bwrap` to run the official deb package.

## Background

For a long time I assumed moomoo desktop was Windows-only, and ran it on Ubuntu via Wine.
While trying out Arch Linux, I stumbled upon the [AUR PKGBUILD](https://aur.archlinux.org/moomoo.git) and discovered that a Linux (deb) build actually exists.

Reading through the PKGBUILD, I noticed the only declared dependency is `libglvnd`, with no kernel-level checks or aggressive anti-cheat involved. This suggested it should run fine outside of Ubuntu/Debian — so I built this flake to make it work on NixOS.

## How It Works

- **nvfetcher** manages the upstream deb URL and hash, enabling automatic version tracking
- The deb package is extracted into the Nix store using `dpkg-deb`
- `buildFHSEnv` constructs an FHS-compliant environment to run the extracted binary
- `bwrap` sandboxes `/opt` and `/etc` with `tmpfs`, keeping the host environment clean
- GitHub Actions automatically opens PRs when nvfetcher detects a new upstream version

## Usage

### Add to your flake inputs

```nix
inputs = {
  moomoo.url = "github:Benzenec6h6/moomoo_flake";
};
```

### Add to your NixOS configuration

```nix
environment.systemPackages = [
  inputs.moomoo.packages.x86_64-linux.default
];
```

### Run directly with nix run

```bash
nix run github:Benzenec6h6/moomoo_flake
```

### Debug shell

To drop into the FHS environment for inspection:

```bash
nix develop github:Benzenec6h6/moomoo_flake
```

## Notes

- Only `x86_64-linux` is supported
- Requires `nixpkgs.config.allowUnfree = true`

## References

- [moomoo desktop official site](https://www.moomoo.com/)
- [AUR: moomoo (PKGBUILD)](https://aur.archlinux.org/moomoo.git)
