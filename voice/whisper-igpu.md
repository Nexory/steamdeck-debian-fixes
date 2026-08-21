# Speech to text on the iGPU: whisper.cpp over Vulkan

The CPU path in [the main write-up](./README.md) works, and on an idle Deck the
faster-whisper turbo German build lands around one to two seconds. That number is
only true when nothing else is running, though, and this box is a 24/7 server.

The Deck also carries Home Assistant, Docker and, in my case, heavy background
compute. Under real CPU load a single room clip climbed to nine to sixteen
seconds through faster-whisper, long enough that the assistant felt broken even
though every part of it was working. The fix is to take speech to text off the
CPU entirely and run it on the Deck's integrated GPU.

## What this buys you, honestly

The Steam Deck LCD has an RDNA2 iGPU (the "VAN GOGH" part), and Mesa's open
`radv` driver exposes it through Vulkan on Debian with no extra setup. whisper.cpp
has a Vulkan backend, so the whole model runs there.

| Deck state | CPU (faster-whisper turbo) | iGPU (whisper.cpp Vulkan) |
|---|---|---|
| idle | about 1-2 s | about 2.5-3 s |
| under CPU load | 9-16 s | about 2.5-3 s |

So this is not "the GPU is faster". On an idle machine the CPU build is a touch
quicker. The point is that the iGPU number does not move: transcription stays at
two to three seconds no matter what the CPU is doing. On a server that is
actually busy, that is the difference between usable and not.

If your Deck only ever runs the voice assistant, stay on the CPU path. If it is a
real server doing other work at the same time, move STT to the iGPU.

## Confirm the iGPU is there

```sh
sudo apt install -y vulkan-tools mesa-vulkan-drivers
vulkaninfo --summary | grep -E 'deviceName|driverName'
#   deviceName = AMD Custom GPU 0405 (RADV VANGOGH)
#   driverName = radv
```

If that prints the RADV VANGOGH line you are done with drivers. The stock
`mesa-vulkan-drivers` package already contains everything the iGPU needs.

## Build whisper.cpp with Vulkan

```sh
sudo apt install -y build-essential cmake git \
     libvulkan-dev glslc spirv-headers spirv-tools

git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
cmake -B build -DGGML_VULKAN=1
cmake --build build -j --config Release
```

**The one trap:** cmake fails with `Could not find SPIRV-Headers` until both
`spirv-headers` **and** `spirv-tools` are installed. They are separate Debian
packages and the error only names the first one. Verified on Debian 13 (trixie)
with `libvulkan-dev` 1.4.309 and `mesa-vulkan-drivers` 25.0.

A successful build leaves `build/bin/whisper-server` and the other tools.

## Model

large-v3-turbo quantized to q5_0 is the sweet spot: full large-v3-turbo accuracy,
about 548 MB, comfortable on the iGPU. The download script fetches the quantized
file directly, no separate quantize step.

```sh
./models/download-ggml-model.sh large-v3-turbo-q5_0
# -> models/ggml-large-v3-turbo-q5_0.bin
```

## Run it as an HTTP service

`whisper-server` serves an HTTP `/inference` endpoint that replaces the in-process
faster-whisper call. Same idea as the CPU service: load the model once and keep
it resident.

```sh
build/bin/whisper-server \
  -m models/ggml-large-v3-turbo-q5_0.bin \
  -l de --host 127.0.0.1 --port 9979 -bs 1 -bo 1
```

The startup log tells you it is on the GPU, not the CPU:

```
whisper_backend_init_gpu: found GPU device 0: Vulkan0
whisper_backend_init_gpu: using Vulkan0 backend
whisper_model_load:      Vulkan0 total size =   573.40 MB
```

Flash attention is on by default in current whisper.cpp and helps here, there is
nothing to enable. Wrap that command in a user systemd service exactly like
`voiced.service` so it survives logout and restarts on its own.

## Point the front-end at it

The recorder still writes a WAV, only the transcription step changes. Instead of
calling faster-whisper in process, post the clip to the server:

```python
import urllib.request

def stt(wav_path, prompt=""):
    boundary = "----whisper"
    with open(wav_path, "rb") as f:
        audio = f.read()
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="a.wav"\r\n'
        "Content-Type: audio/wav\r\n\r\n"
    ).encode() + audio + (
        f"\r\n--{boundary}\r\n"
        'Content-Disposition: form-data; name="response_format"\r\n\r\ntext\r\n'
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="prompt"\r\n\r\n'
    ).encode() + prompt.encode() + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        "http://127.0.0.1:9979/inference", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    return urllib.request.urlopen(req, timeout=60).read().decode().strip()
```

`response_format=text` returns the plain transcript. `prompt` is the same
vocabulary bias as faster-whisper's `initial_prompt`: a short list of the phrases
you actually say cuts down on look-alike misreads. Keep it short.

Gotcha 1 from the main write-up does not apply here. whisper.cpp does not run the
blunt second VAD pass that faster-whisper does, so short clips transcribe normally.
Silero VAD in the recorder is still doing the real gating upstream.

---

Author: Nexory
