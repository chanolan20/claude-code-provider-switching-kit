# Claude Code Provider Switching Kit

Switch Claude Code between **Anthropic**, **GLM**, and **OpenRouter** (including free models) with one command.

No code changes. No config juggling. Just `claude-switch glm` and you're running on a different provider.

## What's included

```
profiles/
  anthropic.json     # Default Anthropic API (best quality)
  glm.json           # GLM via z.ai (budget-friendly)
  openrouter.json    # OpenRouter (free models included)
claude-switch.sh     # The switching script
```

## Quick Setup (2 minutes)

### 1. Create the profiles folder

```bash
mkdir -p ~/.claude/profiles
```

### 2. Copy everything into place

```bash
cp profiles/*.json ~/.claude/profiles/
cp claude-switch.sh ~/.claude/profiles/claude-switch.sh
chmod +x ~/.claude/profiles/claude-switch.sh
```

### 3. Add your API keys

Edit each profile file in `~/.claude/profiles/` and replace the placeholder keys:

- **Anthropic** - get your key at [console.anthropic.com](https://console.anthropic.com)
- **GLM** - get your key at [z.ai](https://z.ai)
- **OpenRouter** - get your key at [openrouter.ai](https://openrouter.ai)

### 4. Add the alias

Add this to your `~/.zshrc` (or `~/.bashrc`):

```bash
alias claude-switch="~/.claude/profiles/claude-switch.sh"
```

Then reload:

```bash
source ~/.zshrc
```

### 5. Switch providers

```bash
claude-switch anthropic    # Best quality, full cost
claude-switch glm          # Solid quality, minimal cost
claude-switch openrouter   # Free models, great for learning
```

## Provider Comparison

| Provider | Cost | Quality | Extended Thinking | Best For |
|----------|------|---------|-------------------|----------|
| Anthropic | ~$200/mo heavy use | Best | Yes | Production work, complex tasks |
| GLM | ~$5-15/mo | Good (close to Sonnet) | No | Daily work, drafting, research |
| OpenRouter | Free tier available | Variable | No | Learning, testing, simple tasks |

## What stays the same across providers

- All file operations (read, edit, create, search)
- Terminal access
- MCP server connections
- Permission system
- Your workspace, skills, and context files
- The agentic loop

## What changes when you switch

- Reasoning quality (Opus > Sonnet > GLM > free models)
- Speed and latency
- Cost
- Extended thinking (Anthropic-only feature)
- Complex multi-step tool chains may be less reliable on non-Claude models

## Adding your own providers

```bash
claude-switch add deepseek
```

This creates a template at `~/.claude/profiles/deepseek.json`. Edit the URL, API key, and model names, then `claude-switch deepseek` works.

Any JSON file in `~/.claude/profiles/` becomes a valid provider. No code changes needed.

## Other commands

```bash
claude-switch list       # Show all available profiles
claude-switch current    # Show what's currently active
```

## OpenRouter: Free models that work with Claude Code

Claude Code requires models with **tool calling** support. These free models work:

| Model ID | Notes |
|----------|-------|
| `qwen/qwen3-coder:free` | Best free coding model. 262K context. |
| `meta-llama/llama-3.3-70b-instruct:free` | Solid 70B for simple tasks. |
| `openai/gpt-oss-120b:free` | 117B MoE, native tool use. |
| `z-ai/glm-4.5-air:free` | Same GLM family as the GLM profile. |
| `mistralai/mistral-small-3.1-24b-instruct:free` | Lightweight, tool calling supported. |
| `google/gemma-3-27b-it:free` | 27B, tool calling supported. |

### Cheap paid alternatives (10-100x cheaper than Claude)

| Model ID | Input $/M tokens | Output $/M tokens |
|----------|-------------------|---------------------|
| `deepseek/deepseek-chat-v3.1` | $0.15 | $0.75 |
| `deepseek/deepseek-v3.2` | $0.25 | $0.40 |
| `qwen/qwen3-coder` (paid) | $0.22 | $1.00 |
| `google/gemini-2.5-flash` | ~$0.15 | ~$0.60 |

To swap models, edit `~/.claude/profiles/openrouter.json`:

```json
"ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek/deepseek-v3.2"
```

Then run `claude-switch openrouter` to apply.

### Free model rate limits

Free models on OpenRouter have limits of ~20 requests/minute, ~200 requests/day. Fine for learning, tight for heavy coding sessions. Paid models have no limits.

---

Made by [Riccardo Vandra](https://youtube.com/@riccardovandra) - AI Orchestration for business.
