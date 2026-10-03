import json

import httpx
from anthropic import Anthropic
from openai import OpenAI

from . import config


class _GatewayTransport(httpx.HTTPTransport):
    """The gateway reports a blocked request as
    {"error": "<message>", "reason": "...", "violations": ["..."], "details": {...}}
    The OpenAI SDK only exposes the `error` field on a raised API error, which would
    drop `reason` and `violations`. This transport nests the whole body under `error`,
    so `err.body["message"]`, `err.body["reason"]` and `err.body["violations"]`
    are available in an except block.
    """

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        response = super().handle_request(request)
        if response.status_code < 400:
            return response
        response.read()
        try:
            body = json.loads(response.content)
        except ValueError:
            return response
        if not isinstance(body, dict) or not isinstance(body.get("error"), str):
            return response
        nested = {"error": {"message": body["error"], **{k: v for k, v in body.items() if k != "error"}}}
        headers = {k: v for k, v in response.headers.items() if k.lower() not in ("content-length", "content-encoding")}
        return httpx.Response(response.status_code, headers=headers, json=nested, request=request)


def _http_client() -> httpx.Client:
    return httpx.Client(transport=_GatewayTransport())


# OpenAI SDK client pointed at the Cloptima gateway. The only changes from a
# direct-to-provider setup are the API key (a Cloptima virtual key) and the base URL.
def openai_client(virtual_key: str, **kwargs) -> OpenAI:
    return OpenAI(api_key=virtual_key, base_url=f"{config.BASE_URL}/v1/ai", http_client=_http_client(), **kwargs)


# Anthropic SDK client pointed at the Cloptima gateway.
def anthropic_client(virtual_key: str, **kwargs) -> Anthropic:
    return Anthropic(api_key=virtual_key, base_url=config.BASE_URL, **kwargs)

