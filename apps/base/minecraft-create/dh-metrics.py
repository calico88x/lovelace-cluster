#!/usr/bin/env python3

import os
import re
import socket
import struct
import time
from pathlib import Path


RCON_HOST = os.environ.get("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("RCON_PORT", "25575"))
RCON_PASSWORD = os.environ["RCON_PASSWORD"]
POLL_SECONDS = max(float(os.environ.get("POLL_SECONDS", "5")), 1.0)
METRICS_FILE = Path(
    os.environ.get("METRICS_FILE", "/textfile/minecraft_dh.prom")
)

ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

POOL_NAMES = {
    "World Gen/Import": "world_gen_import",
    "Render Load": "render_load",
    "File Handler": "file_handler",
    "Update Propagator": "update_propagator",
    "LOD Builder": "lod_builder",
    "Networking": "networking",
}

POOL_PATTERN = re.compile(
    r"^(?P<name>World Gen/Import|Render Load|File Handler|"
    r"Update Propagator|LOD Builder|Networking), "
    r"Tasks: (?P<queued>[\d,]+), "
    r"Done: (?P<completed>[\d,]+), "
    r"Active: (?P<active>[\d,]+)/(?P<capacity>[\d,]+), "
    r"Avg: <?(?P<average_ms>[\d,.]+)ms$",
    re.MULTILINE,
)

QUEUE_PATTERN = re.compile(
    r"^Chunk Update Queues: (?P<active>[\d,]+)/(?P<capacity>[\d,]+)$",
    re.MULTILINE,
)

VERSION_PATTERN = re.compile(r"^Distant Horizons: (?P<version>\S+)$", re.MULTILINE)


def parse_integer(value):
    return int(value.replace(",", ""))


def parse_number(value):
    return float(value.replace(",", ""))


def clean_output(value):
    return ANSI_ESCAPE.sub("", value).replace("\r", "")


def parse_debug_output(raw_output):
    output = clean_output(raw_output)
    pools = {}

    for match in POOL_PATTERN.finditer(output):
        pool = POOL_NAMES[match.group("name")]
        pools[pool] = {
            "queued": parse_integer(match.group("queued")),
            "completed": parse_integer(match.group("completed")),
            "active": parse_integer(match.group("active")),
            "capacity": parse_integer(match.group("capacity")),
            "average_seconds": parse_number(match.group("average_ms")) / 1000.0,
        }

    missing_pools = set(POOL_NAMES.values()) - set(pools)
    if missing_pools:
        missing = ", ".join(sorted(missing_pools))
        raise ValueError(f"missing DH task pools: {missing}")

    queue_match = QUEUE_PATTERN.search(output)
    if queue_match is None:
        raise ValueError("missing DH chunk update queue status")

    version_match = VERSION_PATTERN.search(output)
    if version_match is None:
        raise ValueError("missing DH version")

    return {
        "version": version_match.group("version"),
        "pools": pools,
        "chunk_update_queues_active": parse_integer(queue_match.group("active")),
        "chunk_update_queues_capacity": parse_integer(queue_match.group("capacity")),
    }


class RconConnection:
    def __init__(self, host, port, password):
        self.host = host
        self.port = port
        self.password = password
        self.socket = None
        self.request_id = 100

    def close(self):
        if self.socket is not None:
            try:
                self.socket.close()
            finally:
                self.socket = None

    @staticmethod
    def _read_exact(connection, length):
        chunks = []
        remaining = length

        while remaining:
            chunk = connection.recv(remaining)
            if not chunk:
                raise ConnectionError("RCON connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)

        return b"".join(chunks)

    @staticmethod
    def _packet(request_id, packet_type, payload):
        encoded_payload = payload.encode("utf-8")
        packet_length = len(encoded_payload) + 10
        return (
            struct.pack("<iii", packet_length, request_id, packet_type)
            + encoded_payload
            + b"\x00\x00"
        )

    def _receive(self):
        raw_length = self._read_exact(self.socket, 4)
        packet_length = struct.unpack("<i", raw_length)[0]

        if packet_length < 10 or packet_length > 10 * 1024 * 1024:
            raise ValueError(f"invalid RCON packet length: {packet_length}")

        packet = self._read_exact(self.socket, packet_length)
        request_id, packet_type = struct.unpack("<ii", packet[:8])
        payload = packet[8:-2].decode("utf-8", errors="replace")
        return request_id, packet_type, payload

    def connect(self):
        self.close()
        connection = socket.create_connection((self.host, self.port), timeout=5)
        connection.settimeout(5)
        self.socket = connection

        auth_id = 1
        self.socket.sendall(self._packet(auth_id, 3, self.password))

        for _ in range(2):
            response_id, response_type, _ = self._receive()

            if response_id == -1:
                raise PermissionError("RCON authentication failed")

            if response_type == 2:
                if response_id != auth_id:
                    raise PermissionError("unexpected RCON authentication response")
                return

        raise PermissionError("RCON authentication response was not received")

    def command(self, command):
        if self.socket is None:
            self.connect()

        self.request_id += 1
        request_id = self.request_id
        self.socket.sendall(self._packet(request_id, 2, command))
        response_id, _, payload = self._receive()

        if response_id != request_id:
            raise ValueError(
                f"unexpected RCON response ID {response_id}; expected {request_id}"
            )

        return payload


def prometheus_document(
    *,
    up,
    errors,
    last_success_timestamp,
    collection_duration,
    debug=None,
    pregen_running=None,
):
    lines = [
        "# HELP minecraft_dh_up Whether the DH collector can query and parse the server.",
        "# TYPE minecraft_dh_up gauge",
        f"minecraft_dh_up {up}",
        "# HELP minecraft_dh_collector_errors_total Total DH collector failures.",
        "# TYPE minecraft_dh_collector_errors_total counter",
        f"minecraft_dh_collector_errors_total {errors}",
        "# HELP minecraft_dh_last_success_timestamp_seconds Unix timestamp of the latest successful DH collection.",
        "# TYPE minecraft_dh_last_success_timestamp_seconds gauge",
        f"minecraft_dh_last_success_timestamp_seconds {last_success_timestamp:.3f}",
        "# HELP minecraft_dh_collection_duration_seconds Time required to collect and parse DH statistics.",
        "# TYPE minecraft_dh_collection_duration_seconds gauge",
        f"minecraft_dh_collection_duration_seconds {collection_duration:.6f}",
    ]

    if debug is not None:
        version = debug["version"].replace("\\", "\\\\").replace('"', '\\"')
        lines.extend(
            [
                "# HELP minecraft_dh_info Distant Horizons build information.",
                "# TYPE minecraft_dh_info gauge",
                f'minecraft_dh_info{{version="{version}"}} 1',
                "# HELP minecraft_dh_pregen_running Whether explicit DH pregeneration is running.",
                "# TYPE minecraft_dh_pregen_running gauge",
                f"minecraft_dh_pregen_running {pregen_running}",
                "# HELP minecraft_dh_task_queued Current tasks waiting in a DH task pool.",
                "# TYPE minecraft_dh_task_queued gauge",
                "# HELP minecraft_dh_task_completed_total Tasks completed by a DH task pool since process start.",
                "# TYPE minecraft_dh_task_completed_total counter",
                "# HELP minecraft_dh_task_active Current active workers in a DH task pool.",
                "# TYPE minecraft_dh_task_active gauge",
                "# HELP minecraft_dh_task_capacity Configured worker capacity for a DH task pool.",
                "# TYPE minecraft_dh_task_capacity gauge",
                "# HELP minecraft_dh_task_average_duration_seconds Average task duration reported by DH.",
                "# TYPE minecraft_dh_task_average_duration_seconds gauge",
            ]
        )

        for pool, values in debug["pools"].items():
            labels = f'{{pool="{pool}"}}'
            lines.extend(
                [
                    f"minecraft_dh_task_queued{labels} {values['queued']}",
                    f"minecraft_dh_task_completed_total{labels} {values['completed']}",
                    f"minecraft_dh_task_active{labels} {values['active']}",
                    f"minecraft_dh_task_capacity{labels} {values['capacity']}",
                    f"minecraft_dh_task_average_duration_seconds{labels} {values['average_seconds']:.6f}",
                ]
            )

        lines.extend(
            [
                "# HELP minecraft_dh_chunk_update_queues_active Current active DH chunk update queues.",
                "# TYPE minecraft_dh_chunk_update_queues_active gauge",
                f"minecraft_dh_chunk_update_queues_active {debug['chunk_update_queues_active']}",
                "# HELP minecraft_dh_chunk_update_queues_capacity Configured DH chunk update queue capacity.",
                "# TYPE minecraft_dh_chunk_update_queues_capacity gauge",
                f"minecraft_dh_chunk_update_queues_capacity {debug['chunk_update_queues_capacity']}",
            ]
        )

    return "\n".join(lines) + "\n"


def write_metrics(document):
    temporary_file = METRICS_FILE.with_suffix(METRICS_FILE.suffix + ".tmp")
    temporary_file.write_text(document, encoding="utf-8")
    os.replace(temporary_file, METRICS_FILE)


def main():
    client = RconConnection(RCON_HOST, RCON_PORT, RCON_PASSWORD)
    errors = 0
    last_success_timestamp = 0.0
    collector_was_up = False

    while True:
        started = time.monotonic()

        try:
            debug_output = client.command("dh debug")
            pregen_output = clean_output(client.command("dh pregen status"))
            debug = parse_debug_output(debug_output)

            if "Pregen is not running" in pregen_output:
                pregen_running = 0
            elif pregen_output.strip():
                pregen_running = 1
            else:
                raise ValueError("empty DH pregen response")

            last_success_timestamp = time.time()
            duration = time.monotonic() - started
            document = prometheus_document(
                up=1,
                errors=errors,
                last_success_timestamp=last_success_timestamp,
                collection_duration=duration,
                debug=debug,
                pregen_running=pregen_running,
            )
            write_metrics(document)

            if not collector_was_up:
                print(
                    f"DH metrics collection connected to {RCON_HOST}:{RCON_PORT}",
                    flush=True,
                )
            collector_was_up = True

        except Exception as error:
            errors += 1
            client.close()
            duration = time.monotonic() - started

            try:
                write_metrics(
                    prometheus_document(
                        up=0,
                        errors=errors,
                        last_success_timestamp=last_success_timestamp,
                        collection_duration=duration,
                    )
                )
            except Exception as write_error:
                print(f"Unable to write DH failure metrics: {write_error}", flush=True)

            if collector_was_up or errors == 1 or errors % 12 == 0:
                print(f"DH metrics collection failed: {error}", flush=True)
            collector_was_up = False

        elapsed = time.monotonic() - started
        time.sleep(max(POLL_SECONDS - elapsed, 0.1))


if __name__ == "__main__":
    main()
