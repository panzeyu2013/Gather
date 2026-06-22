import io
import os
import struct

# Add engine directory to path so we can import protocol
import sys

import msgpack

_engine_dir = os.path.join(os.path.dirname(__file__), "..", "desktop", "engine")
if _engine_dir not in sys.path:
    sys.path.insert(0, _engine_dir)

import protocol


def _pack_message(msg: dict) -> bytes:
    payload = msgpack.packb(msg)
    header = struct.pack(">I", len(payload))
    return header + payload  # type: ignore[no-any-return]


def _reset_protocol_state():
    protocol._read_buffer = b""
    protocol._binary_stream_cache = {}


# ---------------------------------------------------------------------------
# Valid 4-byte frame header + msgpack payload
# ---------------------------------------------------------------------------


def test_read_single_message():
    _reset_protocol_state()
    msg = {"id": 1, "type": "test", "payload": "hello"}
    stream = io.BytesIO(_pack_message(msg))

    result = protocol.read_message(stream)
    assert result == msg


def test_read_multiple_messages():
    _reset_protocol_state()
    msgs = [
        {"id": 1, "type": "a"},
        {"id": 2, "type": "b"},
        {"id": 3, "type": "c"},
    ]
    data = b"".join(_pack_message(m) for m in msgs)
    stream = io.BytesIO(data)

    for expected in msgs:
        result = protocol.read_message(stream)
        assert result == expected


def test_read_message_with_nested_data():
    _reset_protocol_state()
    msg = {
        "id": 42,
        "ok": True,
        "data": {
            "sessions": [
                {"id": "abc", "name": "Session 1", "photo_count": 5},
                {"id": "def", "name": "Session 2", "photo_count": 10},
            ]
        },
    }
    stream = io.BytesIO(_pack_message(msg))

    result = protocol.read_message(stream)
    assert result == msg


# ---------------------------------------------------------------------------
# Oversized message triggers ValueError
# ---------------------------------------------------------------------------


def test_oversized_message_is_skipped_and_stream_continues():
    _reset_protocol_state()
    oversized_length = protocol.MAX_MESSAGE_SIZE + 1
    header = struct.pack(">I", oversized_length)
    body = b"\x00" * 10  # some garbage after header
    stream = io.BytesIO(header + body)

    # Protocol now skips oversized frames and returns None (stream exhausted)
    result = protocol.read_message(stream)
    assert result is None

    # Buffer should be cleared after the oversized frame is skipped
    assert protocol._read_buffer == b""


# ---------------------------------------------------------------------------
# Split packets across multiple read() calls
# ---------------------------------------------------------------------------


def test_header_split_across_reads():
    _reset_protocol_state()
    msg = {"id": 1, "type": "split_header"}
    full_data = _pack_message(msg)

    # First read: only 2 bytes of the 4-byte header
    first = full_data[:2]
    second = full_data[2:]

    stream = io.BytesIO(first + second)

    # Make read() return only the first 2 bytes on first call
    original_read = stream.read
    call_count = [0]

    def simulated_read(n=-1):
        if call_count[0] == 0:
            call_count[0] += 1
            chunk = bytes(original_read(2))
            return chunk
        return original_read(n)

    stream.read = simulated_read  # type: ignore[method-assign]

    result = protocol.read_message(stream)
    assert result == msg


def test_body_split_across_reads():
    _reset_protocol_state()
    msg = {"id": 2, "type": "split_body"}
    full_data = _pack_message(msg)

    # Read 4-byte header + first half of body, then the rest
    split_point = 4 + len(msgpack.packb(msg)) // 2
    first = full_data[:split_point]
    second = full_data[split_point:]

    stream = io.BytesIO(first + second)
    original_read = stream.read
    call_count = [0]

    def simulated_read(n=-1):
        if call_count[0] == 0:
            call_count[0] += 1
            chunk = bytes(original_read(len(first)))
            return chunk
        return original_read(n)

    stream.read = simulated_read  # type: ignore[method-assign]

    _reset_protocol_state()
    result = protocol.read_message(stream)
    assert result == msg



def test_multiple_messages_with_split_boundaries():
    _reset_protocol_state()
    msg1 = {"id": 1, "type": "first"}
    msg2 = {"id": 2, "type": "second"}
    full_data = _pack_message(msg1) + _pack_message(msg2)

    # Split in the middle of the second message's body
    split_point = len(_pack_message(msg1)) + 4
    first = full_data[:split_point]
    second = full_data[split_point:]

    stream = io.BytesIO(first + second)
    original_read = stream.read
    call_count = [0]

    def simulated_read(n=-1):
        if call_count[0] == 0:
            call_count[0] += 1
            chunk = bytes(original_read(len(first)))
            return chunk
        return original_read(n)

    stream.read = simulated_read  # type: ignore[method-assign]

    _reset_protocol_state()
    r1 = protocol.read_message(stream)
    assert r1 == msg1
    r2 = protocol.read_message(stream)
    assert r2 == msg2


def test_tiny_chunks():
    """Read message 1 byte at a time."""
    _reset_protocol_state()
    msg = {"id": 7, "type": "byte_by_byte"}
    full_data = _pack_message(msg)

    stream = io.BytesIO(full_data)
    original_read = stream.read
    call_count = [0]

    def simulated_read(n=-1):
        call_count[0] += 1
        chunk = bytes(original_read(1))
        return chunk

    stream.read = simulated_read  # type: ignore[method-assign]

    result = protocol.read_message(stream)
    assert result == msg
    # Should have made many read calls
    assert call_count[0] >= len(full_data)


# ---------------------------------------------------------------------------
# EOF returns None
# ---------------------------------------------------------------------------


def test_eof_returns_none():
    _reset_protocol_state()
    stream = io.BytesIO(b"")
    result = protocol.read_message(stream)
    assert result is None


def test_eof_after_header_returns_none():
    _reset_protocol_state()
    msg = {"id": 1, "type": "incomplete"}
    full_data = _pack_message(msg)

    # Only send the header, no body
    stream = io.BytesIO(full_data[:4])
    result = protocol.read_message(stream)
    assert result is None
    # Buffer should be cleared on EOF
    assert protocol._read_buffer == b""


def test_eof_mid_body_returns_none():
    _reset_protocol_state()
    msg = {"id": 1, "type": "partial_body"}
    full_data = _pack_message(msg)

    # Send header + partial body
    partial = full_data[: 4 + len(msgpack.packb(msg)) // 2]
    stream = io.BytesIO(partial)
    result = protocol.read_message(stream)
    assert result is None
    assert protocol._read_buffer == b""


def test_eof_when_reading_header_returns_none():
    _reset_protocol_state()
    # 2 bytes of header only, then EOF
    stream = io.BytesIO(b"\x00\x00")
    result = protocol.read_message(stream)
    assert result is None
    assert protocol._read_buffer == b""
