# MIL Playground HUD

The Playground HUD answers three questions while using the Multi-Model Inference Layer:

- Can this request run?
- What is MIL doing right now?
- What is the operational and cost posture while I wait?

The document viewer remains the primary output surface after a completion is produced. The HUD stays visible beside it so inference state remains visible while reading the answer.

## First Pass Coverage

Implemented in the first pass:

- Endpoint state: active model, worker min/max, zero-idle or warm posture, endpoint id, and base URL copy support.
- Worker state: initializing, ready, running, idle, unhealthy, throttled, plus recent worker ids and statuses.
- Queue and jobs: queued, active, completed, failed, and retried job counters.
- Current request: state, elapsed time, prompt character count, response character count, and prompt preview.
- Cost posture: zero-idle or warm mode, estimated active hourly burn, and warnings for warm workers or `workers_max = 0`.
- Diagnostics: refresh diagnostics, open RunPod logs, and show current log summary/errors.
- Request-time polling: while a prompt is waiting for a response, the HUD refreshes monitor and log diagnostics.
- Long-wait warnings: queued jobs with ready workers and requests over five minutes are called out in the HUD.

## GPU Priority

RunPod's GPU ID for H100 SXM is `NVIDIA H100 80GB HBM3`. The preferred Serverless order should put it first, then fall back to A100 SXM and A100 PCIe:

```text
NVIDIA H100 80GB HBM3,NVIDIA A100-SXM4-80GB,NVIDIA A100 80GB PCIe
```

For very large models, H200/H100 NVL can be considered later, but that should be a conscious cost and availability decision.

## Layout Contract

- Before output exists, the Playground is a centered MIL HUD above the chat bar.
- After output exists, the area above the chat bar becomes an 80 / 20 layout:
  - 80 percent: Markdown document viewer.
  - 20 percent: compact MIL HUD.
- On narrow windows, the document and HUD stack vertically to avoid crushed controls.
- The chat bar remains full-width at the bottom in both states.

## Future HUD Work

- #todo Add TTFT when the inference client can measure first-token latency or streaming is enabled.
- #todo Add tokens/sec once streaming token timestamps or provider usage metrics are available.
- #todo Add input/output token counts from OpenAI-compatible `usage` responses.
- #todo Add request id and RunPod job id correlation if RunPod exposes it in responses.
- #todo Add historical sparkline for queue depth and worker readiness.
- #todo Add model load/cold-start phase labels from raw worker logs or structured worker events.
- #todo Add per-model cost posture when switching between GPT-OSS, Gemma, Qwen, and GLM.
- #todo Add warnings for high retry rates, repeated worker exits, and long cold-start windows.
- #todo Add H100/H200 placement history so the HUD shows which GPU family actually served the request.
- #todo Add a diagnostics drawer with the last raw sanitized `zenith logs --json` payload.
- #todo Add exportable request report with prompt metadata, elapsed time, model, endpoint, and billing estimate.
