#!/usr/bin/env python3

import json
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ICECAST_URL = "http://127.0.0.1:8000/status-json.xsl"
LISTEN_ADDRESS = "0.0.0.0"
LISTEN_PORT = 9119
TIMEOUT_SECONDS = 3


def parse_timestamp(value):
    if not value:
        return 0.0

    try:
        return datetime.fromisoformat(value).timestamp()
    except (TypeError, ValueError):
        return 0.0


def parse_audio_info(value):
    result = {
        "bitrate": 0.0,
        "samplerate": 0.0,
        "channels": 0.0,
    }

    if not isinstance(value, str):
        return result

    for item in value.split(";"):
        if "=" not in item:
            continue

        key, raw_value = item.split("=", 1)
        key = key.strip()
        raw_value = raw_value.strip()

        if key in result:
            try:
                result[key] = float(raw_value)
            except ValueError:
                pass

    return result


def fetch_icecast():
    request = urllib.request.Request(
        ICECAST_URL,
        headers={"User-Agent": "novalabs-icecast-exporter/1.0"},
    )

    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def get_source(icestats):
    source = icestats.get("source")

    if isinstance(source, list):
        for candidate in source:
            if candidate.get("listenurl", "").endswith("/radio.mp3"):
                return candidate
        return None

    if isinstance(source, dict):
        if source.get("listenurl", "").endswith("/radio.mp3"):
            return source

    return None


def render_metrics():
    scrape_success = 0.0
    stream_up = 0.0
    listeners = 0.0
    listener_peak = 0.0
    bitrate = 0.0
    samplerate = 0.0
    channels = 0.0
    stream_start = 0.0
    server_start = 0.0

    try:
        payload = fetch_icecast()
        icestats = payload.get("icestats", {})
        source = get_source(icestats)

        scrape_success = 1.0
        server_start = parse_timestamp(icestats.get("server_start_iso8601"))

        if source:
            stream_up = 1.0
            listeners = float(source.get("listeners", 0) or 0)
            listener_peak = float(source.get("listener_peak", 0) or 0)

            audio = parse_audio_info(source.get("audio_info"))
            bitrate = audio["bitrate"]
            samplerate = audio["samplerate"]
            channels = audio["channels"]

            stream_start = parse_timestamp(
                source.get("stream_start_iso8601")
            )

    except Exception:
        pass

    metrics = [
        "# HELP icecast_exporter_scrape_success Whether the Icecast status endpoint was scraped successfully.",
        "# TYPE icecast_exporter_scrape_success gauge",
        f"icecast_exporter_scrape_success {scrape_success}",
        "# HELP icecast_stream_up Whether the radio mount is currently present.",
        "# TYPE icecast_stream_up gauge",
        f"icecast_stream_up {stream_up}",
        "# HELP icecast_listeners Current number of listeners.",
        "# TYPE icecast_listeners gauge",
        f"icecast_listeners {listeners}",
        "# HELP icecast_listener_peak Peak listener count reported by Icecast.",
        "# TYPE icecast_listener_peak gauge",
        f"icecast_listener_peak {listener_peak}",
        "# HELP icecast_bitrate_kbps Stream bitrate in kilobits per second.",
        "# TYPE icecast_bitrate_kbps gauge",
        f"icecast_bitrate_kbps {bitrate}",
        "# HELP icecast_samplerate_hz Stream sample rate in hertz.",
        "# TYPE icecast_samplerate_hz gauge",
        f"icecast_samplerate_hz {samplerate}",
        "# HELP icecast_channels Number of audio channels.",
        "# TYPE icecast_channels gauge",
        f"icecast_channels {channels}",
        "# HELP icecast_stream_start_timestamp_seconds Unix timestamp when the stream started.",
        "# TYPE icecast_stream_start_timestamp_seconds gauge",
        f"icecast_stream_start_timestamp_seconds {stream_start}",
        "# HELP icecast_server_start_timestamp_seconds Unix timestamp when Icecast started.",
        "# TYPE icecast_server_start_timestamp_seconds gauge",
        f"icecast_server_start_timestamp_seconds {server_start}",
    ]

    return "\n".join(metrics) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        body = render_metrics().encode()

        self.send_response(200)
        self.send_header(
            "Content-Type",
            "text/plain; version=0.0.4; charset=utf-8",
        )
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(
        (LISTEN_ADDRESS, LISTEN_PORT),
        Handler,
    )

    server.serve_forever()