#!/usr/bin/env python3
"""AirBridge CLI — control AirBridge from the command line."""

import argparse
import json
import mimetypes
import os
import sys
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def base_url(args):
    return f"http://{args.host}:{args.port}"


def headers(args):
    h = {}
    if args.token:
        h["Authorization"] = f"Bearer {args.token}"
    return h


def api(method, path, args, body=None, content_type=None):
    url = f"{base_url(args)}{path}"
    h = headers(args)
    if content_type:
        h["Content-Type"] = content_type
    req = Request(url, data=body, headers=h, method=method)
    try:
        with urlopen(req) as resp:
            data = resp.read()
            return json.loads(data) if data else {}
    except HTTPError as e:
        data = e.read()
        try:
            err = json.loads(data)
            print(f"Error {e.code}: {err.get('message', err.get('error', data.decode()))}", file=sys.stderr)
        except (json.JSONDecodeError, UnicodeDecodeError):
            print(f"Error {e.code}: {data.decode()}", file=sys.stderr)
        sys.exit(1)
    except URLError as e:
        print(f"Connection failed: {e.reason}", file=sys.stderr)
        sys.exit(1)


def multipart_upload(method, path, args, filepath):
    boundary = uuid.uuid4().hex
    filename = os.path.basename(filepath)
    mime = mimetypes.guess_type(filepath)[0] or "application/octet-stream"

    with open(filepath, "rb") as f:
        file_data = f.read()

    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {mime}\r\n"
        f"\r\n"
    ).encode() + file_data + f"\r\n--{boundary}--\r\n".encode()

    return api(method, path, args, body=body, content_type=f"multipart/form-data; boundary={boundary}")


def pp(data):
    print(json.dumps(data, indent=2))


# --- subcommand handlers ---

def cmd_status(args):
    pp(api("GET", "/status", args))


def cmd_play(args):
    pp(multipart_upload("POST", "/play", args, args.file))


def cmd_queue(args):
    pp(multipart_upload("POST", "/queue", args, args.file))


def cmd_queue_list(args):
    pp(api("GET", "/queue", args))


def cmd_queue_next(args):
    pp(api("POST", "/queue/next", args))


def cmd_queue_prev(args):
    pp(api("POST", "/queue/prev", args))


def cmd_queue_remove(args):
    pp(api("DELETE", f"/queue/{args.id}", args))


def cmd_queue_move(args):
    body = json.dumps({"id": args.id, "position": args.position}).encode()
    pp(api("POST", "/queue/move", args, body=body, content_type="application/json"))


def cmd_pause(args):
    pp(api("POST", "/pause", args))


def cmd_resume(args):
    pp(api("POST", "/resume", args))


def cmd_stop(args):
    pp(api("POST", "/stop", args))


def cmd_outputs(args):
    pp(api("GET", "/outputs", args))


def cmd_output(args):
    pp(api("GET", "/outputs/current", args))


def cmd_output_set(args):
    body = json.dumps({"id": args.id}).encode()
    pp(api("PUT", "/outputs/current", args, body=body, content_type="application/json"))


def main():
    parser = argparse.ArgumentParser(prog="airbridge", description="AirBridge CLI")
    parser.add_argument("-H", "--host", default="127.0.0.1", help="AirBridge host (default: 127.0.0.1)")
    parser.add_argument("-p", "--port", type=int, default=9876, help="AirBridge port (default: 9876)")
    parser.add_argument("-t", "--token", default=None, help="Bearer auth token")

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Show playback status")

    p = sub.add_parser("play", help="Upload and play immediately")
    p.add_argument("file", help="Audio file to play")

    p = sub.add_parser("queue", help="Upload and enqueue")
    p.add_argument("file", help="Audio file to enqueue")

    sub.add_parser("queue-list", help="List queue tracks")
    sub.add_parser("queue-next", help="Skip to next track")
    sub.add_parser("queue-prev", help="Go to previous track")

    p = sub.add_parser("queue-remove", help="Remove a track from queue")
    p.add_argument("id", help="Track UUID to remove")

    p = sub.add_parser("queue-move", help="Move a track to a new position")
    p.add_argument("id", help="Track UUID to move")
    p.add_argument("position", type=int, help="Target position (0-based)")

    sub.add_parser("pause", help="Pause playback")
    sub.add_parser("resume", help="Resume playback")
    sub.add_parser("stop", help="Stop playback and clear queue")

    sub.add_parser("outputs", help="List AirPlay devices")
    sub.add_parser("output", help="Show selected AirPlay device")

    p = sub.add_parser("output-set", help="Select an AirPlay device")
    p.add_argument("id", help="Bonjour service ID of the device")

    args = parser.parse_args()

    dispatch = {
        "status": cmd_status,
        "play": cmd_play,
        "queue": cmd_queue,
        "queue-list": cmd_queue_list,
        "queue-next": cmd_queue_next,
        "queue-prev": cmd_queue_prev,
        "queue-remove": cmd_queue_remove,
        "queue-move": cmd_queue_move,
        "pause": cmd_pause,
        "resume": cmd_resume,
        "stop": cmd_stop,
        "outputs": cmd_outputs,
        "output": cmd_output,
        "output-set": cmd_output_set,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
