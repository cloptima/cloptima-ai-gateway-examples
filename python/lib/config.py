import os
import secrets

from dotenv import load_dotenv

load_dotenv()


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required env var {name} - copy .env.example to .env and fill it in.")
    return value


# The gateway is a fixed public endpoint - nobody running these examples
# should need to know or configure its URL. Only override it (unset by
# default) for internal testing against a non-production environment.
_GATEWAY_BASE_URL_DEFAULT = "https://api.cloptima.ai"

# Every example in this repo needs only one thing: an ai:admin management
# key. Each example mints whatever policy, binding, and virtual key it needs
# from there - nothing is pre-provisioned.
BASE_URL = os.environ.get("CLOPTIMA_GATEWAY_BASE_URL", _GATEWAY_BASE_URL_DEFAULT).rstrip("/")
AI_ADMIN_KEY = _required("CLOPTIMA_AI_ADMIN_KEY")

# The gateway sits behind Cloudflare, which bot-manages requests with no or
# generic User-Agent strings (Python's requests library sends a generic
# "python-requests/x.y" UA by default, which looks like anonymous scripted
# traffic). The official openai/anthropic SDKs already send their own
# identifying UA, so this only needs to be applied to this repo's own raw
# requests calls (see gateway_admin.py and any example that calls requests
# directly instead of going through an SDK client).
USER_AGENT = "Cloptima-AI-Gateway-Examples/1.0"

# Console tab URLs each example points to as corroborating evidence.
# These are the canonical, public paths to view results in the console.
_CONSOLE_ROOT = "https://app.cloptima.ai/llm"
CONSOLE = {
    "dashboard": "https://app.cloptima.ai",
    "spend": f"{_CONSOLE_ROOT}/spend",
    "unit_economics": f"{_CONSOLE_ROOT}/unit-economics",
    "recommendations": f"{_CONSOLE_ROOT}/recommendations",
    "policies": f"{_CONSOLE_ROOT}/policies",
    "credentials": f"{_CONSOLE_ROOT}/credentials",
    "audit": f"{_CONSOLE_ROOT}/audit",
}


def run_suffix() -> str:
    """A short, unique-ish suffix so re-running an example doesn't collide
    with a policy/app name it created on a previous run (policy names are
    unique per customer)."""
    return secrets.token_hex(3)
