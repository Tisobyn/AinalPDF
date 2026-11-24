# Ainal PDF

An iOS app that turns documents and photos into PDF files. Everything runs on the device. Nothing is uploaded.

## How to use

1. Pick a page size: **A4**, **Letter** or **Original size**.
2. Tap **Choose a file** or **Choose photos**.
3. Preview, share or save the PDF. Past files are listed under **Recent**.

You can also send a file from another app (for example Air Printer) with **Share > Open in...** or **Copy to...** and pick Ainal PDF.

## Page size

| Option | What it does |
| --- | --- |
| A4 | Fits content on A4 pages (default). |
| Letter | Fits content on US Letter pages. |
| Original size | Photos keep their own size, with no margins. |

Word (.docx) files keep the page size set in the file. PDFs are not changed. Other documents use A4 when "Original size" is picked.

## Supported files

- **Word:** docx, doc, dot
- **PowerPoint:** pptx, ppt, ppsx, pps
- **Excel:** xlsx, xls, csv, tsv
- **Apple:** pages, numbers, key
- **Text:** txt, rtf, md, log, json, xml, yaml, html, svg
- **Images:** jpg, png, heic, tiff, gif, bmp, webp, ico, dng
- **PDF:** opened as is

## How it works

- `.docx` is drawn with a bundled JavaScript renderer inside a hidden web view.
- Other documents are shown in a hidden WebKit view and printed to PDF.
- Photos are placed on pages with `UIGraphicsPDFRenderer`.

Code is in `AinalPDF/Converter`.

## Build

Open `AinalPDF.xcodeproj` in Xcode and run. It needs iOS 16 or later.
