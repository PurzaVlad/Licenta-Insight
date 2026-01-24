#!/usr/bin/env python3
import http.server
import os
import shutil
import subprocess
import tempfile
import urllib.parse


def _soffice_path():
    return shutil.which("soffice") or "/Applications/LibreOffice.app/Contents/MacOS/soffice"


class ConvertHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/convert":
            self.send_error(404, "Not Found")
            return

        params = urllib.parse.parse_qs(parsed.query or "")
        target = (params.get("target") or [""])[0].strip().lower()
        if not target:
            self.send_error(400, "Missing target")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return

        if length <= 0:
            self.send_error(400, "Empty body")
            return

        filename = self.headers.get("X-Filename", "document")
        filename = filename.replace("/", "_")
        header_ext = (self.headers.get("X-File-Ext") or "").strip().lower()
        source_ext = header_ext or os.path.splitext(filename)[1].lstrip(".") or "bin"

        soffice = _soffice_path()
        if not os.path.exists(soffice):
            self.send_error(500, "LibreOffice soffice not found in PATH")
            return

        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = os.path.join(tmpdir, f"input.{source_ext}")
            with open(input_path, "wb") as f:
                f.write(self.rfile.read(length))

            filter_target = target
            if target == "docx":
                filter_target = "docx:MS Word 2007 XML"
            elif target == "xlsx":
                filter_target = "xlsx:Calc MS Excel 2007 XML"
            elif target == "pptx":
                filter_target = "pptx:Impress MS PowerPoint 2007 XML"

            cmd = [
                soffice,
                "--headless",
                "--nologo",
                "--nolockcheck",
                "--norestore",
                "--convert-to",
                filter_target,
                "--outdir",
                tmpdir,
                input_path,
            ]
            if source_ext == "pdf":
                if target in ("ppt", "pptx"):
                    cmd.insert(cmd.index("--convert-to"), "--infilter=impress_pdf_import")
                elif target == "docx":
                    cmd.insert(cmd.index("--convert-to"), "--infilter=writer_pdf_import")
                elif target == "xlsx":
                    cmd.insert(cmd.index("--convert-to"), "--infilter=calc_pdf_import")

            print("Running:", " ".join(cmd))
            result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.stdout:
                print("LibreOffice stdout:", result.stdout.decode("utf-8", errors="ignore"))
            if result.stderr:
                print("LibreOffice stderr:", result.stderr.decode("utf-8", errors="ignore"))
            if result.returncode != 0:
                detail = result.stderr.decode("utf-8", errors="ignore")[:1000]
                self.send_error(500, f"LibreOffice conversion failed: {detail}")
                return

            output_path = os.path.join(tmpdir, f"input.{target}")
            if not os.path.exists(output_path):
                self.send_error(500, "Converted file not found")
                return

            with open(output_path, "rb") as f:
                data = f.read()

        output_name = os.path.splitext(filename)[0] or "document"
        output_name = f"{output_name}.{target}"

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{output_name}"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        return


def main():
    host = os.environ.get("CONVERT_HOST", "127.0.0.1")
    port = int(os.environ.get("CONVERT_PORT", "8787"))
    server = http.server.ThreadingHTTPServer((host, port), ConvertHandler)
    print(f"LibreOffice convert server listening on http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
