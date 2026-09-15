#!/usr/bin/env python3

import base64
import json
import os
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ICECAST_URL = "http://127.0.0.1:8000/status-json.xsl"
ICECAST_CLIENTS_URL = (
    "http://127.0.0.1:8000/admin/listclients?mount=/radio.mp3"
)

ICECAST_ADMIN_USERNAME = os.environ.get(
    "ICECAST_ADMIN_USERNAME",
    "admin",
)
ICECAST_ADMIN_PASSWORD = os.environ.get(
    "ICECAST_ADMIN_PASSWORD",
    "",
)

LISTEN_ADDRESS = "0.0.0.0"
LISTEN_PORT = 9119
TIMEOUT_SECONDS = 3

LISTENER_START_CLUSTER_SECONDS = 3.0


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
        headers={
            "User-Agent": "novalabs-icecast-exporter/1.0",
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=TIMEOUT_SECONDS,
    ) as response:
        return json.load(response)


def fetch_icecast_clients():
    credentials = (
        f"{ICECAST_ADMIN_USERNAME}:{ICECAST_ADMIN_PASSWORD}"
    ).encode()

    authorization = base64.b64encode(credentials).decode()

    request = urllib.request.Request(
        ICECAST_CLIENTS_URL,
        headers={
            "Authorization": f"Basic {authorization}",
            "User-Agent": "novalabs-icecast-exporter/1.0",
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=TIMEOUT_SECONDS,
    ) as response:
        return ET.fromstring(response.read())


def get_source(icestats):
    source = icestats.get("source")

    if isinstance(source, list):
        for candidate in source:
            if candidate.get(
                "listenurl",
                "",
            ).endswith("/radio.mp3"):
                return candidate

        return None

    if isinstance(source, dict):
        if source.get(
            "listenurl",
            "",
        ).endswith("/radio.mp3"):
            return source

    return None


def estimate_unique_listeners(root):
    listeners = root.findall("./source/listener")

    if not listeners:
        return 0.0

    now = time.time()
    fingerprints = {}

    for listener in listeners:
        ip = listener.findtext("ip", default="")
        user_agent = listener.findtext(
            "useragent",
            default="",
        )
        referer = listener.findtext(
            "referer",
            default="",
        )
        host = listener.findtext(
            "host",
            default="",
        )

        try:
            connected = float(
                listener.findtext(
                    "connected",
                    default="0",
                )
                or 0
            )
        except ValueError:
            connected = 0.0

        approximate_start = now - connected

        fingerprint = (
            ip,
            user_agent,
            referer,
            host,
        )

        fingerprints.setdefault(
            fingerprint,
            [],
        ).append(approximate_start)

    estimated_unique = 0

    for start_times in fingerprints.values():
        start_times.sort()

        cluster_start = None

        for start_time in start_times:
            if cluster_start is None:
                estimated_unique += 1
                cluster_start = start_time
                continue

            if (
                start_time - cluster_start
                > LISTENER_START_CLUSTER_SECONDS
            ):
                estimated_unique += 1
                cluster_start = start_time

    return float(estimated_unique)


def render_metrics():
    scrape_success = 0.0
    listener_estimator_success = 0.0
    stream_up = 0.0
    listeners = 0.0
    estimated_unique_listeners = 0.0
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
        server_start = parse_timestamp(
            icestats.get("server_start_iso8601")
        )

        if source:
            stream_up = 1.0

            listeners = float(
                source.get("listeners", 0)
                or 0
            )

            listener_peak = float(
                source.get("listener_peak", 0)
                or 0
            )

            audio = parse_audio_info(
                source.get("audio_info")
            )

            bitrate = audio["bitrate"]
            samplerate = audio["samplerate"]
            channels = audio["channels"]

            stream_start = parse_timestamp(
                source.get(
                    "stream_start_iso8601"
                )
            )

            estimated_unique_listeners = listeners

            try:
                clients = fetch_icecast_clients()

                estimated_unique_listeners = (
                    estimate_unique_listeners(
                        clients
                    )
                )

                listener_estimator_success = 1.0

            except Exception:
                pass

    except Exception:
        pass

    metrics = [
        "# HELP icecast_exporter_scrape_success Whether the Icecast status endpoint was scraped successfully.",
        "# TYPE icecast_exporter_scrape_success gauge",
        f"icecast_exporter_scrape_success {scrape_success}",

        "# HELP icecast_listener_estimator_success Whether the Icecast client list was scraped successfully.",
        "# TYPE icecast_listener_estimator_success gauge",
        (
            "icecast_listener_estimator_success "
            f"{listener_estimator_success}"
        ),

        "# HELP icecast_stream_up Whether the radio mount is currently present.",
        "# TYPE icecast_stream_up gauge",
        f"icecast_stream_up {stream_up}",

        "# HELP icecast_listeners Current number of Icecast listener connections.",
        "# TYPE icecast_listeners gauge",
        f"icecast_listeners {listeners}",

        "# HELP icecast_estimated_unique_listeners Estimated number of unique active listeners.",
        "# TYPE icecast_estimated_unique_listeners gauge",
        (
            "icecast_estimated_unique_listeners "
            f"{estimated_unique_listeners}"
        ),

        "# HELP icecast_listener_peak Peak listener connection count reported by Icecast.",
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
        (
            "icecast_stream_start_timestamp_seconds "
            f"{stream_start}"
        ),

        "# HELP icecast_server_start_timestamp_seconds Unix timestamp when Icecast started.",
        "# TYPE icecast_server_start_timestamp_seconds gauge",
        (
            "icecast_server_start_timestamp_seconds "
            f"{server_start}"
        ),
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

        self.send_header(
            "Content-Length",
            str(len(body)),
        )

        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(
        (
            LISTEN_ADDRESS,
            LISTEN_PORT,
        ),
        Handler,
    )

    server.serve_forever()