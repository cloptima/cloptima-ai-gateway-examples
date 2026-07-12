// Cloptima canonical model IDs (see pkg/llm_model_catalog in the main platform
// repo). These are examples, not an exhaustive list - any canonical ID with
// status "active" in the catalog can be allowlisted in a policy.
export const MODELS = {
  default: 'vertex_ai/gemini-2.5-flash',
  premium: 'vertex_ai/gemini-3.5-flash',
};

// Additional Gemini variants for the one-policy, several-models cost/latency
// comparison story - see multi-model.mjs. These examples are built with
// Gemini models; bring your own credentials for other providers/models via
// the byok example.
export const OTHER_GEMINI_MODELS = {
  'gemini-2.5-flash-lite': 'vertex_ai/gemini-2.5-flash-lite',
  'gemini-2.5-pro': 'vertex_ai/gemini-2.5-pro',
};
