"""
Persistent VibeVoice ASR server for SuperVibe.

Protocol: one JSON object per line on stdin (requests) and stdout (events).

Requests
    {"op": "start",  "id": 1, "rate": 24000, "context": "term1, term2"}
    {"op": "audio",  "id": 1, "pcm": "<base64 int16le mono>"}
    {"op": "stop",   "id": 1}      finish: transcribe whatever is still buffered
    {"op": "cancel", "id": 1}      discard the session

Events
    {"event": "ready", "model": ..., "streaming": bool, "sample_rate": int, ...}
    {"event": "delta", "id": 1, "text": "..."}        streaming checkpoints only
    {"event": "done",  "id": 1, "text": "...", "audio_sec": f, "compute_sec": f}
    {"event": "error", "id": 1 | null, "error": "..."}

Threading: a reader thread drains stdin into a queue (so the parent never
blocks on a full pipe, including while the model is still loading); all MLX
work stays on the main thread. Between two inference steps the main thread
drains the queue, so a cancel takes effect after at most one step.

The server exits when stdin reaches EOF, so it cannot outlive the app.
"""
import base64
import json
import os
import queue
import re
import sys
import threading
import time

# The protocol owns the real stdout. Anything a library prints goes to stderr.
_proto = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8")
sys.stdout = sys.stderr

_EOF = object()


def emit(obj):
    _proto.write(json.dumps(obj, ensure_ascii=False) + "\n")
    _proto.flush()


def logerr(msg):
    sys.stderr.write(f"[vibevoice] {msg}\n")
    sys.stderr.flush()


def reader(q):
    import numpy as np

    for raw in sys.stdin.buffer:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            logerr("dropping malformed request line")
            continue
        if msg.get("op") == "audio":
            pcm = np.frombuffer(base64.b64decode(msg.pop("pcm", "")), dtype="<i2")
            msg["samples"] = pcm.astype(np.float32) / 32768.0
        q.put(msg)
    q.put(_EOF)


# Streaming checkpoints prefix a speaker label ("\n Speaker 0:") whenever the
# speaker starts or changes. Dictation only needs the spoken content.
_SPEAKER_RE = re.compile(r"\s*Speaker \d+:[ \t]?")
# Non-speech audio is reported as a bracketed tag such as "[Silence]".
_EVENT_TAG_RE = re.compile(r"\[[A-Z][A-Za-z ]{2,24}\]")


def chunk_content(text):
    """Strip speaker labels and non-speech tags from one streaming chunk."""
    return _EVENT_TAG_RE.sub("", _SPEAKER_RE.sub("", text))


class StreamingSession:
    """Live session on a VibeVoice-ASR-Streaming checkpoint."""

    def __init__(self, model, sid, rate, context):
        import numpy as np

        self.np = np
        self.model = model
        self.id = sid
        self.window = model.streaming_window_samples
        self.hop = model.streaming_chunk_samples
        self.buf = np.zeros(0, dtype=np.float32)
        self.finishing = False
        self.parts = []
        self.audio_samples = 0
        self.compute_sec = 0.0
        self.resampler = None
        if rate != model.sample_rate:
            import soxr

            self.resampler = soxr.ResampleStream(
                rate, model.sample_rate, 1, dtype="float32"
            )
        t0 = time.time()
        self.state = model.init_streaming_state(context_info=context or None)
        self.compute_sec += time.time() - t0

    def feed(self, samples):
        if self.resampler is not None:
            samples = self.resampler.resample_chunk(samples, last=False)
        self.audio_samples += len(samples)
        self.buf = self.np.concatenate([self.buf, samples])

    def finish(self):
        if self.resampler is not None:
            tail = self.resampler.resample_chunk(
                self.np.zeros(0, dtype=self.np.float32), last=True
            )
            self.audio_samples += len(tail)
            self.buf = self.np.concatenate([self.buf, tail])
        self.finishing = True

    def can_step(self):
        if len(self.buf) >= self.window:
            return True
        return self.finishing and len(self.buf) > 0

    def is_done(self):
        return self.finishing and len(self.buf) == 0

    def step(self):
        """Run one audio window. Returns the text delta ('' if none)."""
        import mlx.core as mx

        np = self.np
        window = self.buf[: self.window]
        if len(window) < self.window:
            window = np.pad(window, (0, self.window - len(window)))
        self.buf = self.buf[self.hop :]

        t0 = time.time()
        features = self.model.encode_speech(mx.array(window)[None, :])
        raw, self.state = self.model.streaming_generate_step(features, self.state)
        mx.clear_cache()
        self.compute_sec += time.time() - t0

        if os.environ.get("SUPERVIBE_ASR_DEBUG") == "1":
            logerr(f"chunk raw: {raw!r}")
        text = chunk_content(raw)
        if not self.parts:
            text = text.lstrip()
        if text:
            self.parts.append(text)
        return text

    def result(self):
        return "".join(self.parts).strip()

    def audio_sec(self):
        return self.audio_samples / self.model.sample_rate


class BatchSession:
    """Session on a long-form (non-streaming) checkpoint: transcribe on stop."""

    def __init__(self, model, sid, rate, context):
        import numpy as np

        self.np = np
        self.model = model
        self.id = sid
        self.rate = rate
        self.context = context or None
        self.chunks = []
        self.finishing = False
        self.transcribed = False
        self.text = ""
        self.compute_sec = 0.0

    def feed(self, samples):
        self.chunks.append(samples)

    def finish(self):
        self.finishing = True

    def can_step(self):
        return self.finishing and not self.transcribed

    def is_done(self):
        return self.finishing and self.transcribed

    def step(self):
        self.transcribed = True
        if not self.chunks:
            return ""
        audio = self.np.concatenate(self.chunks)
        t0 = time.time()
        result = self.model.generate(
            audio,
            sampling_rate=self.rate,
            context=self.context,
            max_tokens=8192,
            prefill_step_size=4096,
        )
        self.compute_sec += time.time() - t0
        segments = getattr(result, "segments", None) or []
        if segments:
            self.text = "".join(seg.get("text", "") for seg in segments).strip()
        else:
            self.text = (getattr(result, "text", "") or "").strip()
        return ""

    def result(self):
        return self.text

    def audio_sec(self):
        return sum(len(c) for c in self.chunks) / float(self.rate)


def main():
    model_name = (
        sys.argv[1] if len(sys.argv) > 1 else "microsoft/VibeVoice-ASR-Streaming-1.5B"
    )

    q = queue.Queue()
    threading.Thread(target=reader, args=(q,), daemon=True).start()

    logerr(f"loading model {model_name}...")
    t0 = time.time()
    try:
        import mlx.core as mx
        from mlx_audio.stt import load

        model = load(model_name)
    except Exception as e:  # noqa: BLE001 - reported to the parent verbatim
        emit({"event": "error", "id": None, "error": f"model load failed: {e}"})
        return 1

    streaming = bool(getattr(model, "is_streaming_model", False))
    if streaming:
        # The first inference after load pays one-time graph/kernel setup
        # (seconds). Pay it here on a silent window, not on the user's audio.
        try:
            import numpy as np

            state = model.init_streaming_state()
            silence = mx.array(np.zeros(model.streaming_window_samples, np.float32))
            model.streaming_generate_step(
                model.encode_speech(silence[None, :]), state, max_new_tokens=8
            )
            del state
            mx.clear_cache()
        except Exception as e:  # noqa: BLE001 - warmup is best effort
            logerr(f"warmup failed: {e}")
    emit(
        {
            "event": "ready",
            "model": model_name,
            "streaming": streaming,
            "sample_rate": model.sample_rate,
            "load_sec": round(time.time() - t0, 2),
            "active_memory_gb": round(mx.get_active_memory() / 1e9, 2),
        }
    )
    logerr(f"model loaded in {time.time() - t0:.1f}s (streaming={streaming})")

    session = None
    while True:
        # Drain every pending request before spending time on inference.
        while True:
            try:
                # Only block on the queue when there is nothing to compute
                # and no finished session waiting for its `done` event.
                if session is not None and (session.can_step() or session.is_done()):
                    msg = q.get_nowait()
                else:
                    msg = q.get()
            except queue.Empty:
                break
            if msg is _EOF:
                return 0

            op, sid = msg.get("op"), msg.get("id")
            try:
                if op == "start":
                    cls = StreamingSession if streaming else BatchSession
                    session = cls(
                        model, sid, int(msg.get("rate", 24000)), msg.get("context")
                    )
                elif session is None or sid != session.id:
                    continue  # stale request for a session that is gone
                elif op == "audio":
                    session.feed(msg["samples"])
                elif op == "stop":
                    session.finish()
                elif op == "cancel":
                    session = None
                    mx.clear_cache()
            except Exception as e:  # noqa: BLE001
                emit({"event": "error", "id": sid, "error": str(e)})
                session = None

        if session is None:
            continue

        try:
            if session.can_step():
                delta = session.step()
                if delta:
                    emit({"event": "delta", "id": session.id, "text": delta})
            if session.is_done():
                emit(
                    {
                        "event": "done",
                        "id": session.id,
                        "text": session.result(),
                        "audio_sec": round(session.audio_sec(), 2),
                        "compute_sec": round(session.compute_sec, 2),
                        "peak_memory_gb": round(mx.get_peak_memory() / 1e9, 2),
                    }
                )
                session = None
                mx.clear_cache()
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "id": session.id, "error": str(e)})
            session = None


if __name__ == "__main__":
    sys.exit(main() or 0)
