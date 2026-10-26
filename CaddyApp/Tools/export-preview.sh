#!/bin/zsh
# Builds the Word export of a library script without the app, renders it to
# PDF in Pages and lays every page out on one PNG. --quicklook renders the
# first page as Finder previews it instead. (Word's AppleScript "save as"
# fails with -1708 in Word 16.114, so Word can't render it here.)
#
#   CaddyApp/Tools/export-preview.sh [name] [--quicklook] [--open]
#
# name matches a library script (the most recently modified match, or the most
# recent script with no name). Output is in build/export-preview/.

set -e
cd "${0:A:h}/../.."
out="$PWD/build/export-preview"
mkdir -p "$out"

name="" renderer=pages open=0
for arg in "$@"; do
  case $arg in
    --quicklook) renderer=quicklook ;;
    --open) open=1 ;;
    *) name=$arg ;;
  esac
done

# Rebuild only when a model file or the tool changed.
tool="$out/ExportPreview"
sources=(CaddyApp/Caddy/Model/*.swift CaddyApp/Tools/ExportPreview/main.swift)
if [[ ! -x $tool || -n $(find $sources -newer $tool) ]]; then
  swiftc -Onone -swift-version 6 -target arm64-apple-macos26.2 \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature MemberImportVisibility \
    $sources -o "$tool"
fi

rm -f "$out/Export.docx" "$out/Export.pdf" "$out/Export.png"
"$tool" docx "$name" "$out/Export.docx"

case $renderer in
  pages)
    osascript <<EOF
tell application "Pages"
  set d to open POSIX file "$out/Export.docx"
  export d to POSIX file "$out/Export.pdf" as PDF
  close d saving no
end tell
EOF
    ;;
  quicklook)
    # First page only, as Finder previews it.
    qlmanage -t -s 1600 -o "$out" "$out/Export.docx" >/dev/null
    mv "$out/Export.docx.png" "$out/Export.png"
    ;;
esac

[[ -f $out/Export.pdf ]] && "$tool" png "$out/Export.pdf" "$out/Export.png"
echo "$out/Export.png"
(( open )) && open "$out/Export.png"
exit 0
