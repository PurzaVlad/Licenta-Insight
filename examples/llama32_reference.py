#!/usr/bin/env python3
"""
Reference recipes for Llama 3.2 1B Instruct outside React Native.

Install example deps as needed:
  pip install torch transformers accelerate bitsandbytes vllm peft
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


MODEL_ID = "meta-llama/Llama-3.2-1B-Instruct"


@dataclass
class SamplingConfig:
    max_new_tokens: int = 256
    temperature: float = 0.5
    top_p: float = 0.92
    repetition_penalty: float = 1.1


def pipeline_text_example(prompt: str, cfg: Optional[SamplingConfig] = None) -> str:
    from transformers import pipeline

    cfg = cfg or SamplingConfig()
    pipe = pipeline(
        "text-generation",
        model=MODEL_ID,
        torch_dtype="auto",
        device_map="auto",
    )
    out = pipe(
        prompt,
        max_new_tokens=cfg.max_new_tokens,
        temperature=cfg.temperature,
        top_p=cfg.top_p,
        repetition_penalty=cfg.repetition_penalty,
    )
    return out[0]["generated_text"]


def transformers_8bit_example(prompt: str, cfg: Optional[SamplingConfig] = None) -> str:
    from transformers import AutoModelForCausalLM, AutoTokenizer

    cfg = cfg or SamplingConfig()
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        load_in_8bit=True,
        torch_dtype="auto",
        device_map="auto",
    )
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    outputs = model.generate(
        **inputs,
        max_new_tokens=cfg.max_new_tokens,
        temperature=cfg.temperature,
        top_p=cfg.top_p,
        repetition_penalty=cfg.repetition_penalty,
        do_sample=True,
        pad_token_id=tokenizer.eos_token_id,
    )
    return tokenizer.decode(outputs[0], skip_special_tokens=True)


def pipeline_chat_messages_example(user_prompt: str, system_prompt: str = "You are a helpful assistant.") -> str:
    from transformers import pipeline

    pipe = pipeline(
        "text-generation",
        model=MODEL_ID,
        torch_dtype="auto",
        device_map="auto",
    )
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]
    out = pipe(messages, max_new_tokens=150, temperature=0.5, top_p=0.92, repetition_penalty=1.1)
    return str(out[0]["generated_text"])


def vllm_example(prompt: str) -> str:
    from vllm import LLM, SamplingParams

    llm = LLM(
        model=MODEL_ID,
        max_num_seqs=16,
        gpu_memory_utilization=0.95,
    )
    params = SamplingParams(max_tokens=256, temperature=0.5, top_p=0.92, repetition_penalty=1.1)
    out = llm.generate([prompt], params)
    return out[0].outputs[0].text


def lora_peft_stub():
    from peft import LoraConfig, get_peft_model
    from transformers import AutoModelForCausalLM

    base_model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        torch_dtype="auto",
        device_map="auto",
    )
    lora_config = LoraConfig(
        r=16,
        lora_alpha=32,
        lora_dropout=0.05,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
        task_type="CAUSAL_LM",
    )
    lora_model = get_peft_model(base_model, lora_config)
    return lora_model


if __name__ == "__main__":
    sample = "Explain quantum computing in simple terms."
    print(pipeline_text_example(sample))
