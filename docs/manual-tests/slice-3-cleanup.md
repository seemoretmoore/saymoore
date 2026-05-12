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

### 6. Punctuation — missing periods
- Dictate (one breath, no pauses): "I think we should ship Friday let me know if that works"
- **Expect**: "I think we should ship Friday. Let me know if that works."
- **Failure to watch for**: model rephrases ("I'm thinking…") rather than just adding the period.

### 7. Capitalization — proper nouns + "I"
- Dictate: "i talked to sarah yesterday about the london trip"
- **Expect**: "I talked to Sarah yesterday about the London trip."
- **Note**: Whisper may already capitalize some of these; the test passes if the final output is correct, regardless of which stage fixed it.

### 8. Question marks
- Dictate (flat intonation): "are you free on Tuesday"
- **Expect**: "Are you free on Tuesday?"

### 9. Prompt-tuning iteration log
Record before/after for at least 10 representative phrases. Update PRD §Slice 3 prompt only if needed.

| Phrase dictated | Raw whisper | Cleaned output | Verdict |
|---|---|---|---|
| (fill in during run) | | | |
