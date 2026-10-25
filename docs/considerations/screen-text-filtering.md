# Filtering in-scene text from supers

Status: under consideration, not planned.

Signage and other background text get suggested as supers. The only filter today is Vision confidence ≥ 0.3 (`ScreenTextReader.swift`), and signage is often read confidently, so a confidence slider won't help.

## Option A: overlay score with a slider

Score each read on how much it looks like an overlay:

- Stays in the same place across samples while the picture changes.
- Upright and flat (Vision's corners show no skew or perspective).
- Appears on its own scene change, not with a cut.
- Doesn't recur across many sections.

A slider over that score re-applies to saved samples, like scene Sensitivity. Needs each read's box saved in `ScreenText`; existing documents need their text read again.

## Option B: dismiss everywhere (cheap)

Dismissing a screen suggestion dismisses the same text (normalised) in every section. Doesn't fix detection, but clears a recurring sign in one click.
