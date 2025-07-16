#!/usr/bin/env python3
"""Simple HTTP server for offline assets.

This script serves the directory containing downloaded package
and image files so that other nodes in the cluster can fetch them
without manual copying. It only uses Python's standard library and
therefore works in air‑gapped environments.
"""
import http.server
import socketserver
import os
import argparse


def main():
    parser = argparse.ArgumentParser(description="Serve offline assets via HTTP")
    parser.add_argument(
        "-d", "--directory", default="/opt/offline",
        help="Root directory containing 'pkgs' and 'images' subdirectories",
    )
    parser.add_argument(
        "-p", "--port", type=int, default=8080, help="Port to listen on"
    )
    args = parser.parse_args()

    os.chdir(args.directory)
    handler = http.server.SimpleHTTPRequestHandler
    with socketserver.TCPServer(("", args.port), handler) as httpd:
        print(f"Serving {args.directory} on port {args.port}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            httpd.server_close()


if __name__ == "__main__":
    main()
