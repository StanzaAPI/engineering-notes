{
  description = "Engineering Notes: a public log of what we build, what breaks, and what we get wrong";

  # Pinned to the nixpkgs revision the platform repos use, so the toolchain
  # matches and the source is already in the store.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/ef34387ddd751e1ab8857adf4676492d32eb24ec";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      helpText = ''
        # Engineering Notes

        A public log of what we build, what breaks, and what we get wrong.
        One file per entry under entries/, named YYYY-MM-slug.md.

        ## Run it

            nix run .#help               this text
            nix run .#list               every entry, newest last
            nix run .#show -- <slug>     render one entry
            nix run .#new  -- <slug>     scaffold an entry for this month
            nix run .#lint               check names, sections and vocabulary
            nix flake check              the same lint, as a build
            nix develop                  a shell with glow, jq and nixfmt

        Against the repo with no checkout:

            nix run github:StanzaAPI/engineering-notes#list
            nix run github:StanzaAPI/engineering-notes#show -- <slug>

        ## Adding an entry

        1. nix run .#new -- word-level-lyric-alignment
        2. write it: why, then Method, Results, what we learned, what changed,
           Reproduce it, Open items
        3. nix run .#lint
        4. commit

        Phrasing rules live in STYLE.md: Orwell's rules and the phrases to
        avoid, which the lint partly enforces.
      '';

      # Every command is a writeShellApplication: Nix owns the interpreter and
      # PATH, and shellcheck runs at build time.
      tools =
        pkgs:
        let
          baseInputs = with pkgs; [
            coreutils
            gnugrep
            gnused
          ];
          # Read commands work on a checkout when there is one, and on the flake
          # source otherwise, so `nix run github:...#list` works with no clone.
          defaultRoot = self;
          mkApp =
            name: extra: text:
            pkgs.writeShellApplication {
              inherit name text;
              runtimeInputs = baseInputs ++ extra;
            };
        in
        {
          help = mkApp "help" [ pkgs.glow ] ''
            exec glow -s dark ${pkgs.writeText "engineering-notes-help.md" helpText}
          '';

          list = mkApp "list" [ ] ''
            root=.
            if [ ! -d "$root/entries" ]; then
              root=${defaultRoot}
            fi
            printf '%-46s %-9s %s\n' SLUG DATE TITLE
            printf '%-46s %-9s %s\n' ---- ---- -----
            found=0
            for f in "$root"/entries/*.md; do
              [ -e "$f" ] || continue
              found=1
              slug=$(basename "$f" .md)
              date=$(awk "NR==3" "$f")
              date="''${date//\*/}"
              title=$(head -n 1 "$f")
              title="''${title#\# }"
              printf '%-46s %-9s %s\n' "$slug" "$date" "$title"
            done
            if [ "$found" -eq 0 ]; then
              echo "no entries found" >&2
              exit 1
            fi
          '';

          show = mkApp "show" [ pkgs.glow pkgs.findutils ] ''
            want="''${1:-}"
            if [ -z "$want" ]; then
              echo "usage: nix run .#show -- <slug>" >&2
              exit 2
            fi
            want="''${want%.md}"
            root=.
            if [ ! -d "$root/entries" ]; then
              root=${defaultRoot}
            fi
            file=""
            if [ -f "$root/entries/$want.md" ]; then
              file="$root/entries/$want.md"
            else
              mapfile -t matches < <(find "$root/entries" -maxdepth 1 -name "*-$want.md" -type f | sort)
              if [ "''${#matches[@]}" -eq 1 ]; then
                file="''${matches[0]}"
              elif [ "''${#matches[@]}" -eq 0 ]; then
                echo "no entry matches: $want" >&2
                exit 1
              else
                echo "ambiguous, matches:" >&2
                printf '  %s\n' "''${matches[@]}" >&2
                exit 1
              fi
            fi
            exec glow -s dark "$file"
          '';

          new = mkApp "new" [ ] ''
            slug="''${1:-}"
            if [ -z "$slug" ]; then
              echo "usage: nix run .#new -- <slug>" >&2
              exit 2
            fi
            case "$slug" in
              *[!a-z0-9-]*)
                echo "slug must be lowercase letters, digits and dashes" >&2
                exit 1
                ;;
            esac
            month=$(date +%Y-%m)
            mkdir -p entries
            file="entries/''${month}-''${slug}.md"
            if [ -e "$file" ]; then
              echo "$file already exists" >&2
              exit 1
            fi
            {
              printf '# Title\n\n'
              printf '*%s*\n\n' "$month"
              printf '## Method\n\n'
              printf '## Results\n\n'
              printf '## What we learned\n\n'
              printf '## What changed as a result\n\n'
              printf '## Reproduce it\n\n'
              printf '## Open items\n'
            } > "$file"
            echo "wrote $file"
          '';

          lint = mkApp "lint" [ pkgs.findutils ] ''
            root="''${1:-}"
            if [ -z "$root" ]; then
              root=.
              if [ ! -d "$root/entries" ]; then
                root=${defaultRoot}
              fi
            fi
            mapfile -t files < <(find "$root/entries" -maxdepth 1 -name "*.md" -type f | sort)
            if [ "''${#files[@]}" -eq 0 ]; then
              echo "no entries under $root/entries" >&2
              exit 1
            fi
            status=0
            for f in "''${files[@]}"; do
              base=$(basename "$f")
              case "$base" in
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-*.md) ;;
                *)
                  echo "$base: filename must be YYYY-MM-slug.md" >&2
                  status=1
                  ;;
              esac
              if ! head -n 1 "$f" | grep -q "^# "; then
                echo "$base: missing H1 title" >&2
                status=1
              fi
              if ! sed -n "3p" "$f" | grep -qE "^\*[0-9][0-9][0-9][0-9]-[0-9][0-9]\*$"; then
                echo "$base: line 3 must be *YYYY-MM*" >&2
                status=1
              fi
              for section in Method Results "What we learned" "What changed as a result" "Reproduce it"; do
                if ! grep -qF "## $section" "$f"; then
                  echo "$base: missing section: ## $section" >&2
                  status=1
                fi
              done
              if grep -niE "delve|leverage|robust|seamless|showcase|showcasing|tapestry|myriad|pivotal|crucial|vital|testament|thrilled|passionate|meticulous|underscor|boasts|nestled|vibrant|profound|groundbreaking|renowned|stands as|serves as|in the heart of|it is worth noting|at the end of the day" "$f" >&2; then
                echo "$base: banned vocabulary above" >&2
                status=1
              fi
              while IFS= read -r line; do
                echo "$base: phrasing: $line" >&2
              done < <(grep -niE "in order to|the fact that|not only|not just" "$f" || true)
              dashes=$(tr -cd "—" < "$f" | wc -c)
              if [ "$dashes" -gt 2 ]; then
                echo "$base: $dashes em dashes; house limit is 2" >&2
              fi
            done
            if [ "$status" -ne 0 ]; then
              echo "lint failed" >&2
              exit 1
            fi
            echo "ok: ''${#files[@]} entries"
          '';
        };
    in
    {
      packages = forAllSystems (pkgs: tools pkgs);

      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (_: drv: {
          type = "app";
          program = lib.getExe drv;
        }) (tools pkgs)
      );

      checks = forAllSystems (pkgs: {
        lint =
          pkgs.runCommand "engineering-notes-lint"
            {
              nativeBuildInputs = [ pkgs.findutils ];
            }
            ''
              cp -r ${self}/entries .
              ${lib.getExe (tools pkgs).lint}
              touch $out
            '';
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            glow
            git
            jq
            nixfmt
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
