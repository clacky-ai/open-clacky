#!/usr/bin/env python3
"""
pdf_parser_plumber.py — extract text from a PDF using pdfplumber.

Usage:
    python3 pdf_parser_plumber.py <file_path>

Output:
    stdout — extracted text, one block per page, separated by blank lines
    stderr — error messages
    exit 0  — success (text was extracted)
    exit 1  — failure / no text found
    exit 2  — dependency missing

Called from pdf_parser.rb as the second-tier extractor (after pdftotext).
This script is copied into ~/.clacky/parsers/ and can be edited freely by
the LLM — e.g. to tune table extraction, layout heuristics, or filter out
boilerplate headers/footers. Edit, then re-run to test.

Install:
    pip3 install pdfplumber
"""

# VERSION: 1

import sys


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: pdf_parser_plumber.py <file_path>\n")
        sys.exit(1)

    path = sys.argv[1]

    try:
        import pdfplumber
    except ImportError as e:
        sys.stderr.write(f"pdfplumber missing: {e}\n")
        sys.stderr.write("Install with: pip3 install pdfplumber\n")
        sys.exit(2)

    pages = []
    try:
        with pdfplumber.open(path) as pdf:
            for i, page in enumerate(pdf.pages, 1):
                text = page.extract_text()
                if text and text.strip():
                    pages.append(f"--- Page {i} ---\n{text.strip()}")
    except Exception as e:
        sys.stderr.write(f"pdfplumber failed: {e}\n")
        sys.exit(1)

    if not pages:
        sys.stderr.write("pdfplumber produced no text.\n")
        sys.exit(1)

    print("\n\n".join(pages))


if __name__ == "__main__":
    main()
