#!/usr/bin/env bash
# Export a public Confluence page tree to one merged PDF.
#
# - Walks the root page and all descendants (depth-first, sidebar order)
# - If a page is mainly a public Google Docs link, exports that Doc as PDF
# - If a page mainly embeds a Word/PDF attachment (view-file), converts that
# - Otherwise renders the Confluence HTML via headless Chrome
# - Merges parts with pdfunite
#
# Usage:
#   ./export-confluence-pdf.sh
#   ./export-confluence-pdf.sh --page-id 8533089
#   ./export-confluence-pdf.sh --url 'https://nmsprime.atlassian.net/wiki/spaces/NMS/pages/8533089/German'
#   ./export-confluence-pdf.sh --out /tmp/german-contracts.pdf
#
# Replace one page's content but keep that page's original children:
#   ./export-confluence-pdf.sh --leistungsschein 987654321
#   ./export-confluence-pdf.sh --replace leistungsschein=987654321
#   ./export-confluence-pdf.sh --replace avv='https://nmsprime.atlassian.net/wiki/spaces/NMS/pages/111/AVV-Kunde'
#
# --replace SLOT=PAGE can be repeated. SLOT is a page id, page title, or alias
# (leistungsschein, agb, eula, hbv, pt, abnahme, avv, tom). PAGE is a page id
# or Confluence URL. Child pages stay on the original tree page.
#
# Drop/cancel tagged blocks (HTML pages only). Cancelled headings stay as a
# light-gray stub "2.3. entfällt bei On-Prem" at the original heading size;
# tagged plain lines are removed:
#   ./export-confluence-pdf.sh --type cloud
#   ./export-confluence-pdf.sh --leistungsschein 1192067073 --type on-prem
#   ./export-confluence-pdf.sh --no-hw-support
#
# Optional auth for non-public spaces:
#   export CONFLUENCE_EMAIL=you@example.com
#   export CONFLUENCE_API_TOKEN=...

set -euo pipefail

BASE_URL="${CONFLUENCE_BASE_URL:-https://nmsprime.atlassian.net/wiki}"
PAGE_ID="8533089"
OUT_FILE=""
KEEP_PARTS=0
CHROME_BIN=""
CONTRACT_TYPE=""
NO_HW_SUPPORT=0
declare -A PAGE_REPLACEMENTS=()

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

parse_page_ref() {
  local ref="${1:?}"
  if [[ "${ref}" =~ /pages/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "${ref}" =~ ^[0-9]+$ ]]; then
    echo "${ref}"
  else
    echo "Could not parse page id from: ${ref}" >&2
    exit 1
  fi
}

parse_contract_type() {
  local raw
  raw="$(printf '%s' "${1:?}" | tr '[:upper:]' '[:lower:]')"
  raw="${raw//_/-}"
  raw="${raw// /-}"
  case "${raw}" in
    cloud) echo cloud ;;
    on-prem|onprem|on-premise|onpremise|on-premises|onpremises) echo on-prem ;;
    *)
      echo "Unknown --type '${1}'. Use cloud or on-prem." >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --page-id) PAGE_ID="${2:?}"; shift 2 ;;
    --url)
      PAGE_ID="$(parse_page_ref "${2:?}")"
      shift 2
      ;;
    --base-url) BASE_URL="${2:?}"; shift 2 ;;
    --out) OUT_FILE="${2:?}"; shift 2 ;;
    --keep-parts) KEEP_PARTS=1; shift ;;
    --type)
      CONTRACT_TYPE="$(parse_contract_type "${2:?}")"
      shift 2
      ;;
    --no-hw-support)
      NO_HW_SUPPORT=1
      shift
      ;;
    --leistungsschein)
      PAGE_REPLACEMENTS[leistungsschein]="$(parse_page_ref "${2:?}")"
      shift 2
      ;;
    --replace)
      spec="${2:?}"
      if [[ "${spec}" != *=* ]]; then
        echo "--replace expects SLOT=PAGE (page id or URL), got: ${spec}" >&2
        exit 1
      fi
      PAGE_REPLACEMENTS["${spec%%=*}"]="$(parse_page_ref "${spec#*=}")"
      shift 2
      ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for cmd in curl python3 pdfunite; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

for candidate in google-chrome chromium-browser chromium google-chrome-stable; do
  if command -v "$candidate" >/dev/null; then
    CHROME_BIN="$(command -v "$candidate")"
    break
  fi
done
[[ -n "$CHROME_BIN" ]] || { echo "Missing Chrome/Chromium for HTML→PDF" >&2; exit 1; }

SOFFICE=""
if command -v soffice >/dev/null; then
  SOFFICE="$(command -v soffice)"
elif command -v libreoffice >/dev/null; then
  SOFFICE="$(command -v libreoffice)"
fi

CURL_AUTH=()
if [[ -n "${CONFLUENCE_EMAIL:-}" && -n "${CONFLUENCE_API_TOKEN:-}" ]]; then
  CURL_AUTH=(-u "${CONFLUENCE_EMAIL}:${CONFLUENCE_API_TOKEN}")
fi

api_get() {
  local path="$1"
  curl -fsSL "${CURL_AUTH[@]}" \
    -H 'Accept: application/json' \
    "${BASE_URL%/}${path}"
}

download() {
  local url="$1" dest="$2"
  curl -fsSL -L -A 'Mozilla/5.0 (compatible; ConfluencePdfExport/1.0)' \
    "${CURL_AUTH[@]}" \
    -o "$dest" "$url"
}

is_pdf() {
  [[ -s "$1" ]] && file -b --mime-type "$1" | grep -qi 'application/pdf'
}

slugify() {
  python3 - "$1" <<'PY'
import re, sys, unicodedata
s = unicodedata.normalize("NFKD", sys.argv[1])
s = "".join(c for c in s if not unicodedata.combining(c))
s = re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("._-")
print(s[:80] or "page")
PY
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/confluence-pdf.XXXXXX")"
PARTS_DIR="${WORKDIR}/parts"
mkdir -p "${PARTS_DIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

REPLACEMENTS_FILE="${WORKDIR}/replacements.txt"
: > "${REPLACEMENTS_FILE}"
if ((${#PAGE_REPLACEMENTS[@]})); then
  for slot in "${!PAGE_REPLACEMENTS[@]}"; do
    printf '%s\t%s\n' "${slot}" "${PAGE_REPLACEMENTS[${slot}]}" >> "${REPLACEMENTS_FILE}"
  done
fi

echo "Working directory: ${WORKDIR}"
echo "Root page id: ${PAGE_ID}"
echo "Base URL: ${BASE_URL}"
if [[ -n "${CONTRACT_TYPE}" ]]; then
  echo "Contract type: ${CONTRACT_TYPE} (dropping opposite [cloud]/[on-prem] headline sections)"
fi
if ((NO_HW_SUPPORT)); then
  echo "Dropping [Hardware-Support] tagged headings and lines"
fi
if ((${#PAGE_REPLACEMENTS[@]})); then
  echo "Page replacements (content only; children stay on the original page):"
  while IFS=$'\t' read -r slot repl; do
    echo "  ${slot} → ${repl}"
  done < "${REPLACEMENTS_FILE}"
fi

# Collect page ids depth-first (sidebar / childPosition order).
PAGE_IDS_FILE="${WORKDIR}/page_ids.txt"
: > "${PAGE_IDS_FILE}"

collect_tree() {
  local id="$1"
  echo "${id}" >> "${PAGE_IDS_FILE}"

  local start=0 limit=50 size=1
  while (( start < size )); do
    local json_file batch_file
    json_file="${WORKDIR}/children.${id}.${start}.json"
    batch_file="${WORKDIR}/children.${id}.${start}.txt"
    api_get "/rest/api/content/${id}/child/page?limit=${limit}&start=${start}" > "${json_file}"
    size="$(python3 - "${json_file}" "${batch_file}" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(
    "\n".join(item["id"] for item in data.get("results", [])) + ("\n" if data.get("results") else ""),
    encoding="utf-8",
)
print(data.get("size", 0))
PY
)"
    local child
    while IFS= read -r child; do
      [[ -z "${child}" ]] && continue
      collect_tree "${child}"
    done < "${batch_file}"

    start=$((start + limit))
  done
}

collect_tree "${PAGE_ID}"
mapfile -t PAGE_IDS < "${PAGE_IDS_FILE}"
echo "Found ${#PAGE_IDS[@]} page(s)"

resolve_export_page_id() {
  local tree_page_id="$1"
  local meta_json_file="$2"
  python3 - "${REPLACEMENTS_FILE}" "${meta_json_file}" "${tree_page_id}" <<'PY'
import json, re, sys, unicodedata
from pathlib import Path

repl_path, meta_path, tree_page_id = sys.argv[1], sys.argv[2], sys.argv[3]
replacements = []
text = Path(repl_path).read_text(encoding="utf-8")
for line in text.splitlines():
    if not line.strip():
        continue
    slot, repl = line.split("\t", 1)
    replacements.append((slot.strip(), repl.strip()))
if not replacements:
    print(tree_page_id)
    raise SystemExit(0)

data = json.loads(Path(meta_path).read_text(encoding="utf-8"))
title = data.get("title") or ""

def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "", s.casefold())

title_n = normalize(title)
prefix_aliases = {"leistungsschein", "abnahme", "eula", "tom"}

for slot, repl in replacements:
    if slot == tree_page_id:
        print(repl)
        raise SystemExit(0)

for slot, repl in replacements:
    slot_n = normalize(slot)
    if not slot_n:
        continue
    if slot_n == title_n or (slot_n in prefix_aliases and title_n.startswith(slot_n)):
        print(repl)
        raise SystemExit(0)

print(tree_page_id)
PY
}

export_page_pdf() {
  local tree_page_id="$1"
  local page_id="$1"
  local index="$2"
  local meta_json_file out_pdf resolved

  meta_json_file="${WORKDIR}/meta.${tree_page_id}.json"
  api_get "/rest/api/content/${tree_page_id}?expand=body.storage,body.view,children.attachment" \
    > "${meta_json_file}"

  resolved="$(resolve_export_page_id "${tree_page_id}" "${meta_json_file}")"
  if [[ "${resolved}" != "${tree_page_id}" ]]; then
    echo "  replace page ${tree_page_id} → ${resolved} (children stay on ${tree_page_id})"
    page_id="${resolved}"
    meta_json_file="${WORKDIR}/meta.${page_id}.json"
    api_get "/rest/api/content/${page_id}?expand=body.storage,body.view,children.attachment" \
      > "${meta_json_file}"
  fi

  python3 - "${meta_json_file}" "${WORKDIR}" "${page_id}" "${CONTRACT_TYPE}" "${NO_HW_SUPPORT}" <<'PY' > "${WORKDIR}/decision.${page_id}.env"
import json, re, sys
from pathlib import Path
from html import unescape

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
workdir = Path(sys.argv[2])
page_id = sys.argv[3]
title = data.get("title") or page_id
storage = data.get("body", {}).get("storage", {}).get("value") or ""
view = data.get("body", {}).get("view", {}).get("value") or ""
attachments = data.get("children", {}).get("attachment", {}).get("results") or []

html_path = workdir / f"{page_id}.html"

def text_only(html: str) -> str:
    html = re.sub(r"(?is)<script.*?>.*?</script>", " ", html)
    html = re.sub(r"(?is)<style.*?>.*?</style>", " ", html)
    html = re.sub(r"(?is)<[^>]+>", " ", html)
    html = unescape(html)
    return re.sub(r"\s+", " ", html).strip()


def storage_link_labels(storage_html: str) -> list[str]:
    """Labels from Confluence storage ac:link macros (document order)."""
    labels: list[str] = []
    for m in re.finditer(r"<ac:link(?:\s[^>]*)?>.*?</ac:link>", storage_html, flags=re.S):
        block = m.group(0)
        body = re.search(r"<ac:link-body>(.*?)</ac:link-body>", block, flags=re.S)
        plain_body = re.search(
            r"<ac:plain-text-link-body><!\[CDATA\[(.*?)\]\]></ac:plain-text-link-body>",
            block,
            flags=re.S,
        )
        content_title = re.search(r'ri:content-title="([^"]+)"', block)
        if body:
            label = unescape(re.sub(r"<[^>]+>", "", body.group(1))).strip()
        elif plain_body:
            label = unescape(plain_body.group(1)).strip()
        elif content_title:
            label = unescape(content_title.group(1)).strip()
        else:
            label = ""
        labels.append(label)
    return labels


def is_wiki_href(href: str | None) -> bool:
    if not href:
        return False
    return bool(
        re.search(r"(?:^|https?://[^/]+)/wiki/(?:spaces/|pages/)", href)
        or href.startswith("/wiki/")
    )


def looks_like_wiki_path_text(text: str, href: str | None) -> bool:
    """True when Confluence fell back to showing the internal path as link text."""
    t = (text or "").strip()
    h = (href or "").strip()
    if not t:
        return True
    if h and t == h:
        return True
    # /wiki/spaces/... or https://x.atlassian.net/wiki/spaces/...
    if re.search(r"(?i)(?:^|https?://[^/\s]+)/?wiki/(?:spaces|pages)/", t):
        return True
    if re.fullmatch(r"/?wiki/\S+", t):
        return True
    return False


def title_from_wiki_href(href: str | None) -> str:
    if not href:
        return ""
    # /wiki/spaces/KEY/pages/123/Some+Title
    m = re.search(r"/pages/\d+/([^?#]+)", href)
    if m:
        from urllib.parse import unquote

        return unquote(m.group(1).replace("+", " ")).strip()
    return ""


def restore_confluence_link_labels(view_html: str, storage_html: str) -> str:
    """
    Non-public page links often render in body.view as '/wiki/spaces/...'.
    Restore the human label from body.storage (ac:link-body / content-title).
    Path-like wiki links become plain text so the PDF keeps readable Confluence wording.
    """
    from html import escape

    labels = storage_link_labels(storage_html)

    # Collect wiki anchors with exact source slices (order-preserving).
    wiki_anchors: list[tuple[int, int, str, str]] = []
    for m in re.finditer(r"(?is)<a\b([^>]*)>(.*?)</a>", view_html):
        attr_blob, inner = m.group(1), m.group(2)
        href_m = re.search(r"""(?i)\bhref\s*=\s*(['"])(.*?)\1""", attr_blob)
        href = unescape(href_m.group(2)) if href_m else ""
        if not is_wiki_href(href):
            continue
        text = unescape(re.sub(r"<[^>]+>", "", inner))
        text = re.sub(r"\s+", " ", text).strip()
        wiki_anchors.append((m.start(), m.end(), href, text))

    replacements: dict[tuple[int, int], str] = {}
    if len(labels) == len(wiki_anchors):
        for label, (start, end, href, text) in zip(labels, wiki_anchors):
            if not looks_like_wiki_path_text(text, href):
                continue
            nice = (label or title_from_wiki_href(href) or text).strip()
            if not nice:
                continue
            # Plain text keeps the Confluence wording; avoids broken private-page URLs.
            replacements[(start, end)] = escape(nice)
    else:
        # Fallback without perfect pairing: only rewrite path-like texts via URL slug.
        for start, end, href, text in wiki_anchors:
            if not looks_like_wiki_path_text(text, href):
                continue
            nice = title_from_wiki_href(href)
            if nice:
                replacements[(start, end)] = escape(nice)

    if not replacements:
        return view_html

    out: list[str] = []
    cursor = 0
    for (start, end), repl in sorted(replacements.items(), key=lambda x: x[0][0]):
        out.append(view_html[cursor:start])
        out.append(repl)
        cursor = end
    out.append(view_html[cursor:])
    return "".join(out)


CONTRACT_TAG_RE = re.compile(
    r"(?i)\[\s*(on[\s_-]*prem(?:ise)?s?|cloud)\s*\]"
)
HW_TAG_RE = re.compile(r"(?i)\[\s*(hardware[\s_-]*support)\s*\]")
ANY_TAG_RE = re.compile(
    r"(?i)\[\s*(on[\s_-]*prem(?:ise)?s?|cloud|hardware[\s_-]*support)\s*\]"
)
HEADING_RE = re.compile(r"(?is)<h([1-6])\b([^>]*)>(.*?)</h\1>")


def heading_plain_text(inner: str) -> str:
    return unescape(re.sub(r"<[^>]+>", " ", inner))


def classify_tags(text: str) -> set[str]:
    tags: set[str] = set()
    for m in ANY_TAG_RE.finditer(text):
        token = re.sub(r"[^a-z]+", "", m.group(1).casefold())
        if token == "cloud":
            tags.add("cloud")
        elif token.startswith("onprem"):
            tags.add("on-prem")
        elif token.startswith("hardwaresupport"):
            tags.add("hw-support")
    return tags


def should_drop_tagged(text: str, keep: str, no_hw: bool) -> bool:
    tags = classify_tags(text)
    if no_hw and "hw-support" in tags:
        return True
    if keep in ("cloud", "on-prem"):
        if "cloud" in tags and keep != "cloud":
            return True
        if "on-prem" in tags and keep != "on-prem":
            return True
    return False


ENTFAELLT_COLOR = "#d0d0d0"
HEADING_NUMBER_RE = re.compile(
    r"(?is)^(\s*(?:<[^>]+>\s*)*)(\d+(?:\.\d+)*\.?)"
)
PLAIN_NUMBER_RE = re.compile(r"^\s*(\d+(?:\.\d+)*\.?)")


def heading_number(inner: str) -> str:
    numbered = HEADING_NUMBER_RE.match(inner)
    raw = numbered.group(2) if numbered else ""
    if not raw:
        plain = PLAIN_NUMBER_RE.match(heading_plain_text(inner))
        raw = plain.group(1) if plain else ""
    if raw and not raw.endswith("."):
        raw += "."
    return raw


def cancel_reason_phrase(text: str, keep: str, no_hw: bool) -> str:
    tags = classify_tags(text)
    if keep in ("cloud", "on-prem"):
        if ("cloud" in tags and keep != "cloud") or ("on-prem" in tags and keep != "on-prem"):
            return "bei On-Prem" if keep == "on-prem" else "bei Cloud"
    if no_hw and "hw-support" in tags:
        return ""
    if keep == "on-prem":
        return "bei On-Prem"
    if keep == "cloud":
        return "bei Cloud"
    return ""


def cancelled_heading_label(inner: str, keep: str, no_hw: bool) -> str:
    number = heading_number(inner)
    reason = cancel_reason_phrase(heading_plain_text(inner), keep, no_hw)
    label = f"{number} entfällt" if number else "entfällt"
    if reason:
        label = f"{label} {reason}"
    return label


def restyle_cancelled_heading(level: str, attrs: str, inner: str, keep: str, no_hw: bool) -> str:
    if re.search(r"(?i)\bclass=", attrs):
        attrs = re.sub(
            r"""(?i)\bclass=(["'])(.*?)\1""",
            lambda m: f"class={m.group(1)}{m.group(2)} entfaellt{m.group(1)}",
            attrs,
            count=1,
        )
    else:
        attrs += ' class="entfaellt"'
    cancel_style = f"color:{ENTFAELLT_COLOR};"
    if re.search(r"(?i)\bstyle=", attrs):
        attrs = re.sub(
            r"""(?i)\bstyle=(["'])(.*?)\1""",
            lambda m: f"style={m.group(1)}{cancel_style}{m.group(2)}{m.group(1)}",
            attrs,
            count=1,
        )
    else:
        attrs += f' style="{cancel_style}"'
    return f"<h{level}{attrs}>{cancelled_heading_label(inner, keep, no_hw)}</h{level}>"


def filter_contract_sections(html: str, keep: str, no_hw: bool = False) -> tuple[str, int]:
    """Cancel tagged headings (keep title, drop body) and drop tagged plain lines."""
    if (keep not in ("cloud", "on-prem") and not no_hw) or not html:
        return html, 0

    matches = list(HEADING_RE.finditer(html))
    ops: list[tuple[int, int, str]] = []
    i = 0
    while i < len(matches):
        m = matches[i]
        level = int(m.group(1))
        if should_drop_tagged(heading_plain_text(m.group(3)), keep, no_hw):
            body_end = len(html)
            for nxt in matches[i + 1 :]:
                if int(nxt.group(1)) <= level:
                    body_end = nxt.start()
                    break
            ops.append(
                (
                    m.start(),
                    body_end,
                    restyle_cancelled_heading(m.group(1), m.group(2), m.group(3), keep, no_hw),
                )
            )
            while i + 1 < len(matches) and matches[i + 1].start() < body_end:
                i += 1
        i += 1

    if ops:
        parts: list[str] = []
        cursor = 0
        for start, end, repl in ops:
            parts.append(html[cursor:start])
            parts.append(repl)
            cursor = end
        parts.append(html[cursor:])
        html = "".join(parts)

    remaining_ids = set(
        re.findall(r"""(?i)<h[1-6]\b[^>]*\bid=["']([^"']+)["']""", html)
    )

    def drop_stale_anchor(m: re.Match[str]) -> str:
        hid = unescape(m.group(1))[1:]
        if hid and hid not in remaining_ids:
            return ""
        return m.group(0)

    if remaining_ids:
        html = re.sub(
            r"""(?is)<a\b(?=[^>]*\bhref=["'](#[^"']+)["'])[^>]*>.*?</a>""",
            drop_stale_anchor,
            html,
        )

    dropped_lines = 0

    def drop_tagged_plain_block(m: re.Match) -> str:
        nonlocal dropped_lines
        if should_drop_tagged(heading_plain_text(m.group(3)), keep, no_hw):
            dropped_lines += 1
            return ""
        return m.group(0)

    # Plain paragraphs/list items: drop only that block, not following siblings.
    html = re.sub(
        r"(?is)<(p|li)\b([^>]*)>(.*?)</\1>",
        drop_tagged_plain_block,
        html,
    )
    for _ in range(5):
        prev = html
        html = re.sub(r"(?is)<li\b[^>]*>\s*</li>", "", html)
        html = re.sub(r"(?is)<ul\b[^>]*>\s*</ul>", "", html)
        html = re.sub(r"(?is)<ol\b[^>]*>\s*</ol>", "", html)
        if html == prev:
            break

    if keep in ("cloud", "on-prem"):
        html = CONTRACT_TAG_RE.sub(r"\1", html)
    if no_hw:
        html = HW_TAG_RE.sub(r"\1", html)
    html = re.sub(r"[ \t]{2,}", " ", html)
    html = re.sub(r" +(</h[1-6]>)", r"\1", html, flags=re.I)
    return html, len(ops) + dropped_lines


gdoc_ids = []
for m in re.finditer(
    r"https?://docs\.google\.com/(?:document|spreadsheets|presentation)/d/([a-zA-Z0-9_-]+)",
    storage + "\n" + view,
):
    if m.group(1) not in gdoc_ids:
        gdoc_ids.append(m.group(1))

# Attachment candidates (prefer .pdf, then office docs)
att_candidates = []
media_rank = {
    "application/pdf": 0,
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": 1,
    "application/msword": 2,
    "application/vnd.oasis.opendocument.text": 3,
}
for att in attachments:
    media = (att.get("metadata") or {}).get("mediaType") or att.get("extensions", {}).get("mediaType") or ""
    title_a = att.get("title") or ""
    download = (att.get("_links") or {}).get("download") or ""
    if not download:
        continue
    lower = title_a.lower()
    if media in media_rank or lower.endswith((".pdf", ".doc", ".docx", ".odt")):
        att_candidates.append((media_rank.get(media, 9), title_a, download, media))

att_candidates.sort()
has_view_file = 'ac:name="view-file"' in storage or "ac:name='view-file'" in storage

plain = text_only(storage)
plain_wo_urls = re.sub(r"https?://\S+", "", plain).strip()
# Stub pages: nearly empty aside from one or more Google Doc links
is_gdoc_stub = bool(gdoc_ids) and len(plain_wo_urls) < 120
# Attachment stub: view-file macro / almost no text besides the file
is_att_stub = bool(att_candidates) and (has_view_file or len(plain_wo_urls) < 80)

strategy = "html"
payload = ""
filtered_sections = 0
if is_gdoc_stub:
    strategy = "gdoc"
    payload = gdoc_ids[0]
elif is_att_stub:
    strategy = "attachment"
    payload = att_candidates[0][2]  # download path
else:
    strategy = "html"
    body = restore_confluence_link_labels(view, storage) if view else f"<pre>{plain}</pre>"
    contract_type = sys.argv[4].strip() if len(sys.argv) > 4 else ""
    no_hw = (sys.argv[5].strip() if len(sys.argv) > 5 else "0") in ("1", "true", "yes")
    body, filtered_sections = filter_contract_sections(body, contract_type, no_hw)
    html = f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>{title}</title>
<style>
  @page {{ size: A4; margin: 14mm; }}
  body {{ font-family: DejaVu Sans, Arial, Helvetica, sans-serif; margin: 0; line-height: 1.4; font-size: 9pt; color: #111; }}
  h1 {{ font-size: 14pt; line-height: 1.25; margin: 0.6em 0 0.35em; page-break-after: avoid; break-after: avoid; }}
  h2 {{ font-size: 12pt; line-height: 1.25; margin: 0.55em 0 0.3em; page-break-after: avoid; break-after: avoid; }}
  h3 {{ font-size: 10.5pt; line-height: 1.25; margin: 0.5em 0 0.25em; page-break-after: avoid; break-after: avoid; }}
  h4,h5,h6 {{ font-size: 9.5pt; line-height: 1.25; margin: 0.45em 0 0.2em; page-break-after: avoid; break-after: avoid; }}
  h1.entfaellt, h2.entfaellt, h3.entfaellt, h4.entfaellt, h5.entfaellt, h6.entfaellt {{ color: #d0d0d0; }}
  h1 + *, h2 + *, h3 + *, h4 + *, h5 + *, h6 + * {{ page-break-before: avoid; break-before: avoid; }}
  p {{ orphans: 3; widows: 3; margin: 0.35em 0; }}
  ul, ol {{ margin: 0.35em 0 0.35em 1.2em; padding: 0; }}
  li {{ margin: 0.15em 0; page-break-inside: avoid; break-inside: avoid; }}
  li > ul, li > ol {{ margin-top: 0.15em; margin-bottom: 0.15em; }}
  table {{ border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 8.5pt; page-break-inside: auto; }}
  thead {{ display: table-header-group; }}
  tr {{ page-break-inside: avoid; break-inside: avoid-page; }}
  th, td {{ border: 1px solid #bbb; padding: 4px 6px; vertical-align: top; }}
  th {{ background: #f3f4f6; font-weight: 600; }}
  img, video {{ max-width: 100%; height: auto; page-break-inside: avoid; break-inside: avoid; }}
  figure, .confluence-embedded-file-wrapper {{ page-break-inside: avoid; break-inside: avoid; margin: 0.6em 0; }}
  a {{ color: #0645ad; }}
  pre, code {{ font-family: DejaVu Sans Mono, Consolas, monospace; font-size: 8pt; }}
  pre {{ white-space: pre-wrap; page-break-inside: avoid; break-inside: avoid; background: #f7f7f8; padding: 6px 8px; border-radius: 3px; }}
  blockquote {{ margin: 0.6em 0; padding: 0.2em 0 0.2em 0.8em; border-left: 3px solid #ccc; color: #333; }}
  .confluence-information-macro {{ border-left: 4px solid #3572b0; background: #f4f8fc; padding: 6px 10px; margin: 0.8em 0; page-break-inside: avoid; break-inside: avoid; }}
  .confluence-information-macro-tip {{ border-left-color: #14892c; background: #f3f9f4; }}
  .confluence-information-macro-note {{ border-left-color: #ff8b00; background: #fff8ef; }}
  .confluence-information-macro-warning {{ border-left-color: #d04437; background: #fdf4f3; }}
</style>
</head><body>
<h1>{title}</h1>
{body}
</body></html>
"""
    html_path.write_text(html, encoding="utf-8")
    payload = str(html_path)

def sh_quote(s: str) -> str:
    return "'" + s.replace("'", "'\"'\"'") + "'"

print(f"TITLE={sh_quote(title)}")
print(f"STRATEGY={sh_quote(strategy)}")
print(f"PAYLOAD={sh_quote(payload)}")
print(f"FILTERED_SECTIONS={filtered_sections}")
PY

  # shellcheck disable=SC1090
  source "${WORKDIR}/decision.${page_id}.env"
  local slug
  slug="$(printf '%02d_%s' "${index}" "$(slugify "${TITLE}")")"
  out_pdf="${PARTS_DIR}/${slug}.pdf"

  echo "[${index}] ${TITLE} (${page_id}) → ${STRATEGY}"
  if [[ "${STRATEGY}" == "html" && "${FILTERED_SECTIONS:-0}" != 0 ]]; then
    echo "  cancelled/dropped ${FILTERED_SECTIONS} tagged heading/line block(s)"
  fi

  case "${STRATEGY}" in
    gdoc)
      download "https://docs.google.com/document/d/${PAYLOAD}/export?format=pdf" "${out_pdf}.dl"
      if is_pdf "${out_pdf}.dl"; then
        mv "${out_pdf}.dl" "${out_pdf}"
      else
        echo "  ! Google Doc export failed for ${PAYLOAD}, falling back to Confluence HTML" >&2
        rm -f "${out_pdf}.dl"
        STRATEGY="html"
        PAYLOAD="${WORKDIR}/${page_id}.html"
        python3 - "${meta_json_file}" "${PAYLOAD}" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
title = data.get("title") or "page"
body = data.get("body", {}).get("view", {}).get("value") or "<p>(empty)</p>"
Path(sys.argv[2]).write_text(
    f"<!doctype html><html><head><meta charset=utf-8><title>{title}</title></head>"
    f"<body><h1>{title}</h1>{body}</body></html>",
    encoding="utf-8",
)
PY
      fi
      ;;
    attachment)
      local rel="${PAYLOAD}"
      local abs
      if [[ "${rel}" == http* ]]; then
        abs="${rel}"
      else
        abs="${BASE_URL%/}${rel}"
      fi
      local att_file="${WORKDIR}/${page_id}.att"
      download "${abs}" "${att_file}"
      local mime
      mime="$(file -b --mime-type "${att_file}")"
      if [[ "${mime}" == application/pdf ]]; then
        mv "${att_file}" "${out_pdf}"
      else
        if [[ -z "${SOFFICE}" ]]; then
          echo "  ! LibreOffice missing; cannot convert attachment ${mime}" >&2
          exit 1
        fi
        "${SOFFICE}" --headless --norestore --convert-to pdf --outdir "${WORKDIR}" "${att_file}" >/dev/null
        local converted
        converted="$(python3 - "${att_file}" "${WORKDIR}" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1])
workdir = Path(sys.argv[2])
cand = workdir / (src.stem + ".pdf")
print(cand if cand.exists() else "")
PY
)"
        [[ -n "${converted}" && -s "${converted}" ]] || { echo "  ! Conversion failed for attachment" >&2; exit 1; }
        mv "${converted}" "${out_pdf}"
      fi
      ;;
  esac

  if [[ "${STRATEGY}" == "html" ]]; then
    # Prefix site-absolute paths (/wiki/..., /download/...) so Chrome can load assets.
    local site_origin
    site_origin="$(python3 - "$BASE_URL" <<'PY'
from urllib.parse import urlsplit
import sys
parts = urlsplit(sys.argv[1])
print(f"{parts.scheme}://{parts.netloc}")
PY
)"
    python3 - "${PAYLOAD}" "${site_origin}" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
origin = sys.argv[2].rstrip("/")
html = path.read_text(encoding="utf-8")
html = re.sub(
    r'''(?i)(\b(?:href|src)=["'])/(?!/)''',
    rf'''\1{origin}/''',
    html,
)
path.write_text(html, encoding="utf-8")
PY
    "${CHROME_BIN}" --headless --disable-gpu --no-pdf-header-footer \
      --print-to-pdf="${out_pdf}" "file://${PAYLOAD}" >/dev/null 2>&1
  fi

  if ! is_pdf "${out_pdf}"; then
    echo "Failed to produce PDF for page ${page_id} (${TITLE})" >&2
    exit 1
  fi
  echo "${out_pdf}" >> "${WORKDIR}/pdf_list.txt"
}

INDEX=1
: > "${WORKDIR}/pdf_list.txt"
for id in "${PAGE_IDS[@]}"; do
  export_page_pdf "${id}" "${INDEX}"
  INDEX=$((INDEX + 1))
done

ROOT_TITLE="$(api_get "/rest/api/content/${PAGE_ID}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
if [[ -z "${OUT_FILE}" ]]; then
  OUT_FILE="$(pwd)/$(slugify "${ROOT_TITLE}")_merged.pdf"
fi

mapfile -t PDFS < "${WORKDIR}/pdf_list.txt"
echo "Merging ${#PDFS[@]} PDF(s) → ${OUT_FILE}"
pdfunite "${PDFS[@]}" "${OUT_FILE}"

if (( KEEP_PARTS )); then
  KEEP_DIR="$(dirname "${OUT_FILE}")/$(basename "${OUT_FILE}" .pdf)_parts"
  mkdir -p "${KEEP_DIR}"
  cp "${PDFS[@]}" "${KEEP_DIR}/"
  echo "Kept individual parts in ${KEEP_DIR}"
fi

echo "Done: ${OUT_FILE}"
pdfinfo "${OUT_FILE}" | sed -n '1,12p' || true
