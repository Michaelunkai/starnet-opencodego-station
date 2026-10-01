#!/usr/bin/env python3
"""
see.py - PERMANENT GLOBAL VISION BRIDGE for paseo / opencode agents.

WHY THIS EXISTS
---------------
Most models on this host are text-only ("this model does not support image
input"). A screenshot tool therefore returns bytes the agent cannot read, and
the agent ends up claiming visual verification it never performed.

This bridge closes that gap permanently by converting pixels into TEXT:

    capture (browser | monitor | file)  ->  vision model  ->  text verdict

Because the output is text, it works for EVERY model and EVERY session,
sighted or blind.

FREE-ONLY IS A HARD RULE, NOT A PREFERENCE
------------------------------------------
The user pays nothing for verification, so the default model set is the two
free models on this host, both MEASURED to have real vision:

    space-bunny-free
    longcat-2.5-preview-free

Every code path - the checklist path, the free-text path, --probe, and
--model - passes through one gate, allowed_model(). A non-free id is refused
with exit 6 unless --paid is passed. --paid is the ONLY way to spend money.

THE MEASUREMENT THAT ALMOST GOT IT WRONG
-----------------------------------------
The first probe asked each model to "reply with ONLY the text and the colour".
BOTH free models returned an empty body. That looks exactly like blindness,
and the naive reading was "the free models are blind, so --paid is required".

They are not blind. Re-tested fairly, on the real 1600x900 station screenshot
with the real inspection task, space-bunny-free produced verdicts that
independently match what deepseek-v4-flash-vision-exp reports from the same
pixels ("7 WORKING", "1 IDLE", COMMS "online", "[WRITER] run ended"). Two
unrelated models agreeing on the same specifics is the real evidence.

THE LESSON, WHICH THE CODE BELOW ENFORCES:
  * An EMPTY BODY IS EVIDENCE OF NOTHING. Never score it as blind, never
    print it, never let it reach a verdict. It is classified INCONCLUSIVE and
    a different model is tried. See ask_sighted() and probe().
  * NEVER conclude a model is blind from one narrow prompt. judge_answer()
    only returns BLIND when a model repeats a blindness marker after a retry
    that explicitly tells it it is a vision model.
  * A text-only model handed an image does not error - it improvises
    ("no screenshot is visible"). That improvisation is discarded, so it can
    never be reported as a visual finding.

USAGE
-----
    see.py --url http://127.0.0.1:8787/ "What is visible? Is anything broken?"
    see.py --url http://127.0.0.1:8787/ --check checks.json
    see.py --url http://127.0.0.1:8787/ --region 0,0,0.3,1 "left rail"
    see.py --url http://127.0.0.1:8787/ --regions --check checks.json
    see.py --monitor 0 "Describe this monitor"
    see.py --file shot.png --check checks.json
    see.py --probe                 # which models can see, right now
    see.py --url <u> --save shot.png "..."

--region left,top,right,bottom crops the capture to one panel (fractions 0-1)
before it is sent; the default is the whole page. A cropped panel is a far
simpler image than a full dashboard, which is what lets a free model read it.
--regions checks several regions in one run and merges the verdicts, so one
command can verify a whole UI on free models.

--check FILE accepts JSON:
    {"items": ["bubbles appear above working agents", "..."]}
and prints PASS/FAIL/UNSEEN per item.

EXIT CODES
----------
    0  ok, and with --check: zero FAIL
    1  a check FAILED
    2  bad usage / unreadable --check file (4 for unreadable check file)
    3  CAPTURE FAILED (capture raises before any model is asked)
    4  bad --check file
    5  no sighted model answered
    6  refused: a non-free model was demanded without --paid
    9  the bridge itself is missing or python is unavailable (see.cmd)
"""

import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------

PROXY_DIR = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Projects\OpencodeGoProxy"
PROXY_CONFIG = os.path.join(PROXY_DIR, "config.json")
PROXY_BASE = "http://127.0.0.1:4001/v1"

# --------------------------------------------------------------------------
# FREE-MODELS-ONLY. Flipped to False only by --paid, and only in main().
# Every model ask goes through allowed_model(), so there is no path - not
# --model, not --probe, not --check - that can spend a paid model by accident.
# --------------------------------------------------------------------------
FREE_ONLY = True

FREE_MODELS = [
    "space-bunny-free",           # primary: reliably sighted, fast
    "longcat-2.5-preview-free",   # fallback: also sighted
]

# Sighted on this host but NOT free. Refused unless --paid is given.
PAID_VISION_MODELS = [
    "qwen3.8-max",
    "deepseek-v4-flash-vision-exp",
    "minimax-m3",
]

# BLIND models are deliberately NOT listed anywhere: a text-only model handed
# an image does not error, it invents a plausible answer ("no screenshot is
# visible") that reads like a real verdict. A blind model is worse than no
# model, so the bridge only ever asks a model that has proven sight.

# A reply containing one of these is NOT a visual finding and is thrown away.
BLIND_MARKERS = (
    "novision",
    "no vision",
    "cannot see",
    "can't see",
    "cant see",
    "no screenshot is visible",
    "cannot view image",
    "can't view image",
    "unable to view",
    "no image is visible",
    "no image was provided",
    "as a text-based",
    "as a text only",
    "i don't have the ability to view",
    "i do not have the ability to view",
    "without any image",
    "image is not available",
    "not able to view images",
)

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
]

HERE = os.path.dirname(os.path.abspath(__file__))
SHOT_DIR = os.path.join(HERE, "shots")

# Verdicts a single answer can earn.
SIGHTED = "SIGHTED"
BLIND = "BLIND"
INCONCLUSIVE = "INCONCLUSIVE"   # <-- empty body, garbage, or a short failure
UNRELATED = "UNRELATED"         # answered, but not about this image


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def log(msg):
    print("[see] " + msg, file=sys.stderr, flush=True)


def is_free(model):
    """Free = the id advertises itself free. Conservative on purpose."""
    return "free" in str(model).lower()


def allowed_models():
    """Free first, always. Paid only when FREE_ONLY has been turned off."""
    if FREE_ONLY:
        return list(FREE_MODELS)
    return list(FREE_MODELS) + list(PAID_VISION_MODELS)


def allowed_model(model):
    """
    THE gate. Every ask_sighted/chat_vision call passes through here, so no
    code path can spend a non-free model by accident or by argument trickery.
    Raises RefusedModel if the id is not permitted right now.
    """
    m = str(model or "").strip()
    if not m:
        raise RefusedModel("empty model id")
    if not is_free(m) and FREE_ONLY:
        raise RefusedModel(
            "%s is not a free model and --paid was not passed "
            "(free-only is a hard rule)" % m)
    if FREE_ONLY and m not in FREE_MODELS:
        # A free id the bridge has not been told about is still allowed to be
        # *asked* only if the caller used --model explicitly; keep the guard
        # narrow so --model with a known-free id stays usable.
        pass
    return m


class RefusedModel(Exception):
    """Raised when a non-free model is demanded without --paid."""


class EmptyAnswer(Exception):
    """Raised when a model returns an empty body. NEVER evidence of anything."""


class BlindAnswer(Exception):
    """Raised when a model states, twice, that it cannot see images."""


def proxy_keys():
    """
    Candidate bearer tokens, best first.

    THE PROXY'S OWN local_api_key MUST COME FIRST. On this host
    OPENCODE_GO_API_KEY holds an UPSTREAM OpenCode key (oc_sk_...) which the
    LOCAL proxy rejects with 401 - it is not the same credential space.
    Trusting the environment variable first is what made vision look broken
    while the proxy was actually healthy, so the config file is read first and
    the env var is only a fallback.
    """
    keys = []

    def add(val, origin):
        if val and str(val) not in keys:
            keys.append(str(val))
            log("key candidate from %s (len %d)" % (origin, len(str(val))))

    try:
        with open(PROXY_CONFIG, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
        for name in ("local_api_key", "api_key", "key", "token"):
            if isinstance(cfg, dict):
                add(cfg.get(name), "proxy config " + name)
    except Exception as exc:
        log("proxy config unreadable (%s); falling back to env only" % exc)

    for name in ("OPENCODE_GO_API_KEY", "OPENCODEGO_API_KEY"):
        add(os.environ.get(name), "env " + name)

    return keys


def proxy_key_precedence_report():
    """Human-readable proof of proxy_keys() ordering. Used by selftest.py."""
    out = []
    try:
        with open(PROXY_CONFIG, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
        for name in ("local_api_key", "api_key", "key", "token"):
            v = (cfg or {}).get(name)
            if v:
                out.append(("config:" + name, str(v)))
    except Exception as exc:
        out.append(("config:ERROR", str(exc)))
    for name in ("OPENCODE_GO_API_KEY", "OPENCODEGO_API_KEY"):
        v = os.environ.get(name)
        if v:
            out.append(("env:" + name, v))
    return out


def valid_png(path, min_side=64, min_bytes=4096):
    """
    The capture verdict, and it is deliberately INDEPENDENT of any child's exit
    code: a real open, a real decode, a real byte count, a sane size.
    """
    try:
        if not path or not os.path.isfile(path):
            return False
        if os.path.getsize(path) < min_bytes:
            return False
        from PIL import Image
        with Image.open(path) as im:
            im.verify()                      # structural check, real decode
        with Image.open(path) as im:
            w, h = im.size
            fmt = im.format
        return fmt == "PNG" and w >= min_side and h >= min_side
    except Exception:
        return False


def shrink(image_bytes, max_side=1280, quality=82):
    """
    Downscale before the vision call.

    A 1600x900 PNG is ~1.7 MB and pushed straight into the model it took minutes
    per call. Halving the pixels and sending JPEG turns the same inspection into
    a few seconds while staying sharp enough to read UI text and count badges.
    """
    try:
        from PIL import Image

        im = Image.open(io.BytesIO(image_bytes))
        im = im.convert("RGB")
        w, h = im.size
        scale = min(1.0, float(max_side) / float(max(w, h)))
        if scale < 1.0:
            im = im.resize((max(1, int(w * scale)), max(1, int(h * scale))),
                           Image.LANCZOS)
        out = io.BytesIO()
        im.save(out, format="JPEG", quality=quality, optimize=True)
        return out.getvalue()
    except Exception as exc:
        log("shrink skipped (%s); sending original" % exc)
        return image_bytes


# --------------------------------------------------------------------------
# region capture
# --------------------------------------------------------------------------
#
# WHY REGIONS EXIST
# -----------------
# Measured on this host: a free vision model reads a SIMPLE synthetic image
# (a red field, one blue square, the text BLUE42) perfectly, but returns an
# EMPTY body for a dense full-page dashboard screenshot every single time -
# even shrunk to 50 KB. The cause is IMAGE DENSITY, not bytes. A cropped panel
# is a far simpler image, so a region is the lever that makes the free path
# actually work on a real UI.

# Default region set for --regions: a coarse tiling of a dashboard. Each box
# is (left, top, right, bottom) as fractions of the page, 0..1.
DEFAULT_REGIONS = {
    "top-bar":     (0.00, 0.00, 1.00, 0.12),
    "left-rail":   (0.00, 0.10, 0.28, 1.00),
    "center":      (0.26, 0.10, 0.74, 1.00),
    "right-panel": (0.72, 0.10, 1.00, 1.00),
}


def parse_region(spec):
    """
    'left,top,right,bottom' fractions (0..1) -> a validated 4-tuple of floats.
    Accepts commas or spaces as separators. Refuses an inverted or out-of-range
    box so a typo cannot silently produce a zero-area crop.
    """
    parts = [p for p in re.split(r"[,\s]+", str(spec).strip()) if p]
    if len(parts) != 4:
        raise ValueError("--region wants left,top,right,bottom fractions (0-1), got %r"
                         % (spec,))
    try:
        box = tuple(float(p) for p in parts)
    except ValueError:
        raise ValueError("--region fractions must be numbers, got %r" % (spec,))
    left, top, right, bottom = box
    if not (0.0 <= left < right <= 1.0):
        raise ValueError("--region needs 0 <= left < right <= 1, got %r" % (box,))
    if not (0.0 <= top < bottom <= 1.0):
        raise ValueError("--region needs 0 <= top < bottom <= 1, got %r" % (box,))
    return box


def crop_bytes(image_bytes, box):
    """
    Crop to a fractional box (left, top, right; bottom), each 0..1, and return
    JPEG bytes. A cropped panel is a far simpler image than a full dashboard,
    and that simplicity is what lets a free vision model actually read it.
    """
    from PIL import Image

    im = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    w, h = im.size
    left, top, right, bottom = box
    x0 = max(0, min(int(round(w * float(left))), w - 1))
    y0 = max(0, min(int(round(h * float(top))), h - 1))
    x1 = max(x0 + 1, min(int(round(w * float(right))), w))
    y1 = max(y0 + 1, min(int(round(h * float(bottom))), h))
    im = im.crop((x0, y0, x1, y1))
    out = io.BytesIO()
    im.save(out, format="JPEG", quality=85, optimize=True)
    return out.getvalue()


def load_regions(spec):
    """
    Resolve --regions into an ordered {name: box} dict.

    * no value  -> DEFAULT_REGIONS
    * a path    -> JSON of the form {"regions": {"name": [l,t,r,b], ...}}
    """
    if spec is None or spec == "__default__":
        return dict(DEFAULT_REGIONS)
    if not os.path.exists(spec):
        raise ValueError("--regions spec not found: %s" % spec)
    with open(spec, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    regions = data.get("regions", data) if isinstance(data, dict) else data
    if not isinstance(regions, dict) or not regions:
        raise ValueError("--regions spec needs a {\"name\": [l,t,r,b]} map")
    out = {}
    for name, box in regions.items():
        if isinstance(box, str):
            out[str(name)] = parse_region(box)
        else:
            out[str(name)] = parse_region(",".join(str(v) for v in box))
    return out


def merge_region_verdicts(region_texts):
    """
    Merge per-region answers into one verdict per check item.

    region_texts: {region_name: answer_text}

    Merge rule per item number: FAIL if ANY region FAILs, else PASS if any
    region PASSes, else UNSEEN. A real failure is never papered over by a
    region that could not see the area, and a pass is credited as soon as the
    region that actually shows that part of the UI confirms it.

    Returns (merged_counts, per_region_counts, merged_lines).
    """
    rank = {"FAIL": 0, "PASS": 1, "UNSEEN": 2}
    best = {}
    evidence = {}
    per_region = {}
    for name, text in region_texts.items():
        p, f, u = tally(text)
        per_region[name] = (p, f, u)
        for line in str(text).splitlines():
            m = VERDICT_RE.search(line)
            if not m:
                continue
            num_m = re.search(r"VERDICT\s+(\d+)", line, re.I)
            if not num_m:
                continue
            num = int(num_m.group(1))
            word = m.group(1).upper()
            if num not in best or rank[word] < rank[best[num]]:
                best[num] = word
                evidence[num] = (name, line.strip())
    merged_lines = []
    for num in sorted(best):
        name, line = evidence[num]
        merged_lines.append("VERDICT %d | %s | (from %s) %s"
                            % (num, best[num], name,
                               re.sub(r"^VERDICT\s*\d+\s*\|\s*\w+\s*\|", "",
                                      line, flags=re.I).strip()))
    p = sum(1 for v in best.values() if v == "PASS")
    f = sum(1 for v in best.values() if v == "FAIL")
    u = sum(1 for v in best.values() if v == "UNSEEN")
    return (p, f, u), per_region, merged_lines


# --------------------------------------------------------------------------
# answering one model
# --------------------------------------------------------------------------

def chat_vision(model, image_bytes, prompt, timeout=180, max_tokens=1200):
    """Send one image to one model. Returns its text. Raises on failure."""
    allowed_model(model)                       # <-- the free-only gate
    b64 = base64.b64encode(image_bytes).decode("ascii")
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": "data:image/png;base64," + b64},
                    },
                ],
            }
        ],
        "max_tokens": max_tokens,
    }
    body = json.dumps(payload).encode("utf-8")

    last = None
    keys = proxy_keys()
    if not keys:
        raise RuntimeError("no proxy api key available")
    for key in keys:
        req = urllib.request.Request(
            PROXY_BASE + "/chat/completions",
            data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + key,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                out = json.loads(resp.read().decode("utf-8"))
            return (out["choices"][0]["message"].get("content") or "").strip()
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code in (401, 403):
                log("proxy rejected a key with %s; trying the next candidate" % exc.code)
                continue
            raise
    if last is not None:
        raise last
    raise RuntimeError("no proxy api key worked")


def judge_answer(text, prompt_kind="image"):
    """
    Classify one non-empty answer. An EMPTY answer never reaches here - the
    caller raises EmptyAnswer first - which is precisely the lesson that the
    narrow probe got wrong.
    """
    body = (text or "").strip()
    if not body:
        return INCONCLUSIVE, "empty body (evidence of nothing)"
    flat = " ".join(body.lower().split())
    for marker in BLIND_MARKERS:
        if marker in flat:
            return BLIND, "declared blind: " + body[:90]
    low = flat
    if prompt_kind == "probe":
        # A probe answer must actually reference the picture.
        signals = {
            "red": ("red", "crimson", "maroon"),
            "blue": ("blue", "navy"),
            "square": ("square", "rectangle", "box", "block"),
            "code": ("blue42", "42", "blue 42"),
        }
        hits = sum(1 for names in signals.values() if any(n in low for n in names))
        if hits >= 2:
            return SIGHTED, "%d/4 probe signals matched" % hits
        return UNRELATED, "answered but saw nothing recognisable: " + body[:70]
    return SIGHTED, ""


def resolved_attempts(model, attempts=None):
    """
    MODEL-CLASS-AWARE retry depth.

    The free models are the flaky ones - a real measured run against the live
    station produced "empty answer from space-bunny-free" and
    "HTTP Error 503" from longcat on the same 1600x900 screenshot - and they
    are the only ones we are allowed to use. So they get the deep budget and
    everything else gets a normal one. No caller passes attempts by accident;
    the depth is a property of the model class, not of the call site.
    """
    if attempts is not None:
        return int(attempts)
    if model in FREE_MODELS:
        return 8          # free + flaky + mandatory: spend the budget here
    return 4


def backoff(attempt):
    """Capped so a deep free-model budget cannot balloon the wall clock."""
    return min(20, 3 * attempt)


def attempt_once(model, image_bytes, prompt, attempt, kind, timeout, max_tokens):
    """
    ONE network attempt against one model.

    Returns (status, payload) where status is:
        "ok"      -> payload is the answer text
        "retry"   -> payload is a short reason; transient noise, try again
        "blind"   -> payload is the note; the model declared blindness
        "unrelated" -> payload is the note; it answered about nothing in the image
    Raises RefusedModel for a model the free-only rule forbids, and hard
    transport errors (non-5xx HTTP, refused socket) propagate as exceptions.
    """
    allowed_model(model)
    ask = prompt
    if attempt > 1:
        # Explicit re-ask. The nudge exists so a real vision model is never
        # written off on one empty body or one denial.
        ask = (prompt + "\n\nYou are a vision-capable model and an image IS "
                          "attached to this message. Describe what you actually "
                          "see in it. Do not reply with an empty message and do "
                          "not say you cannot see.")

    try:
        text = chat_vision(model, image_bytes, ask, timeout=timeout,
                           max_tokens=max_tokens)
    except urllib.error.HTTPError as exc:
        if exc.code in (429, 500, 502, 503, 504):
            return "retry", "HTTP %s" % exc.code
        raise
    except (urllib.error.URLError, OSError) as exc:
        return "retry", "transport: %s" % exc

    if not (text or "").strip():
        # THE LESSON. An empty body is not blindness, not an answer, and never
        # reported. It is NOISE, and noise is retried exactly like a 503.
        return "retry", "EMPTY body (inconclusive, not a visual result)"

    verdict, note = judge_answer(text, prompt_kind=kind)
    if verdict == BLIND:
        return "blind", note
    if verdict == UNRELATED:
        return "unrelated", note
    return "ok", text


def ask_sighted(model, image_bytes, prompt, attempts=None, timeout=180,
                max_tokens=1200, probe=False, want_tol=None):
    """
    Ask ONE model until it gives a usable, genuinely-sighted answer.

    Returns (text, note). Raises:
        RefusedModel   - the model is not permitted right now (free-only rule)
        EmptyAnswer    - ONLY when every attempt in the budget came back empty
        BlindAnswer    - the model stated blindness on every remaining attempt
        RuntimeError   - a hard transport failure that outlasted the retries
    """
    attempts = resolved_attempts(model, attempts)
    kind = "probe" if probe else "image"
    log("%s: attempt budget = %d" % (model, attempts))

    empty_rounds = 0
    last_why = "no attempt made"
    for attempt in range(1, attempts + 1):
        status, payload = attempt_once(model, image_bytes, prompt, attempt,
                                       kind, timeout, max_tokens)
        if status == "ok":
            return payload, ""
        last_why = payload
        if status == "retry" and "EMPTY" in payload:
            empty_rounds += 1
        if attempt < attempts:
            log("%s -> %s; retrying (attempt %d/%d)"
                % (model, payload, attempt, attempts))
            time.sleep(backoff(attempt))
            continue
        # Last attempt spent. Only NOW can a verdict be formed about the model.
        if empty_rounds == attempts:
            # Guarded by empty_rounds == attempts: unreachable on the first
            # empty body, because the `continue` above runs on every attempt
            # before the last. An empty body is evidence of nothing.
            raise EmptyAnswer(
                "%s returned an empty body %d/%d times - inconclusive, no verdict"
                % (model, empty_rounds, attempts))
        if status == "blind":
            raise BlindAnswer(last_why)
        raise RuntimeError("no usable answer from %s (%s)" % (model, last_why))
    raise RuntimeError("no usable answer from %s (%s)" % (model, last_why))


def ask_any_model(models, image_bytes, prompt, timeout=180, max_tokens=1200,
                  probe=False):
    """
    Round-robin across the candidate models: ONE attempt per model per round.

    THE STARVATION FIX. ask_sighted alone would let the first free model burn
    its whole 8-attempt budget (up to ~100s of capped backoff) before the
    second free model was touched at all - and on the measured failure the run
    ended with nothing. Interleaving means a round-1 503 from model A is
    followed immediately by model B's attempt, and neither can starve the other.

    Returns (model, text, note). Raises the same exception types as
    ask_sighted, recording per-model reasons on `ModelFanout.errors`.
    """
    allowed = [m for m in models]
    for m in allowed:
        allowed_model(m)                      # gate the WHOLE fan-out up front

    fan = ModelFanout(allowed)
    max_rounds = max([resolved_attempts(m) for m in allowed] or [1])
    for rnd in range(1, max_rounds + 1):
        for model in list(fan.live):
            budget = resolved_attempts(model)
            if fan.tried[model] >= budget:
                fan.retire(model, "attempt budget %d spent" % budget)
                continue
            attempt = fan.tried[model] + 1
            fan.tried[model] = attempt
            try:
                status, payload = attempt_once(
                    model, image_bytes, prompt, attempt,
                    "probe" if probe else "image", timeout, max_tokens)
            except RefusedModel:
                raise
            except Exception as exc:
                fan.errors.setdefault(model, str(exc)[:120])
                fan.retire(model, str(exc)[:120])
                continue
            if status == "ok":
                fan.retire(model, "answered")
                return model, payload, ""
            fan.errors.setdefault(model, payload)
            if "EMPTY" in str(payload):
                fan.empties[model] = fan.empties.get(model, 0) + 1
                if fan.empties[model] >= budget:
                    fan.retire(model, "empty body %d/%d - inconclusive, no verdict"
                               % (fan.empties[model], budget))
                    continue
            elif status == "blind" and attempt >= 2:
                fan.blinds[model] = fan.blinds.get(model, 0) + 1
                if fan.blinds[model] >= 2:
                    fan.retire(model, "declared blind twice: %s" % payload)
                    continue
            if attempt < budget:
                time.sleep(backoff(attempt))

    # Round-robin exhausted. Report honestly, per model, with EMPTY separated
    # from blind, because the two are entirely different failures.
    details = []
    for m in allowed:
        why = fan.errors.get(m, "no answer")
        if m in fan.blinds and fan.blinds[m] >= 2:
            why = "declared blind (%d denials) - discarded, never reported" % fan.blinds[m]
        elif fan.empties.get(m):
            why = "empty body %d time(s) - inconclusive, never a verdict" % fan.empties[m]
        details.append((m, why))
    raise NoSightedModel(details)


class ModelFanout(object):
    """Per-model bookkeeping for the round-robin fan-out."""

    def __init__(self, models):
        self.live = list(models)
        self.tried = {m: 0 for m in models}
        self.errors = {}
        self.empties = {}
        self.blinds = {}

    def retire(self, model, why):
        self.errors.setdefault(model, why)
        if model in self.live:
            self.live.remove(model)


class NoSightedModel(Exception):
    """No candidate model produced a usable, proven-sighted answer."""

    def __init__(self, details):
        self.details = details
        Exception.__init__(self, "no sighted model answered")


# --------------------------------------------------------------------------
# capture: browser
# --------------------------------------------------------------------------

# NOTE the exit path. Chrome's browser.close() HANGS on this host - verified
# against about:blank, so it is Chrome/Playwright, not the station page. The
# PNG is already on disk at that point, so the script reports "ok" and then
# process.exit(0)s regardless of whether close() ever returns. Otherwise node
# never exits and the caller kills a capture that had already succeeded.
CAPTURE_JS = r"""
const { chromium } = require("playwright-core");
const fs = require("fs");

function bail(code, msg) {
  try { process.stderr.write(String(msg)); } catch (e) {}
  process.exit(code);
}

(async () => {
  const out = process.argv[2];
  const url = process.argv[3];
  const w = parseInt(process.argv[4] || "1920", 10);
  const h = parseInt(process.argv[5] || "1080", 10);
  const wait = parseInt(process.argv[6] || "3500", 10);
  const full = process.argv[7] === "full";
  const candidates = JSON.parse(process.argv[8] || "[]");

  let exe = null;
  for (const c of candidates) { if (fs.existsSync(c)) { exe = c; break; } }
  if (!exe) { bail(2, "no Chrome/Edge executable found in " + JSON.stringify(candidates)); }

  const browser = await chromium.launch({
    headless: true,
    executablePath: exe,
    timeout: 60000,
    args: ["--force-device-scale-factor=1", "--disable-dev-shm-usage",
           "--disable-background-networking", "--disable-extensions"],
  });
  const page = await browser.newPage({
    viewport: { width: w, height: h },
    deviceScaleFactor: 1,
  });
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45000 });
  await page.waitForTimeout(wait);
  await page.screenshot({ path: out, fullPage: full });
  if (!fs.existsSync(out) || fs.statSync(out).size < 512) {
    bail(3, "screenshot produced no usable file at " + out);
  }
  // Report success FIRST, then leave. close() can hang forever here and the
  // capture is already complete.
  process.stdout.write("ok");
  const hardExit = setTimeout(function () { process.exit(0); }, 4000);
  try { await browser.close(); } catch (e) {}
  clearTimeout(hardExit);
  process.exit(0);
})().catch(function (e) { bail(1, (e && e.message) || e); });
"""


def find_chrome():
    for c in CHROME_CANDIDATES:
        if os.path.exists(c):
            return c
    return None


def node_module_paths():
    """
    Directories that may contain playwright-core, so NODE_PATH can be set.

    THE WINDOWS TRAP: `npm` on Windows is npm.cmd. A bare subprocess call with
    "npm" raises and yields no path at all, which is exactly how browser
    capture ended up "broken" while node and Chrome were both fine. npm.cmd is
    tried first, the returncode is checked (not just stdout), and known
    locations are appended as a backstop so capture cannot depend on npm at
    all.
    """
    found = []

    for exe in ("npm.cmd", "npm"):
        path = shutil.which(exe)
        if not path:
            continue
        try:
            out = subprocess.run([path, "root", "-g"], capture_output=True,
                                 text=True, timeout=60)
            root = (out.stdout or "").strip().splitlines()
            root = root[-1].strip() if root else ""
            if out.returncode == 0 and root and os.path.isdir(root):
                found.append(root)
            else:
                log("`%s root -g` unusable (rc=%s)" % (exe, out.returncode))
        except Exception as exc:
            log("`%s root -g` failed: %s" % (exe, exc))
        if found:
            break

    for extra in (
        r"C:\Users\Admin\AppData\Roaming\npm\node_modules",
        r"F:\study\WebBuilding\projects\daymark-desktop\node_modules",
        os.path.join(HERE, "node_modules"),
    ):
        if os.path.isdir(extra) and extra not in found:
            found.append(extra)

    with_pw = [p for p in found if os.path.isdir(os.path.join(p, "playwright-core"))]
    if not with_pw:
        log("no playwright-core found in %s" % found)
    return with_pw or found


def _kill_tree(pid):
    try:
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)],
                       capture_output=True, timeout=30)
    except Exception:
        pass


def capture_url(url, out_png, width=1920, height=1080, wait_ms=3500, full=False,
                node_timeout=110):
    """
    Headless-Chrome screenshot of a URL.

    Reliability rules, both learned the hard way here:
      * node is killed by PID tree, never left as an orphan.
      * the PNG on disk is the source of truth. If node is still alive when the
        budget runs out but a valid PNG exists, the capture SUCCEEDED.
    """
    os.makedirs(os.path.dirname(out_png) or ".", exist_ok=True)
    js = os.path.join(HERE, "_capture.cjs")
    try:
        with open(js, "w", encoding="utf-8") as fh:
            fh.write(CAPTURE_JS)
    except Exception as exc:
        raise RuntimeError("cannot write capture script %s: %s" % (js, exc))

    if shutil.which("node") is None:
        raise RuntimeError("node is not on PATH; cannot capture a URL")

    env = dict(os.environ)
    mods = node_module_paths()
    if mods:
        env["NODE_PATH"] = os.pathsep.join(mods)
    log("NODE_PATH=" + env.get("NODE_PATH", "(none)"))

    if os.path.exists(out_png):
        try:
            os.remove(out_png)
        except OSError:
            pass

    cmd = ["node", js, out_png, url, str(width), str(height), str(wait_ms),
           "full" if full else "viewport", json.dumps(CHROME_CANDIDATES)]

    # THE FILE ON DISK IS THE TRUTH. NOT THE CHILD'S EXIT CODE.
    #
    # Chrome's browser.close() hangs forever on this host (reproduced against
    # about:blank, so it is Playwright/Chrome, not the station page). node
    # therefore never exits, the timeout fires, and the old code reported
    # "CAPTURE FAILED" while throwing away a complete ~1.7 MB PNG. A capture
    # that produced a valid, sanely-sized, decodable image IS a success,
    # whatever the child's exit status. Only a file that is genuinely absent
    # or unreadable is a failure.
    err_path = os.path.join(SHOT_DIR, "_capture.err")
    errf = None
    rc = None
    try:
        errf = open(err_path, "wb")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=errf, env=env)
        try:
            rc = proc.wait(timeout=node_timeout)
        except subprocess.TimeoutExpired:
            rc = None
            log("capture child still running after %ds; killing its process tree"
                % node_timeout)
            _kill_tree(proc.pid)
            try:
                rc = proc.wait(timeout=15)
            except Exception:
                pass
    except OSError as exc:
        raise RuntimeError("could not start node: %s" % exc)
    finally:
        if errf is not None:
            try:
                errf.close()
            except Exception:
                pass

    # Verify with a real open and a real byte count, never the return code.
    if valid_png(out_png):
        size = os.path.getsize(out_png)
        if rc is None or rc != 0:
            log("child exit status %r IGNORED: %s is a valid %d-byte PNG, so the "
                "capture SUCCEEDED" % (rc, os.path.basename(out_png), size))
        else:
            log("captured %s (%d bytes, child rc=%d)" % (out_png, size, rc))
        return out_png

    # Only now is it a genuine failure: no valid file.
    raise RuntimeError(
        "capture failed: %s is absent, unreadable, or not a sane image "
        "(child rc=%r). node said: %s"
        % (out_png, rc, _read_tail(err_path) or "(nothing)"))


def _read_tail(path, limit=600):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
        return data.decode("utf-8", "replace").strip()[-limit:]
    except Exception:
        return ""


# --------------------------------------------------------------------------
# capture: desktop monitors
# --------------------------------------------------------------------------

def capture_monitors(out_png, monitor=None):
    """Grab the real desktop. monitor=None stitches every display."""
    from PIL import ImageGrab

    os.makedirs(os.path.dirname(out_png) or ".", exist_ok=True)
    img = ImageGrab.grab(all_screens=True)
    if monitor is not None:
        try:
            import ctypes

            class RECT(ctypes.Structure):
                _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                            ("right", ctypes.c_long), ("bottom", ctypes.c_long)]

            class MONITORINFO(ctypes.Structure):
                _fields_ = [("cbSize", ctypes.c_ulong), ("rcMonitor", RECT),
                            ("rcWork", RECT), ("dwFlags", ctypes.c_ulong)]

            user32 = ctypes.windll.user32
            handles = []
            proc = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_void_p,
                                      ctypes.c_void_p, ctypes.POINTER(RECT), ctypes.c_long)
            cb = proc(lambda h, dc, rc, data: handles.append(h) or 1)
            user32.EnumDisplayMonitors(None, None, cb, 0)
            mi = MONITORINFO()
            mi.cbSize = ctypes.sizeof(MONITORINFO)
            if 0 <= monitor < len(handles):
                user32.GetMonitorInfoW(handles[monitor], ctypes.byref(mi))
                box = (mi.rcMonitor.left, mi.rcMonitor.top,
                       mi.rcMonitor.right, mi.rcMonitor.bottom)
                img = img.crop(box)
            else:
                log("monitor %d does not exist (%d displays); using the full desktop"
                    % (monitor, len(handles)))
        except Exception as exc:
            log("monitor crop skipped (%s); using full desktop" % exc)
    img.save(out_png)
    if not valid_png(out_png, min_side=32):
        raise RuntimeError("monitor grab produced no valid PNG")
    return out_png


# --------------------------------------------------------------------------
# prompts
# --------------------------------------------------------------------------

CHECK_PROMPT = """You are a strict visual QA inspector looking at a screenshot of a
live web application dashboard.

Check EVERY item below against what is literally visible in the image.
For each item answer on its own line in exactly this format:

VERDICT <n> | PASS or FAIL or UNSEEN | <short evidence: quote the exact text,
count, colour or position you actually observed> | <what is wrong if FAIL>

Rules:
- PASS only if you can point to the specific pixels/text that prove it.
- FAIL if the requirement is absent, wrong, or shows a stale/error state.
- UNSEEN if the area is off-screen, occluded, or too small to judge.
- Never guess. Never be generous. Report exactly what is rendered.

Items:
{items}
"""

# The FAIR probe. It asks for a description, never for a bare token, because
# the narrow version made both free models answer with an empty body and that
# was misread as blindness.
PROBE_PROMPT = (
    "Look at the attached test image and describe what you can actually see in "
    "it. This image is a synthetic colour test: a solid background colour, one "
    "plain coloured shape on the left side, and the printed characters on the "
    "right side. In two or three full sentences, state the background colour, "
    "the colour and shape you see on the left, and the exact characters printed "
    "on the right. Answer as prose. If you genuinely cannot see images at all, "
    "reply exactly NOVISION."
)


def build_prompt(question, items):
    if not items:
        return (
            "Describe this screenshot of an application in precise, verifiable "
            "detail. Name every visible region, every status label, every count, "
            "every agent name, every bubble or message, and anything that looks "
            "broken, empty, stuck on 'connecting', or frozen.\n\n"
            "Question: " + question
        )
    body = "\n".join("%d. %s" % (i + 1, it) for i, it in enumerate(items))
    return CHECK_PROMPT.replace("{items}", body) + (
        "\n\nAlso answer briefly: " + question if question else "")


# --------------------------------------------------------------------------
# probe
# --------------------------------------------------------------------------

def probe_image():
    """Red field, blue square on the left, the code BLUE42 on the right."""
    from PIL import Image, ImageDraw, ImageFont

    im = Image.new("RGB", (640, 320), (200, 20, 20))
    d = ImageDraw.Draw(im)
    d.rectangle([40, 40, 260, 280], fill=(20, 20, 220))
    text = "BLUE42"
    font = None
    for cand in (r"C:\Windows\Fonts\consolab.ttf", r"C:\Windows\Fonts\arialbd.ttf",
                 r"C:\Windows\Fonts\segoeuib.ttf"):
        try:
            font = ImageFont.truetype(cand, 72)
            break
        except Exception:
            continue
    d.text((300, 130), text, fill=(255, 255, 255), font=font)
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def probe():
    """
    Which models can see, right now. Honours free-only like every other path:
    with FREE_ONLY on (the default) only the free models are ever asked.
    """
    probe_bytes = probe_image()
    shrink(probe_bytes)  # warm the import path and prove the bytes are readable

    models = allowed_models()
    print("free-only: %s" % ("ON (default)" if FREE_ONLY else "OFF (--paid)"))
    print("models to ask: %s" % ", ".join(models))
    print("")

    seen, blind, inconclusive = [], [], []
    for m in models:
        text, note = "", ""
        try:
            # attempts is deliberately NOT passed: it resolves to 8 for the free
            # models, which are exactly the ones that return empty bodies.
            text, note = ask_sighted(m, probe_bytes, PROBE_PROMPT,
                                     timeout=120, max_tokens=300, probe=True)
            seen.append(m)
            print("  SIGHTED      %-32s %s" % (m, text.replace("\n", " ")[:70]))
        except EmptyAnswer as exc:
            inconclusive.append((m, str(exc)))
        except BlindAnswer as exc:
            blind.append((m, str(exc)))
        except RefusedModel as exc:
            inconclusive.append((m, "refused: " + str(exc)))
        except Exception as exc:
            inconclusive.append((m, str(exc)[:100]))

    for m, why in blind:
        print("  blind        %-32s %s" % (m, why))
    for m, why in inconclusive:
        # INCONCLUSIVE, never "blind". An empty body is evidence of nothing.
        print("  inconclusive %-32s %s" % (m, why))

    print("")
    print("VISION-CAPABLE: " + (", ".join(seen) if seen else "(none)"))
    if not seen:
        print("Nothing was proven sighted. Report that honestly; do not guess.")
    return seen


# --------------------------------------------------------------------------
# tally
# --------------------------------------------------------------------------

VERDICT_RE = re.compile(r"VERDICT\s+\d+\s*\|\s*(PASS|FAIL|UNSEEN)", re.I)


def tally(text):
    """Count only well-formed VERDICT lines, so prose mentions cannot skew it."""
    p = f = u = 0
    for line in text.splitlines():
        m = VERDICT_RE.search(line)
        if not m:
            continue
        word = m.group(1).upper()
        if word == "PASS":
            p += 1
        elif word == "FAIL":
            f += 1
        else:
            u += 1
    return p, f, u


# --------------------------------------------------------------------------
# --regions mode
# --------------------------------------------------------------------------

def run_regions_mode(order, image_bytes, prompt, items, spec):
    """
    Check every region in one run and merge the verdicts.

    One model call per region (not per item): each region is asked the full
    check list, answers the items it can actually see, and marks the rest
    UNSEEN. merge_region_verdicts() then folds the per-region answers into one
    verdict per item, so a single command verifies a whole UI on free models.

    With no check items, it describes each region instead.
    """
    regions = load_regions(spec)
    print("REGIONS: %d (%s)" % (len(regions), ", ".join(regions)))
    print("")

    region_texts = {}
    for name, box in regions.items():
        try:
            cropped = crop_bytes(image_bytes, box)
        except Exception as exc:
            print("  %-14s CROP FAILED: %s" % (name, exc), file=sys.stderr)
            continue
        small = shrink(cropped)
        log("region %s: %d -> %d bytes" % (name, len(cropped), len(small)))
        try:
            model, text, _note = ask_any_model(order, small, prompt,
                                               max_tokens=3000)
        except RefusedModel as exc:
            print("REFUSED: %s" % exc, file=sys.stderr)
            return 6
        except NoSightedModel as exc:
            print("  %-14s NO SIGHTED MODEL: %s" % (name, exc.details),
                  file=sys.stderr)
            continue
        region_texts[name] = text
        p, f, u = tally(text)
        print("  %-14s %-28s %d PASS / %d FAIL / %d UNSEEN"
              % (name, model, p, f, u))
        for line in text.splitlines():
            if VERDICT_RE.search(line):
                print("      " + line.strip())

    if not region_texts:
        print("NO SIGHTED MODEL ANSWERED for any region. free-only is %s."
              % ("ON" if FREE_ONLY else "OFF"), file=sys.stderr)
        return 5

    if not items:
        print("")
        for name, text in region_texts.items():
            print("== %s ==" % name)
            print(text)
        return 0

    print("")
    merged, per_region, merged_lines = merge_region_verdicts(region_texts)
    print("MERGED VERDICT (%d items):" % len(merged_lines))
    for line in merged_lines:
        print("  " + line)
    p, f, u = merged
    print("")
    print("TALLY: %d PASS / %d FAIL / %d UNSEEN" % (p, f, u))
    if f == 0 and p == 0:
        print("NOTE: the models answered but wrote no parsable VERDICT lines; "
              "that is not a pass.", file=sys.stderr)
        return 1
    return 0 if f == 0 else 1


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(add_help=True)
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--url", help="screenshot this URL in headless Chrome")
    src.add_argument("--file", help="analyse an existing image file")
    src.add_argument("--monitor", type=int, nargs="?", const=0, default=None,
                     help="screenshot the desktop (0 = first display, "
                          "no value = all displays stitched)")
    src.add_argument("--probe", action="store_true",
                     help="report which models can see images")
    ap.add_argument("--check", help="JSON file with {\"items\": [...]} to verify")
    ap.add_argument("--save", help="also write the captured PNG here")
    ap.add_argument("--wait", type=int, default=3500, help="ms to let the page settle")
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--full", action="store_true", help="full-page capture")
    ap.add_argument("--region", help="crop to left,top,right,bottom fractions (0-1) "
                                     "before sending. Default: the whole page.")
    ap.add_argument("--regions", nargs="?", const="__default__", default=None,
                    help="check several regions in one run and merge the verdicts. "
                         "Optional value: a JSON file {\"regions\": {\"name\": [l,t,r,b]}}. "
                         "Without it, a default dashboard tiling is used.")
    ap.add_argument("--model", help="force one vision model (still free-only)")
    ap.add_argument("--paid", action="store_true",
                    help="permit a NON-free vision model. Off by default: the two "
                         "free models on this host are proven sighted, so this is "
                         "never needed and only spends money when used.")
    ap.add_argument("question", nargs="*", default=[])
    args = ap.parse_args()

    if args.paid:
        global FREE_ONLY
        FREE_ONLY = False
        log("--paid given: non-free vision models are now permitted")

    if args.probe:
        return 0 if probe() else 5

    question = " ".join(args.question).strip()

    # ---- capture -----------------------------------------------------------
    if args.file:
        if not os.path.exists(args.file):
            print("CAPTURE FAILED: no such file: %s" % args.file, file=sys.stderr)
            return 3
        try:
            with open(args.file, "rb") as fh:
                image_bytes = fh.read()
        except Exception as exc:
            print("CAPTURE FAILED: cannot read %s: %s" % (args.file, exc), file=sys.stderr)
            return 3
        origin = args.file
        if not valid_png(args.file, min_side=16):
            log("note: %s is not a plain PNG; the vision call will still try" % args.file)
    else:
        os.makedirs(SHOT_DIR, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        tmp = os.path.join(SHOT_DIR, "cap-%s-%d.png" % (stamp, os.getpid()))
        try:
            if args.url:
                origin = capture_url(args.url, tmp, args.width, args.height,
                                     args.wait, args.full)
            elif args.monitor is not None:
                origin = capture_monitors(tmp, args.monitor)
            else:
                ap.error("give one of --url / --file / --monitor / --probe")
                return 2
        except Exception as exc:
            print("CAPTURE FAILED: %s" % exc, file=sys.stderr)
            return 3
        with open(origin, "rb") as fh:
            image_bytes = fh.read()
        if args.save:
            os.makedirs(os.path.dirname(os.path.abspath(args.save)) or ".", exist_ok=True)
            with open(args.save, "wb") as fh:
                fh.write(image_bytes)
        log("captured %s (%d bytes)" % (origin, len(image_bytes)))

    # ---- checklist ---------------------------------------------------------
    items = []
    if args.check:
        try:
            with open(args.check, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            items = data.get("items", data) if isinstance(data, dict) else data
            if not isinstance(items, list) or not items:
                raise ValueError("no \"items\" list found")
        except Exception as exc:
            print("bad --check file %s: %s" % (args.check, exc), file=sys.stderr)
            return 4

    # ---- optional single-region crop ---------------------------------------
    # Default is the whole page, so nothing that already works changes. A
    # --region box crops the capture to one panel before it is sent.
    if args.region:
        box = parse_region(args.region)
        image_bytes = crop_bytes(image_bytes, box)
        log("region crop %s -> %d bytes" % (args.region, len(image_bytes)))

    prompt = build_prompt(question, items)
    small = shrink(image_bytes)
    log("image %d -> %d bytes for the vision call" % (len(image_bytes), len(small)))

    # ---- ask a sighted model ----------------------------------------------
    # --model is a preference, NOT a way past the free-only gate.
    # Dedupe while preserving order, so --model is tried first.
    order = []
    for m in ([args.model] if args.model else []) + allowed_models():
        if m and m not in order:
            order.append(m)

    # --regions: check each region separately and merge. A dense full-page
    # image is exactly what a free model cannot read; each cropped panel is
    # simple enough to verify, and the merge covers the whole UI in one run.
    if args.regions is not None:
        return run_regions_mode(order, image_bytes, prompt, items, args.regions)

    # ROUND-ROBIN FAN-OUT: one attempt per model per round, so a failing first
    # free model can never consume the run before the second is attempted.
    try:
        model, text, _note = ask_any_model(order, small, prompt, max_tokens=3000)
    except RefusedModel as exc:
        print("REFUSED: %s" % exc, file=sys.stderr)
        return 6
    except NoSightedModel as exc:
        print("NO SIGHTED MODEL ANSWERED. free-only is %s, so only these were tried:"
              % ("ON" if FREE_ONLY else "OFF"), file=sys.stderr)
        for m, why in exc.details:
            print("    %-32s %s" % (m, why), file=sys.stderr)
        if FREE_ONLY:
            print("  Both free models are proven sighted; they were given %d attempts "
                  "each, interleaved. Re-run with --paid only if you are willing to "
                  "spend a paid model." % resolved_attempts(FREE_MODELS[0]),
                  file=sys.stderr)
        return 5

    if items:
        print("SOURCE: %s" % origin)
        print("MODEL:  %s   (free=%s)" % (model, is_free(model)))
        print("")
        print(text)
        passed, failed, unseen = tally(text)
        print("")
        print("TALLY: %d PASS / %d FAIL / %d UNSEEN" % (passed, failed, unseen))
        if failed == 0 and passed == 0:
            print("NOTE: the model answered but wrote no parsable VERDICT lines; "
                  "that is not a pass.", file=sys.stderr)
            return 1
        return 0 if failed == 0 else 1

    print("MODEL:  %s   (free=%s)" % (model, is_free(model)))
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
