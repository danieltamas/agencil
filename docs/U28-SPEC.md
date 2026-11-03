# U28: paste an image into a manual sitting

Builds on U27. The owner pastes a screenshot from the clipboard into the New sitting form; Claude and Codex seats see
it natively, every other seat is told an image was attached and not shown.

Owner decision (2026-11-03): vision seats only. Verified by hand: `claude -p` reads an image file named by absolute
path with its Read tool; `codex exec -i <file> -- <prompt>` shows the image to the model.

## Behaviour: panel

1. The New sitting form takes an image from the clipboard two ways: Cmd-V while the form is focused when the
   pasteboard holds an image and no text, and a `Paste image` chip button that reads the pasteboard on press. With no
   image on the pasteboard the button says so in the form's problem line and does nothing else.
2. A pasted image is converted to PNG and saved as `<home>/attachments/<uuid>.png` (`attachments` mode 0700, the file
   0600; `<home>` is `~/.agencil` or `$AGENCIL_HOME`) and its path joins the draft's `files`: it counts toward the 8 and
   shows as a chip `Pasted image N` with a remove control (like a picked file). A ninth image is refused in the problem
   line. Data that is not an image is refused the same way.
3. Removing a pasted image deletes its file. Closing the form without starting deletes every pasted image of the draft.
   After Start succeeds the pasted files are deleted (the broker has read them). A refusal keeps them.

## Behaviour: broker

4. In `wake` `files`, a path whose first bytes are a PNG, JPEG, GIF or WebP signature is an image, not text: it is
   never decoded as text and never put in a prompt as text. At most 10 MB each and 20 MB in all, read at wake time and
   held for the sitting, so the file may be deleted afterwards. Over either limit, or an unreadable image: exit 64
   `image too large: <path>` / `cannot read <path>`, before any seat is probed or any run written. The stored brief
   keeps one `file: <path>` line per image (path only).
5. `ask --file <image>` is refused, exit 64, `images attach to a wake, not an ask: <path>`.
6. Per seat, when a round's prompt is built:
   - `claude`: the image is written to `<run directory>/images/<n>.<ext>` (mode 0600) and the prompt gains
     `IMAGE FILE <absolute path> (an attached image; open it with your Read tool)` after the question and text files.
   - `codex`: the same file is written and the argv gains `-i <path>` for each image and `--` before the prompt.
   - every other harness, and ollama: the prompt gains `IMAGE <n>.<ext>: attached, not shown to this seat` per image;
     no image bytes reach the process.
   Hosted-seat redaction does not apply to an image the owner attached on purpose; a local-only council or route still
   refuses hosted seats before this step.
7. When any seat of the council cannot see images, the stored brief gains `images_not_shown: <seat>, <seat>` (the
   council's configured seats and spares of other harnesses); the sitting's detail page shows it with the brief.

## Acceptance

B1. wake with a PNG in `files`, council with a claude stub seat: the seat's prompt carries `IMAGE FILE <path>` where the
    path exists inside the seat's run directory at launch and holds the PNG's bytes; the prompt has no PNG bytes.
B2. Same with a codex stub seat: the argv has `-i <path>` and `--` immediately before the prompt; the file holds the
    PNG's bytes. A wake with no image leaves the codex argv unchanged (no `-i`, no `--`).
B3. A hermes or opencode stub seat gets `IMAGE <n>.png: attached, not shown to this seat` and nothing else about it.
B4. An image over 10 MB, or images over 20 MB together, exit 64 `image too large`, no sitting, no seat started.
B5. A text file still inlines as before; a file that merely has a `.png` extension but text bytes inlines as text.
B6. `ask` with an image path exits 64 with the refusal above and starts no seat.
B7. The stored brief has a `file:` line for the image and `images_not_shown:` naming the non-vision seats; absent when
    every seat is claude or codex.
B8. Panel store: `attachImage(_ data: Data)` with PNG data writes a 0600 `.png` in a 0700 `attachments` directory under
    the store's attachments root and appends its path to `compose.files`; TIFF data is converted to PNG; non-image data
    sets the problem and adds nothing; a ninth image is refused. `detachFile` deletes the file. `closeCompose` deletes the
    draft's pasted files and leaves picked files alone. A successful start deletes the pasted files, a refusal keeps them.
B9. Layout: a form with 8 pasted images and a long question fits the panel (as U27 A10).
