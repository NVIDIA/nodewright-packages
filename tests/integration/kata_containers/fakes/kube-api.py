# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""A TLS Kubernetes API stub for smoke-pod lifecycle contract tests."""

import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import socket
import ssl


CASE = os.environ.get("CASE", "success")
OWNER = hashlib.sha256(b"test-resource:test-node").hexdigest()
TRACE = Path("/tmp/kata-api-trace")
TRACE.touch()
STATE = {"pod": None, "gets": 0, "posts": 0, "deletes": 0, "transient": False}


def existing(name, foreign=False):
    return {"metadata": {"name": name, "uid": "previous-uid",
        "annotations": {"nodewright.nvidia.com/kata-smoke-owner": "another-owner" if foreign else OWNER}},
        "spec": {"nodeName": "test-node", "runtimeClassName": "kata-containers-qemu-nvidia-cpu-runtime-rs"}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self, body=None):
        assert self.headers.get("Authorization") == "Bearer REPLACE_ME"
        with TRACE.open("a") as stream:
            stream.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")

    def send(self, code, value):
        payload = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.record()
        if CASE in ("foreign", "stale") and STATE["pod"] is None and STATE["posts"] == 0 and STATE["deletes"] == 0:
            STATE["pod"] = existing(self.path.rsplit("/", 1)[1], CASE == "foreign")
        if CASE == "forbidden":
            return self.send(403, {"message": "denied"})
        if STATE["pod"] is None:
            return self.send(404, {"reason": "NotFound"})
        if CASE == "transient" and not STATE["transient"] and STATE["posts"]:
            STATE["transient"] = True
            return self.send(503, {"reason": "ServiceUnavailable"})
        STATE["gets"] += 1
        phase = "Pending" if CASE == "timeout" else "Failed" if CASE == "failed" else "Succeeded"
        STATE["pod"]["status"] = {"phase": phase, "containerStatuses": [{"name": "guest", "state": {
            "terminated": {"exitCode": 1 if CASE == "wrong-exit" else 0}}}]}
        return self.send(200, STATE["pod"])

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.record(body)
        if STATE["pod"]:
            return self.send(409, {"reason": "AlreadyExists"})
        STATE["posts"] += 1
        body["metadata"]["uid"] = "created-uid"
        STATE["pod"] = body
        if CASE == "lost-response" and STATE["posts"] == 1:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        return self.send(201, body)

    def do_DELETE(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.record(body)
        STATE["deletes"] += 1
        if CASE == "delete-forbidden":
            return self.send(403, {"reason": "Forbidden"})
        if CASE == "uid-conflict":
            return self.send(409, {"reason": "Conflict"})
        if not STATE["pod"]:
            return self.send(404, {"reason": "NotFound"})
        if body.get("preconditions", {}).get("uid") != STATE["pod"]["metadata"]["uid"]:
            return self.send(409, {"reason": "Conflict"})
        if CASE != "delete-stuck":
            STATE["pod"] = None
        return self.send(200, {"status": "Success"})


server = HTTPServer(("127.0.0.1", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/tmp/smoke-cert.pem", "/tmp/smoke-key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
Path("/tmp/kata-api-ready").touch()
server.serve_forever()
