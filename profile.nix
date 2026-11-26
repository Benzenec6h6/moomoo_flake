{
  pkgs,
  fontsConf,
}: let
  envVars = {
    LANG = "ja_JP.UTF-8";
    LC_ALL = "ja_JP.UTF-8";

    # --- タイムゾーン対策（取引クラッシュ防止の鉄壁設定） ---
    TZ = "Asia/Tokyo";
    TZDIR = "${pkgs.tzdata}/share/zoneinfo";

    # --- ロケール・SSL証明書 ---
    LOCALE_ARCHIVE = "/etc/locale-archive";
    SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";

    # --- GSettings / デスクトップスキーマ ---
    XDG_DATA_DIRS = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:$XDG_DATA_DIRS";

    FONTCONFIG_FILE = "${fontsConf}";
  };

  mkEnvs = pkgs.lib.concatStringsSep "\n" (
    pkgs.lib.mapAttrsToList (n: v: ''export ${n}="${v}"'') envVars
  );
in ''
  # --- Setup Environment Variables ---
  ${mkEnvs}
''
