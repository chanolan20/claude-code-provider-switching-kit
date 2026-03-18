#!/bin/bash

# claude-switch — Switch Claude Code between providers in one command
# Usage: claude-switch <profile>       Switch to a profile
#        claude-switch add <name>      Create a new profile from template
#        claude-switch list            List available profiles
#        claude-switch current         Show which profile is active

PROFILES="$HOME/.claude/profiles"
SETTINGS="$HOME/.claude/settings.json"

# Ensure profiles directory exists
mkdir -p "$PROFILES"

# No arguments — show help
if [ -z "$1" ]; then
    echo "Usage:"
    echo "  claude-switch <profile>     Switch to a profile"
    echo "  claude-switch add <name>    Create a new profile"
    echo "  claude-switch list          List available profiles"
    echo "  claude-switch current       Show active profile"
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
        if [ -f "$SETTINGS" ]; then
            echo "Current settings.json:"
            cat "$SETTINGS"
        else
            echo "No settings.json found."
        fi
        ;;
    add)
        if [ -z "$2" ]; then
            echo "Usage: claude-switch add <profile-name>"
            exit 1
        fi
        PROFILE_FILE="$PROFILES/$2.json"
        if [ -f "$PROFILE_FILE" ]; then
            echo "Profile '$2' already exists at $PROFILE_FILE"
            exit 1
        fi
        cat > "$PROFILE_FILE" << 'TEMPLATE'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-provider-url",
    "ANTHROPIC_AUTH_TOKEN": "your-api-key",
    "ANTHROPIC_API_KEY": "",
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
        # Dynamic profile switching — any JSON in profiles/ works
        PROFILE_FILE="$PROFILES/$1.json"
        if [ -f "$PROFILE_FILE" ]; then
            cp "$PROFILE_FILE" "$SETTINGS"
            echo "Switched to $1."
        else
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
        ;;
esac
