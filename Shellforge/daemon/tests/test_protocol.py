import json
import pytest
from shellforged import protocol


def test_encode_appends_newline_and_is_compact():
    data = protocol.encode({"id": 1, "method": "iterm.status"})
    assert data.endswith(b"\n")
    assert b"\n" not in data[:-1]
    assert json.loads(data) == {"id": 1, "method": "iterm.status"}


def test_encode_survives_a_lone_surrogate():
    # json.loads turns "\ud800" in a hook body into a str that UTF-8 cannot encode.
    data = protocol.encode({"title": "a\ud800b"})
    assert json.loads(data.decode("utf-8")) == {"title": "a?b"}


def test_decode_round_trips():
    assert protocol.decode(b'{"id": 7, "result": {"ok": true}}\n') == {"id": 7, "result": {"ok": True}}


def test_decode_rejects_non_object():
    with pytest.raises(protocol.ProtocolError):
        protocol.decode(b"[1,2]\n")
    with pytest.raises(protocol.ProtocolError):
        protocol.decode(b"not json\n")


def test_response_error_event_shapes():
    assert protocol.response(3, {"a": 1}) == {"id": 3, "result": {"a": 1}}
    assert protocol.error(3, "not_found", "no such window") == {"id": 3, "error": {"code": "not_found", "message": "no such window"}}
    assert protocol.event("iterm.connected", {"version": "3.7.2"}) == {"event": "iterm.connected", "payload": {"version": "3.7.2"}}
