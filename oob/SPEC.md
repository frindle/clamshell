# Out-of-band unlock — build spec

This is the task specification for the clamshell out-of-band access component.
The verifiers in this directory are the contract: implement against them.

Nothing here needs a Raspberry Pi. Both modules are pure functions, and both
are the parts that are dangerous to get wrong.

## Background

clamshell cannot reach the macOS lock screen, the login window, or FileVault
pre-boot — no software agent can, without pre-login privileges. The plan is a
Raspberry Pi Zero 2 W acting as a **USB HID gadget only**: clamshell shows its
own username/password form and the Pi types the keystrokes. There is no video
capture, so there are no resolution constraints and the Mac's screen never
leaves the Mac.

The trade is that we are typing blind, which makes the two modules below the
whole safety story.

## Module 1 — `hid_report.py`

Convert a string into USB HID keyboard reports.

A HID keyboard report is 8 bytes: `[modifiers, 0x00, k1, k2, k3, k4, k5, k6]`.
We only ever press one key at a time, so `k2..k6` stay `0x00`.

Required functions:

```python
encode_char(ch: str) -> tuple[int, int]      # (modifier_byte, usage_code)
encode_string(s: str) -> list[bytes]         # full report sequence
```

Rules that the tests pin, and that are easy to get wrong:

- Lowercase `a`–`z` are usage codes `0x04`–`0x1d`, no modifier.
- Uppercase letters are the SAME usage code with left-shift (`0x02`) set.
- Digits `1`–`9` are `0x1e`–`0x26`; **`0` is `0x27`**, after `9`, not before `1`.
- Symbols requiring shift (`!@#$%^&*()_+{}|:"<>?~`) set `0x02` and use the
  usage code of the unshifted key on the same physical key.
- **A key-up report (`8 × 0x00`) must be emitted between two identical
  consecutive characters.** Without it the host coalesces them and `aa` types
  as `a`. This is the single most common defect in this kind of code.
- A key-up report must also terminate the sequence, so no key is left held.
- Unsupported characters raise `ValueError` rather than silently emitting
  nothing — a password that types wrong is worse than one that refuses.

## Module 2 — `unlock_policy.py`

Decide whether to send keystrokes, given what is known about the Mac.

```python
decide(agent: str | None, ssh_up: bool, hdmi_signal: bool | None) -> Decision
```

`agent` is `"unlocked"`, `"locked"`, or `None` (unreachable).

| agent | ssh | meaning | action |
|---|---|---|---|
| `"unlocked"` | any | logged in, session live | **send nothing** |
| `"locked"` | any | lock screen, known state | send password |
| `None` | up | login window | send username, Tab, password |
| `None` | down, hdmi signal | FileVault pre-boot | send password |
| `None` | down, no signal | powered off | send nothing |
| `None` | down, hdmi unknown | ambiguous | send nothing |

The first row is the one that matters. Injecting a password into an unlocked
desktop types it into whatever holds focus — a terminal, a chat window, a
shared screen. **When in doubt, send nothing.** A refused unlock costs a walk
to the machine; a leaked password costs a credential rotation.

`Decision` exposes `.send` (bool), `.keys` (list of field names to type, in
order) and `.reason` (a short string suitable for showing the user).

## Running the verifiers

```
cd "/Users/penn/Desktop/GitHub Projects/clamshell/oob"
python3 -m unittest discover -s tests -v
```

Both test files must pass unmodified. They import from `hid_report.py` and
`unlock_policy.py` in this directory; neither module exists yet.
