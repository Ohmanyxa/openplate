"""Local HTTPS-ready recognition API used by the mounted camera app."""

from __future__ import annotations

import argparse
import hmac
import os
from contextlib import asynccontextmanager
from time import monotonic
from typing import Annotated

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from starlette.concurrency import run_in_threadpool

from openplate.backends.fast_alpr import FastAlprDetector, FastPlateOcrReader
from openplate.pipeline import PlatePipeline
from openplate.temporal import TemporalConfirmation

MAX_IMAGE_BYTES = 5 * 1024 * 1024


class RecognitionRuntime:
    def __init__(self) -> None:
        self.pipeline = PlatePipeline(FastAlprDetector(), FastPlateOcrReader())
        self.confirmation = TemporalConfirmation()


def create_app() -> FastAPI:
    runtime: RecognitionRuntime | None = None

    @asynccontextmanager
    async def lifespan(_app: FastAPI):  # type: ignore[no-untyped-def]
        nonlocal runtime
        runtime = await run_in_threadpool(RecognitionRuntime)
        yield

    app = FastAPI(title="OpenPlate Recognition API", version="1.0", lifespan=lifespan)

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ready" if runtime else "starting"}

    @app.post("/v1/recognize")
    async def recognize(
        image: Annotated[UploadFile, File()],
        device_id: Annotated[str, Form(min_length=1, max_length=100)],
        x_openplate_api_key: Annotated[str | None, Header()] = None,
    ) -> dict[str, object]:
        configured_key = os.environ.get("OPENPLATE_API_KEY")
        if not configured_key:
            raise HTTPException(503, "OPENPLATE_API_KEY is not configured")
        if x_openplate_api_key is None or not hmac.compare_digest(
            x_openplate_api_key, configured_key
        ):
            raise HTTPException(401, "invalid API key")

        raw = await image.read(MAX_IMAGE_BYTES + 1)
        if len(raw) > MAX_IMAGE_BYTES:
            raise HTTPException(413, "image exceeds 5 MiB")
        frame = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        if frame is None:
            raise HTTPException(400, "invalid image")
        if runtime is None:
            raise HTTPException(503, "models are not ready")

        report = await run_in_threadpool(runtime.pipeline.process_image, frame)
        confirmed = runtime.confirmation.update(device_id, report.results, monotonic())
        return {
            "schema_version": 1,
            "timings_ms": report.timings.as_dict(),
            "detections": len(report.results),
            "plates": [
                {
                    "plate": item.plate,
                    "confidence": round(item.confidence, 6),
                    "observations": item.observations,
                    "new_event": item.new_event,
                }
                for item in confirmed
            ],
        }

    return app


app = create_app()


def main() -> None:
    parser = argparse.ArgumentParser(description="OpenPlate local recognition server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8844)
    parser.add_argument("--ssl-certfile")
    parser.add_argument("--ssl-keyfile")
    args = parser.parse_args()
    import uvicorn

    uvicorn.run(
        "openplate.service:app",
        host=args.host,
        port=args.port,
        ssl_certfile=args.ssl_certfile,
        ssl_keyfile=args.ssl_keyfile,
    )


if __name__ == "__main__":
    main()
