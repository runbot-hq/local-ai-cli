# local-ai-cli

A thin, domain-ignorant Swift CLI pass-through to a local [Ollama](https://ollama.com) instance.

This is the Ollama-backed equivalent of [`afm-cli`](https://github.com/runbot-hq/afm-cli) — same design principles, same flag conventions, but powered by any model Ollama supports (Qwen, CodeGeeX, Llama, etc.) instead of Apple's on-device FoundationModels framework.

> Used as a sidecar binary by [`local-ai-code-review-action`](https://github.com/runbot-hq/local-ai-code-review-action) and other action repos in the runbot-hq org.

## Requirements

- macOS 13+ (Apple Silicon recommended — M1/M2/M3/M4)
- [Ollama](https://ollama.com) installed and running (`ollama serve`)
- Swift 6 toolchain (for building from source)

## Installation

### Use the pre-built binary (recommended)

```sh
curl -L https://github.com/runbot-hq/local-ai-cli/releases/latest/download/local-ai-cli-bin \
  -o local-ai-cli-bin && chmod +x local-ai-cli-bin
```

### Build from source

```sh
git clone https://github.com/runbot-hq/local-ai-cli
cd local-ai-cli
swift build -c release
# binary at .build/release/local-ai-cli
```

## Usage

```sh
./local-ai-cli-bin --prompt "Explain async/await in Swift"
```

```sh
./local-ai-cli-bin \
  --prompt "Review this function for bugs" \
  --instructions "You are a senior Swift engineer. Be concise." \
  --model qwen3.5:9b \
  --temperature 0.2 \
  --maximum-response-tokens 2048
```

## Flags

| Flag | Default | Description |
|---|---|---|
| `--prompt` | *(required)* | The user message sent to the model |
| `--instructions` | *(none)* | System prompt (maps to Ollama `system` role message) |
| `--model` | `qwen3.5:9b` | Any model pulled via `ollama pull` |
| `--temperature` | *(Ollama default)* | Sampling temperature (0.0–1.0) |
| `--maximum-response-tokens` | *(Ollama default)* | Max tokens to generate (`num_predict`) |
| `--base-url` | `http://localhost:11434` | Ollama base URL |

## Recommended models for Apple Silicon (16GB RAM)

| Model | Pull command | Best for |
|---|---|---|
| `qwen3.5:9b` | `ollama pull qwen3.5:9b` | General coding + chat |
| `codegeex4:9b` | `ollama pull codegeex4:9b` | Dedicated code review (89K context) |
| `qwen3.5:4b` | `ollama pull qwen3.5:4b` | Fastest, lowest RAM usage |

## Design principles

1. **No domain knowledge.** This binary knows nothing about release notes, code review, or output formats. It takes text in, returns text out.
2. **Flag names mirror the Ollama API.** No invented vocabulary.
3. **All prompt assembly belongs in the caller** — action `src/index.ts` files, not here.

## Related

- [`afm-cli`](https://github.com/runbot-hq/afm-cli) — Apple FoundationModels equivalent
- [`local-ai-code-review-action`](https://github.com/runbot-hq/local-ai-code-review-action) — GitHub Action that uses this binary
- [RunBot](https://github.com/runbot-hq/run-bot) — macOS menu bar app for GitHub Actions
