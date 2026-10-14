#!/usr/bin/env python3
"""Interactively summarize common sources with Fabric and a local Ollama model.

The displayed elapsed time measures only the Fabric command. Local text files
are passed through standard input; PDF extraction requires Poppler's pdftotext,
and DOCX extraction requires Pandoc. Audio/video transcription uses Fabric's
separate transcription setup and may use an external provider.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

LONG_INPUT_WARNING_CHARS = 8_000
TEXT_EXTENSIONS = {".txt", ".text", ".md", ".markdown", ".vtt", ".srt", ".log", ".csv"}


def read_required(prompt: str) -> str:
    while True:
        value = input(f"{prompt}: ").strip().strip('"')
        if value:
            return value
        print("Please enter a value.")


def read_local_file_path(title: str, filetypes: list[tuple[str, str]]) -> Optional[Path]:
    choice = input("Press Enter to browse for a file, or type P to enter its path: ").strip()
    if choice.casefold() in {"p", "path"}:
        return Path(read_required("Enter the local file path")).expanduser()

    try:
        import tkinter as tk
        from tkinter import filedialog

        root = tk.Tk()
        root.withdraw()
        root.update()
        selected = filedialog.askopenfilename(title=title, filetypes=filetypes)
        root.destroy()
        return Path(selected) if selected else None
    except Exception as exc:
        print(f"File picker could not open: {exc}")
        return Path(read_required("Enter the local file path instead")).expanduser()


def require_command(name: str, purpose: str) -> str:
    command = shutil.which(name)
    if not command:
        raise RuntimeError(f"{purpose} requires '{name}' in PATH. Install it, reopen the terminal, and try again.")
    return command


def get_ollama_models() -> list[str]:
    ollama = require_command("ollama", "Listing local Ollama models")
    result = subprocess.run([ollama, "list"], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"'ollama list' failed (exit code {result.returncode}). Is Ollama running?\n{detail}")

    models = []
    for line in result.stdout.splitlines()[1:]:
        fields = line.split()
        if fields:
            models.append(fields[0])
    if not models:
        raise RuntimeError("No Ollama models were listed. Run 'ollama pull <model>' first.")
    return models


def choose_model(models: list[str]) -> str:
    print("\nLocal Ollama models:")
    for index, model in enumerate(models, 1):
        print(f"  [{index}] {model}")
    while True:
        answer = input("Select a model number: ").strip()
        if answer.isdigit() and 1 <= int(answer) <= len(models):
            return models[int(answer) - 1]
        print(f"Enter a number from 1 to {len(models)}.")


def extract_document_text(path: Path, document_type: str) -> str:
    resolved = path.expanduser().resolve(strict=True)
    expected_extension = ".pdf" if document_type == "PDF" else ".docx"
    if resolved.suffix.casefold() != expected_extension:
        raise RuntimeError(f"The selected document type requires a {expected_extension} file.")

    if document_type == "PDF":
        command = require_command("pdftotext", "PDF extraction (provided by Poppler)")
        result = subprocess.run(
            [command, "-enc", "UTF-8", str(resolved), "-"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    else:
        command = require_command("pandoc", "Word .docx extraction")
        result = subprocess.run(
            [command, str(resolved), "-t", "plain"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"{document_type} text extraction failed (exit code {result.returncode}).\n{detail}")
    if not result.stdout.strip():
        raise RuntimeError("No text was extracted. The document may contain scanned images; run OCR and try again.")
    return result.stdout


def read_plain_text(path: Path) -> str:
    resolved = path.expanduser().resolve(strict=True)
    if resolved.suffix.casefold() not in TEXT_EXTENSIONS:
        extensions = ", ".join(sorted(TEXT_EXTENSIONS))
        raise RuntimeError(f"Option 3 expects a plain-text file ({extensions}). For PDF or Word .docx, choose option 4.")
    text = resolved.read_text(encoding="utf-8-sig", errors="replace")
    if not text.strip():
        raise RuntimeError("The selected file did not yield any text to summarize.")
    return text


def choose_source() -> tuple[str, list[str], Optional[str]]:
    print("Fabric Summarizer")
    print("Choose the content you want to summarize:")
    print("  [1] Web page URL")
    print("  [2] YouTube video URL (summarize its transcript)")
    print("  [3] Local text, transcript, or notes (plain text only)")
    print("      Examples: .txt, .md, .vtt, .srt, .log, .csv; PDF/Word use option 4.")
    pdf_status = "available" if shutil.which("pdftotext") else "needs pdftotext"
    word_status = "available" if shutil.which("pandoc") else "needs Pandoc"
    print(f"  [4] PDF or Word .docx document (PDF: {pdf_status}; Word: {word_status})")
    print("  [5] Local audio or video file (transcribe, then summarize)")

    while True:
        source_type = input("Select source type [1-5]: ").strip()
        if source_type in {"1", "2", "3", "4", "5"}:
            break
        print("Enter a number from 1 to 5.")

    source: str
    text_input: Optional[str] = None
    if source_type == "1":
        source = read_required("Enter the web page URL")
        args = ["-u", source, "-p", "summarize"]
    elif source_type == "2":
        require_command("yt-dlp", "YouTube transcript retrieval")
        source = read_required("Enter the YouTube video URL")
        args = ["-y", source, "-p", "summarize"]
    elif source_type == "3":
        path = read_local_file_path(
            "Select a plain-text file to summarize",
            [("Text files", "*.txt *.text *.md *.markdown *.vtt *.srt *.log *.csv"), ("All files", "*.*")],
        )
        if path is None:
            print("Cancelled; no file was selected.")
            raise SystemExit(0)
        source = str(path)
        text_input = read_plain_text(path)
        args = ["-p", "summarize"]
    elif source_type == "4":
        print("  [1] PDF (.pdf)")
        print("  [2] Word document (.docx)")
        while True:
            document_choice = input("Select document type [1-2]: ").strip()
            if document_choice in {"1", "2"}:
                break
            print("Enter 1 or 2.")
        document_type = "PDF" if document_choice == "1" else "Word"
        if document_type == "PDF" and not shutil.which("pdftotext"):
            raise RuntimeError("PDF option needs pdftotext in PATH (provided by Poppler), or extract the PDF to .txt and use option 3.")
        if document_type == "Word" and not shutil.which("pandoc"):
            raise RuntimeError("Word .docx option needs Pandoc in PATH, or export the document to .txt and use option 3.")
        if document_type == "PDF":
            types = [("PDF files", "*.pdf"), ("All files", "*.*")]
            title = "Select a PDF document to summarize"
        else:
            types = [("Word documents", "*.docx"), ("All files", "*.*")]
            title = "Select a Word document to summarize"
        path = read_local_file_path(title, types)
        if path is None:
            print("Cancelled; no file was selected.")
            raise SystemExit(0)
        source = str(path)
        text_input = extract_document_text(path, document_type)
        args = ["-p", "summarize"]
    else:
        print("\nAudio/video transcription uses Fabric's separate transcription model, not the selected Ollama chat model.")
        print("Depending on your configuration, media may be sent to an external provider and could incur charges.")
        consent = input("Continue with transcription? [y/N]: ").strip().casefold()
        if consent not in {"y", "yes"}:
            print("Cancelled before sending the media for transcription.")
            raise SystemExit(0)
        media_path = Path(read_required("Enter the local audio/video file path")).expanduser().resolve(strict=True)
        source = str(media_path)
        args = ["--transcribe-file", str(media_path)]
        if media_path.stat().st_size > 25 * 1024 * 1024:
            if not shutil.which("ffmpeg"):
                raise RuntimeError("This media file is larger than 25 MB. Install ffmpeg and put it in PATH to split larger files.")
            args.append("--split-media-file")
        args += ["-p", "summarize"]

    return source, args, text_input


def run_fabric(args: list[str], text_input: Optional[str]) -> tuple[int, float, list[str]]:
    fabric = require_command("fabric", "Running Fabric")
    command = [fabric, *args]
    output_lines: list[str] = []
    start = time.perf_counter()
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE if text_input is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        write_errors: list[OSError] = []
        writer: Optional[threading.Thread] = None

        if text_input is not None and process.stdin is not None:
            stdin_pipe = process.stdin

            def send_input() -> None:
                try:
                    stdin_pipe.write(text_input)
                    stdin_pipe.flush()
                except OSError as exc:
                    write_errors.append(exc)
                finally:
                    try:
                        stdin_pipe.close()
                    except OSError as exc:
                        write_errors.append(exc)

            # Read Fabric output while a separate thread feeds its input.
            # This avoids deadlock when both process pipes fill up.
            writer = threading.Thread(target=send_input, daemon=True)
            writer.start()

        assert process.stdout is not None
        for line in process.stdout:
            line = line.rstrip("\r\n")
            output_lines.append(line)
            print(line)
        process.stdout.close()
        return_code = process.wait()
        if writer is not None:
            writer.join()
        if write_errors and return_code == 0:
            raise RuntimeError(f"Could not send input to Fabric: {write_errors[0]}")
    except OSError as exc:
        raise RuntimeError(f"Could not start Fabric: {exc}") from exc
    finally:
        elapsed = time.perf_counter() - start
    return return_code, elapsed, output_lines


def save_markdown(source: str, model: str, elapsed: float, output_lines: list[str]) -> None:
    choice = input("Save the output to a Markdown file? [y/N]: ").strip().casefold()
    if choice not in {"y", "yes"}:
        return
    output_path = Path(read_required("Enter the output file path")).expanduser()
    if not output_path.parent.exists():
        raise RuntimeError(f"Output folder does not exist: {output_path.parent}")
    if output_path.exists():
        overwrite = input("File already exists. Overwrite it? [y/N]: ").strip().casefold()
        if overwrite not in {"y", "yes"}:
            print("Save cancelled; the existing file was left unchanged.")
            return
    report = [
        "# Fabric Summary",
        "",
        f"- Source: {source}",
        f"- Model: Ollama/{model}",
        f"- Fabric elapsed time: {elapsed:.1f} seconds",
        "",
        "## Output",
        "",
        *output_lines,
        "",
    ]
    output_path.write_text("\n".join(report), encoding="utf-8")
    print(f"Saved: {output_path.resolve()}")


def main() -> int:
    try:
        require_command("fabric", "Running Fabric")
        source, args, text_input = choose_source()
        if text_input is not None and len(text_input) > LONG_INPUT_WARNING_CHARS:
            approx_tokens = (len(text_input) + 3) // 4
            print("\nLong input warning")
            print(f"This file contains {len(text_input):,} characters (roughly {approx_tokens:,} tokens at 4 characters per token).")
            print("The estimate varies by text and language. Fabric instructions and the requested summary also use the model context window.")
            print("A long input may exceed the context available to the selected Ollama model or produce an incomplete summary.")
            answer = input("Continue and send this full text to Fabric? [y/N]: ").strip().casefold()
            if answer not in {"y", "yes"}:
                print("Cancelled before sending the text to Fabric.")
                return 0

        models = get_ollama_models()
        selected_model = choose_model(models)
        args += ["-V", "Ollama", "-m", selected_model]
        print(f"\nSource: {source}")
        print(f"Model:  Ollama/{selected_model}")
        print("Starting Fabric. Elapsed time will be shown when it finishes.\n")

        exit_code, elapsed, output_lines = run_fabric(args, text_input)
        if exit_code == 0:
            print(f"\nFabric completed in {elapsed:.1f} seconds.")
            save_markdown(source, selected_model, elapsed, output_lines)
        else:
            print(f"\nFabric exited with code {exit_code} after {elapsed:.1f} seconds.")
            print("Summary was not saved because Fabric did not complete successfully.")
        return exit_code
    except KeyboardInterrupt:
        print("\nCancelled.")
        return 130
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"\nError: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
