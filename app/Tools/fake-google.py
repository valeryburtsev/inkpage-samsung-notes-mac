#!/usr/bin/env python3
"""A stand-in for Google on this Mac, for checking the app's Google Drive sync without Google.

Answers as Google's sign-in page (by sending the browser straight back with a code), its token
service and Drive v3 (the app's hidden folder, kept in memory) are documented to answer.

    fake-google.py <port> [page size]

The app is pointed at it with --google-test-server=http://127.0.0.1:<port>.
"""
import base64, hashlib, json, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
files = []          # {id, name, data, modified}
codes = {}          # code -> challenge
tokens = set()
pending = {}        # upload id -> (name, file id)
clock = [0]
page_size = int(sys.argv[2]) if len(sys.argv) > 2 else 1000


def tick():
    clock[0] += 1
    return clock[0]


def described(f):
    return {"id": f["id"], "name": f["name"], "md5Checksum": hashlib.md5(f["data"]).hexdigest(),
            "modifiedTime": "2026-10-13T%02d:%02d:%02d.000Z" % (f["modified"] // 3600, f["modified"] // 60 % 60, f["modified"] % 60)}


def store(name, file_id, data):
    if file_id:
        for f in files:
            if f["id"] == file_id:
                f["data"] = data
                f["modified"] = tick()
                if name:
                    f["name"] = name
                return 200, described(f)
        return 404, {"error": {"message": "File not found"}}
    f = {"id": "f%d" % tick(), "name": name or "", "data": data, "modified": clock[0]}
    files.append(f)
    return 200, described(f)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, form, *args):
        sys.stdout.write("%s %s -> %s\n" % (self.command, self.path.split("?")[0], args[1] if len(args) > 1 else ""))
        sys.stdout.flush()

    def answer(self, status, body=b"", headers=None, kind="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        url = urllib.parse.urlsplit(self.path)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        path, method = url.path, self.command
        with lock:
            # The sign-in page: whoever opens it is "signed in" and sent back with a code.
            if path == "/o/oauth2/v2/auth":
                wanted = ["client_id", "redirect_uri", "state", "code_challenge", "scope"]
                if any(k not in query for k in wanted) or query.get("response_type") != "code" or query.get("code_challenge_method") != "S256":
                    return self.answer(400, b"the page was not asked for properly", kind="text/plain")
                code = "code%d" % tick()
                codes[code] = (query["code_challenge"], query["redirect_uri"], query["client_id"])
                back = query["redirect_uri"] + "?" + urllib.parse.urlencode({"state": query["state"], "code": code, "scope": query["scope"]})
                return self.answer(302, b"", {"Location": back})
            if path == "/token":
                form = {k: v[0] for k, v in urllib.parse.parse_qs(body.decode()).items()}
                good = False
                if form.get("grant_type") == "authorization_code" and form.get("code") in codes:
                    challenge, redirect, client = codes.pop(form["code"])
                    made = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).decode().rstrip("=")
                    good = made == challenge and form.get("redirect_uri") == redirect and form.get("client_id") == client
                elif form.get("grant_type") == "refresh_token":
                    good = form.get("refresh_token") == "lasting"
                if not good:
                    return self.answer(400, {"error": "invalid_grant", "error_description": "Bad Request"})
                token = "access%d" % tick()
                tokens.add(token)
                out = {"access_token": token, "expires_in": 3600, "token_type": "Bearer", "scope": "https://www.googleapis.com/auth/drive.appdata"}
                if form["grant_type"] == "authorization_code":
                    out["refresh_token"] = "lasting"
                return self.answer(200, out)
            if path == "/revoke":
                return self.answer(200, {})
            if path == "/_files":
                return self.answer(200, sorted(f["name"] for f in files))

            bearer = self.headers.get("Authorization", "")
            if not bearer.startswith("Bearer ") or bearer[7:] not in tokens:
                return self.answer(401, {"error": {"code": 401, "message": "Invalid Credentials"}})
            if path == "/drive/v3/about":
                return self.answer(200, {"user": {"emailAddress": "user@example.com"}})
            if path == "/drive/v3/files" and method == "GET":
                if query.get("spaces") != "appDataFolder":
                    return self.answer(400, {"error": {"message": "only the hidden folder is allowed"}})
                start = int(query.get("pageToken") or 0)
                page = files[start:start + page_size]
                out = {"files": [described(f) for f in page]}
                if start + len(page) < len(files):
                    out["nextPageToken"] = str(start + len(page))
                return self.answer(200, out)
            if path.startswith("/drive/v3/files/"):
                file_id = path[len("/drive/v3/files/"):]
                found = [f for f in files if f["id"] == file_id]
                if not found:
                    return self.answer(404, {"error": {"message": "File not found"}})
                if method == "DELETE":
                    files.remove(found[0])
                    return self.answer(204)
                if method == "GET" and query.get("alt") == "media":
                    return self.answer(200, found[0]["data"], kind="application/octet-stream")
            if path.startswith("/upload/drive/v3/files"):
                file_id = path[len("/upload/drive/v3/files/"):] or None
                if method == "PUT" and query.get("upload_id") in pending:
                    name, target = pending.pop(query["upload_id"])
                    return self.answer(*store(name, target, body))
                if method != ("PATCH" if file_id else "POST"):
                    return self.answer(400, {"error": {"message": "wrong method"}})
                if query.get("uploadType") == "multipart":
                    boundary = self.headers.get("Content-Type", "").split("boundary=")[-1].encode()
                    parts = body.split(b"--" + boundary)
                    if len(parts) < 4:
                        return self.answer(400, {"error": {"message": "not two parts"}})
                    metadata = json.loads(parts[1].split(b"\r\n\r\n", 1)[1].rsplit(b"\r\n", 1)[0])
                    content = parts[2].split(b"\r\n\r\n", 1)[1][:-2]
                    if (metadata.get("parents") == ["appDataFolder"]) != (file_id is None):
                        return self.answer(403, {"error": {"message": "a new file belongs in the hidden folder, an old one stays where it is"}})
                    return self.answer(*store(metadata.get("name"), file_id, content))
                if query.get("uploadType") == "resumable":
                    metadata = json.loads(body)
                    if file_id and not [f for f in files if f["id"] == file_id]:
                        return self.answer(404, {"error": {"message": "File not found"}})
                    upload = "u%d" % tick()
                    pending[upload] = (metadata.get("name"), file_id)
                    return self.answer(200, b"", {"Location": "http://%s/upload/drive/v3/files?uploadType=resumable&upload_id=%s" % (self.headers.get("Host"), upload)})
            return self.answer(400, {"error": {"message": "unexpected %s %s" % (method, path)}})

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_any


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    print("standing in for Google on http://127.0.0.1:%d" % server.server_address[1], flush=True)
    server.serve_forever()
