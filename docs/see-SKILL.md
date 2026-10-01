---
name: see
description: "Convert screenshots and screen regions into TEXT so a text-only model can actually inspect them. Use whenever a task involves looking at a UI, a rendered page, a canvas, a diagram, or any image the user sends. Also use before claiming any visual work is done."
---

# See — vision bridge for text-only models

## The problem this exists to solve

Most models on this host are **text-only**: a screenshot tool hands one a PNG and the
result is

```
ERROR: Cannot read image (this model does not support image input)
```

The model is then holding bytes it cannot read, and the predictable failure is an agent
that *claims* visual verification it never performed ("the screenshot proves it"). That
claim is always false on a blind model. This bridge removes the excuse: it turns pixels
into **text**, which a blind model reads perfectly well.

## The rule

**Never report a visual result you did not read through `see`.**

## Usage

```powershell
see --url http://127.0.0.1:8787/ "what is on screen?"
see --url http://127.0.0.1:8787/ --check C:\Users\Admin\bin\see-checks.json
see --url http://127.0.0.1:8787/ --regions            # split into regions, merge verdicts
see --monitor                # every display, stitched
see --monitor 0              # first display only
see --file C:\Temp\shot.png "describe this"
see --probe                  # which models can read an image, right now
```

`--wait <ms>` lets a page settle (default 3500; use 10000-12000 for a busy dashboard).
A run can take **60-180 seconds** — it retries empty bodies and 503s on purpose.

## MEASURED CAPABILITY — read this before you trust a result

This is the honest picture, measured on this host against a dense 1920x1080 dashboard:

| image | free models (`space-bunny-free`, `longcat-2.5-preview-free`) |
|---|---|
| simple synthetic (red field, blue square, "BLUE42") | **reads correctly** |
| simple, wide, low-density region (a top bar) | **often reads** — but the same region failed 6/6 in one window and succeeded in another |
| dense or tall region (a crew rail, a chat panel) | **usually empty** — 6/8, 7/7, 8/8 empty |
| full-page dashboard | **never** readable, at any size or quality |

**Consequence you must respect:** a single successful region read is *not* evidence that
the path is reliable. It is one lucky sample. Do not generalise from one run.

**Therefore:** if the UI is dense, free-only verification will mostly return INCONCLUSIVE.
That is the correct outcome, and you must report it as such — "I could not visually verify
this; no free model could read that region" — rather than substituting a paid model
silently or claiming success. `--paid` exists and is the only way to permit a non-free
model; using it is a decision to be made openly, not a fallback to slip in.

## Checking a UI against requirements

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

The inspector answers only from what is literally rendered and says UNSEEN rather than
guess. Exit code is `0` only when every item passed.

## When the user sends you an image

Their attachment reaches you as an image part you may not be able to read. Find the file
on disk, then `see --file <path> "transcribe and describe everything in this image"`.

## How it behaves

* **Free-models-only by default.** Only ids containing `free` may be spent. `--paid` is
  the single, explicit opt-out. Every path — including `--probe` and `--check` — goes
  through the same guard.
* **Empty body is noise, never an answer.** The free models intermittently return an
  empty body. That is retried to the full budget and is never reported as a result.
* **A 503 is transient.** A TEXT request to both free models failed with 503 at the same
  moment an IMAGE request to the same models succeeded. So 503s are retried with capped
  backoff (`min(20, 3*attempt)`) and never read as a verdict.
* **Blind answers are rejected.** A text-only model handed an image does not error — it
  invents a plausible answer ("no screenshot is visible") that reads like a real verdict.
  Answers matching a blindness marker are discarded and the next model is tried.
* **Retry depth is model-class aware** (`resolved_attempts`): 8 for free models, 4
  otherwise, because the free ones are the flaky ones and they are the mandatory ones.
* **Capture truth is the file on disk, not the child's exit code.** `browser.close()`
  can hang, so a perfectly good PNG was once discarded as "CAPTURE FAILED".

## When the bridge cannot help

`see` exits non-zero and says so. Report that plainly. The alternative for a dense UI is
either a human look, or an explicit decision to spend a non-free model with `--paid`. Do
not do either one silently.
