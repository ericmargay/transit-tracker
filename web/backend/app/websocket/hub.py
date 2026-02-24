import asyncio
import json
from typing import Dict, Set
from fastapi import WebSocket
import logging

logger = logging.getLogger(__name__)


class ConnectionHub:
    def __init__(self):
        self._subscribers: Dict[str, Set[WebSocket]] = {}
        self._all_connections: Set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        async with self._lock:
            self._all_connections.add(websocket)

    async def disconnect(self, websocket: WebSocket):
        async with self._lock:
            self._all_connections.discard(websocket)
            for subs in self._subscribers.values():
                subs.discard(websocket)

    async def subscribe(self, websocket: WebSocket, line_id: str):
        async with self._lock:
            self._subscribers.setdefault(line_id, set()).add(websocket)

    async def unsubscribe(self, websocket: WebSocket, line_id: str):
        async with self._lock:
            if line_id in self._subscribers:
                self._subscribers[line_id].discard(websocket)

    async def broadcast_to_line(self, line_id: str, message: dict):
        subscribers = self._subscribers.get(line_id, set()).copy()
        if not subscribers:
            return
        payload = json.dumps(message)
        dead = set()
        for ws in subscribers:
            try:
                await ws.send_text(payload)
            except Exception:
                dead.add(ws)
        if dead:
            async with self._lock:
                for ws in dead:
                    self._all_connections.discard(ws)
                    for subs in self._subscribers.values():
                        subs.discard(ws)

    @property
    def active_connections(self) -> int:
        return len(self._all_connections)


hub = ConnectionHub()
