{ pkgs }:
let
  etcFiles = {
    "timezone" = "Asia/Tokyo";
    "default/locale" = ''
      LANG=ja_JP.UTF-8
      LC_ALL=ja_JP.UTF-8
    '';
    "nsswitch.conf" = ''
      passwd:    files
      group:     files
      hosts:     files mymachines resolve [!UNAVAIL=return] dns myhostname
      networks:  files
    '';
  };
  envVars = {
    LANG = "ja_JP.UTF-8";
    LC_ALL = "ja_JP.UTF-8";
    TZ = "Asia/Tokyo";
    LOCALE_ARCHIVE = "/etc/locale-archive";
    SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";
    FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
    XDG_DATA_DIRS = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:$XDG_DATA_DIRS";
  };
  mkFiles = pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: value: ''
    mkdir -p $(dirname /etc/${name})
    echo "${value}" > /etc/${name}
  '') etcFiles);
  mkEnvs = pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (n: v: ''export ${n}="${v}"'') envVars);
in
''
  # --- Setup FHS Files ---
  ${mkFiles}
  # --- Setup Environment Variables ---
  ${mkEnvs}
''
