# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## The app (`CaddyApp/`)

A native SwiftUI Mac app (see BRD). No Python, ffmpeg or other tools are needed; the old Python web app was removed (it's in git history). Open `CaddyApp/Caddy.xcodeproj`. Swift 6, default actor isolation `MainActor`, macOS 26.2+, folder-synced group, so every file in `CaddyApp/Caddy/` is compiled. `Info.plist` sits outside that folder and declares the `.caddy` package type (`andreasthoma.caddy.document`).

- `CaddyApp.swift`: one `Window` holding `LibraryView` (sidebar of projects and scripts), menu commands, and `VideoFile` (mp4/mov/m4v; AVFoundation can't read MKV or AVI)
- `Model/Library.swift`: the local library in `~/Library/Application Support/Caddy`: `library.json` (projects, names) and one `.caddy` package per script
- `Model/Script.swift`: reads and writes a `.caddy` package holding `script.json`; `Script`, `ScriptRow`, `Timecode`, `Script.sample`
- `Model/Playback.swift`: per-window `AVPlayer`, current time, segment playback
- `Model/Thumbnails.swift`: `AVAssetImageGenerator` frame grabs, cached in memory
- `Model/Export.swift`: `ExportOptions` and `ExportDocument` (title, folder, details, sections, logo): Frame and Script columns, one row per section, each element in order with its label (SCENE, VO, SUPER, SFX, MUSIC, DISCLAIMER), keeping bold, italic and underline. Empty elements are always left out, scene descriptions and suggestions unless included. `Exporter.frames` grabs 1280 px JPEGs off the main actor; `Exporter.logo` renders the frog logo (`FrogLogo` in the asset catalog, an SVG from Figma node 423:2396) as a white-on-black tile PNG
- `Model/DocxWriter.swift`: an Apple-style document. US Letter, 0.75" sides, BentonSansF throughout, named on every run since Pages and Quick Look ignore the document default (Word names it by legacy family: `BentonSansF Book` for regular, italic and bold, `BentonSansF Medium` for medium). Apple greys (#1D1D1F, #6E6E73, #86868B, hairlines #D2D2D7). Laid out to match the team's Pages template (`Uber Eats Ding Dong Deals Script.pages`): the folder as a 25 pt bold title (the script's name when it has no folder), the video's name under it in grey. No grid: small grey "Frame" and "SCRIPT" labels (cased as the template has them) over a hairline, repeated on each page, then hairlines between sections; cells padded 4 pt. Each section's number and timecode sit above its frame, which has rounded corners; script lines are `LABEL: text` with the label bold, 10 pt. The footer has the script's name and page number left in 10 pt, and the frog tile (white on black, 55 pt) anchored to the bottom edge of the page on the right margin. Run, paragraph and table properties follow the schema's element order, which Word holds to. Fonts aren't embedded, so a reader without BentonSansF sees a substitute
- `Model/IssueReport.swift`: Help › Report an issue… (`ReportIssueSheet`) posts a report to `CaddyReportURL` in Info.plist; the Netlify relay in `relay/` files it as a GitHub issue. Never sends scripts, frames or videos
- `Model/ZipWriter.swift`: stores entries uncompressed, so the `.docx` needs no dependency
- `Model/PDFWriter.swift`: Core Graphics PDF drawn top down with AppKit text (Helvetica Neue 9 pt); a section never splits across pages
- `Model/Analyzer.swift`: runs scene detection, on-screen text reading, then transcription, writing suggested rows, supers and VO into the script as results arrive; re-applies sensitivity to saved scores
- `Model/SceneDetector.swift`: per-frame score = share of 5×5 px blocks (160 px wide frame) whose change jumps more than 10 grey levels above their 12-frame median. Cut ≈ 0.7, full-screen graphic ≈ 0.25, super ≈ 0.03. Sensitivity 0 to 1 maps to threshold 0.3 to 0.005 (default 0.73 ≈ 0.015). Scores are saved in the document
- `Model/ScreenTextReader.swift`: Vision text recognition for supers, sampled every 0.5 s plus just after each candidate scene change. Each frame is read at full and quarter size (text taller than 8% of the frame from the quarter pass, which reads large display type that full size drops). Stacked pieces under 5× apart in height join into one block. Per row, reads are de-duplicated on letters and digits, merged reads (containing two other reads) and partial reads are dropped. In-scene text such as signage is read too. Samples are saved in the document
- `Model/VoiceoverTranscriber.swift`: SpeechTranscriber with per-word times; VO is aligned a sentence at a time to the row it overlaps most. Accepted rows keep their VO
- `Views/`: `LibraryView`, `DocumentView` (toolbar, status, layout), `ScriptSheet`, `InspectorView` (uses `AVPlayerView`; SwiftUI `VideoPlayer` crashes with the Xcode 27.1 SDK), `FilmstripView`, `ExportSheet` (format, template and what to include, a page sketch, then a save panel; grabs frames, writes the file and closes, or says why it couldn't save)

Model types are `nonisolated` so `FileDocument` can read and write them off the main actor. Detection and transcription are `@concurrent` and take a URL, since `AVAsset` isn't `Sendable`. Frame times get `Playback.frameNudge` (1 ms) before conversion to `CMTime`, or grabs can land on the previous frame.

Test ad: `~/Documents/Work/frog/HRB-MaxYourTax_Hero_16x9_15_OP59-v09.mp4` (15 s). Expected frames at the default sensitivity: 0, 7.08, 9.24, 10.92, 13.12, 14.08. Expected supers: "Don't tax yourself" (10.92), "MAX YOUR TAX" (13.12), "H&R BLOCK® / IN-OFFICE | ONLINE" (14.08); "H&R BLOCK®" at 9.24 and 10.92 is the wall sign.

## Imported Claude Cowork project instructions
