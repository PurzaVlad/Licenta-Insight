import React, {useEffect, useRef, useState} from 'react';
import {Alert, StyleSheet, NativeModules, NativeEventEmitter} from 'react-native';
import RNFS from 'react-native-fs';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {initLlama, releaseAllLlama} from 'llama.rn';
import {downloadModel} from './src/api/model';

import NativeChatView from './src/native/NativeChatView';
const {EdgeAI} = NativeModules;

type Message = {
  role: 'system' | 'user' | 'assistant';
  content: string;
  timestamp: number;
};

type SummaryLengthOption = 'short' | 'medium' | 'long';
type SummaryContentOption = 'general' | 'finance' | 'legal' | 'academic' | 'medical';

const MODEL_FILENAME = 'Qwen2.5-1.5B-Instruct.Q4_K_M.gguf';
const MODEL_URL =
  'https://huggingface.co/MaziyarPanahi/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct.Q4_K_M.gguf';
const MODEL_DOWNLOAD_STATE_KEY = 'edgeai:model_download_state';
const MODEL_DOWNLOAD_IN_PROGRESS = 'in_progress';
const LLAMA_N_CTX = 2048;
const DEFAULT_MAX_NEW_TOKENS = 160;
const SUMMARY_MAX_NEW_TOKENS = 220;
const DEFAULT_TEMPERATURE = 0.2;
const CHAT_TEMPERATURE = 0.15;
const DEFAULT_TOP_P = 0.9;
const DEFAULT_REPEAT_PENALTY = 1.1;
const CHAT_REPEAT_PENALTY = 1.15;
const MAX_CHAT_HISTORY_MESSAGES = 3;
const MIN_MODEL_FILE_SIZE_BYTES = 200 * 1024 * 1024;

const SUMMARY_PROMPT_COMMON = `
  You will receive extracted text from a document.
  Write a concise summary of the key points in plain sentences.

  Rules:
  Output only the summary text.
  English only. Always respond in English.
  If the input is not English, translate the summary to English.
  Do not output any non-English words or sentences.
  No title, no label, no introduction, no headings, no bullet points.
  Do not repeat any idea.
  Do not rephrase earlier sentences.
  Do not add information not explicitly stated.
  Omit unclear details.
  `;

const SUMMARY_LENGTH_RULES: Record<SummaryLengthOption, string> = {
  short: `
  2-4 sentences max.
  ~60-100 words.
  Prefer only the highest-signal points.
  `,
  medium: `
  4–7 sentences max.
  ~120–180 words.
  If more info exists, prefer omission.
  Keep it short.
  `,
  long: `
  8-12 sentences max.
  ~220-320 words.
  Include more key details while avoiding repetition.
  `,
};

const SUMMARY_CONTENT_RULES: Record<SummaryContentOption, string> = {
  general: `
  Provide a neutral general summary of the document's main points.
  Do not adopt a domain-specific style or persona.
  `,
  finance: `
  Focus on financial information first.
  Prioritize concrete numbers and financial facts: amounts, currencies, rates, KPIs, trends, costs, revenues, margins, forecasts, and financial risks.
  If exact numbers are present, include them.
  `,
  legal: `
  Focus on legal meaning and constraints in the document.
  Prioritize parties, obligations, rights, prohibitions, conditions, deadlines, liabilities, remedies, and compliance requirements.
  Mention legal constraints only if they are explicitly present.
  `,
  academic: `
  Explain the document in technically specific terms.
  Prioritize objective, methods/approach, data/evidence, key concepts, findings/results, assumptions, and limitations.
  Use precise technical wording based only on the source text.
  `,
  medical: `
  Focus on clinical and medical facts in the document.
  Prioritize patient/context details, findings, diagnosis or differential, treatment/medications, dosages, timelines, outcomes, contraindications, precautions, and follow-up instructions.
  If values or measurements are present, include the exact numbers and units.
  Mention medical constraints or cautions only if explicitly stated.
  `,
};

const SUMMARY_PROMPT_FOOTER = `
  Stop after the last sentence.
  `;

const TAG_SYSTEM_PROMPT = `
  You will receive a short excerpt from a document.
  Extract exactly 4 single-word tags that capture the topic.

  Rules:
  Output tags as a comma-separated list.
  Output exactly 4 items, no more and no fewer.
  Use plain words only; no punctuation, no numbering, no labels, no phrases.
  Prefer specific topics or names over generic words.
  Never output stopwords such as: and, or, the, a, an, including, with, without, for, from.
  Do not repeat words.
  `;

const CHAT_SYSTEM_PROMPT = `You are a document assistant. Answer questions using only the evidence provided.

Rules:
- Answer in 1-2 short sentences.
- Use only information from EVIDENCE_CHUNKS.
- For numbers, use only numbers that appear with the asked subject on the same line.
- If not found, say: "Not specified in the documents."
- Never include system markers or metadata.`;

const CONTINUATION_SYSTEM_PROMPT =
  'Continue the previous answer in 1 short sentence. Do not repeat.';

const CHAT_DETAIL_MARKER = '<<<CHAT_DETAIL>>>';
const CHAT_BRIEF_MARKER = '<<<CHAT_BRIEF>>>';
const NO_HISTORY_MARKER = '<<<NO_HISTORY>>>';
const SUMMARY_MARKER = '<<<SUMMARY_REQUEST>>>';
const SUMMARY_STYLE_PREFIX = '<<<SUMMARY_STYLE:';
const NAME_MARKER = '<<<NAME_REQUEST>>>';
const TAG_MARKER = '<<<TAG_REQUEST>>>';

const parseSummaryStylePayload = (
  raw: string,
): { text: string; length: SummaryLengthOption; content: SummaryContentOption } => {
  const fallback = {text: raw.trim(), length: 'medium' as SummaryLengthOption, content: 'general' as SummaryContentOption};
  const trimmed = raw.trimStart();
  if (!trimmed.startsWith(SUMMARY_STYLE_PREFIX)) {
    return fallback;
  }

  const endIndex = trimmed.indexOf('>>>');
  if (endIndex <= SUMMARY_STYLE_PREFIX.length) {
    return fallback;
  }

  const header = trimmed.slice(SUMMARY_STYLE_PREFIX.length, endIndex);
  const rest = trimmed.slice(endIndex + 3).trimStart();
  let length: SummaryLengthOption = 'medium';
  let content: SummaryContentOption = 'general';

  for (const chunk of header.split(';')) {
    const [rawKey, rawValue] = chunk.split('=');
    const key = (rawKey ?? '').trim().toLowerCase();
    const value = (rawValue ?? '').trim().toLowerCase();

    if (key === 'length' && (value === 'short' || value === 'medium' || value === 'long')) {
      length = value;
    } else if (
      key === 'content' &&
      (value === 'general' || value === 'finance' || value === 'legal' || value === 'academic' || value === 'medical')
    ) {
      content = value;
    }
  }

  return {text: rest, length, content};
};

const buildSummarySystemPrompt = (
  length: SummaryLengthOption,
  content: SummaryContentOption,
): string => {
  const contentRules = SUMMARY_CONTENT_RULES[content];
  const lengthRules = SUMMARY_LENGTH_RULES[length];
  return `${SUMMARY_PROMPT_COMMON}${contentRules}${lengthRules}${SUMMARY_PROMPT_FOOTER}`;
};

const INITIAL_CONVERSATION: Message[] = [
  {
    role: 'system',
    content: CHAT_SYSTEM_PROMPT,
    timestamp: Date.now(),
  },
];

function App(): React.JSX.Element {
  const [context, setContext] = useState<any>(null);
  const [isDownloading, setIsDownloading] = useState(false);
  const [downloadProgress, setDownloadProgress] = useState(0);

  // Keep conversation in JS so you can pass it to the model
  const conversationRef = useRef<Message[]>(INITIAL_CONVERSATION);
  // Guard against duplicate initialization
  const isInitializingRef = useRef(false);
  // Serialize AI requests to avoid "context is busy" errors
  const queueRef = useRef<Array<{ requestId: string; prompt: string }>>([]);
  const isRunningRef = useRef(false);
  const currentJobRef = useRef<{ requestId: string; prompt: string; type: 'summary' | 'name' | 'tag' | 'chat' } | null>(null);
  const abortCurrentRef = useRef(false);
  const canceledRequestIdsRef = useRef<Set<string>>(new Set());
  const pendingSummaryRestartRef = useRef<{ requestId: string; prompt: string } | null>(null);

  useEffect(() => {
    let cancelled = false;

    const prepareModel = async () => {
      // USE REF GUARD
      if (isInitializingRef.current) {
        console.log('[Model] Already initializing, skipping duplicate call');
        return;
      }
      
      isInitializingRef.current = true;
      console.log('[Model] Starting model preparation...');
      try {
        EdgeAI?.setModelReady?.(false);
      } catch {}
      setIsDownloading(true);
      setDownloadProgress(0);
      try {
        const filePath = `${RNFS.DocumentDirectoryPath}/${MODEL_FILENAME}`;
        const validateModelFile = async (): Promise<{valid: boolean; sizeBytes: number}> => {
          const exists = await RNFS.exists(filePath);
          if (!exists) {
            console.log('[Model] File does not exist at:', filePath);
            return {valid: false, sizeBytes: 0};
          }
          try {
            const stat = await RNFS.stat(filePath);
            const sizeBytes = Number(stat.size ?? 0);
            const valid = Number.isFinite(sizeBytes) && sizeBytes >= MIN_MODEL_FILE_SIZE_BYTES;
            console.log('[Model] File validation - size:', (sizeBytes / (1024 * 1024)).toFixed(2), 'MB, valid:', valid, 'min required:', (MIN_MODEL_FILE_SIZE_BYTES / (1024 * 1024)).toFixed(2), 'MB');
            return {valid, sizeBytes: Number.isFinite(sizeBytes) ? sizeBytes : 0};
          } catch (err) {
            console.warn('[Model] Failed to read model file metadata:', err);
            return {valid: false, sizeBytes: 0};
          }
        };

        console.log('[Model] Checking for model at:', filePath);
        
        // First validate the existing model file
        let validation = await validateModelFile();
        
        // Check for interrupted download marker
        let interruptedDownloadState: string | null = null;
        try {
          interruptedDownloadState = await AsyncStorage.getItem(MODEL_DOWNLOAD_STATE_KEY);
        } catch (err) {
          console.warn('[Model] Failed to read download state marker:', err);
        }
        const hadInterruptedDownload = interruptedDownloadState === MODEL_DOWNLOAD_IN_PROGRESS;
        
        // If model is valid but marker exists, clear the marker (app was closed after successful download)
        if (validation.valid && hadInterruptedDownload) {
          console.log('[Model] Model is valid but download marker exists, clearing marker');
          try {
            await AsyncStorage.removeItem(MODEL_DOWNLOAD_STATE_KEY);
          } catch (err) {
            console.warn('[Model] Failed to clear download state marker:', err);
          }
        }
        
        // Only remove file if it's invalid OR if it was an interrupted download AND file is incomplete
        if (hadInterruptedDownload && !validation.valid) {
          console.warn('[Model] Interrupted download detected with invalid file, removing partial model');
          try {
            const partialExists = await RNFS.exists(filePath);
            if (partialExists) {
              await RNFS.unlink(filePath);
            }
          } catch (err) {
            console.warn('[Model] Failed to remove partial model file:', err);
          }
          setDownloadProgress(0);
          validation = await validateModelFile();
        } else if (!validation.valid && validation.sizeBytes > 0) {
          console.warn('[Model] Existing model file looks invalid; deleting before redownload');
          try {
            await RNFS.unlink(filePath);
          } catch (err) {
            console.warn('[Model] Failed to remove invalid model file:', err);
          }
          validation = await validateModelFile();
        }

        // Remove any other installed GGUF models to save space when switching models.
        try {
          const dirItems = await RNFS.readDir(RNFS.DocumentDirectoryPath);
          for (const item of dirItems) {
            if (!item.isFile()) continue;
            if (!item.name.endsWith('.gguf')) continue;
            if (item.name === MODEL_FILENAME) continue;
            try {
              console.log('[Model] Removing old model:', item.name);
              await RNFS.unlink(item.path);
            } catch (err) {
              console.warn('[Model] Failed to remove old model:', item.name, err);
            }
          }
        } catch (err) {
          console.warn('[Model] Failed to scan for old models:', err);
        }

        if (!validation.valid) {
          console.log('[Model] Model not found or invalid. Starting download...');
          try {
            await AsyncStorage.setItem(MODEL_DOWNLOAD_STATE_KEY, MODEL_DOWNLOAD_IN_PROGRESS);
          } catch (err) {
            console.warn('[Model] Failed to set download state marker:', err);
          }

          let downloadedAndValidated = false;
          let lastDownloadError: unknown = null;
          for (let attempt = 1; attempt <= 2; attempt++) {
            try {
              // IMPORTANT: Delete any existing partial/corrupted file BEFORE starting download
              // This handles cases where Metro disconnects mid-download and leaves a partial file
              const existsBeforeDownload = await RNFS.exists(filePath);
              if (existsBeforeDownload) {
                console.log('[Model] Deleting existing file before download attempt', attempt);
                await RNFS.unlink(filePath);
              }
              
              setDownloadProgress(0);
              await downloadModel(MODEL_FILENAME, MODEL_URL, setDownloadProgress);
              validation = await validateModelFile();
              if (!validation.valid) {
                throw new Error(
                  `Downloaded model file failed integrity check (size=${validation.sizeBytes} bytes, expected>=${MIN_MODEL_FILE_SIZE_BYTES}).`,
                );
              }
              downloadedAndValidated = true;
              console.log('[Model] Download completed and validated. Size bytes:', validation.sizeBytes);
              break;
            } catch (err) {
              lastDownloadError = err;
              console.warn(`[Model] Download attempt ${attempt} failed:`, err);
              // Clean up failed download
              try {
                const partialExists = await RNFS.exists(filePath);
                if (partialExists) {
                  console.log('[Model] Removing failed download file');
                  await RNFS.unlink(filePath);
                }
              } catch (unlinkErr) {
                console.warn('[Model] Failed to remove invalid downloaded model file:', unlinkErr);
              }
            }
          }

          try {
            await AsyncStorage.removeItem(MODEL_DOWNLOAD_STATE_KEY);
          } catch (err) {
            console.warn('[Model] Failed to clear download state marker:', err);
          }

          if (!downloadedAndValidated) {
            throw lastDownloadError instanceof Error
              ? lastDownloadError
              : new Error('Failed to download and validate model file.');
          }
        } else {
          console.log('[Model] Using existing model file. Size bytes:', validation.sizeBytes);
        }

        if (cancelled) {
          console.log('[Model] Preparation cancelled');
          return;
        }

        console.log('[Model] Initializing llama context...');
        const llamaContext = await initLlama({
          model: filePath,
          use_mlock: false,
          n_ctx: LLAMA_N_CTX,
          n_gpu_layers: -1, // Use all available GPU layers when supported
        });
        
        console.log('[Model] Llama context initialized:', !!llamaContext);

        if (cancelled) {
          console.log('[Model] Cancelled after init, releasing...');
          try {
            releaseAllLlama();
          } catch {}
          return;
        }

        setContext(llamaContext);
        try {
          EdgeAI?.setModelReady?.(true);
        } catch {}
        console.log('[Model] Model ready for use!');
      } catch (error: any) {
        console.error('[Model] AI Model Error:', error);
        const errorMsg = error instanceof Error ? error.message : String(error);
        console.error('[Model] Error details:', errorMsg);
        Alert.alert('AI Model Error', `Failed to initialize model: ${errorMsg}`);
        try {
          EdgeAI?.setModelReady?.(false);
        } catch {}
      } finally {
        if (!cancelled) {
          setIsDownloading(false);
          isInitializingRef.current = false; // RESET HERE
        }
      }
    };

    prepareModel();

    return () => {
      cancelled = true;
      isInitializingRef.current = false; // RESET ON CLEANUP
      try {
        releaseAllLlama();
      } catch (e) {
        console.warn('Error releasing llama context', e);
      }
      try {
        EdgeAI?.setModelReady?.(false);
      } catch {}
    };
  }, []);

useEffect(() => {
  if (!context) return;

  const emitter = new NativeEventEmitter(EdgeAI);

  const formatPrompt = (messages: Message[]): string => {
    const sections = messages
      .map((m) => {
        const roleLabel = m.role === 'system' ? 'system' : m.role === 'assistant' ? 'assistant' : 'user';
        return `<|im_start|>${roleLabel}\n${m.content.trim()}\n<|im_end|>`;
      })
      .join('\n');
    return `${sections}\n<|im_start|>assistant\n`;
  };

  const stopTokensForModel = (): string[] => {
    return ['<|im_end|>', '<|im_start|>', '<|system|>', '<|assistant|>', '<|user|>', '</s>', '<|endoftext|>'];
  };

  const truncateChatHistory = (messages: Message[]): Message[] => {
    const systemMessage = [...messages].reverse().find((message) => message.role === 'system');
    const nonSystemMessages = messages.filter((message) => message.role !== 'system');
    const trimmedNonSystemMessages = nonSystemMessages.slice(-MAX_CHAT_HISTORY_MESSAGES);
    return systemMessage ? [systemMessage, ...trimmedNonSystemMessages] : trimmedNonSystemMessages;
  };

  const parsePromptControlMarkers = (
    input: string,
  ): { text: string; noHistory: boolean; nPredict: number | null } => {
    let text = input;
    let noHistory = false;
    let nPredict: number | null = null;

    if (text.includes(NO_HISTORY_MARKER)) {
      noHistory = true;
      text = text.replace(NO_HISTORY_MARKER, '').trimStart();
    }

    // Extract and strip <<<N_PREDICT:N>>> token embedded by Swift for output length control
    const nPredictMatch = text.match(/<<<N_PREDICT:(\d+)>>>\n?/);
    if (nPredictMatch) {
      nPredict = parseInt(nPredictMatch[1], 10);
      text = text.replace(/<<<N_PREDICT:\d+>>>\n?/, '').trimStart();
    }

    if (text.startsWith(CHAT_DETAIL_MARKER)) {
      text = text.slice(CHAT_DETAIL_MARKER.length).trimStart();
    } else if (text.startsWith(CHAT_BRIEF_MARKER)) {
      text = text.slice(CHAT_BRIEF_MARKER.length).trimStart();
    }

    return {text, noHistory, nPredict};
  };

  const buildNoHistoryMessages = (input: string): Message[] => {
    const trimmed = input.trim();
    const fallbackUserMessage: Message = {
      role: 'user',
      content: trimmed,
      timestamp: Date.now(),
    };

    if (!trimmed.startsWith('SYSTEM:')) {
      return [fallbackUserMessage];
    }

    const afterSystem = trimmed.slice('SYSTEM:'.length).trimStart();
    const sectionMatch = /\n{2,}([A-Z][A-Z_ ]{2,}):\s*\n/.exec(afterSystem);
    if (!sectionMatch || sectionMatch.index == null) {
      return [fallbackUserMessage];
    }

    const firstSectionIndex = sectionMatch.index;
    const systemContent = afterSystem.slice(0, firstSectionIndex).trim();
    const userContent = afterSystem.slice(firstSectionIndex).trim();
    if (!systemContent || !userContent) {
      return [fallbackUserMessage];
    }

    const now = Date.now();
    return [
      {role: 'system', content: systemContent, timestamp: now},
      {role: 'user', content: userContent, timestamp: now},
    ];
  };

  const isUserPromptText = (raw: string): boolean => {
    const {text} = parsePromptControlMarkers(raw);
    return !(text.startsWith(SUMMARY_MARKER) || text.startsWith(NAME_MARKER) || text.startsWith(TAG_MARKER));
  };

  const processQueue = async () => {
    console.log('[EdgeAI] processQueue called, isRunning:', isRunningRef.current, 'queue length:', queueRef.current.length);
    if (isRunningRef.current) {
      console.log('[EdgeAI] Queue already processing, skipping');
      return;
    }
    if (queueRef.current.length === 0) {
      console.log('[EdgeAI] Queue is empty, nothing to process');
      return;
    }
    
    isRunningRef.current = true;
    console.log('[EdgeAI] Starting queue processing...');
    
    try {
      while (queueRef.current.length > 0) {
        const job = queueRef.current.shift();
        if (!job) break;
        const { requestId, prompt } = job;
        console.log('[EdgeAI] Processing request:', requestId, 'prompt length:', prompt.length);
        
        const parsedPrompt = parsePromptControlMarkers(prompt);
        let rawPrompt = parsedPrompt.text;
        const noHistory = parsedPrompt.noHistory;
        const nPredictOverride = parsedPrompt.nPredict;
        // Structured Swift task (summary, keyword, etc.) — n_predict controls length, not JS caps
        const isStructuredTask = noHistory && nPredictOverride !== null;
        const isSummary = rawPrompt.startsWith(SUMMARY_MARKER);
        const isName = rawPrompt.startsWith(NAME_MARKER);
        const isTag = rawPrompt.startsWith(TAG_MARKER);
        let summaryLength: SummaryLengthOption = 'medium';
        let summaryContent: SummaryContentOption = 'general';
        const userContent = isSummary
          ? (() => {
              const parsed = parseSummaryStylePayload(rawPrompt.slice(SUMMARY_MARKER.length).trim());
              summaryLength = parsed.length;
              summaryContent = parsed.content;
              return parsed.text;
            })()
          : isName
          ? rawPrompt.slice(NAME_MARKER.length).trim()
          : isTag
          ? rawPrompt.slice(TAG_MARKER.length).trim()
          : rawPrompt;
        const summaryContentMaxChars = 50000;
        const modeLabel: 'summary' | 'name' | 'tag' | 'chat' = isSummary ? 'summary' : isName ? 'name' : isTag ? 'tag' : 'chat';
        const jobType = modeLabel;
        console.log('[EdgeAI] Mode:', modeLabel, 'content length:', userContent.length, 'summary style:', `${summaryLength}/${summaryContent}`);
        currentJobRef.current = { requestId, prompt, type: modeLabel };
        abortCurrentRef.current = false;
        
        const userMessage: Message = { role: 'user', content: userContent, timestamp: Date.now() };
        const summarySystemPrompt = buildSummarySystemPrompt(summaryLength, summaryContent);
        const summaryChunkPrompt = `${summarySystemPrompt}\n  Extract only the most important points; ignore minor details.`;
        const summaryCombinePrompt = `${summarySystemPrompt}\n  Merge and deduplicate; prefer omission over repetition.`;

        const messagesForAI: Message[] = isSummary
          ? [{ role: 'system', content: summarySystemPrompt, timestamp: Date.now() }, userMessage]
          : isName
          ? [userMessage]
          : isTag
          ? [{ role: 'system', content: TAG_SYSTEM_PROMPT, timestamp: Date.now() }, userMessage]
          : noHistory
          ? buildNoHistoryMessages(userContent)
          : truncateChatHistory([...conversationRef.current, userMessage]);

        try {
          if (!context) {
            throw new Error('Model context is not initialized');
          }
          
          const promptText = formatPrompt(messagesForAI);
          console.log('[EdgeAI] Generated prompt length:', promptText.length);
          console.log('[EdgeAI] Prompt preview:', promptText.substring(0, 200) + '...');
          
          const stopTokens = stopTokensForModel();
          let generationHitTokenLimit = false;

          const approximateTokenCount = (input: string): number => {
            const words = input.trim().split(/\s+/).filter(Boolean).length;
            const punctuation = (input.match(/[.,!?;:]/g) ?? []).length;
            return words + punctuation;
          };

          const inferHitTokenLimit = (result: any, nPredict: number, outputText: string): boolean => {
            const rawPredicted =
              result?.timings?.predicted_n ??
              result?.timings?.predictedTokens ??
              result?.n_tokens_predicted ??
              result?.tokens_predicted;
            const predictedCount = Number(rawPredicted);
            if (Number.isFinite(predictedCount) && predictedCount > 0) {
              return predictedCount >= Math.max(1, nPredict - 2);
            }
            const approxCount = approximateTokenCount(outputText);
            return approxCount >= Math.max(24, Math.floor(nPredict * 0.9));
          };

          const runSummary = async (summaryText: string, nPredict: number): Promise<string> => {
            const nPredictClamped = Math.min(nPredict, SUMMARY_MAX_NEW_TOKENS);
            const summaryMessages: Message[] = [
              { role: 'system', content: summaryChunkPrompt, timestamp: Date.now() },
              { role: 'user', content: summaryText, timestamp: Date.now() }
            ];
            const summaryPrompt = formatPrompt(summaryMessages);
            const summaryResult = await context.completion(
              {
                prompt: summaryPrompt,
                n_predict: nPredictClamped,
                temperature: DEFAULT_TEMPERATURE,
                top_p: DEFAULT_TOP_P,
                repeat_penalty: DEFAULT_REPEAT_PENALTY,
                repeat_last_n: 256,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );

            let out = (summaryResult?.text ?? '').trim();
            out = out.replace(/\b(\w+)\b(?:\s+\1){5,}/gi, '$1');
            generationHitTokenLimit = inferHitTokenLimit(summaryResult, nPredictClamped, out);
            return out;
          };

          const runSummaryFinalCombine = async (summaryText: string, nPredict: number): Promise<string> => {
            const nPredictClamped = Math.min(nPredict, SUMMARY_MAX_NEW_TOKENS);
            const summaryMessages: Message[] = [
              { role: 'system', content: summaryCombinePrompt, timestamp: Date.now() },
              { role: 'user', content: summaryText, timestamp: Date.now() }
            ];
            const summaryPrompt = formatPrompt(summaryMessages);
            const summaryResult = await context.completion(
              {
                prompt: summaryPrompt,
                n_predict: nPredictClamped,
                temperature: DEFAULT_TEMPERATURE,
                top_p: DEFAULT_TOP_P,
                repeat_penalty: DEFAULT_REPEAT_PENALTY,
                repeat_last_n: 256,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );

            let out = (summaryResult?.text ?? '').trim();
            out = out.replace(/\b(\w+)\b(?:\s+\1){5,}/gi, '$1');
            generationHitTokenLimit = inferHitTokenLimit(summaryResult, nPredictClamped, out);
            return out;
          };

          const combineSummaries = async (summaries: string[]): Promise<string> => {
            const items = summaries.map(s => s.trim()).filter(Boolean);
            if (items.length === 0) return '';
            if (items.length === 1) return items[0];
            if (items.length > 6) {
              const intermediates: string[] = [];
              for (let i = 0; i < items.length; i += 5) {
                const slice = items.slice(i, i + 5);
                const combined = await combineSummaries(slice);
                if (combined) intermediates.push(combined);
              }
              return combineSummaries(intermediates);
            }

            const combined = items.join('\n');
            const finalPrompt =
              `Combine the following chunk summaries into one concise summary in plain sentences. ` +
              `No bullets, no headings, no labels. Do not repeat ideas.\n\n` +
              combined;
            return runSummaryFinalCombine(finalPrompt, 420);
          };

          const runContinuation = async (draftText: string, nPredict: number): Promise<string> => {
            const continuationMessages: Message[] = [
              { role: 'system', content: CONTINUATION_SYSTEM_PROMPT, timestamp: Date.now() },
              { role: 'user', content: draftText, timestamp: Date.now() }
            ];
            const continuationPrompt = formatPrompt(continuationMessages);
            const continuationTemperature = isSummary ? DEFAULT_TEMPERATURE : CHAT_TEMPERATURE;
            const continuationRepeatPenalty = isSummary ? DEFAULT_REPEAT_PENALTY : CHAT_REPEAT_PENALTY;
            const continuationResult = await context.completion(
              {
                prompt: continuationPrompt,
                n_predict: Math.min(nPredict, DEFAULT_MAX_NEW_TOKENS),
                temperature: continuationTemperature,
                top_p: DEFAULT_TOP_P,
                repeat_penalty: continuationRepeatPenalty,
                repeat_last_n: 256,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );

            let out = (continuationResult?.text ?? '').trim();
            out = out.replace(/\b(\w+)\b(?:\s+\1){3,}/gi, '$1');
            return out;
          };

          let text = "";
          if (isSummary) {
            const summaryInput =
              userContent.length > summaryContentMaxChars
                ? userContent.slice(0, summaryContentMaxChars)
                : userContent;
            const chunkSize = 4000;
            const chunks: string[] = [];
            const paragraphs = summaryInput.split(/\n\s*\n/);
            let current = '';
            for (const para of paragraphs) {
              const trimmed = para.trim();
              if (!trimmed) continue;
              const candidate = current ? `${current}\n\n${trimmed}` : trimmed;
              if (candidate.length > chunkSize && current) {
                chunks.push(current);
                current = trimmed;
              } else {
                current = candidate;
              }
            }
            if (current) {
              chunks.push(current);
            }

            if (chunks.length <= 1) {
              text = await runSummary(summaryInput, SUMMARY_MAX_NEW_TOKENS);
            } else {
              const chunkSummaries: string[] = [];
              for (let i = 0; i < chunks.length; i++) {
                if (abortCurrentRef.current) break;
                const chunk = chunks[i];
                const chunkSummary = await runSummary(chunk, 192);
                if (abortCurrentRef.current) break;
                if (chunkSummary) {
                  chunkSummaries.push(chunkSummary);
                }
              }

              if (!abortCurrentRef.current) {
                text = await combineSummaries(chunkSummaries);
              }
            }
          } else if (isName) {
            const nPredictClamped = 50;
            const namePrompt = formatPrompt(messagesForAI);
            const nameResult = await context.completion(
              {
                prompt: namePrompt,
                n_predict: nPredictClamped,
                temperature: DEFAULT_TEMPERATURE,
                top_p: DEFAULT_TOP_P,
                repeat_penalty: DEFAULT_REPEAT_PENALTY,
                repeat_last_n: 128,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );
            text = (nameResult?.text ?? '').trim();
            generationHitTokenLimit = inferHitTokenLimit(nameResult, nPredictClamped, text);
          } else if (isTag) {
            const nPredictClamped = nPredictOverride ?? 60;
            const tagPrompt = formatPrompt(messagesForAI);
            const tagResult = await context.completion(
              {
                prompt: tagPrompt,
                n_predict: nPredictClamped,
                temperature: DEFAULT_TEMPERATURE,
                top_p: DEFAULT_TOP_P,
                repeat_penalty: DEFAULT_REPEAT_PENALTY,
                repeat_last_n: 128,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );
            text = (tagResult?.text ?? '').trim();
            generationHitTokenLimit = inferHitTokenLimit(tagResult, nPredictClamped, text);
          } else {
            const nPredictClamped = nPredictOverride ?? DEFAULT_MAX_NEW_TOKENS;
            const completionParams = {
              prompt: promptText,
              n_predict: nPredictClamped,
              temperature: CHAT_TEMPERATURE,
              top_p: DEFAULT_TOP_P,
              repeat_penalty: CHAT_REPEAT_PENALTY,
              repeat_last_n: 256,
              min_p: 0.05,
              stop: stopTokens
            };

            console.log('[EdgeAI] Calling context.completion with params:', Object.keys(completionParams));
            const result = await context.completion(completionParams, () => {});

            console.log('[EdgeAI] Got result:', {
              hasText: !!result?.text,
              textLength: result?.text?.length ?? 0,
              textPreview: result?.text?.substring(0, 100)
            });

            text = (result?.text ?? '').trim();
            generationHitTokenLimit = inferHitTokenLimit(result, nPredictClamped, text);
          }

          const endsCleanly = (s: string) => /[.!?]["')\]]?\s*$/.test(s.trim());

          const trimToLastCompleteSentence = (input: string): string => {
            const match = input.match(/[\s\S]*[.!?]["')\]]?\s*/);
            return match ? match[0].trim() : input.trim();
          };

          const hasUnfinishedCodeFence = (input: string): boolean => {
            const fences = input.match(/```/g) ?? [];
            return fences.length % 2 === 1;
          };

          const hasUnmatchedQuote = (input: string): boolean => {
            const escapedDoubleQuotes = input.match(/\\"/g)?.length ?? 0;
            const rawDoubleQuotes = input.match(/"/g)?.length ?? 0;
            const unescapedDoubleQuotes = Math.max(0, rawDoubleQuotes - escapedDoubleQuotes);
            const smartOpen = input.match(/“/g)?.length ?? 0;
            const smartClose = input.match(/”/g)?.length ?? 0;
            const backticks = input.match(/`/g)?.length ?? 0;
            return unescapedDoubleQuotes % 2 === 1 || smartOpen !== smartClose || backticks % 2 === 1;
          };

          const looksCutOff = (s: string): boolean => {
            const t = s.trim();
            if (!t) return false;
            if (/[.!?]["')\]]?$/.test(t)) return false;
            if (/[,\-–—:]$/.test(t)) return true;

            const tail = t.split(/\s+/).slice(-2).join(' ').toLowerCase();
            const dangling = ['and', 'or', 'to', 'of', 'for', 'with', 'a', 'an', 'the', 'in', 'on', 'at', 'as', 'by'];
            if (dangling.some(w => tail === w || tail.endsWith(' ' + w))) return true;

            if (t.length > 260 && !/[.!?]/.test(t.slice(-80))) return true;
            return false;
          };

          const shouldAttemptContinuation = (input: string, hitTokenLimit: boolean): boolean => {
            const trimmed = input.trimEnd();
            if (!trimmed) return false;

            const lastChar = trimmed[trimmed.length - 1] ?? '';
            const endsMidWord = /[a-z0-9]/i.test(lastChar) && !endsCleanly(trimmed);
            const unfinishedDelimitedText = hasUnfinishedCodeFence(trimmed) || hasUnmatchedQuote(trimmed);
            const tokenLimitLikelyCut = hitTokenLimit && endsMidWord;
            return looksCutOff(trimmed) || endsMidWord || unfinishedDelimitedText || tokenLimitLikelyCut;
          };

          const squashWordStutter = (input: string): string => {
            let out = input;
            // Collapse repeated words (3+ in a row) to reduce stutter.
            out = out.replace(/\b(\w+)\b(?:\s+\1){2,}\b/gi, '$1');
            // Collapse repeated two-word phrases (3+ in a row).
            out = out.replace(/\b(\w+\s+\w+)\b(?:\s+\1){2,}\b/gi, '$1');
            return out;
          };

          const dedupeRepeats = (input: string): string => {
            const lines = input.split('\n');
            const dedupedLines: string[] = [];
            for (const line of lines) {
              if (dedupedLines[dedupedLines.length - 1] !== line) {
                dedupedLines.push(line);
              }
            }
            return dedupedLines.join('\n').trim();
          };

          const dedupeSentencesGlobal = (input: string): string => {
            const sentences = input.split(/(?<=[.!?])\s+/);
            const seen = new Set<string>();
            const out: string[] = [];

            const norm = (s: string) =>
              s
                .toLowerCase()
                .replace(/\s+/g, ' ')
                .replace(/[“”"']/g, '')
                .replace(/[^a-z0-9 .,!?:;-]/gi, '')
                .trim();

            for (const s of sentences) {
              const t = s.trim();
              if (!t) continue;
              const key = norm(t);
              if (seen.has(key)) continue;
              seen.add(key);
              out.push(t);
            }
            return out.join(' ').trim();
          };

          const approxDedupeSentences = (input: string): string => {
            const sentences = input.split(/(?<=[.!?])\s+/).filter(Boolean);
            if (sentences.length <= 1) return input.trim();
            const stopwords = new Set([
              'a','an','the','and','or','but','if','then','else','when','while','of','to','in','on','for','with',
              'at','by','from','as','is','are','was','were','be','been','being','it','this','that','these','those',
              'its','their','they','them','we','you','your','i','me','my','our','ours'
            ]);
            const norm = (s: string) =>
              s
                .toLowerCase()
                .replace(/[^a-z0-9\s]/g, ' ')
                .replace(/\s+/g, ' ')
                .trim();
            const toSet = (s: string) => {
              const words = norm(s).split(' ').filter(Boolean).filter(w => !stopwords.has(w));
              return new Set(words);
            };
            const sets: Array<Set<string>> = [];
            const out: string[] = [];

            for (const s of sentences) {
              const setA = toSet(s);
              if (setA.size === 0) {
                out.push(s.trim());
                sets.push(setA);
                continue;
              }
              let isDup = false;
              for (const setB of sets) {
                if (setB.size === 0) continue;
                let inter = 0;
                for (const w of setA) {
                  if (setB.has(w)) inter++;
                }
                const union = setA.size + setB.size - inter;
                const jaccard = union === 0 ? 0 : inter / union;
                if (jaccard >= 0.82) {
                  isDup = true;
                  break;
                }
              }
              if (!isDup) {
                out.push(s.trim());
                sets.push(setA);
              }
            }

            return out.join(' ').trim();
          };

          const trimRepeatedTail = (input: string): string => {
            const sentences = input.split(/(?<=[.!?])\s+/).filter(Boolean);
            if (sentences.length < 2) return input.trim();
            const norm = (s: string) =>
              s
                .toLowerCase()
                .replace(/\s+/g, ' ')
                .replace(/[“”"']/g, '')
                .replace(/[^a-z0-9 .,!?:;-]/gi, '')
                .trim();

            let pops = 0;
            while (sentences.length >= 2 && pops < 5) {
              const last = sentences[sentences.length - 1];
              const lastKey = norm(last);
              let seenEarlier = false;
              for (let i = 0; i < sentences.length - 1; i++) {
                if (norm(sentences[i]) === lastKey) {
                  seenEarlier = true;
                  break;
                }
              }
              if (!seenEarlier) break;
              sentences.pop();
              pops++;
            }

            return sentences.join(' ').trim();
          };

          const stripSummaryHeading = (input: string): string => {
            let out = input;
            // Remove a leading sentence that contains "summary" up to the first colon.
            out = out.replace(/^\s*[^:\n]*\bsummary\b[^:\n]*:\s*/i, '');
            return out;
          };

          const stripLeadingMarkdownMarkers = (input: string): string => {
            let out = input;
            // Remove leftover bold/italic markers at the start.
            out = out.replace(/^\s*(\*\*|__|\*)+\s*/, '');
            return out;
          };

          const formatBullets = (input: string): string => {
            let out = input;
            // Inline dashes -> new line + tab.
            out = out.replace(/([^\n])\s*-\s+/g, '$1\n\t- ');
            // Line-start dashes -> ensure newline + tab.
            out = out.replace(/(^|\n)\s*-\s+/g, '\n\t- ');
            // Inline bullets -> new line + tab.
            out = out.replace(/([^\n])\s*•\s*/g, '$1\n\t• ');
            // Line-start bullets -> ensure newline + tab.
            out = out.replace(/(^|\n)\s*•\s*/g, '\n\t• ');
            // Remove a leading newline added at the start of the string.
            out = out.replace(/^\n/, '');
            return out;
          };

          const looksLikeKeywordDump = (input: string): boolean => {
            const s = input.trim();
            if (!s) return false;

            // If there's very little sentence punctuation but many commas, it's likely a dump.
            const commas = (s.match(/,/g) ?? []).length;
            const sentencePunct = (s.match(/[.!?]/g) ?? []).length;

            // Many commas, few sentence endings -> dump
            if (commas >= 8 && sentencePunct === 0) return true;

            // Extremely long single "sentence" with tons of separators
            if (s.length > 260 && sentencePunct <= 1 && commas >= 6) return true;

            return false;
          };

          // Collapses comma/space-separated repeated 1-5 word phrases.
          // Example: "Logistics internship, Logistics internship, ..." -> "Logistics internship"
          const squashCommaPhraseRepeats = (input: string): string => {
            let out = input;

            // 1) Collapse exact repeated multi-word phrases separated by commas/spaces.
            // Matches: "<phrase>, <phrase>, <phrase> ..." (phrase up to 5 words)
            out = out.replace(
              /\b((?:[a-z0-9]+(?:\s+[a-z0-9]+){0,4}))\b(?:\s*,\s*\1\b){2,}/gi,
              '$1'
            );

            // 2) Collapse repeated single words separated by commas.
            out = out.replace(/\b([a-z0-9]+)\b(?:\s*,\s*\1\b){3,}/gi, '$1');

            // 3) Clean up leftover doubled commas/spaces.
            out = out.replace(/\s*,\s*,+/g, ', ').replace(/\s{2,}/g, ' ').trim();

            return out;
          };

          // Hard length cap for chat outputs to prevent UI explosions when punctuation is missing.
          const hardCapChatLength = (input: string, maxChars: number = 420): string => {
            const s = input.trim();
            if (s.length <= maxChars) return s;
            return s.slice(0, maxChars).trimEnd();
          };

          const limitToSentenceCount = (input: string, maxSentences: number): string => {
            const trimmed = input.trim();
            if (!trimmed || maxSentences <= 0) return '';

            const sentenceMatches = trimmed.match(/[^.!?]+[.!?]["')\]]*/g);
            if (!sentenceMatches || sentenceMatches.length <= maxSentences) {
              return trimmed;
            }

            return sentenceMatches
              .slice(0, maxSentences)
              .map((sentence) => sentence.trim())
              .join(' ')
              .trim();
          };

          const truncateAtTemplateRoleTokens = (input: string): string => {
            const markers = [
              '<|im_end|>',
              '<|im_start|>',
              '<|system|>',
              '<|assistant|>',
              '<|user|>',
              '</s>',
              '<|start_header_id|>',
              '<|end_header_id|>',
              '<|endoftext|>'
            ];
            let cutIndex = -1;
            for (const marker of markers) {
              const idx = input.indexOf(marker);
              if (idx >= 0 && (cutIndex === -1 || idx < cutIndex)) {
                cutIndex = idx;
              }
            }
            if (cutIndex < 0) return input;
            return input.slice(0, cutIndex).trimEnd();
          };

          const finishIfCut = async (
            input: string,
            hitTokenLimit: boolean,
            maxAttempts: number = 2,
          ): Promise<string> => {
            let out = input.trim();
            if (!shouldAttemptContinuation(out, hitTokenLimit)) return out;

            for (let i = 0; i < maxAttempts; i++) {
              if (!shouldAttemptContinuation(out, hitTokenLimit)) break;
              const continuation = await runContinuation(out, 60);
              const cont = continuation.replace(/^[\s.\-–—:;]+/, '').trim();
              if (!cont) break;
              out = (out.trimEnd() + ' ' + cont).trim();
            }

            return shouldAttemptContinuation(out, hitTokenLimit)
              ? trimToLastCompleteSentence(out)
              : out;
          };

          // strip only template artifacts
          text = truncateAtTemplateRoleTokens(text)
            .replace(/<start_of_turn>/g, '')
            .replace(/<end_of_turn>/g, '')
            .replace(/<\|im_start\|>/g, '')
            .replace(/<\|im_end\|>/g, '')
            .replace(/<\|begin_of_text\|>/g, '')
            .replace(/<\|start_header_id\|>/g, '')
            .replace(/<\|end_header_id\|>/g, '')
            .replace(/<\|eot_id\|>/g, '')
            .replace(/^\s*model\s*\n/i, '')
            .trim();
          if (isSummary && !abortCurrentRef.current) {
            text = stripSummaryHeading(text);
            text = stripLeadingMarkdownMarkers(text).trimStart();
          }
          
          if (isSummary && !abortCurrentRef.current) {
            text = squashWordStutter(text);
            text = approxDedupeSentences(dedupeSentencesGlobal(dedupeRepeats(text)));
            text = trimRepeatedTail(text);
            text = await finishIfCut(text, generationHitTokenLimit, 2);
            text = text.trim();
          } else {
            // Non-summary (chat) cleanup
            if (!isName && !isTag) {
              text = await finishIfCut(text, generationHitTokenLimit, 1);
            }

            text = truncateAtTemplateRoleTokens(text).trim();

            // New: squash comma-separated phrase loops
            text = squashCommaPhraseRepeats(text);

            text = squashWordStutter(text);
            text = approxDedupeSentences(dedupeSentencesGlobal(dedupeRepeats(text)));

            // New: if it still looks like a keyword dump, force a safe clamp
            if (!isName && !isTag && !isStructuredTask && looksLikeKeywordDump(text)) {
              text = hardCapChatLength(text, 260);
            }

            if (!isName && !isTag && !isStructuredTask) {
              text = limitToSentenceCount(text, 3);
            }

            // New: final hard cap for any case where punctuation is absent
            if (!isName && !isTag && !isStructuredTask) {
              text = hardCapChatLength(text, 420);
            }

            text = text.trim();
          }

          // Remove any leftover chat/template markers (failsafe).
          text = text.replace(/<\|[^|>]*\|>/g, '').trim();

          if (abortCurrentRef.current && isSummary) {
            abortCurrentRef.current = false;
            continue;
          }

          if (canceledRequestIdsRef.current.has(requestId)) {
            canceledRequestIdsRef.current.delete(requestId);
            console.log('[EdgeAI] Skipping canceled request:', requestId);
            continue;
          }

          if (!text) text = "(No output)";

          if (!isSummary && !isName && !noHistory) {
            const isFallback =
              text.trim() === "Not specified in the documents.";

            if (text.length > 0 && !isFallback) {
              const assistantMessage: Message = {
                role: 'assistant',
                content: text,
                timestamp: Date.now(),
              };
              conversationRef.current = [...messagesForAI, assistantMessage];
            } else {
              // Do NOT store fallback answers in history
              conversationRef.current = messagesForAI;
            }
          }

          console.log('[EdgeAI] Resolving request with text length:', text.length);
          EdgeAI.resolveRequest(requestId, text);
        } catch (e: any) {
          console.error('[EdgeAI] Generation error:', e);
          const errorMsg = e?.message ?? 'Unknown error';
          if (abortCurrentRef.current && isSummary) {
            abortCurrentRef.current = false;
          } else {
            EdgeAI.rejectRequest(requestId, 'GEN_ERR', errorMsg);
          }
        } finally {
          if (jobType === 'chat' && pendingSummaryRestartRef.current) {
            const hasQueuedUserPrompt = queueRef.current.some((job) => isUserPromptText(job.prompt));
            if (!hasQueuedUserPrompt) {
              const pending = pendingSummaryRestartRef.current;
              pendingSummaryRestartRef.current = null;
              queueRef.current.unshift(pending);
            }
          }
          currentJobRef.current = null;
          console.log('[EdgeAI] Request processed, remaining queue:', queueRef.current.length);
        }
      }
    } catch (globalError: any) {
      console.error('[EdgeAI] Global queue processing error:', globalError);
    } finally {
      isRunningRef.current = false;
      console.log('[EdgeAI] Queue processing finished');
    }
  };

  const sub = emitter.addListener('EdgeAIRequest', (evt) => {
    console.log('[EdgeAI] Received request:', evt);
    const { requestId, prompt } = evt;
    if (!requestId || !prompt) {
      console.error('[EdgeAI] Invalid request - missing requestId or prompt:', evt);
      return;
    }
    console.log('[EdgeAI] Adding to queue. Current queue length:', queueRef.current.length);
    const normalizedPrompt = parsePromptControlMarkers(String(prompt)).text;
    const isName = normalizedPrompt.startsWith(NAME_MARKER);
    const isSummary = normalizedPrompt.startsWith(SUMMARY_MARKER);
    const isTag = normalizedPrompt.startsWith(TAG_MARKER);
    const isUserPrompt = !isSummary && !isName && !isTag;
    let enqueued = false;

    if (isUserPrompt) {
      if (isRunningRef.current && currentJobRef.current?.type === 'summary') {
        const currentSummary = currentJobRef.current;
        if (currentSummary) {
          pendingSummaryRestartRef.current = { requestId: currentSummary.requestId, prompt: currentSummary.prompt };
        }
        abortCurrentRef.current = true;
        context?.stopCompletion().catch((err: any) => {
          console.warn('[EdgeAI] Failed to stop summary completion:', err);
        });
        queueRef.current.unshift({ requestId, prompt });
        enqueued = true;
      }
    }

    if (!enqueued && (isName || isTag)) {
      // Let summaries finish; name/tag can wait.
      queueRef.current.push({ requestId, prompt });
      enqueued = true;
    }

    if (!enqueued) {
      queueRef.current.push({ requestId, prompt });
    }
    processQueue().catch((err: any) => {
      console.error('[EdgeAI] Queue processing error:', err);
      EdgeAI.rejectRequest(requestId, 'QUEUE_ERR', err?.message ?? 'Unknown queue error');
    });
  });

  const cancelSub = emitter.addListener('EdgeAICancel', async () => {
    const current = currentJobRef.current;
    if (!current || current.type !== 'chat') {
      console.log('[EdgeAI] Cancel requested but no active chat job');
      return;
    }
    console.log('[EdgeAI] Cancel requested for job:', current.requestId);
    canceledRequestIdsRef.current.add(current.requestId);
    try {
      await context?.stopCompletion();
    } catch (err: any) {
      console.warn('[EdgeAI] stopCompletion failed:', err);
    }
    EdgeAI.rejectRequest(current.requestId, 'CANCELLED', 'CANCELLED');
  });

  return () => {
    sub.remove();
    cancelSub.remove();
  };
}, [context]);

  // Render native SwiftUI chat UI
  return <NativeChatView style={styles.container} />;
}

const styles = StyleSheet.create({
  container: {flex: 1},
});



export default App;
