#!/bin/bash

# claude-switch — Switch Claude Code between providers in one command
# Usage: claude-switch <profile>       Switch to a profile (merges env, backs up first)
#        claude-switch run <profile> [args...]  Launch claude with a profile for one session only
#        claude-switch add <name>      Create a new profile from template
#        claude-switch list            List available profiles
#        claude-switch current         Show which profile is active
#        claude-switch doctor          Verify setup and detect conflicting config
#        claude-switch backups         List saved settings backups
#        claude-switch completions <sh>  Print a bash or zsh completion script
#
# Everything this tool manages lives under ~/.claude:
#   ~/.claude/profiles/                  provider profiles (JSON)
#   ~/.claude/settings.json              Claude Code settings (env is merged, never clobbered)
#   ~/.claude/backups/claude-switch/     timestamped settings backups (last 10 kept)
#
# Claude Code reads settings.json at startup, so a switch takes effect on the
# next `claude` session — no restart of anything else.

PROFILES="$HOME/.claude/profiles"
SETTINGS="$HOME/.claude/settings.json"
BACKUPS="$HOME/.claude/backups/claude-switch"
MAX_BACKUPS=10

# Profile names: start with a letter/digit, then letters/digits/-/_
# (blocks path traversal like ../foo, plus names with dots, spaces, or slashes)
PROFILE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]*$'

mkdir -p "$PROFILES"

# --- helpers ---------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

die() { echo "Error: $*" >&2; exit 1; }

# Exit 0 = valid JSON, 1 = invalid, 2 = no validator installed
validate_json() {
    local file="$1"
    [ -f "$file" ] || return 0
    if have jq; then
        jq empty "$file" >/dev/null 2>&1
    elif have python3; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" >/dev/null 2>&1
    else
        return 2
    fi
}

# Snapshot the current settings.json before every switch (keeps newest MAX_BACKUPS).
backup_settings() {
    [ -s "$SETTINGS" ] || return 0
    mkdir -p "$BACKUPS"
    local target="$BACKUPS/settings.$(date +%Y%m%d-%H%M%S).json"
    cp "$SETTINGS" "$target" || die "Could not write backup to $BACKUPS"
    echo "Backed up previous settings -> $target"
    ls -t "$BACKUPS"/settings.*.json 2>/dev/null |
        tail -n +$((MAX_BACKUPS + 1)) |
        while IFS= read -r old; do rm -f "$old"; done
}

# Merge a profile's env into settings.json without touching anything else.
# Provider-owned keys (all ANTHROPIC_*, plus API_TIMEOUT_MS) are replaced;
# user settings like permissions, hooks, and model are preserved, and stale
# keys from the previous provider are removed so tokens never mix.
merge_env() {
    local profile_file="$1"
    if have python3; then
        python3 - "$SETTINGS" "$profile_file" <<'PYEOF'
import json, os, sys, tempfile

settings_path, profile_path = sys.argv[1], sys.argv[2]

def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

settings = load(settings_path) if (os.path.exists(settings_path) and os.path.getsize(settings_path) > 0) else {}
profile = load(profile_path)

env = {k: v for k, v in (settings.get("env") or {}).items()
       if not k.startswith("ANTHROPIC_") and k != "API_TIMEOUT_MS"}
env.update(profile.get("env") or {})
settings["env"] = env

directory = os.path.dirname(settings_path) or "."
fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".claude-settings-", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, settings_path)  # atomic swap
except BaseException:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
    raise
PYEOF
    elif have jq; then
        local tmp="$SETTINGS.tmp.$$"
        jq --slurpfile prof "$profile_file" '
            .env = (((.env // {}) | with_entries(
                        select((((.key | startswith("ANTHROPIC_")) | not)
                                and (.key != "API_TIMEOUT_MS"))))
                    ) + ($prof[0].env // {}))
        ' "$SETTINGS" > "$tmp" || { rm -f "$tmp"; die "jq merge failed."; }
        mv "$tmp" "$SETTINGS"
    else
        die "Cannot merge safely: install python3 or jq, then retry."
    fi
}

# Diff the provider-owned env keys in settings.json against every profile.
show_current() {
    if [ ! -s "$SETTINGS" ]; then
        echo "No settings.json found — nothing active yet. Run: claude-switch <profile>"
        return 1
    fi
    if ! have python3; then
        echo "Install python3 for active-profile detection. Current settings.json:"
        cat "$SETTINGS"
        return 0
    fi
    python3 - "$SETTINGS" "$PROFILES" <<'PYEOF'
import json, os, sys

settings_path, profiles_dir = sys.argv[1], sys.argv[2]

def owned(env):
    return {k: v for k, v in (env or {}).items()
            if k.startswith("ANTHROPIC_") or k == "API_TIMEOUT_MS"}

def mask(key, value):
    if "TOKEN" in key or "KEY" in key:
        s = str(value)
        return (s[:6] + "...") if s else "(empty)"
    return value

try:
    with open(settings_path, encoding="utf-8") as f:
        senv = owned(json.load(f).get("env"))
except Exception as exc:
    print(f"settings.json is unreadable or invalid JSON: {exc}")
    sys.exit(1)

match = None
try:
    names = sorted(n for n in os.listdir(profiles_dir) if n.endswith(".json"))
except OSError:
    names = []
for name in names:
    try:
        with open(os.path.join(profiles_dir, name), encoding="utf-8") as f:
            penv = owned(json.load(f).get("env"))
    except Exception:
        continue
    if penv and penv == senv:
        match = name[:-5]
        break

print("Active profile: " + (match if match else "none (custom settings)"))
print("Provider keys in settings.json:")
if senv:
    for k in sorted(senv):
        print(f"  {k} = {mask(k, senv[k])}")
else:
    print("  (none)")
PYEOF
}

# Verify the setup: layout, settings health, and config elsewhere that could
# override the profile (shell rc exports, project-level .claude settings).
show_doctor() {
    echo "claude-switch doctor"
    echo ""
    echo "Everything lives under ~/.claude:"
    echo "  profiles: $PROFILES"
    echo "  settings: $SETTINGS"
    echo "  backups:  $BACKUPS"
    echo ""

    local count=0 f rc hit
    for f in "$PROFILES"/*.json; do
        [ -f "$f" ] || continue
        [ "$count" -eq 0 ] && echo "Profiles:"
        echo "  - $(basename "$f" .json)"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && echo "Profiles: none found (create one with: claude-switch add <name>)"
    echo ""

    if [ -s "$SETTINGS" ]; then
        if validate_json "$SETTINGS"; then
            echo "settings.json: valid JSON"
        else
            echo "settings.json: INVALID JSON — Claude Code may fail to start."
            echo "  Restore with: cp $BACKUPS/settings.<timestamp>.json $SETTINGS"
        fi
    else
        echo "settings.json: not found (run e.g. claude-switch anthropic to create it)"
    fi
    echo ""
    show_current || true
    echo ""

    echo "Shell rc exports that could override profiles:"
    echo "  (top-level only — indented, function-scoped assignments are ignored)"
    local conflicts=0
    for rc in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [ -f "$rc" ] || continue
        while IFS= read -r hit; do
            echo "  $rc:$hit"
            conflicts=$((conflicts + 1))
        done < <(grep -nE '^(export[[:space:]]+)?(ANTHROPIC_|CLAUDE_CODE_)[A-Z_]+=' "$rc" 2>/dev/null)
    done
    [ "$conflicts" -eq 0 ] && echo "  none found — profile switching takes full effect"

    echo ""
    echo "Project-level Claude settings in $(pwd) that could override the user profile:"
    local project_hits=0
    for f in ./.claude/settings.json ./.claude/settings.local.json; do
        [ -f "$f" ] || continue
        while IFS= read -r hit; do
            echo "  $f:$hit"
            project_hits=$((project_hits + 1))
        done < <(grep -nE '"(ANTHROPIC_[A-Z_]*|API_TIMEOUT_MS)"' "$f" 2>/dev/null)
    done
    [ "$project_hits" -eq 0 ] && echo "  none found"

    echo ""
    if [ -f "$HOME/.claude.json" ]; then
        echo "~/.claude.json (Claude Code state file): present"
    else
        echo "~/.claude.json (Claude Code state file): not found"
    fi
}

# No arguments — show help
if [ -z "$1" ]; then
    echo "Usage:"
    echo "  claude-switch <profile>     Switch to a profile (merges env, backs up first)"
    echo "  claude-switch run <profile> [args...]"
    echo "                              Launch claude with a profile for one session only"
    echo "                              (settings.json is never touched)"
    echo "  claude-switch add <name>    Create a new profile"
    echo "  claude-switch list          List available profiles"
    echo "  claude-switch current       Show active profile"
    echo "  claude-switch doctor        Verify setup and detect conflicts"
    echo "  claude-switch backups       List saved settings backups"
    echo "  claude-switch completions <bash|zsh>"
    echo "                              Print a shell completion script"
    echo ""
    echo "Available profiles:"
    for f in "$PROFILES"/*.json; do
        [ -f "$f" ] && echo "  $(basename "$f" .json)"
    done
    exit 0
fi

case $1 in
    list)
        echo "Available profiles:"
        for f in "$PROFILES"/*.json; do
            [ -f "$f" ] && echo "  $(basename "$f" .json)"
        done
        ;;
    current)
        show_current
        ;;
    doctor)
        show_doctor
        ;;
    backups)
        if ls "$BACKUPS"/settings.*.json >/dev/null 2>&1; then
            echo "Saved backups (newest first; keeping last $MAX_BACKUPS):"
            ls -t "$BACKUPS"/settings.*.json
        else
            echo "No backups yet."
        fi
        ;;
    run)
        shift
        [ -n "${1:-}" ] || die "Usage: claude-switch run <profile> [claude args...]"
        prof="$1"
        shift
        if ! [[ "$prof" =~ $PROFILE_NAME_RE ]]; then
            die "Invalid profile name '$prof'. Use letters, digits, '-' or '_' only (no '/', '.', or spaces)."
        fi
        pf="$PROFILES/$prof.json"
        [ -f "$pf" ] || die "Profile '$prof' not found in $PROFILES"
        validate_json "$pf" ||
            die "Profile '$prof' is not valid JSON — fix $pf first."
        have claude || die "claude not found on PATH — install Claude Code first."
        have python3 || have jq ||
            die "claude-switch needs python3 or jq to read the profile safely."

        # Drop provider keys inherited from the shell so tokens never mix,
        # then apply the profile's env to this process only.
        # settings.json is never read or written.
        while IFS= read -r k; do
            case "$k" in ANTHROPIC_*|API_TIMEOUT_MS) unset "$k" ;; esac
        done < <(env | sed 's/=.*$//')
        prof_kv=()
        if have python3; then
            while IFS= read -r -d '' kv; do prof_kv+=("$kv"); done < <(
                python3 - "$pf" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    env = json.load(f).get("env") or {}
for k, v in env.items():
    sys.stdout.write(f"{k}={v}\0")
PYEOF
            )
        else
            while IFS= read -r -d '' kv; do prof_kv+=("$kv"); done < <(
                jq -j '.env // {} | to_entries[] | "\(.key)=\(.value)\u0000"' "$pf"
            )
        fi
        [ ${#prof_kv[@]} -gt 0 ] && export "${prof_kv[@]}"
        echo "Launching claude with profile '$prof' (this session only — settings.json untouched)." >&2
        exec claude "$@"
        ;;
    completions)
        case "${2:-}" in
            bash)
                cat << 'BASHCOMP'
# bash completion for claude-switch
_claude_switch() {
    local cur f
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    local profiles=""
    for f in "$HOME"/.claude/profiles/*.json; do
        [ -f "$f" ] && profiles="$profiles $(basename "$f" .json)"
    done
    local commands="list current doctor backups add run completions"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands$profiles" -- "$cur") )
    elif [ "$COMP_CWORD" -eq 2 ] && [ "${COMP_WORDS[1]}" = run ]; then
        COMPREPLY=( $(compgen -W "$profiles" -- "$cur") )
    fi
    return 0
}
complete -F _claude_switch claude-switch
BASHCOMP
                ;;
            zsh)
                cat << 'ZSHCOMP'
#compdef claude-switch
_claude_switch() {
    local -a profiles actions
    local f
    for f in "$HOME"/.claude/profiles/*.json(N); do
        profiles+=("${f:t:r}")
    done
    actions=(
        'list:List available profiles'
        'current:Show the active profile'
        'doctor:Verify setup and detect conflicts'
        'backups:List saved settings backups'
        'add:Create a new profile'
        'run:Launch claude with a profile for one session'
        'completions:Print a shell completion script'
    )
    if (( CURRENT == 2 )); then
        _describe -t actions 'action' actions
        _describe -t profiles 'profile' profiles
    elif (( CURRENT == 3 )); then
        case "$words[2]" in
            run) _describe -t profiles 'profile' profiles ;;
            completions) _values 'shell' bash zsh ;;
            add) _message 'new profile name' ;;
        esac
    fi
}
compdef _claude_switch claude-switch
ZSHCOMP
                ;;
            *)
                echo "Usage: claude-switch completions <bash|zsh>" >&2
                exit 1
                ;;
        esac
        ;;
    add)
        [ -n "$2" ] || die "Usage: claude-switch add <profile-name>"
        if ! [[ "$2" =~ $PROFILE_NAME_RE ]]; then
            die "Invalid profile name '$2'. Use letters, digits, '-' or '_' only (no '/', '.', or spaces)."
        fi
        PROFILE_FILE="$PROFILES/$2.json"
        if [ -f "$PROFILE_FILE" ]; then
            die "Profile '$2' already exists at $PROFILE_FILE"
        fi
        cat > "$PROFILE_FILE" << 'TEMPLATE'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-provider-url",
    "ANTHROPIC_AUTH_TOKEN": "your-api-key",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "model-name",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "model-name",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "model-name",
    "API_TIMEOUT_MS": "300000"
  }
}
TEMPLATE
        echo "Created profile '$2' at $PROFILE_FILE"
        echo "Edit the file to add your provider URL, API key, and model names."
        ;;
    *)
        PROFILE_FILE="$PROFILES/$1.json"
        if [ ! -f "$PROFILE_FILE" ]; then
            echo "Profile '$1' not found."
            echo ""
            echo "Available profiles:"
            for f in "$PROFILES"/*.json; do
                [ -f "$f" ] && echo "  $(basename "$f" .json)"
            done
            echo ""
            echo "Create one with: claude-switch add $1"
            exit 1
        fi

        if ! have python3 && ! have jq; then
            die "claude-switch needs python3 or jq to merge JSON safely. Install one and retry."
        fi

        validate_json "$PROFILE_FILE" ||
            die "Profile '$1' is not valid JSON — fix $PROFILE_FILE before switching."

        if [ -s "$SETTINGS" ]; then
            validate_json "$SETTINGS" ||
                die "Existing $SETTINGS is not valid JSON — refusing to merge on top of it. Fix the file or restore a backup from $BACKUPS first."
        fi

        backup_settings
        [ -s "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
        merge_env "$PROFILE_FILE" || die "Merge failed; settings.json was not modified."

        echo "Switched to $1 — env merged, all other settings preserved."
        echo "Claude Code reads settings.json at startup, so the next 'claude' session uses it."
        ;;
esac
