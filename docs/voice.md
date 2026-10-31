# Local voice

Double-Shift opens the sidebar and starts listening. Speak your question, then double-Shift again or click the send arrow to send it. The microphone button also starts voice input. Escape, Cancel, hiding the sidebar, or switching chats cancels it. Existing typed text is preserved and the transcript is appended before sending. Recording ends after two minutes and leaves an editable draft instead of sending a cut-off question.

The input meter shows microphone activity; transcription starts after you finish recording. The first use asks for macOS microphone permission. If denied, use **Open Microphone Settings** in the sidebar, enable D-Shift, and try again. Voice input requires the bundled app from `scripts/bundle.sh`, which supplies the microphone purpose string and signing entitlement. The bare `swift run` executable supports text chat but cannot request microphone access.

Whisper transcribes your recording locally, OpenAI writes the answer, and Qwen3-TTS reads the completed explanation aloud. Audio goes only to the local speech service; the resulting question is sent to OpenAI like typed input. Temporary recordings are deleted after transcription begins or recording is cancelled. Neither audio client sends the OpenAI API key to the local service. Both accept loopback addresses and refuse redirects. There is no cloud speech fallback.

Use **Voice on** below the transcript for automatic narration. The speaker under a reply reads that reply again, even with automatic voice off. **Stop**, a new question, or switching chats cancels speech. Starting the microphone stops playback, and automatic replies do not interrupt an active recording. Code blocks and citation URLs are omitted from narration. The first reply can take longer while the model loads.

## Run the speech service

On Apple Silicon, reuse an installed [MLX Audio](https://github.com/Blaizzy/mlx-audio#web-interface--api-server) environment and cached Qwen3-TTS CustomVoice model. Install the server extra into that environment, then start the standard server on loopback:

```sh
uv pip install --python "$HOME/.local/share/qwen3-tts/.venv/bin/python" 'mlx-audio[server]==0.6.1'
"$HOME/.local/share/qwen3-tts/.venv/bin/python" -m uvicorn mlx_audio.server:app --host 127.0.0.1 --port 8870
```

The models must already be downloaded to use the service offline. Dictation uses the MLX Audio compatible `mlx-community/whisper-large-v3-turbo-asr-fp16` checkpoint, including its tokenizer and preprocessor files. Older MLX Whisper checkpoints without a Hugging Face processor cannot serve this transcription endpoint. Set `HF_HUB_OFFLINE=1` on the server to require cached weights. Running the server as a macOS LaunchAgent keeps it available across app restarts and login; keep it bound to loopback.

The audio settings in [.env.example](../.env.example) select the endpoints, models, and preset voice. Put overrides in `~/.config/dshift/.env` when launching the installed app. Defaults live in [the speech client](../Sources/DShift/Audio/LocalSpeechClient.swift) and [transcription client](../Sources/DShift/Audio/LocalTranscriptionClient.swift).

If the sidebar reports that the local voice service is unavailable, start the server and use the reply’s speaker button to retry. Chat remains usable while the service is stopped.
