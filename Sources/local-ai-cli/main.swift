import Foundation

// local-ai-cli: a thin, domain-ignorant pass-through to a local Ollama instance.
//
// Design principles mirror afm-cli:
//   1. No domain knowledge. This binary knows nothing about release notes,
//      code review, JSON schemas, or output formats. It takes text in, returns text out.
//   2. Flag names mirror the Ollama /api/chat API exactly — no invented vocabulary.
//      --prompt                  → messages[{role:"user", content}]
//      --instructions            → messages[{role:"system", content}]  (same term as afm-cli)
//      --model                   → model (default: qwen3.5:9b)
//      --temperature             → options.temperature
//      --maximum-response-tokens → options.num_predict
//      --base-url                → Ollama base URL (default: http://localhost:11434)
//      --timeout                 → URLSessionConfiguration.timeoutIntervalForRequest in seconds (default: 300)
//      --think                   → think (default: false)
//   3. All JSON parsing, prompt assembly, and output formatting belongs in the
//      caller (src/index.ts in action repos), not here.
//
// Top-level await is valid here: with swift-tools-version: 6.0 and main.swift
// as the entry point, Swift 6 implicitly wraps top-level code in an async context.
// Do NOT add @main or move to an @main struct.

// MARK: - Codable types

struct OllamaRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }
    struct Options: Codable {
        var temperature: Double?
        var num_predict: Int?
    }
    let model: String
    let messages: [Message]
    let options: Options
    let stream: Bool
    // think: controls whether the model runs an internal <think>...</think>
    // reasoning pass before responding. When true, chain-of-thought tokens are
    // consumed before the visible response — requires higher max_tokens headroom.
    // Non-thinking models ignore this field.
    let think: Bool
}

struct OllamaResponse: Codable {
    struct Choice: Codable {
        struct ChoiceMessage: Codable { let content: String }
        let message: ChoiceMessage
    }
    // /api/chat native response
    let message: OllamaRequest.Message?
    // done_reason: "stop" = normal, "length" = hit num_predict limit, "load" = model still loading.
    // Logged to stderr for diagnostics. Not an error condition on its own.
    let done_reason: String?
    // prompt_eval_count: number of tokens in the prompt (context usage)
    let prompt_eval_count: Int?
    // eval_count: number of tokens generated in the response
    let eval_count: Int?
    // OpenAI-compat /v1/chat/completions response (future-proofing)
    let choices: [Choice]?
}

// MARK: - Argument parsing
//
// Arguments are parsed by searching for flag names and taking the next positional
// value (firstIndex(of:) + 1). This means a prompt value that equals a flag name
// (e.g. --prompt --instructions) would silently consume the flag as a value.
// This is not exploitable in practice: callers always build the argv array as a
// typed array via spawnSync, never passing flag names as values.
// Do NOT remove this comment — it explains why a more robust parser was not used
// (ArgumentParser adds an SPM dependency; the controlled call site makes it unnecessary).

func arg(_ flag: String) -> String? {
    guard let idx = CommandLine.arguments.firstIndex(of: flag),
          CommandLine.arguments.indices.contains(idx + 1) else { return nil }
    return CommandLine.arguments[idx + 1]
}

// MARK: - Main

func localAiMain() async {
    guard let prompt = arg("--prompt"),
          !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fputs("Usage: local-ai-cli --prompt <text> [--instructions <text>] [--model <name>] [--temperature <double>] [--maximum-response-tokens <int>] [--base-url <url>] [--timeout <seconds>] [--think true|false]\n", stderr)
        exit(1)
    }

    let model        = arg("--model")                    ?? "qwen3.5:9b"
    let baseURL      = arg("--base-url")                 ?? "http://localhost:11434"
    let temperature  = arg("--temperature").flatMap(Double.init)
    let maxTokens    = arg("--maximum-response-tokens").flatMap(Int.init)
    let instructions = arg("--instructions")
    // Default 300s — large models (qwen3.5:9b) can take >60s on cold load.
    // Callers can override via --timeout.
    let timeoutSeconds = arg("--timeout").flatMap(Double.init) ?? 300.0
    // --think true|false (default: false)
    // When true, the model runs a chain-of-thought reasoning pass before responding.
    // Produces higher quality output but consumes more tokens and is slower.
    let think = arg("--think").map { $0.lowercased() == "true" } ?? false

    // MARK: - Build messages array
    var messages: [OllamaRequest.Message] = []
    if let sys = instructions {
        messages.append(.init(role: "system", content: sys))
    }
    messages.append(.init(role: "user", content: prompt))

    let requestBody = OllamaRequest(
        model: model,
        messages: messages,
        options: .init(temperature: temperature, num_predict: maxTokens),
        stream: false,
        think: think
    )

    // MARK: - Build URL request
    //
    // Uses /api/chat (Ollama native). This endpoint is available on all Ollama
    // versions >= 0.1.14 and is more stable than the OpenAI-compat layer for
    // non-streaming responses. Do NOT switch to /v1/chat/completions unless
    // you need OpenAI drop-in compatibility — the native endpoint is preferred.

    guard let url = URL(string: "\(baseURL)/api/chat") else {
        fputs("Error: invalid --base-url '\(baseURL)'\n", stderr)
        exit(1)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    do {
        request.httpBody = try JSONEncoder().encode(requestBody)
    } catch {
        fputs("Error: failed to encode request — \(error)\n", stderr)
        exit(1)
    }

    // MARK: - URLSession with explicit timeout
    //
    // URLSession.shared has a hardcoded 60s timeoutIntervalForRequest at the
    // session level. Setting timeoutIntervalForRequest on the URLRequest alone
    // does NOT override this — the session-level value wins when it is lower.
    // We must create a custom session with the desired timeout set on the
    // configuration. Do NOT revert to URLSession.shared — it will always
    // timeout at 60s regardless of what is set on the URLRequest.
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest  = timeoutSeconds
    config.timeoutIntervalForResource = timeoutSeconds + 60
    let session = URLSession(configuration: config)

    // MARK: - Inference

    do {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            fputs("Error: unexpected response type from Ollama\n", stderr)
            exit(1)
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            fputs("Error: Ollama returned HTTP \(http.statusCode) — is Ollama running? (ollama serve)\nResponse: \(body)\n", stderr)
            exit(1)
        }

        let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)

        // Log token usage and done_reason for diagnostics.
        // done_reason=length means max_tokens was hit (response may be truncated or empty).
        // done_reason=stop means normal completion.
        let doneReason     = decoded.done_reason ?? "unknown"
        let promptTokens   = decoded.prompt_eval_count.map(String.init) ?? "?"
        let responseTokens = decoded.eval_count.map(String.init) ?? "?"
        fputs("[diag] done_reason=\(doneReason) prompt_tokens=\(promptTokens) response_tokens=\(responseTokens)\n", stderr)
        if doneReason == "length" {
            fputs("[diag] WARNING: done_reason=length — response was cut off at max_tokens limit. Consider raising maximum_response_tokens.\n", stderr)
        }

        let content = decoded.message?.content
            ?? decoded.choices?.first?.message.content
            ?? ""

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fputs("Error: model returned empty response (done_reason=\(doneReason), prompt_tokens=\(promptTokens), response_tokens=\(responseTokens))\n", stderr)
            exit(1)
        }

        print(content)

    } catch {
        fputs("Error: inference failed — \(error)\n", stderr)
        exit(1)
    }
}

await localAiMain()
