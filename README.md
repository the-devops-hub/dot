# dot — The DevOps Toolbox

A single-binary CLI that installs and manages your DevOps tools — helm, kubectl,
terraform, trivy and more — with shell completions and aliases wired up automatically.

## Why does this exist?

Great question. You probably shouldn't use this. You have options:

- **[Homebrew](https://brew.sh)** — works great, as long as you enjoy waiting for Ruby to update
  `libiconv` before you can install `kubectl`
- **[Nix / NixOS](https://nixos.org)** — the correct answer, assuming you have a week to write the
  derivation and a therapist on retainer
- **[webi](https://webinstall.dev)** — genuinely good, but then you'd have nothing to complain about at
  standup
- **[mise](https://mise.jdx.dev) / [asdf](https://asdf-vm.com)** — excellent if your team already agrees on a version manager,
  which they don't
- **manual `curl | tar | mv`** — this is just `dot install` with extra steps

`dot` exists because sometimes you just want to run one command on a fresh VM,
get `kubectl`, `helm`, `terraform` and their completions, and go back to
actually doing your job.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/the-devops-hub/dot/main/install.sh | sh
```

Restart your shell (or `source ~/.zshrc` / `source ~/.config/fish/config.fish`), then:

```sh
dot install helm
dot install --group k8s
dot install --group all     # everything, no regrets
```

## Commands

```sh
dot list                    # all available tools and their status
dot list k8s                # filter by group
dot search prom             # fuzzy search by name or description
dot info terraform          # version, homepage, install details
dot outdated                # which installed tools have newer versions

dot install <tool>          # install a tool
dot install --group <name>  # install a whole group
dot install helm --version 3.14.0   # pin to a specific version

dot upgrade                 # upgrade everything
dot upgrade <tool>          # upgrade one tool
dot uninstall <tool>        # remove a tool

dot pin <tool>              # hold a tool at its current version
dot unpin <tool>            # resume automatic upgrades

dot update                  # update dot itself
dot doctor                  # health check — shell integration, PATH, completions
```

## Groups

| Group        | Examples                                          |
| ------------ | ------------------------------------------------- |
| `k8s`        | kubectl, helm, k9s, argocd, kubeseal, krr         |
| `iac`        | terraform, opentofu, terragrunt, tflint           |
| `cloud`      | aws, gcloud, oci                                  |
| `containers` | podman, podman-compose                            |
| `cm`         | ansible, gh, lazygit                              |
| `security`   | trivy, vault                                      |
| `utils`      | jq, yq, tldr                                      |
| `terminal`   | starship, btop                                    |
| `dev`        | zig, go                                           |
| `all`        | everything above                                  |

## Shell integration

After installing a tool, dot writes completions and aliases to a shell integration
file sourced from your RC. Aliases like `k` (kubectl) and `tf` (terraform) get
completion delegation, so tab-complete works on the alias too.

Supported shells: bash, zsh, fish.

## External repositories

Host your own tools as a JSON file and add them:

```sh
dot repository add https://example.com/my-tools/repository.json
dot repository list
dot repository update
dot repository remove my-tools
```

External tools override builtins with the same ID, so you can pin or replace anything.

## Build from source

Requires [Zig 0.16.x](https://ziglang.org/download/).

```sh
git clone https://github.com/the-devops-hub/dot
cd dot
zig build -Doptimize=ReleaseFast
cp zig-out/bin/dot ~/.local/bin/dot
```

## License

MIT
