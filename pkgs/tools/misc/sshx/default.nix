{
  lib,
  callPackage,
  rustPlatform,
  fetchFromGitHub,
  protobuf,
  darwin,
  stdenv,
  buildNpmPackage,
}:
let
  version = "0.3.1";

  src = fetchFromGitHub {
    owner = "ekzhang";
    repo = "sshx";
    tag = "v${version}";
    hash = "sha256-AOmtN+NoBWuyCDe73dDWFmAWYEAxH8N5Vue1V87CZVU=";
  };

  mkSshxPackage =
    { pname, cargoHash, ... }@args:
    rustPlatform.buildRustPackage (
      rec {
        inherit
          pname
          version
          src
          cargoHash
          ;

        useFetchCargoVendor = true;

        nativeBuildInputs = [ protobuf ];

        buildInputs = lib.optional stdenv.hostPlatform.isDarwin darwin.apple_sdk.frameworks.Security;

        cargoBuildFlags = [
          "--package"
          pname
        ];

        cargoTestFlags = cargoBuildFlags;

        meta = {
          description = "Fast, collaborative live terminal sharing over the web";
          homepage = "https://github.com/ekzhang/sshx";
          changelog = "https://github.com/ekzhang/sshx/releases/tag/v${version}";
          license = lib.licenses.mit;
          maintainers = with lib.maintainers; [
            pinpox
            kranzes
          ];
          mainProgram = pname;
        };
      }
      // args
    );
in
{
  sshx = mkSshxPackage {
    pname = "sshx";
    cargoHash = "sha256-S07xqDiINhOrr7G5EWpEzOrV3UYr74bGehgzRNBlJTo=";
  };

  sshx-server = mkSshxPackage rec {
    pname = "sshx-server";
    cargoHash = "sha256-S07xqDiINhOrr7G5EWpEzOrV3UYr74bGehgzRNBlJTo=";

    postPatch = ''
      substituteInPlace crates/sshx-server/src/web.rs \
        --replace-fail 'ServeDir::new("build")' 'ServeDir::new("${passthru.web.outPath}")' \
        --replace-fail 'ServeFile::new("build/spa.html")' 'ServeFile::new("${passthru.web.outPath}/spa.html")'
    '';

    passthru.web = buildNpmPackage {
      pname = "sshx-web";

      inherit
        version
        src
        ;

      postPatch = ''
        substituteInPlace vite.config.ts \
          --replace-fail 'execSync("git rev-parse --short HEAD").toString().trim()' '"${src.rev}"'
      '';

      npmDepsHash = "sha256-2cO0+ComNa4kDgo3SNGd1kPgKCE0/x9L9arAeHY0sQ4=";

      installPhase = ''
        cp -r build $out
      '';
    };
  };
}
