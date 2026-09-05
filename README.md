# contract-export-pdf

Export the NMS Prime Confluence contract tree to one merged PDF. German is the default; English uses the same options on a parallel page tree.

The script walks the root page and all descendants in sidebar order. For each page it either:

- exports a linked public Google Doc,
- converts a Word/PDF attachment, or
- prints the Confluence HTML with headless Chrome

and then merges the parts with `pdfunite`.

Default root: [German](https://nmsprime.atlassian.net/wiki/spaces/NMS/pages/8533089/German) (`8533089`).  
English root: [English](https://nmsprime.atlassian.net/wiki/spaces/NMS/pages/8533093/English) (`8533093`), via `--lang en`.

## Dependencies

`curl`, `python3`, `pdfunite` (poppler-utils), and Chrome/Chromium. LibreOffice is only needed to convert Word/ODT attachments.

## Usage

```bash
./export-confluence-pdf.sh
./export-confluence-pdf.sh --out ./contracts.pdf
./export-confluence-pdf.sh --lang en --out ./contracts-en.pdf
```

### Customer-specific page

Swap one page’s content (for example Leistungsschein) but keep the original child pages:

```bash
./export-confluence-pdf.sh --leistungsschein 1192067073 --out ./stadtwerker.pdf
./export-confluence-pdf.sh --replace avv=111 --replace hbv=222
```

`--leistungsschein` is a shortcut for `--replace leistungsschein=…` (English title: Service Agreement).  
`--replace SLOT=PAGE` can be repeated. `SLOT` is a page id, title, or alias (`leistungsschein` / `service-agreement`, `agb` / `gtc`, `eula`, `hbv` / `all`, `pt`, `abnahme`, `avv` / `dpa`, `tom`). `PAGE` is a page id or Confluence URL.

### Cloud / On-Prem / Hardware-Support

In Confluence, tag **headings** or **single lines** with `[Cloud]`, `[On-Prem]`, or `[Hardware-Support]` (any capitalization).

```bash
./export-confluence-pdf.sh --type cloud
./export-confluence-pdf.sh --type on-prem --no-hw-support
./export-confluence-pdf.sh --leistungsschein 1192067073 --type cloud --out ./stadtwerker.pdf
```

- `--type cloud` or `--type on-prem` — drop the other variant’s **plain lines**. Cancelled **headings** stay as a light-gray stub so numbering remains (`2.3. entfällt bei Cloud`, or `2.3. omitted for Cloud` with `--lang en`).
- `--no-hw-support` — same for `[Hardware-Support]`; cancelled headings become `3.1. entfällt` / `3.1. omitted`.
- Kept tags are unwrapped: `[Cloud]-Usage` → `Cloud-Usage`.

HTML pages only (Leistungsschein, etc.). Google-Doc pages (AGB, AVV) are not filtered.

Without `--type` / `--no-hw-support`, all sections stay and tags stay visible.

### Other options

| Option | Meaning |
|---|---|
| `--lang de\|en` | German (default) or English contract tree |
| `--page-id ID` | Start at this page (overrides `--lang` root) |
| `--url URL` | Same, parsed from a Confluence URL |
| `--base-url URL` | Wiki base (default `https://nmsprime.atlassian.net/wiki`) |
| `--out FILE` | Output PDF (default: `./<root-title>_merged.pdf`) |
| `--keep-parts` | Also keep the individual page PDFs |
| `-h` / `--help` | Show usage |

### Non-public spaces

```bash
export CONFLUENCE_EMAIL=you@example.com
export CONFLUENCE_API_TOKEN=...
```
