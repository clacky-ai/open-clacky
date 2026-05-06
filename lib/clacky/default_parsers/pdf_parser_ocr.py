#!/usr/bin/env python3
"""
pdf_parser_ocr.py — extract text from a scanned/image-only PDF using OCR.

Usage:
    python3 pdf_parser_ocr.py <file_path>

Output:
    stdout — extracted text, one block per page, separated by blank lines
    stderr — error messages
    exit 0  — success (text was extracted)
    exit 1  — failure / no text found
    exit 2  — dependency missing (pytesseract or pdf2image)
    exit 3  — pdf2image couldn't rasterise the PDF (usually missing poppler)

Called from pdf_parser.rb as the third-tier fallback (after pdftotext and
pdfplumber). This script is copied into ~/.clacky/parsers/ and can be
edited freely by the LLM — common tweaks:
  - Change DPI (higher = better accuracy, slower + more memory)
  - Change OCR_LANG to match your document (e.g. "jpn+eng")
  - Add image preprocessing (deskew, contrast, threshold) before OCR
  - Adjust MAX_PAGES for very large scans

Environment variable overrides:
  CLACKY_OCR_LANG       — override OCR_LANG (e.g. "eng", "jpn+eng")
  CLACKY_OCR_MAX_PAGES  — override MAX_PAGES
  CLACKY_OCR_DPI        — override DPI

Install:
    macOS: brew install tesseract tesseract-lang poppler
           pip3 install pytesseract pdf2image
    Linux: apt install tesseract-ocr tesseract-ocr-chi-sim poppler-utils
           pip3 install pytesseract pdf2image
"""

# VERSION: 1

import os
import sys

# --- Config ---
# Simplified Chinese + English covers most mixed-language documents.
# For pure English scans, "eng" alone is faster and lighter.
OCR_LANG = "chi_sim+eng"

# 200 DPI is a good balance: tesseract's accuracy plateau starts around
# 300 DPI, but memory + time cost scales quadratically. Raise to 300 for
# small fonts or when accuracy matters more than speed.
DPI = 200

# Hard cap on pages to OCR. OCR is slow (~1-3s/page); for huge scans the
# LLM should be told to OCR in chunks instead.
MAX_PAGES = 50


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: pdf_parser_ocr.py <file_path>\n")
        sys.exit(1)

    path = sys.argv[1]

    try:
        import pytesseract
        from pdf2image import convert_from_path
    except ImportError as e:
        sys.stderr.write(f"OCR dependencies missing: {e}\n")
        sys.stderr.write("Install with: pip3 install pytesseract pdf2image\n")
        sys.exit(2)

    lang = os.environ.get("CLACKY_OCR_LANG", OCR_LANG)
    max_pages = int(os.environ.get("CLACKY_OCR_MAX_PAGES", MAX_PAGES))
    dpi = int(os.environ.get("CLACKY_OCR_DPI", DPI))

    try:
        images = convert_from_path(path, dpi=dpi, last_page=max_pages)
    except Exception as e:
        sys.stderr.write(f"pdf2image failed: {e}\n")
        sys.stderr.write("Is poppler installed? (brew install poppler / apt install poppler-utils)\n")
        sys.exit(3)

    pages = []
    for i, image in enumerate(images, 1):
        try:
            text = pytesseract.image_to_string(image, lang=lang)
        except pytesseract.TesseractError as e:
            # Most common cause: requested language pack not installed.
            # Fall back to English-only for this page rather than aborting.
            sys.stderr.write(f"tesseract error on page {i}: {e}\n")
            text = pytesseract.image_to_string(image, lang="eng")
        text = text.strip()
        if text:
            pages.append(f"--- Page {i} (OCR) ---\n{text}")

    if not pages:
        sys.stderr.write("OCR produced no text — PDF may be blank or unreadable.\n")
        sys.exit(1)

    print("\n\n".join(pages))


if __name__ == "__main__":
    main()
