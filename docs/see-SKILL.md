---
name: see
description: "Convert screenshots and screen regions into TEXT so a text-only model can actually inspect them. Use whenever a task involves looking at a UI, a rendered page, a canvas, a game floor, a diagram, or any image the user sends. Also use before claiming any visual work is done."
---

# See — vision bridge for text-only models

## The problem this exists to solve

Most models on this host **cannot read images**. When a screenshot tool hands one of
them a PNG, the tool returns:

```
ERROR: Cannot read image (this model does not support image input)
```

The model is then left holding bytes it cannot interpret — and the predictable
failure is an agent that *claims* visual verification it never performed
("the screenshot proves it", "browser-proven"). That claim is always false on a
blind model. It is the single most expensive failure mode in this environment.

## The rule

**Never report a visual result you did not read through `see`.**

If a task is visual, run `see` first. Its output is TEXT, so it works identically on
a blind model and a sighted one. Paste its findings; do not paraphrase from memory.

## Usage

```powershell
see --url http://127.0.0.1:8787/ "what is on screen?"
see --url http://127.0.0.1:8787/ --check C:\Users\Admin\bin\see-checks.json
see --monitor                # every display, stitched (7680x2160 on this box)
see --monitor 0              # first display only
see --file C:\Temp\shot.png "describe this"
see --probe                  # which models can actually see, right now
```

`--wait <ms>` lets a page settle before capture (default 3500; use 6000-9000 for a
busy dashboard). `--save out.png` keeps the capture. `--full` grabs the whole page.

## Checking a UI against requirements

Write the requirements as JSON and get a PASS/FAIL/UNSEEN table back:

```json
{ "items": [
  "the crew counter reads 5 WORKING, not 0 WORKING",
  "the chat panel says connected, not connecting",
  "every message names the agent that sent it"
] }
```

```
see --url http://127.0.0.1:8787/ --check checks.json
```

The inspector is told to answer only from what is literally rendered and to say
UNSEEN rather than guess. Exit code is `0` only when every item passed.

## When the user sends you an image

Their attachment reaches you as an image part you may not be able to read. Do this
instead of telling them to retype it:

```powershell
# find the attachment on disk, then:
see --file <path> "transcribe and describe everything in this image"
```

## How it works

`see` captures pixels (headless Chrome, a real desktop monitor grab, or a file),
downscales them, and sends them to a **vision-capable** model on the OpenCodeGo
proxy, returning that model's text answer.

Sighted models on this host: `qwen3.8-max`, `deepseek-v4-flash-vision-exp`,
`minimax-m3`. `see --probe` re-derives the live list instead of trusting this one.

The bridge deliberately **refuses to use a blind model**: a text-only model handed
an image does not error, it invents a plausible answer ("no screenshot is visible")
that reads like a real verdict. Answers matching a blindness marker are discarded
and the next model is tried, so a text-only improvisation can never be reported as
a visual finding.

## Reporting honestly

If `see` cannot reach a sighted model it exits `5` and says so. That is the correct
outcome to report: *"I could not visually verify this — no sighted model was
available."* Never paper over it.
