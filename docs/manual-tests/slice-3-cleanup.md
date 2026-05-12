# Slice 3 — Default cleanup via Ollama (manual)

## Prereqs

```sh
brew install ollama
ollama serve &           # background, listens on 11434
ollama pull qwen2.5:7b-instruct
```

## Cases

### 1. Happy path
- Dictate: "uh so like I think we should ship Friday um"
- **Expect**: paste = "I think we should ship Friday." (or similar; tune prompt as needed).
- **Verify in console**: `log stream --predicate 'subsystem == "com.seemoretmoore.saymoore"' --info` shows `[cleanup]` lines.

### 2. Fast path
- Dictate: "yes please"
- **Expect**: raw paste, no cleanup call. Log: `fast-path: 2 words ≤ 3, skipping cleanup`.

### 3. Ollama stopped
- `pkill ollama`
- Dictate a normal sentence (≥4 words).
- **Expect**: notification banner "Ollama not reachable", raw transcript pasted.
- Restart Ollama, redictate — cleanup resumes.

### 4. Model not pulled
- `ollama rm qwen2.5:7b-instruct`
- Dictate.
- **Expect**: notification "Cleanup model missing — Run: ollama pull qwen2.5:7b-instruct", raw paste.
- `ollama pull qwen2.5:7b-instruct` → next dictation cleans normally.

### 5. Startup probe
- Quit SayMoore, stop Ollama, launch SayMoore.
- **Expect**: shortly after the model-bootstrap completes, an "Ollama not reachable" notification fires from the health probe — even before any dictation.

### 6. Prompt-tuning iteration log
Record before/after for at least 10 representative phrases. Update PRD §Slice 3 prompt only if needed.

| Phrase dictated | Raw whisper | Cleaned output | Verdict |
|---|---|---|---|
| (fill in during run) | | | |
