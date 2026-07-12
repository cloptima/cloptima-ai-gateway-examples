from anthropic import Anthropic
from openai import OpenAI


def openai_style_client(virtual_key: str, base_url: str) -> OpenAI:
    """OpenAI-compatible client pointed at <base>/v1/ai; the SDK appends
    /chat/completions, /embeddings, etc. Sends Authorization: Bearer <key>.
    """
    return OpenAI(api_key=virtual_key, base_url=f"{base_url}/v1/ai")


def anthropic_style_client(virtual_key: str, base_url: str) -> Anthropic:
    """Anthropic-compatible client pointed at the gateway root; the SDK
    appends /v1/messages. Sends x-api-key: <key>, which the gateway accepts
    specifically for Anthropic-SDK compatibility on /v1/ai and /v1/messages.
    """
    return Anthropic(api_key=virtual_key, base_url=base_url)
