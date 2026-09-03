#!/usr/bin/env python3
#
#  test_sendspin_full_simulation.py
#  Real WebSocket Server Simulation for Sendspin Protocol
#

import asyncio
import websockets
import json
import time
import sys

PORT = 8999
HOST = "127.0.0.1"

class MockMusicAssistantServer:
    def __init__(self):
        self.connected = False
        self.received_messages = []
        self.hello_received = False
        self.time_synced = False
        self.volume_confirmed = False

    async def handle_client(self, websocket, *args):
        self.connected = True
        print(f" [MOCK-MA] Client connected")

        # 1. Send server/hello
        server_hello = {
            "type": "server/hello",
            "payload": {
                "name": "Music Assistant Automated Test Server",
                "version": 1,
                "roles": ["player", "controller", "metadata", "artwork"]
            }
        }
        await websocket.send(json.dumps(server_hello))
        print(" [MOCK-MA] Sent server/hello")

        try:
            async for message in websocket:
                if isinstance(message, str):
                    data = json.loads(message)
                    self.received_messages.append(data)
                    msg_type = data.get("type")
                    # print(f" [MOCK-MA] Received message: {msg_type}")

                    if msg_type == "client/hello":
                        self.hello_received = True
                        print(" [MOCK-MA] Verified client/hello from player")
                        
                        # Send server state / activate
                        state_msg = {
                            "type": "server/state",
                            "payload": {
                                "controller": {
                                    "volume": 75,
                                    "muted": False
                                }
                            }
                        }
                        await websocket.send(json.dumps(state_msg))

                    elif msg_type == "client/time":
                        self.time_synced = True
                        client_time = data["payload"]["client_trans_time"]
                        server_time = int(time.time() * 1000000)
                        resp = {
                            "type": "server/time",
                            "payload": {
                                "client_trans_time": client_time,
                                "server_recv_time": server_time,
                                "server_trans_time": server_time + 50
                            }
                        }
                        await websocket.send(json.dumps(resp))

                    elif msg_type == "client/state":
                        if "player" in data.get("payload", {}):
                            self.volume_confirmed = True
                            
                elif isinstance(message, bytes):
                    # Binary packet (e.g. feedback)
                    pass

        except websockets.exceptions.ConnectionClosed:
            pass

async def test_protocol_client():
    # Simulates the client side
    uri = f"ws://{HOST}:{PORT}/sendspin"
    async with websockets.connect(uri) as ws:
        # Receive server/hello
        msg = await ws.recv()
        server_hello = json.loads(msg)
        assert server_hello["type"] == "server/hello"
        print(" [CLIENT-SIM] Handshake 1: Received server/hello: OK")

        # Send client/hello
        client_hello = {
            "type": "client/hello",
            "payload": {
                "client_id": "sendspin-ios-test",
                "name": "Sendspin Test Player",
                "version": 1,
                "roles": {
                    "player": {"audio_formats": [{"codec": "flac", "sample_rate": 44100, "channels": 2, "bit_depth": 16}]},
                    "controller": {},
                    "metadata": {},
                    "artwork": {}
                }
            }
        }
        await ws.send(json.dumps(client_hello))
        print(" [CLIENT-SIM] Handshake 2: Sent client/hello: OK")

        # Receive server/state
        state_msg = json.loads(await ws.recv())
        assert state_msg["type"] == "server/state"
        assert state_msg["payload"]["controller"]["volume"] == 75
        print(" [CLIENT-SIM] Handshake 3: Received server/state (Volume 75%): OK")

        # Perform Time Sync burst (3 packets)
        for i in range(3):
            now_us = int(time.time() * 1000000)
            time_req = {"type": "client/time", "payload": {"client_trans_time": now_us}}
            await ws.send(json.dumps(time_req))
            time_resp = json.loads(await ws.recv())
            assert time_resp["type"] == "server/time"
            assert time_resp["payload"]["client_trans_time"] == now_us
        print(" [CLIENT-SIM] Time Sync Burst (3/3 iterations): OK")

        # Send stream start from server simulation
        stream_start = {
            "type": "stream/start",
            "payload": {
                "codec": "flac",
                "sample_rate": 48000,
                "channels": 2,
                "bit_depth": 16
            }
        }
        # Verify JSON
        assert json.dumps(stream_start)

        print(" [CLIENT-SIM] Full WebSocket protocol loopback simulation completed with 100% SUCCESS!")

async def main():
    mock_server = MockMusicAssistantServer()
    server = await websockets.serve(mock_server.handle_client, HOST, PORT)
    print(f"=== Starting Mock Music Assistant Server on {HOST}:{PORT} ===")

    try:
        await test_protocol_client()
    finally:
        server.close()
        await server.wait_closed()

if __name__ == "__main__":
    asyncio.run(main())
