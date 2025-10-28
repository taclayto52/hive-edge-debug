"""Publish a burst of MQTT messages over a single persistent connection."""

from __future__ import annotations

import argparse
import sys
import time
from typing import Optional

try:
    import paho.mqtt.client as mqtt
except ImportError:  # pragma: no cover - dependency hint
    print(
        "Error: paho-mqtt is required. Install it with 'pip install paho-mqtt'.",
        file=sys.stderr,
    )
    sys.exit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Publish a sequence of MQTT messages with incrementing counters.",
        epilog="Example: ./scripts/mqtt-publish-burst.sh --count 5 --topic testing/this/out",
    )
    parser.add_argument("--host", default="localhost", help="MQTT broker host (default: localhost)")
    parser.add_argument(
        "--port",
        type=int,
        default=1883,
        help="MQTT broker port (default: 1883)",
    )
    parser.add_argument(
        "--topic",
        default="testing/this/out",
        help="MQTT topic to publish to (default: testing/this/out)",
    )
    parser.add_argument(
        "--client-id",
        default="pubA",
        help="MQTT client identifier (default: pubA)",
    )
    parser.add_argument("--count", type=int, default=10, help="Number of messages to send (default: 10)")
    parser.add_argument("--start", type=int, default=1, help="Starting counter value (default: 1)")
    parser.add_argument(
        "--message-size",
        type=int,
        default=32,
        help="Exact payload size in bytes for each message (default: 32)",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.0,
        help="Delay between publishes in seconds (default: 0)",
    )
    return parser.parse_args()


def ensure_inputs(count: int, delay: float, message_size: int) -> None:
    if count <= 0:
        raise SystemExit("Count must be greater than zero.")
    if delay < 0:
        raise SystemExit("Delay must be non-negative.")
    if message_size <= 0:
        raise SystemExit("Message size must be greater than zero.")


def build_message(counter: int, message_size: int) -> str:
    counter_str = str(counter)
    # Reserve room for the counter and separator while honouring the exact message size.
    separator = ":"
    overhead = len(counter_str) + len(separator)
    if message_size < overhead:
        raise SystemExit(
            f"Message size must be at least {overhead} bytes to include the counter (got {message_size})."
        )
    filler_length = message_size - overhead
    filler = "x" * filler_length
    return f"{filler}{separator}{counter_str}"


def connect_client(client: mqtt.Client, host: str, port: int) -> None:
    connected: bool = False
    error: Optional[int] = None

    def on_connect(_client: mqtt.Client, _userdata, _flags, rc: int):  # type: ignore[override]
        nonlocal connected, error
        connected = True
        if rc != mqtt.MQTT_ERR_SUCCESS:
            error = rc

    client.on_connect = on_connect
    client.loop_start()
    client.connect(host, port)

    timeout = time.time() + 5
    while not connected and time.time() < timeout:
        time.sleep(0.01)

    if not connected:
        client.loop_stop()
        raise SystemExit("Timed out waiting for MQTT connection.")

    if error is not None:
        client.loop_stop()
        raise SystemExit(f"MQTT connection failed with code {error}.")


def publish_messages(args: argparse.Namespace) -> None:
    ensure_inputs(args.count, args.delay, args.message_size)

    client = mqtt.Client(client_id=args.client_id)

    try:
        connect_client(client, args.host, args.port)

        counter = args.start
        for i in range(args.count):
            message = build_message(counter, args.message_size)
            print(f"Publishing to {args.topic}: ...{message[-20:]} - sized {len(message)}")
            info = client.publish(args.topic, payload=message)
            info.wait_for_publish()
            if info.rc != mqtt.MQTT_ERR_SUCCESS:
                raise SystemExit(f"Publish failed with code {info.rc}.")
            counter += 1
            if args.delay > 0 and i != args.count - 1:
                time.sleep(args.delay)
    finally:
        try:
            client.disconnect()
        finally:
            client.loop_stop()


def main() -> None:
    args = parse_args()
    try:
        publish_messages(args)
    except KeyboardInterrupt:
        raise SystemExit("Interrupted")


if __name__ == "__main__":
    main()
