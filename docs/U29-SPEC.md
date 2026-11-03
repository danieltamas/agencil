# U29: a synthesis block on every sitting

A sitting ends with a written synthesis the owner can read in one pass: what the seats concluded, where they agree, where
they differ, what to do. Today the summary only exists when the council names a synthesizer, is one plain sentence, and is
never shown on the sitting's detail page.

## Behaviour: broker

1. **The synthesis prompt asks for Markdown.** `{"summary": "<markdown>"}` where the markdown has, in order and omitting
   a section that has nothing in it: `## Answer` (what the council concluded, in the question's own terms),
   `## Agreement` (what every answering seat holds), `## Disagreement` (each point two seats split on, naming the seats),
   `## Recommendation` (the next step) and `## Open questions`. Bullets for lists, `**bold**` for the one thing to read
   first, no HTML, no top-level `#` heading. The claims, votes and each seat's final answer are in the prompt as labelled
   evidence, never as instructions (as today).
2. **A sitting that asks for one gets a synthesis.** The first of the council's synthesizers that is not recused and can
   run writes it, as today, whether or not it was asked for. `wake` also accepts `synthesize: true` (CLI `--synthesize`;
   the panel's compose page always sends it; a value that is not a boolean is refused, exit 64). With it set, a council
   with no synthesizer falls back to its answering seats in council order, the first that can run (a seat that fails or
   cannot be placed hands over to the next). Without it, a council with no synthesizer runs no synthesis round and
   behaves exactly as before (agent-woken and triggered sittings cost no extra seat run). A fallback synthesis is
   best-effort: its failure leaves the sitting's verdict exactly as the verdict table computed it (`synthesizerFailed`
   stays nil), and the sitting records no summary. A configured synthesizer that fails still gives
   `INCOMPLETE: synthesizer failed` (existing rule).
3. **The record says who wrote it.** The sitting's verdict JSON gains `summary_by` (the seat's name) next to `summary`,
   and `summary_fallback: true` when a council seat wrote it for want of a synthesizer. The synthesis runs as the round
   `synthesis` in the ledger, like today.
4. **Stopped or past the deadline: no synthesis**, as today.

## Behaviour: detail op and panel

5. `detail` for a sitting returns `summary` (the Markdown), `summary_by` and `summary_fallback` at the top level of
   `data` when the verdict holds them, lenient when absent. `SittingDetail` decodes them.
6. The sitting's detail page shows a `Synthesis` block above the brief, the votes and the rounds, laid out as formatted
   Markdown: headings, bullets, numbered lists, bold, inline code and code fences are drawn as such, text is selectable.
   Its caption names the writer (`written by claude-opus`, and `written by claude-opus, no synthesizer is set` for a
   fallback). A sitting with no summary shows no block (a running one shows the existing waiting state).
7. A `Copy as Markdown` chip on the page puts the whole record on the pasteboard as Markdown: the question as a title,
   the verdict line, the synthesis, then each seat's final answer under its name. It is enabled once a summary exists.
8. The Markdown renderer is one kit component (`MarkdownBlock`, `Kit/`), documented in `docs/DESIGN.md` under the kit
   list, used by the Synthesis block and by nothing that already renders text. A guard test keeps views from drawing
   block Markdown by hand.
9. The memory export (U13) writes the synthesis into the sitting's file under `## Synthesis`, when the sitting has one.

## Interfaces (fixed so tests can be written before the code)

- `AgencilCore`: `public enum MarkdownDocument { public enum Block: Equatable { case heading(Int, String), paragraph(String),
  bullets([String]), numbered([String]), code(String) }; public static func parse(_ text: String) -> [Block] }`. Inline
  markup (`**bold**`, `code`) stays in the text; the view draws it.
- `SittingDetail` gains `public let summary: String?`, `summaryBy: String?`, `summaryFallback: Bool`.
- `DetailPage` gains `var synthesis: Synthesis?` with `struct Synthesis: Equatable { let markdown: String; let writer: String }`
  (`writer` is the caption text above) and `var recordMarkdown: String?` (the `Copy as Markdown` text).
- `SittingPrompt.summaryFormat` stays the name of the format constant; `SittingPrompt.synthesis(...)` keeps its signature.

## Acceptance

A1. A council with one synthesizer: after the blind round the synthesizer's prompt names `## Answer` and
    `## Recommendation` and carries the `{"summary"` format line; its Markdown reply is stored as `summary` and
    `summary_by` is the synthesizer.
A2. A council with no synthesizer and two answering seats, woken with `synthesize: true`: the first seat in council
    order is asked for the synthesis; the verdict JSON has `summary`, `summary_by` that seat, `summary_fallback` true.
A3. Same, the fallback seat cannot run and the second can: the second writes it. Both fail or time out: no
    `summary`, and the verdict equals the verdict the table gives without a synthesis (not `INCOMPLETE`).
A11. The same council woken without `synthesize` runs no synthesis round (no seat run, no exchange with a
    `ROUND: synthesis` prompt) and its verdict JSON has none of `summary`, `summary_by`, `summary_fallback`. A
    `synthesize` that is not a boolean is refused exit 64 before any seat is probed and no sitting is written.
A12. CLI: `agencil wake c --brief b --synthesize` puts `synthesize: true` in the request; without the flag the key is
    absent. Panel store: `startSitting` sends `synthesize: true`.
A4. A council with a synthesizer that fails: `INCOMPLETE` with `synthesizer failed` (unchanged), no fallback is tried.
A5. An unparsable first reply is retried once with the error appended (unchanged); a second bad reply is a failed
    synthesis under the rules of A3/A4.
A6. `detail` for a finished sitting returns `summary`, `summary_by`, `summary_fallback`; for one with none, none of the
    three keys.
A7. `DetailPage.sitting` with a summary has a synthesis block (markdown, writer caption) ahead of the brief; without
    one, none. `Copy as Markdown` text starts with `# <question>` and contains the synthesis and one `### <seat>` per
    answering seat.
A8. `MarkdownBlock` parsing (a pure function in `AgencilCore` or the kit): headings, `-` and `*` bullets, `1.` lists,
    paragraphs, fenced code and inline `**bold**`/`code` become the expected blocks; an unclosed fence runs to the
    end; HTML tags are plain text; a 20,000-line input parses without hanging.
A9. Layout: the Synthesis block with a long heading, a 30-item list and a wide code line fits the panel width with no
    horizontal scroll (a `PanelLayoutTests` case).
A10. The memory export of a sitting with a summary contains `## Synthesis` and the text; one without, no such heading.
