# One image that can run any of the three language directories - Node,
# Python, and shell/curl all need only this one container, so an agent with
# local Docker access can run any example with no GitHub account, no OAuth,
# and nothing touching the host machine beyond the Docker daemon itself.
#
# Build:
#   docker build -t cloptima-examples .
# Run (drops into a shell inside /examples):
#   docker run -it --rm -e CLOPTIMA_AI_ADMIN_KEY=clop_pat_... cloptima-examples
# Then, inside the container:
#   cd node && npm run quickstart-openai
#   cd python && python -m examples.quickstart_openai
#   cd shell && ./quickstart-openai.sh
#
# See docs/RUNNING_SAFELY.md for the full set of ways to run these examples.

FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-pip curl jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /examples
COPY . .

RUN cd node && npm install

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --no-cache-dir -r python/requirements.txt

RUN chmod +x shell/*.sh

CMD ["/bin/bash"]
