import sys, subprocess
def ensure_package(spec: str):
    try:
        import importlib, re
        pkg = re.split(r"[<>=!~]", spec)[0]
        importlib.import_module(pkg)
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", spec])


ensure_package("websockets>=12")
# ensure_package("bleak")
# ensure_package("bleakheart")

import argparse
import asyncio
import json
import logging
import math
import random
import time
from typing import Any, Dict, List, Optional

try:
    from websockets.asyncio.server import serve
except Exception:  # pragma: no cover
    from websockets.server import serve
import websockets  # for .send/.recv

LOG = logging.getLogger("bleak_ws_sidecar")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


class BroadcastHub:
    """Tracks connected WS clients and broadcasts JSON messages to all."""
    def __init__(self) -> None:
        self._clients: set = set()
        self._lock = asyncio.Lock()

    async def register(self, ws) -> None:
        async with self._lock:
            self._clients.add(ws)
            LOG.info("Client connected (%d total)", len(self._clients))

    async def unregister(self, ws) -> None:
        async with self._lock:
            self._clients.discard(ws)
            LOG.info("Client disconnected (%d total)", len(self._clients))

    async def broadcast(self, msg: Dict[str, Any]) -> None:
        payload = json.dumps(msg, separators=(",", ":"), ensure_ascii=False)
        async with self._lock:
            if not self._clients:
                return
            await asyncio.gather(*(self._safe_send(ws, payload) for ws in list(self._clients)),
                                 return_exceptions=True)

    async def _safe_send(self, ws, data: str) -> None:
        try:
            await ws.send(data)
        except Exception as e:
            LOG.warning("Send failed: %s", e)


class MockBackend:
    """Generates synthetic ECG and ACC so you can test without hardware."""
    def __init__(self, need_ecg: bool, need_acc: bool, ecg_fs: int = 130, acc_fs: int = 25):
        self.need_ecg = need_ecg
        self.need_acc = need_acc
        self.ecg_fs = ecg_fs
        self.acc_fs = acc_fs
        self._stop = asyncio.Event()

    def stop(self): self._stop.set()

    async def run(self, hub: BroadcastHub):
        features = []
        if self.need_ecg: features.append("ECG")
        if self.need_acc: features.append("ACC")
        await hub.broadcast({"type":"meta","backend":"mock","device":"Mock Sensor","features":features})
        LOG.info("MOCK streaming: %s", ", ".join(features) or "none")

        ecg_phase = 0.0
        acc_phase = 0.0
        t0 = time.time()

        while not self._stop.is_set():
            now = time.time()
            # ECG (50 ms)
            if self.need_ecg:
                frame_len = max(1, int(self.ecg_fs * 0.05))
                samples: List[float] = []
                for i in range(frame_len):
                    x = (ecg_phase + i) / self.ecg_fs
                    base = 0.7 * math.sin(2 * math.pi * 1.0 * x)
                    spike = 2.0 if int((ecg_phase + i) % self.ecg_fs) == 0 else 0.0
                    noise = random.uniform(-0.05, 0.05)
                    samples.append(base + spike + noise)
                ecg_phase += frame_len
                await hub.broadcast({"type":"ecg","t":now - t0,"fs":self.ecg_fs,"n":len(samples),"ecg":samples})

            # ACC (50 ms)
            if self.need_acc:
                frame_len = max(1, int(self.acc_fs * 0.05))
                acc_samples: List[List[float]] = []
                for i in range(frame_len):
                    x = (acc_phase + i) / self.acc_fs
                    acc_samples.append([
                        0.1 * math.sin(2 * math.pi * 0.5 * x) + random.uniform(-0.02, 0.02),
                        0.1 * math.sin(2 * math.pi * 0.8 * x + 1.0) + random.uniform(-0.02, 0.02),
                        1.0 + 0.02 * math.sin(2 * math.pi * 0.3 * x) + random.uniform(-0.02, 0.02),
                    ])
                acc_phase += frame_len
                await hub.broadcast({"type":"acc","t":now - t0,"fs":self.acc_fs,"n":len(acc_samples),"acc":acc_samples})

            await asyncio.sleep(0.05)


class BleakheartBackend:
    def __init__(self, device_name: Optional[str], device_id: Optional[str],
                 need_ecg: bool, need_acc: bool):
        self.device_name = device_name
        self.device_id = device_id
        self.need_ecg = need_ecg
        self.need_acc = need_acc
        self._stop = asyncio.Event()

    def stop(self): self._stop.set()

    async def run(self, hub: BroadcastHub):
        try:
            import bleakheart as bh
            from bleak import BleakScanner, BleakClient
        except Exception as e:
            LOG.error("bleak/bleakheart import failed: %s", e)
            raise

        # --- find device ---
        dev = None
        if self.device_id:
            LOG.info("Searching by address/id: %s", self.device_id)
            dev = await BleakScanner.find_device_by_address(self.device_id, timeout=10.0)
        if dev is None:
            name_filter = (self.device_name or "polar").lower()
            LOG.info("Scanning for device name containing '%s'…", name_filter)
            dev = await BleakScanner.find_device_by_filter(
                lambda d, adv: (d.name or "").lower().find(name_filter) != -1,
                timeout=15.0
            )
        if dev is None:
            LOG.error("No Polar device found.")
            return

        LOG.info("Connecting to %s (%s)…", dev.name, getattr(dev, "address", ""))
        async with BleakClient(dev) as client:
            if not client.is_connected:
                LOG.error("BLE connection failed")
                return

            features = []
            if self.need_ecg: features.append("ECG")
            if self.need_acc: features.append("ACC")
            await hub.broadcast({"type": "meta", "backend": "bleakheart",
                                 "device": dev.name or "Polar device",
                                 "features": features})

            ecg_q: Optional[asyncio.Queue] = asyncio.Queue() if self.need_ecg else None
            acc_q: Optional[asyncio.Queue] = asyncio.Queue() if self.need_acc else None

            def make_cb(q: asyncio.Queue):
                def _cb(frame_tuple):
                    try:
                        q.put_nowait(frame_tuple)
                    except Exception:
                        pass
                return _cb

            ecg_cb = make_cb(ecg_q) if ecg_q else None
            acc_cb = make_cb(acc_q) if acc_q else None

            try:
                pmd = bh.PolarMeasurementData(
                    client,
                    ecg_queue=ecg_q if ecg_q else None,
                    acc_queue=acc_q if acc_q else None,
                    ecg_callback=ecg_cb,
                    acc_callback=acc_cb,
                )
            except TypeError:
                pmd = bh.PolarMeasurementData(client)
                if ecg_q: setattr(pmd, "ecg_queue", ecg_q); setattr(pmd, "_ecg_queue", ecg_q)
                if acc_q: setattr(pmd, "acc_queue", acc_q); setattr(pmd, "_acc_queue", acc_q)
                if ecg_cb: setattr(pmd, "ecg_callback", ecg_cb); setattr(pmd, "_ecg_callback", ecg_cb)
                if acc_cb: setattr(pmd, "acc_callback", acc_cb); setattr(pmd, "_acc_callback", acc_cb)

            ecg_fs = 130
            acc_fs = 25
            try:
                if self.need_ecg:
                    st = await pmd.available_settings('ECG')
                    for k, v in st.items():
                        if "sample" in k.lower() and isinstance(v, (int, float)):
                            ecg_fs = int(v); break
                if self.need_acc:
                    st = await pmd.available_settings('ACC')
                    for k, v in st.items():
                        if "sample" in k.lower() and isinstance(v, (int, float)):
                            acc_fs = int(v); break
            except Exception:
                pass

            started = []
            try:
                if self.need_ecg:
                    err_code, err_msg, _ = await pmd.start_streaming('ECG')
                    if err_code != 0:
                        LOG.error("ECG start_streaming error: %s", err_msg)
                    else:
                        started.append('ECG'); LOG.info("ECG streaming started (fs≈%s)", ecg_fs)
                if self.need_acc:
                    err_code, err_msg, _ = await pmd.start_streaming('ACC')
                    if err_code != 0:
                        LOG.error("ACC start_streaming error: %s", err_msg)
                    else:
                        started.append('ACC'); LOG.info("ACC streaming started (fs≈%s)", acc_fs)

                async def pump_q(q: asyncio.Queue, label: str, fs_default: int):
                    t0 = time.time()
                    while not self._stop.is_set():
                        frame = await q.get()
                        try:
                            _typ, ts, payload = frame
                        except Exception:
                            ts, payload = time.time() - t0, frame
                        if label == "ECG":
                            samples = list(payload if isinstance(payload, (list, tuple)) else [])
                            await hub.broadcast({"type":"ecg","t":float(ts)-t0 if ts>1e6 else float(ts),
                                                 "fs": ecg_fs or fs_default,
                                                 "n": len(samples), "ecg": samples})
                        else:
                            acc = [list(v) for v in (payload or [])]
                            await hub.broadcast({"type":"acc","t":float(ts)-t0 if ts>1e6 else float(ts),
                                                 "fs": acc_fs or fs_default,
                                                 "n": len(acc), "acc": acc})
                        q.task_done()

                tasks: List[asyncio.Task] = []
                if ecg_q: tasks.append(asyncio.create_task(pump_q(ecg_q, "ECG", 130)))
                if acc_q: tasks.append(asyncio.create_task(pump_q(acc_q, "ACC", 25)))

                if not tasks:
                    LOG.warning("No streams enabled."); return

                await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)

            finally:
                try:
                    if 'ECG' in started: await pmd.stop_streaming('ECG')
                    if 'ACC' in started: await pmd.stop_streaming('ACC')
                except Exception:
                    pass


async def _ws_handler(ws, *_, hub: BroadcastHub):
    await hub.register(ws)
    try:
        async for _ in ws:
            pass
    finally:
        await hub.unregister(ws)



def _windows_selector_policy_fix():
    if sys.platform.startswith("win"):
        try:
            asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())  # type: ignore[attr-defined]
        except Exception:
            pass

async def main():
    ap = argparse.ArgumentParser(description="Polar H10 -> WebSocket bridge (bleakheart/mock)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--device-name", default="Polar H10")
    ap.add_argument("--device-id", default=None)
    ap.add_argument("--ecg", action="store_true", help="Enable ECG stream")
    ap.add_argument("--acc", action="store_true", help="Enable accelerometer stream")
    ap.add_argument("--mock", action="store_true", help="Use synthetic data (no BLE)")
    args = ap.parse_args()

    if not (args.ecg or args.acc):
        args.ecg = args.acc = True

    hub = BroadcastHub()

    if args.mock:
        backend = MockBackend(need_ecg=args.ecg, need_acc=args.acc)
    else:
        try:
            import bleakheart as _bh  # noqa: F401
            from bleak import BleakScanner as _BS, BleakClient as _BC  # noqa: F401
        except Exception as e:
            LOG.error("bleak/bleakheart not available and --mock not set. "
                      "Install them (pip install bleak bleakheart) or run with --mock. (%s)", e)
            return
        backend = BleakheartBackend(
            device_name=args.device_name,
            device_id=args.device_id,
            need_ecg=args.ecg,
            need_acc=args.acc,
        )

    async with serve(lambda ws: _ws_handler(ws, hub=hub), args.host, args.port):
        LOG.info("WebSocket listening on ws://%s:%d", args.host, args.port)
        task = asyncio.create_task(backend.run(hub))
        try:
            await task
        except asyncio.CancelledError:
            pass
        finally:
            if hasattr(backend, "stop"):
                backend.stop()

if __name__ == "__main__":
    _windows_selector_policy_fix()
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
