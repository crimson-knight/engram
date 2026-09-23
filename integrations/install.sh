#!/bin/sh
set -eu

usage() {
  printf '%s\n' "Usage: integrations/install.sh --claude|--codex|--both"
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

mode=$1
case "$mode" in
  --claude|--codex|--both) ;;
  *) usage >&2; exit 2 ;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stamp=$(date '+%Y%m%d%H%M%S')-$$
claude_bin=${CLAUDE_CLI:-claude}
codex_bin=${CODEX_CLI:-codex}

backup_file() {
  source_file=$1
  [ -f "$source_file" ] || return 0
  backup_path="$source_file.agent-kit-backup.$stamp"
  [ -e "$backup_path" ] || cp -p "$source_file" "$backup_path"
  printf 'Backed up %s\n' "$source_file"
}

backup_dir() {
  source_dir=$1
  [ -d "$source_dir" ] || return 0
  backup_path="$source_dir.agent-kit-backup.$stamp"
  [ -e "$backup_path" ] || cp -R "$source_dir" "$backup_path"
  printf 'Backed up %s\n' "$source_dir"
}

install_claude() {
  command -v "$claude_bin" >/dev/null 2>&1 || {
    printf 'Claude CLI not found: %s\n' "$claude_bin" >&2
    return 1
  }
  config_home=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  marketplace_list=$("$claude_bin" plugin marketplace list --json 2>/dev/null || true)
  if printf '%s' "$marketplace_list" | grep -Fq "$repo_root"; then
    printf '%s\n' 'Claude marketplace already points to this checkout.'
  elif printf '%s' "$marketplace_list" | grep -Fq 'engram-agent-kit'; then
    printf '%s\n' 'Claude marketplace name engram-agent-kit is already used by another source; leaving it unchanged.' >&2
    return 1
  else
    backup_file "$config_home/settings.json"
    backup_dir "$config_home/plugins"
    "$claude_bin" plugin marketplace add "$repo_root" --scope user
    printf '%s\n' 'Added the engram Claude marketplace.'
  fi

  installed_list=$("$claude_bin" plugin list --json 2>/dev/null || true)
  if printf '%s' "$installed_list" | grep -Fq 'engram@engram-agent-kit'; then
    printf '%s\n' 'Claude plugin is already installed.'
  else
    backup_file "$config_home/settings.json"
    backup_dir "$config_home/plugins"
    "$claude_bin" plugin install engram@engram-agent-kit --scope user --yes
    printf '%s\n' 'Installed the engram Claude plugin.'
  fi
}

install_codex() {
  command -v "$codex_bin" >/dev/null 2>&1 || {
    printf 'Codex CLI not found: %s\n' "$codex_bin" >&2
    return 1
  }
  codex_home=${CODEX_HOME:-$HOME/.codex}
  marketplace_list=$("$codex_bin" plugin marketplace list --json 2>/dev/null || true)
  if printf '%s' "$marketplace_list" | grep -Fq "$repo_root"; then
    printf '%s\n' 'Codex marketplace already points to this checkout.'
  elif printf '%s' "$marketplace_list" | grep -Fq 'engram-agent-kit'; then
    printf '%s\n' 'Codex marketplace name engram-agent-kit is already used by another source; leaving it unchanged.' >&2
    return 1
  else
    backup_file "$codex_home/config.toml"
    backup_dir "$codex_home/plugins"
    "$codex_bin" plugin marketplace add "$repo_root"
    printf '%s\n' 'Added the engram Codex marketplace.'
  fi

  installed_list=$("$codex_bin" plugin list --json 2>/dev/null || true)
  if printf '%s' "$installed_list" | grep -Fq 'engram@engram-agent-kit'; then
    printf '%s\n' 'Codex plugin is already installed.'
  else
    backup_file "$codex_home/config.toml"
    backup_dir "$codex_home/plugins"
    "$codex_bin" plugin add engram --marketplace engram-agent-kit
    printf '%s\n' 'Installed the engram Codex plugin.'
  fi
}

"$repo_root/integrations/build.sh"

case "$mode" in
  --claude) install_claude ;;
  --codex) install_codex ;;
  --both) install_claude; install_codex ;;
esac

printf '\n%s\n' 'The plugin supplies lifecycle hooks and skills. Review the plugin source before accepting its hook commands.'
