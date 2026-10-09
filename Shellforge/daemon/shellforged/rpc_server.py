from __future__ import annotations
import asyncio
import logging
import os
from collections.abc import Awaitable, Callable
from typing import Any

from . import protocol

log = logging.getLogger(__name__)
Handler = Callable[[Any], Awaitable[Any]]


class AlreadyRunning(RuntimeError):
    """Another daemon is listening on our socket path. Distinct from every other
    startup failure because the caller's correct response is to *use* that daemon,
    not to restart this one."""


class RpcError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class RpcServer:
    def __init__(self, path: str):
        self.path = path
        self._handlers: dict[str, Handler] = {}
        self._server: asyncio.AbstractServer | None = None
        self._clients: set[asyncio.StreamWriter] = set()
        # Requests being answered. Held here because the loop keeps only weak references to tasks.
        self._requests: set[asyncio.Task[None]] = set()
        self._stopping = False
        self._socket_inode: int | None = None

    @property
    def client_count(self) -> int:
        """Live RPC connections. The idle watchdog reads this to decide whether any
        app is still using this daemon."""
        return len(self._clients)

    def register(self, method: str, handler: Handler) -> None:
        self._handlers[method] = handler

    @property
    def methods(self) -> list[str]:
        """The names a request may have, in order: the wire contract's list of them."""
        return sorted(self._handlers)

    async def start(self) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        if os.path.exists(self.path):
            if await self._is_live(self.path):
                raise AlreadyRunning(f"shellforged already running on {self.path}")
            os.unlink(self.path)
        old_umask = os.umask(0o177)
        try:
            self._server = await asyncio.start_unix_server(self._serve, path=self.path, limit=protocol.MAX_FRAME_BYTES)
        finally:
            os.umask(old_umask)
        self._socket_inode = os.stat(self.path).st_ino
        os.chmod(self.path, 0o600)

    @staticmethod
    async def _is_live(path: str) -> bool:
        """True when a socket file at `path` is actually accepting connections,
        i.e. another daemon instance is already running - in which case
        `start()` must not unlink it out from under that instance."""
        try:
            _, writer = await asyncio.wait_for(asyncio.open_unix_connection(path), 1)
        except (TimeoutError, OSError):
            return False
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass
        return True

    async def stop(self) -> None:
        self._stopping = True
        # Aborted, not closed: close() waits to flush what the client has not read, and the
        # server's wait_closed() waits on that -- for good, if the client has stopped reading.
        for w in list(self._clients):
            w.transport.abort()
        if self._server:
            self._server.close()
        # Nobody is left to read their replies.
        requests = [task for task in self._requests if task is not asyncio.current_task()]
        for task in requests:
            task.cancel()
        await asyncio.gather(*requests, return_exceptions=True)
        if self._server:
            await self._server.wait_closed()
        if self._socket_inode is not None:
            try:
                if os.stat(self.path).st_ino == self._socket_inode:
                    os.unlink(self.path)
            except FileNotFoundError:
                pass
            self._socket_inode = None

    async def broadcast(self, event_name: str, payload: Any) -> None:
        data = protocol.encode(protocol.event(event_name, payload))
        # Write to every client before yielding. A later snapshot cannot overtake
        # an earlier event for a client at the back of this set.
        waiting = []
        for w in list(self._clients):
            try:
                if w.transport.get_write_buffer_size() > (1 << 20):
                    # A client this far behind is not reading: its buffer would never flush.
                    w.transport.abort()
                    self._clients.discard(w)
                    continue
                w.write(data)
                waiting.append(self._drain(w))
            except (ConnectionError, RuntimeError):
                self._clients.discard(w)
                w.transport.abort()
        if waiting:
            await asyncio.gather(*waiting)

    async def _drain(self, writer: asyncio.StreamWriter) -> None:
        try:
            await asyncio.wait_for(writer.drain(), timeout=2)
        except (TimeoutError, ConnectionError, RuntimeError):
            self._clients.discard(writer)
            writer.transport.abort()  # as in broadcast: unflushed, a close would never finish

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._clients.add(writer)
        try:
            while line := await reader.readline():
                if self._stopping:
                    break  # stop() has cancelled what was running; nothing may start after it
                # Each request is answered on its own, so a slow one -- a createTask waiting on
                # iTerm2 -- does not hold up, and time out, the ones sent after it.
                task = asyncio.get_running_loop().create_task(self._answer(line, writer))
                self._requests.add(task)
                task.add_done_callback(self._answered)
        except (ConnectionError, RuntimeError, ValueError):
            # `readline()` catches its own `asyncio.LimitOverrunError` (a
            # line longer than the stream `limit`) and re-raises it as a
            # plain `ValueError` (see CPython's asyncio/streams.py), so
            # `ValueError` is what actually needs catching here to keep an
            # over-long line from crashing the connection handler.
            pass
        finally:
            self._clients.discard(writer)
            writer.close()

    async def _answer(self, line: bytes, writer: asyncio.StreamWriter) -> None:
        reply = await self._handle_line(line)
        # Written in the step the handler returned in, before anything else can run: a reply is
        # one write, so two can't interleave, and the workspace.snapshot reply goes out ahead of
        # every event broadcast after its handler read the state it reports.
        if writer.is_closing():
            return  # the client left while its request ran
        writer.write(protocol.encode(reply))
        await self._drain(writer)

    def _answered(self, task: asyncio.Task[None]) -> None:
        self._requests.discard(task)
        if not task.cancelled() and (exc := task.exception()) is not None:
            log.error("answering a request failed", exc_info=exc)

    async def _handle_line(self, line: bytes) -> dict[str, Any]:
        try:
            msg = protocol.decode(line)
        except protocol.ProtocolError as exc:
            return protocol.error(None, protocol.PROTOCOL, str(exc))
        request_id = msg.get("id")
        method = msg.get("method")
        if not isinstance(method, str):
            return protocol.error(request_id, protocol.PROTOCOL, "method must be a string")
        handler = self._handlers.get(method)
        if handler is None:
            return protocol.error(request_id, protocol.UNKNOWN_METHOD, str(method))
        try:
            result = await handler(msg.get("params"))
        except RpcError as exc:
            return protocol.error(request_id, exc.code, exc.message)
        except Exception as exc:  # noqa: BLE001 - surfaced to the client
            log.exception("handler %s failed", method)
            return protocol.error(request_id, protocol.INTERNAL, str(exc))
        return protocol.response(request_id, result)
