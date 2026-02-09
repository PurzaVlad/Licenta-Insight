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

const MODEL_FILENAME = 'Qwen2.5-1.5B-Instruct.Q3_K_M.gguf';
const MODEL_URL =
  'https://huggingface.co/MaziyarPanahi/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct.Q3_K_M.gguf';
const MODEL_DOWNLOAD_STATE_KEY = 'edgeai:model_download_state';
const MODEL_DOWNLOAD_IN_PROGRESS = 'in_progress';

const SUMMARY_SYSTEM_PROMPT = `
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
  4–7 sentences max.
  ~120–180 words.
  If more info exists, prefer omission.
  Keep it short.
  Stop after the last sentence.
  `;

const SUMMARY_CHUNK_PROMPT = `${SUMMARY_SYSTEM_PROMPT}\n  Extract only the most important points; ignore minor details.`;
const SUMMARY_COMBINE_PROMPT = `${SUMMARY_SYSTEM_PROMPT}\n  Merge and deduplicate; prefer omission over repetition.`;

const TAG_SYSTEM_PROMPT = `
  You will receive a short excerpt from a document.
  Extract 4 single-word tags that capture the topic.

  Rules:
  Output tags as a comma-separated list.
  Use plain words only; no punctuation, no numbering, no labels.
  Prefer specific topics or names over generic words.
  Do not repeat words.
  `;

const CHAT_SYSTEM_PROMPT =
  'You are Identity, a proactive, concise assistant. Answer from the provided ACTIVE_CONTEXT and recent chat. Do not reveal internal reasoning; provide the final answer only. If the context is insufficient, ask a brief clarifying question or suggest a document. Never say you cannot access information; ask for the missing document or clarification instead. Cite document titles when using their content. Respond in English. Always finish your last sentence; do not trail off.';

const CONTINUATION_SYSTEM_PROMPT =
  'You will receive a draft assistant response. Continue and complete only the final sentence. Output only the missing continuation. Do not add new sentences. Do not repeat any text from the draft. If the final sentence is already complete, output nothing.';

const CHAT_DETAIL_MARKER = '<<<CHAT_DETAIL>>>';
const CHAT_BRIEF_MARKER = '<<<CHAT_BRIEF>>>';
const NO_HISTORY_MARKER = '<<<NO_HISTORY>>>';
const SUMMARY_MARKER = '<<<SUMMARY_REQUEST>>>';
const NAME_MARKER = '<<<NAME_REQUEST>>>';
const TAG_MARKER = '<<<TAG_REQUEST>>>';

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
      console.log('[Model] Starting model preparation...');
      try {
        EdgeAI?.setModelReady?.(false);
      } catch {}
      setIsDownloading(true);
      setDownloadProgress(0);
      try {
        const filePath = `${RNFS.DocumentDirectoryPath}/${MODEL_FILENAME}`;
        console.log('[Model] Checking for model at:', filePath);
        let interruptedDownloadState: string | null = null;
        try {
          interruptedDownloadState = await AsyncStorage.getItem(MODEL_DOWNLOAD_STATE_KEY);
        } catch (err) {
          console.warn('[Model] Failed to read download state marker:', err);
        }
        const hadInterruptedDownload = interruptedDownloadState === MODEL_DOWNLOAD_IN_PROGRESS;
        if (hadInterruptedDownload) {
          console.warn('[Model] Interrupted download detected, removing partial model file');
          try {
            const partialExists = await RNFS.exists(filePath);
            if (partialExists) {
              await RNFS.unlink(filePath);
            }
          } catch (err) {
            console.warn('[Model] Failed to remove partial model file:', err);
          } finally {
            setDownloadProgress(0);
          }
        }

        const fileExists = await RNFS.exists(filePath);
        console.log('[Model] File exists after recovery check:', fileExists);

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

        if (!fileExists) {
          console.log('[Model] Downloading model...');
          try {
            await AsyncStorage.setItem(MODEL_DOWNLOAD_STATE_KEY, MODEL_DOWNLOAD_IN_PROGRESS);
          } catch (err) {
            console.warn('[Model] Failed to set download state marker:', err);
          }
          await downloadModel(MODEL_FILENAME, MODEL_URL, setDownloadProgress);
          try {
            await AsyncStorage.removeItem(MODEL_DOWNLOAD_STATE_KEY);
          } catch (err) {
            console.warn('[Model] Failed to clear download state marker:', err);
          }
          console.log('[Model] Download completed');
        }

        if (cancelled) {
          console.log('[Model] Preparation cancelled');
          return;
        }

        console.log('[Model] Initializing llama context...');
        const llamaContext = await initLlama({
          model: filePath,
          use_mlock: false,
          n_ctx: 2048,
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
        if (!cancelled) setIsDownloading(false);
      }
    };

    prepareModel();

    return () => {
      cancelled = true;
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

  const formatQwenPrompt = (messages: Message[]): string => {
    let prompt = '';
    for (const m of messages) {
      const role = m.role === 'assistant' ? 'assistant' : m.role;
      prompt += `<|im_start|>${role}\n${m.content.trim()}\n<|im_end|>\n`;
    }
    prompt += `<|im_start|>assistant\n`;
    return prompt;
  };

  const formatPrompt = (messages: Message[]): string => {
    return formatQwenPrompt(messages);
  };

  const stopTokensForModel = (): string[] => {
    return ['<|im_end|>', '</s>'];
  };

  const isUserPromptText = (raw: string): boolean => {
    let text = raw;
    if (text.startsWith(NO_HISTORY_MARKER)) {
      text = text.slice(NO_HISTORY_MARKER.length).trimStart();
    }
    if (text.startsWith(CHAT_DETAIL_MARKER)) {
      text = text.slice(CHAT_DETAIL_MARKER.length).trimStart();
    } else if (text.startsWith(CHAT_BRIEF_MARKER)) {
      text = text.slice(CHAT_BRIEF_MARKER.length).trimStart();
    }
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
        
        let rawPrompt = prompt;
        let noHistory = false;
        if (rawPrompt.startsWith(NO_HISTORY_MARKER)) {
          noHistory = true;
          rawPrompt = rawPrompt.slice(NO_HISTORY_MARKER.length).trimStart();
        }
        let chatDetail = false;
        if (rawPrompt.startsWith(CHAT_DETAIL_MARKER)) {
          chatDetail = true;
          rawPrompt = rawPrompt.slice(CHAT_DETAIL_MARKER.length).trimStart();
        } else if (rawPrompt.startsWith(CHAT_BRIEF_MARKER)) {
          chatDetail = false;
          rawPrompt = rawPrompt.slice(CHAT_BRIEF_MARKER.length).trimStart();
        }
        const isSummary = rawPrompt.startsWith(SUMMARY_MARKER);
        const isName = rawPrompt.startsWith(NAME_MARKER);
        const isTag = rawPrompt.startsWith(TAG_MARKER);
        const userContent = isSummary
          ? rawPrompt.slice(SUMMARY_MARKER.length).trim()
          : isName
          ? rawPrompt.slice(NAME_MARKER.length).trim()
          : isTag
          ? rawPrompt.slice(TAG_MARKER.length).trim()
          : rawPrompt;
        const summaryContentMaxChars = 50000;
        const modeLabel: 'summary' | 'name' | 'tag' | 'chat' = isSummary ? 'summary' : isName ? 'name' : isTag ? 'tag' : 'chat';
        const jobType = modeLabel;
        console.log('[EdgeAI] Mode:', modeLabel, 'content length:', userContent.length);
        currentJobRef.current = { requestId, prompt, type: modeLabel };
        abortCurrentRef.current = false;
        
        const userMessage: Message = { role: 'user', content: userContent, timestamp: Date.now() };

        const messagesForAI: Message[] = isSummary
          ? [{ role: 'system', content: SUMMARY_SYSTEM_PROMPT, timestamp: Date.now() }, userMessage]
          : isName
          ? [userMessage]
          : isTag
          ? [{ role: 'system', content: TAG_SYSTEM_PROMPT, timestamp: Date.now() }, userMessage]
          : noHistory
          ? [userMessage]
          : [...conversationRef.current, userMessage];

        try {
          if (!context) {
            throw new Error('Model context is not initialized');
          }
          
          const promptText = formatPrompt(messagesForAI);
          console.log('[EdgeAI] Generated prompt length:', promptText.length);
          console.log('[EdgeAI] Prompt preview:', promptText.substring(0, 200) + '...');
          
          const stopTokens = stopTokensForModel();

          const runSummary = async (summaryText: string, nPredict: number): Promise<string> => {
            const summaryMessages: Message[] = [
              { role: 'system', content: SUMMARY_CHUNK_PROMPT, timestamp: Date.now() },
              { role: 'user', content: summaryText, timestamp: Date.now() }
            ];
            const summaryPrompt = formatPrompt(summaryMessages);
            const summaryResult = await context.completion(
              {
                prompt: summaryPrompt,
                n_predict: nPredict,
                temperature: 0.2,
                top_p: 0.9,
                repeat_penalty: 1.2,
                repeat_last_n: 256,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );

            let out = (summaryResult?.text ?? '').trim();
            out = out.replace(/\b(\w+)\b(?:\s+\1){5,}/gi, '$1');
            return out;
          };

          const runSummaryFinalCombine = async (summaryText: string, nPredict: number): Promise<string> => {
            const summaryMessages: Message[] = [
              { role: 'system', content: SUMMARY_COMBINE_PROMPT, timestamp: Date.now() },
              { role: 'user', content: summaryText, timestamp: Date.now() }
            ];
            const summaryPrompt = formatPrompt(summaryMessages);
            const summaryResult = await context.completion(
              {
                prompt: summaryPrompt,
                n_predict: nPredict,
                temperature: 0.12,
                top_p: 0.88,
                repeat_penalty: 1.35,
                repeat_last_n: 256,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );

            let out = (summaryResult?.text ?? '').trim();
            out = out.replace(/\b(\w+)\b(?:\s+\1){5,}/gi, '$1');
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
            const continuationResult = await context.completion(
              {
                prompt: continuationPrompt,
                n_predict: nPredict,
                temperature: 0.2,
                top_p: 0.9,
                repeat_penalty: 1.25,
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
              text = await runSummary(summaryInput, 320);
            } else {
              const chunkSummaries: string[] = [];
              for (let i = 0; i < chunks.length; i++) {
                if (abortCurrentRef.current) break;
                const chunk = chunks[i];
                const chunkSummary = await runSummary(chunk, 180);
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
            const namePrompt = formatPrompt(messagesForAI);
            const nameResult = await context.completion(
              {
                prompt: namePrompt,
                n_predict: 50,
                temperature: 0.4,
                top_p: 0.9,
                repeat_penalty: 1.4,
                repeat_last_n: 128,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );
            text = (nameResult?.text ?? '').trim();
          } else if (isTag) {
            const tagPrompt = formatPrompt(messagesForAI);
            const tagResult = await context.completion(
              {
                prompt: tagPrompt,
                n_predict: 60,
                temperature: 0.3,
                top_p: 0.9,
                repeat_penalty: 1.25,
                repeat_last_n: 128,
                min_p: 0.05,
                stop: stopTokens
              },
              () => {}
            );
            text = (tagResult?.text ?? '').trim();
          } else {
            const completionParams = {
              prompt: promptText,
              n_predict: chatDetail ? 480 : 220,
              temperature: 0.25,
              top_p: 0.85,
              repeat_penalty: 1.4,
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
          }

          const endsCleanly = (s: string) => /[.!?]["')\]]?\s*$/.test(s.trim());
          const looksCut = (s: string) =>
            !endsCleanly(s) || /[,;:\-–—]\s*$/.test(s.trim());

          const trimToLastCompleteSentence = (input: string): string => {
            const match = input.match(/[\s\S]*[.!?]["')\]]?\s*/);
            return match ? match[0].trim() : input.trim();
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

          const finishIfCut = async (input: string): Promise<string> => {
            let out = input.trim();
            if (endsCleanly(out) && !looksCut(out)) return out;

            for (let i = 0; i < 2; i++) {
              if (endsCleanly(out) && !looksCut(out)) break;
              const continuation = await runContinuation(out, 60);
              const cont = continuation.replace(/^[\s.\-–—:;]+/, '').trim();
              if (!cont) break;
              out = (out.trimEnd() + ' ' + cont).trim();
            }

            if (endsCleanly(out) && !looksCut(out)) return out;
            return trimToLastCompleteSentence(out);
          };

          // strip only template artifacts
          text = text
            .replace(/<start_of_turn>/g, '')
            .replace(/<end_of_turn>/g, '')
            .replace(/<\|im_start\|>/g, '')
            .replace(/<\|im_end\|>/g, '')
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
            text = await finishIfCut(text);
            text = text.trim();
          } else {
            if (!isName && looksCut(text)) {
              const continuation = await runContinuation(text, 60);
              const cont = continuation.replace(/^[\s.\-–—:;]+/, '').trim();
              if (cont) text = (text.trimEnd() + ' ' + cont).trim();
            }
            text = squashWordStutter(text);
            text = approxDedupeSentences(dedupeSentencesGlobal(dedupeRepeats(text)));
            text = text.trim();
          }

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
            if (text.length > 0) {
              const assistantMessage: Message = { role: 'assistant', content: text, timestamp: Date.now() };
              conversationRef.current = [...messagesForAI, assistantMessage];
            } else {
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
    const isName = prompt.startsWith(NAME_MARKER);
    const isSummary = prompt.startsWith(SUMMARY_MARKER);
    const isTag = prompt.startsWith(TAG_MARKER);
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
