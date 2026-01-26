#!/usr/bin/env python3
import http.server
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import socket


def _soffice_path():
    return shutil.which("soffice") or "/Applications/LibreOffice.app/Contents/MacOS/soffice"


def _http_request(method, url, headers=None, data=None, timeout=60):
    request = urllib.request.Request(url, data=data, method=method)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    return urllib.request.urlopen(request, timeout=timeout)


def _read_json(response):
    payload = response.read()
    if not payload:
        return {}
    return json.loads(payload.decode("utf-8"))


def _adobe_access_token(client_id, client_secret):
    token_url = os.environ.get("PDF_SERVICES_TOKEN_URL", "https://pdf-services.adobe.io/token")
    print(f"[Adobe] Requesting access token from {token_url}")
    form = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
    }).encode("utf-8")
    with _http_request(
        "POST",
        token_url,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=form,
        timeout=30,
    ) as response:
        print(f"[Adobe] Token response status {response.status}")
        data = _read_json(response)
    token = data.get("access_token")
    if not token:
        raise RuntimeError("Adobe token response missing access_token.")
    return token


def _adobe_create_asset(base_url, token, client_id, media_type):
    url = base_url.rstrip("/") + "/assets"
    print(f"[Adobe] Creating asset {url} mediaType={media_type}")
    payload = json.dumps({"mediaType": media_type}).encode("utf-8")
    with _http_request(
        "POST",
        url,
        headers={
            "X-API-Key": client_id,
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        data=payload,
        timeout=30,
    ) as response:
        print(f"[Adobe] Asset response status {response.status}")
        data = _read_json(response)
    upload_uri = data.get("uploadUri") or data.get("upload_uri")
    asset_id = data.get("assetID") or data.get("asset_id")
    if not upload_uri or not asset_id:
        raise RuntimeError("Adobe assets response missing uploadUri/assetID.")
    return upload_uri, asset_id


def _adobe_upload_asset(upload_uri, data, media_type):
    print(f"[Adobe] Uploading asset to {upload_uri}")
    with _http_request(
        "PUT",
        upload_uri,
        headers={"Content-Type": media_type},
        data=data,
        timeout=60,
    ) as response:
        print(f"[Adobe] Upload response status {response.status}")
        response.read()


def _normalize_status_url(base_url, operation, location, request_id):
    if location:
        if location.startswith("http://") or location.startswith("https://"):
            return location
        if location.startswith("/"):
            return base_url.rstrip("/") + location
    if request_id:
        return f"{base_url.rstrip('/')}/operation/{operation}/{request_id}/status"
    return None


def _adobe_export_pdf(base_url, token, client_id, asset_id, target_format):
    url = base_url.rstrip("/") + "/operation/exportpdf"
    print(f"[Adobe] Starting export {url} target={target_format}")
    payload = json.dumps({"assetID": asset_id, "targetFormat": target_format}).encode("utf-8")
    with _http_request(
        "POST",
        url,
        headers={
            "x-api-key": client_id,
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        data=payload,
        timeout=30,
    ) as response:
        location = response.headers.get("location") or response.headers.get("Location")
        request_id = response.headers.get("x-request-id") or response.headers.get("X-Request-Id")
        body = _read_json(response)
    status_url = _normalize_status_url(base_url, "exportpdf", location or body.get("statusUrl"), request_id)
    print(f"[Adobe] Export status URL: {status_url}")
    if not status_url:
        raise RuntimeError("Adobe export response missing status URL.")
    return status_url


def _adobe_poll_status(status_url, token, client_id, timeout_seconds=180):
    print(f"[Adobe] Polling status: {status_url}")
    deadline = time.time() + timeout_seconds
    last_error = None
    while time.time() < deadline:
        try:
            with _http_request(
                "GET",
                status_url,
                headers={
                    "x-api-key": client_id,
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                timeout=30,
            ) as response:
                data = _read_json(response)
        except urllib.error.HTTPError as err:
            last_error = err
            time.sleep(1.0)
            continue

        status = (data.get("status") or "").lower()
        if status:
            print(f"[Adobe] Status: {status}")
        if status in ("done", "succeeded", "success"):
            asset = data.get("asset") or {}
            if not asset and data.get("assetList"):
                asset_list = data.get("assetList") or []
                if asset_list:
                    asset = asset_list[0] or {}
            download_uri = asset.get("downloadUri") or asset.get("download_uri")
            if not download_uri:
                raise RuntimeError("Adobe status response missing downloadUri.")
            print(f"[Adobe] Download URL: {download_uri}")
            return download_uri
        if status in ("failed", "error"):
            error = data.get("error") or {}
            message = error.get("message") or "Adobe export job failed."
            raise RuntimeError(message)
        time.sleep(1.0)
    if last_error:
        raise RuntimeError(f"Adobe status polling failed: {last_error}")
    raise RuntimeError("Adobe status polling timed out.")


def _adobe_download(download_uri):
    print(f"[Adobe] Downloading result from {download_uri}")
    with _http_request("GET", download_uri, timeout=60) as response:
        print(f"[Adobe] Download response status {response.status}")
        return response.read()


class ConvertHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/convert":
            self.send_error(404, "Not Found")
            return

        print("Received /convert request:", self.path)
        try:
            self.connection.settimeout(30)
        except Exception:
            pass
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

        print("[Convert] Content-Length:", length)

        if length <= 0:
            self.send_error(400, "Empty body")
            return

        filename = self.headers.get("X-Filename", "document")
        filename = filename.replace("/", "_")
        header_ext = (self.headers.get("X-File-Ext") or "").strip().lower()
        source_ext = header_ext or os.path.splitext(filename)[1].lstrip(".") or "bin"

        adobe_client_id = os.environ.get("PDF_SERVICES_CLIENT_ID")
        adobe_client_secret = os.environ.get("PDF_SERVICES_CLIENT_SECRET")
        adobe_base_url = os.environ.get("PDF_SERVICES_BASE_URL", "https://pdf-services-ew1.adobe.io")
        requested_engine = (self.headers.get("X-Conversion-Engine") or "").strip().lower()
        can_use_adobe = (
            adobe_client_id
            and adobe_client_secret
            and source_ext == "pdf"
            and target in ("docx", "pptx", "xlsx")
        )
        if requested_engine == "adobe":
            if not can_use_adobe:
                self.send_error(400, "Adobe conversion is not available for this file or credentials.")
                return
            use_adobe = True
        elif requested_engine == "libreoffice":
            use_adobe = False
        else:
            use_adobe = bool(can_use_adobe)

        print(
            "[Convert] engine=",
            "adobe" if use_adobe else "libreoffice",
            "target=",
            target,
            "source=",
            source_ext,
        )

        soffice = _soffice_path()
        if not use_adobe and not os.path.exists(soffice):
            self.send_error(500, "LibreOffice soffice not found in PATH")
            return

        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = os.path.join(tmpdir, f"input.{source_ext}")
            with open(input_path, "wb") as f:
                print("[Convert] Reading request body...")
                remaining = length
                total_read = 0
                try:
                    while remaining > 0:
                        chunk = self.rfile.read(min(1024 * 1024, remaining))
                        if not chunk:
                            break
                        f.write(chunk)
                        total_read += len(chunk)
                        remaining -= len(chunk)
                except socket.timeout:
                    print("[Convert] Body read timed out.")
                print(f"[Convert] Body read bytes: {total_read}/{length}")
                if total_read < length:
                    self.send_error(400, f"Incomplete request body: {total_read}/{length} bytes")
                    return

            if use_adobe:
                try:
                    with open(input_path, "rb") as f:
                        input_data = f.read()
                    token = _adobe_access_token(adobe_client_id, adobe_client_secret)
                    upload_uri, asset_id = _adobe_create_asset(
                        adobe_base_url, token, adobe_client_id, "application/pdf"
                    )
                    _adobe_upload_asset(upload_uri, input_data, "application/pdf")
                    status_url = _adobe_export_pdf(
                        adobe_base_url, token, adobe_client_id, asset_id, target
                    )
                    download_uri = _adobe_poll_status(status_url, token, adobe_client_id)
                    data = _adobe_download(download_uri)
                except Exception as exc:
                    self.send_error(500, f"Adobe PDF Services conversion failed: {exc}")
                    return
            else:
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
    host = os.environ.get("CONVERT_HOST", "0.0.0.0")
    port = int(os.environ.get("CONVERT_PORT", "8787"))
    server = http.server.ThreadingHTTPServer((host, port), ConvertHandler)
    print(f"Convert server listening on http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
