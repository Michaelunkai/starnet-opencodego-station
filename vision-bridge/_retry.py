import io
p = "see.py"
s = io.open(p, encoding="utf-8").read()

old = """def ask_sighted(model, image_bytes, prompt, attempts=4, timeout=180, max_tokens=1200):"""
new = """def ask_sighted(model, image_bytes, prompt, attempts=None, timeout=180, max_tokens=1200):"""
assert old in s
s = s.replace(old, new, 1)

# more attempts, and treat an EMPTY body as retryable noise rather than a final answer
old2 = """        if not text.strip():
            if attempt < attempts:
                time.sleep(2)
                continue
            raise RuntimeError("empty answer from " + model)"""
new2 = """        if not text.strip():
            # An EMPTY BODY IS NOISE, NOT AN ANSWER. The free models return one
            # intermittently on a large screenshot, and treating that as a final
            # result is how a verification tool silently stops verifying. Retry it,
            # and only give up after every attempt has come back empty.
            if attempt < attempts:
                time.sleep(2 + attempt * 2)
                continue
            raise RuntimeError("empty answer from " + model + " after %d attempts" % attempts)"""
assert old2 in s
s = s.replace(old2, new2, 1)

# default the attempt budget from the model class
old3 = """    blind = None
    for attempt in range(1, attempts + 1):"""
new3 = """    blind = None
    if attempts is None:
        # The free models are the ones that flake, and they are the ones we are
        # required to use, so they get the deeper retry budget. A paid model that
        # answers is not worth waiting on.
        attempts = 8 if model in FREE_MODELS else 4
    for attempt in range(1, attempts + 1):"""
assert old3 in s
s = s.replace(old3, new3, 1)

# longer backoff on transient upstream errors
old4 = """                wait = 3 * attempt"""
new4 = """                wait = min(20, 3 * attempt)"""
assert old4 in s
s = s.replace(old4, new4, 1)

io.open(p, "w", encoding="utf-8", newline="").write(s)
print("free path hardened: 8 attempts, empty body is retryable noise, capped backoff")
