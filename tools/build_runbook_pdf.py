#!/usr/bin/env python3
from __future__ import annotations

import argparse
import textwrap
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Build a simple text PDF from markdown.")
    p.add_argument("--input", required=True, help="Input markdown file")
    p.add_argument("--output", required=True, help="Output PDF file")
    p.add_argument("--title", default="RUNBOOK DE FALLOS")
    return p.parse_args()


def normalize_lines(markdown_text: str, title: str) -> list[str]:
    raw = markdown_text.splitlines()
    lines: list[str] = [title, "=" * len(title), ""]
    for line in raw:
        stripped = line.rstrip()
        if not stripped:
            lines.append("")
            continue
        if stripped.startswith("```"):
            continue
        if stripped.startswith("#"):
            clean = stripped.lstrip("#").strip()
            lines.append(clean.upper())
            lines.append("-" * min(len(clean), 72))
            continue
        if stripped.startswith("- "):
            stripped = "• " + stripped[2:]
        lines.append(stripped)
    return lines


def wrap_lines(lines: list[str], width: int = 95) -> list[str]:
    wrapped: list[str] = []
    for line in lines:
        if not line:
            wrapped.append("")
            continue
        chunks = textwrap.wrap(line, width=width, replace_whitespace=False, drop_whitespace=False)
        wrapped.extend(chunks if chunks else [""])
    return wrapped


def split_pages(lines: list[str], max_lines: int = 48) -> list[list[str]]:
    pages: list[list[str]] = []
    for i in range(0, len(lines), max_lines):
        pages.append(lines[i : i + max_lines])
    return pages or [["(sin contenido)"]]


def pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def build_pdf(pages: list[list[str]]) -> bytes:
    page_width = 612
    page_height = 792
    margin_left = 48
    top_y = 750
    line_height = 14

    objects: dict[int, bytes] = {}
    objects[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

    kids_refs: list[str] = []
    next_obj = 4
    for page_lines in pages:
        page_obj = next_obj
        content_obj = next_obj + 1
        next_obj += 2

        stream_lines = [
            "BT",
            "/F1 10 Tf",
            f"{line_height} TL",
            f"{margin_left} {top_y} Td",
        ]
        first = True
        for line in page_lines:
            if first:
                first = False
            else:
                stream_lines.append("T*")
            stream_lines.append(f"({pdf_escape(line)}) Tj")
        stream_lines.append("ET")
        stream = ("\n".join(stream_lines) + "\n").encode("latin-1", "replace")
        objects[content_obj] = f"<< /Length {len(stream)} >>\nstream\n".encode("ascii") + stream + b"endstream"
        objects[page_obj] = (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_width} {page_height}] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {content_obj} 0 R >>"
        ).encode("ascii")
        kids_refs.append(f"{page_obj} 0 R")

    objects[2] = f"<< /Type /Pages /Kids [{' '.join(kids_refs)}] /Count {len(kids_refs)} >>".encode("ascii")
    objects[1] = b"<< /Type /Catalog /Pages 2 0 R >>"

    max_obj = max(objects)
    out = bytearray()
    out.extend(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")

    offsets = [0] * (max_obj + 1)
    for obj_num in range(1, max_obj + 1):
        payload = objects[obj_num]
        offsets[obj_num] = len(out)
        out.extend(f"{obj_num} 0 obj\n".encode("ascii"))
        out.extend(payload)
        out.extend(b"\nendobj\n")

    xref_pos = len(out)
    out.extend(f"xref\n0 {max_obj + 1}\n".encode("ascii"))
    out.extend(b"0000000000 65535 f \n")
    for obj_num in range(1, max_obj + 1):
        out.extend(f"{offsets[obj_num]:010d} 00000 n \n".encode("ascii"))

    out.extend(
        (
            f"trailer\n<< /Size {max_obj + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_pos}\n%%EOF\n"
        ).encode("ascii")
    )
    return bytes(out)


def main() -> int:
    args = parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    text = input_path.read_text(encoding="utf-8")
    lines = normalize_lines(text, args.title)
    lines = wrap_lines(lines, width=95)
    pages = split_pages(lines, max_lines=48)
    pdf = build_pdf(pages)
    output_path.write_bytes(pdf)
    print(f"WROTE {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
