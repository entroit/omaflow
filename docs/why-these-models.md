# Why these models

Checked 4–6 September 2026 on a Ryzen 5 9600X, 32 GB RAM, RTX 5060 Ti 16 GB.

| Stage | Selection | Disk / VRAM | Reason |
|---|---|---:|---|
| Speech | Parakeet TDT 0.6B v3 Q8 | 681 MiB / 0.85 GiB idle, 1.85 GB after a two-minute recording | Best small-model balance of accuracy, European coverage and CUDA speed |
| Cleanup | Gemma 4 E4B Q4_K_M | 9.6 GB / 4.4 GiB | Best result in the local 32-case comparison |
| Guard | Rust | — | Restores exact vocabulary, rejects language and number changes |

NeMo-Speech.cpp is Apache-2.0, Parakeet's weights are CC-BY-4.0, Gemma 4 is
Apache-2.0. Nothing leaves the machine.

## Speech

Hugging Face Open ASR English results, CSV of 3 September 2026, open-weight
models only:

| Model | Rank | Params | Languages | Avg WER ↓ | RTFx ↑ |
|---|---:|---:|---:|---:|---:|
| Qwen3-ASR 1.7B | 1 | 2.04B | 52 | 4.311 | 820× |
| Cohere Transcribe 03-2026 | 9 | 2.0B | 14 | 4.670 | 907× |
| **Parakeet TDT v3** | 13 | 0.60B | 25* | 4.859 | **6,076×** |
| Qwen3-ASR 0.6B | 21 | 0.78B | 52 | 5.045 | 744× |
| Nemotron 3.5 Streaming | 46 | 0.64B | 40 | 7.876 | 1,472× |

\* The model card lists 25 European languages; the leaderboard metadata counts
26. The card's own numbers (6.32 WER, 3,332×) predate the leaderboard's
cleaned datasets.

Parakeet gives up 0.5 WER to the 3× larger Qwen 1.7B and is seven times
faster; against the same-size Qwen 0.6B it wins on both. Qwen3-ASR is the
right choice for a language outside Parakeet's 25. Nemotron streams natively
but its English WER is materially worse. Voxtral Mini 4B Realtime needs the
whole 16 GB card.

Measured against the persistent local NeMo-Speech.cpp 0.1.0 CUDA server, HTTP
time including upload and JSON response:

| Input | Wall time | Speed |
|---|---:|---:|
| 13.69 s, 42 words | 48.8 ms | 281× real time |
| 120.00 s, 369 words | 373.6 ms | 321× real time |

Sources: [Parakeet model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
[NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp),
[Open ASR CSV](https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results/blob/main/english_short_latest.csv),
[Nemotron 3.5](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b),
[Voxtral Mini 4B Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602),
[Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR).

## Cleanup

Six models ran the same 32 dictations: ten German, plus French, Spanish,
Italian, Dutch, code-switched text, number traps, English, a question, a
prompt injection and filler-only input. Gemma 4 E4B passed 29 before the
Rust guard; the VoiceInk Qwen 3.5 2B fine-tune passed 20. Gemma kept every
language and invented no number. Rerun the comparison with
`tools/cleanup_bench.py --model <ollama tag>`.

General benchmarks rank Qwen 3.5 4B above Gemma E4B on reasoning; on these
dictations it translated and altered text, which is the failure that matters
here.

With the production prompt, measured here, `tools/cleanup_bench.py` passes
32/32 at about 220 ms mean after warm-up; a 179-word cleanup takes about 1.2 s.

Sources: [Gemma 4 in Ollama](https://ollama.com/library/gemma4),
[Artificial Analysis Gemma 4 E4B](https://artificialanalysis.ai/models/gemma-4-e4b),
[VoiceInk fine-tune](https://github.com/hourliert/VoiceInk-Qwen3.5-2B-FT/blob/master/docs/BLOG_POST.md).

## Prompt gates

| Gate | Covers | Cases |
|---|---|---:|
| `tools/cleanup_bench.py` | release: languages, commands, injection, numbers | 32 |
| `tools/cleanup_probe.py` | fillers, numbers, dates, emails, paths, six languages, long dictation | 88 |
| `tools/cleanup_generalization.py` | corrections and list requests that appear in no prompt example | 21 |
| `tools/cleanup_itn_gate.py` | spoken-to-written pairs from published data | 180 |

The generalization gate exists because one prompt example can make one
sentence pass without the rule generalizing; the current prompt passes 21/21.

The ITN gate uses a class-balanced 180-sentence sample from
[`pavanBuduguppa/asr_inverse_text_normalization`](https://huggingface.co/datasets/pavanBuduguppa/asr_inverse_text_normalization)
and measures the two failures that matter for dictation, run 6 September 2026
with the guard in the loop:

| Class | No invented digits | No dropped words |
|---|---:|---:|
| CARDINAL, FRACTION, MONEY, TELEPHONE, TIME | 100% | 100% |
| DATE, DECIMAL, MEASURE, ORDINAL | 100% | 95% |
| **Total** | **100%** | **98%** |

Long spoken digit runs (phone numbers, ISBNs, IBANs) were the one class where
the model reliably invented digits. The guard in `src/cleanup.rs` rejects the
edit, retries once with numbers locked, and if that is rejected too keeps the
recognized words with punctuation only.

**Segmentation was tested and rejected.** DRES recommends cleaning
transcripts in roughly four-sentence chunks. On a 75-word dictation with a
mid-paragraph self-correction, a correction spanning a chunk boundary was
repaired on the full transcript and lost when segmented, at every chunk size.
Dictations here are 60–180 words, below the length where long-context instability
dominates, so full-transcript cleanup stays. Two DRES findings do apply and
match the configuration: reasoning modes over-delete, so `think = false`; and
a few demonstrations help modestly, so the prompt carries 19 examples and the
generalization gate checks the rules hold beyond them.

Source: [DRES](https://arxiv.org/abs/2509.20321).
