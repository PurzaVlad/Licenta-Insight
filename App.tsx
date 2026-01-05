import React, {useEffect, useRef, useState} from 'react';
import {Alert, SafeAreaView, StyleSheet, View, ActivityIndicator, Text, NativeModules, NativeEventEmitter} from 'react-native';
import RNFS from 'react-native-fs';
import {initLlama, releaseAllLlama} from 'llama.rn';
import {downloadModel} from './src/api/model';

import NativeChatView from './src/native/NativeChatView';
const {EdgeAI} = NativeModules;

type Message = {
  role: 'system' | 'user' | 'assistant';
  content: string;
  timestamp: number;
};

const MODEL_FILENAME = 'gemma-2-2b-it-Q3_K_S.gguf';
const MODEL_URL =
  'https://huggingface.co/medmekk/gemma-2-2b-it.GGUF/resolve/main/gemma-2-2b-it-Q3_K_S.gguf';

const SUMMARY_SYSTEM_PROMPT =
  'Summarize in 4-6 bullet points. Include key facts, names, actions. Be concise.';

const CHAT_SYSTEM_PROMPT =
  'You are an expert assistant. Provide accurate, neutral answers. Prefer English. Base responses on the given context; avoid fabrications.';

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

  useEffect(() => {
    let cancelled = false;

    const prepareModel = async () => {
      console.log('[Model] Starting model preparation...');
      setIsDownloading(true);
      try {
        const filePath = `${RNFS.DocumentDirectoryPath}/${MODEL_FILENAME}`;
        console.log('[Model] Checking for model at:', filePath);
        const fileExists = await RNFS.exists(filePath);
        console.log('[Model] File exists:', fileExists);

        if (!fileExists) {
          console.log('[Model] Downloading model...');
          await downloadModel(MODEL_FILENAME, MODEL_URL, setDownloadProgress);
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
          n_gpu_layers: 0, // CPU only for better compatibility
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
        console.log('[Model] Model ready for use!');
      } catch (error: any) {
        console.error('[Model] AI Model Error:', error);
        const errorMsg = error instanceof Error ? error.message : String(error);
        console.error('[Model] Error details:', errorMsg);
        Alert.alert('AI Model Error', `Failed to initialize model: ${errorMsg}`);
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
    };
  }, []);

useEffect(() => {
  if (!context) return;

  const emitter = new NativeEventEmitter(EdgeAI);

  // Proper Gemma2 formatting with correct conversation structure
  const formatGemmaPrompt = (messages: Message[]): string => {
    const system = messages
      .filter(m => m.role === 'system')
      .map(m => m.content.trim())
      .join('\n\n')
      .trim();

    const turns = messages.filter(m => m.role !== 'system');

    // Build a proper multi-turn prompt:
    // <bos> is often helpful; some builds inject it automatically, but adding it is usually safe.
    let prompt = `<bos>`;

    // Put system text into the first user turn (common practice for these templates)
    // so it's not ignored by the model.
    const normalizedTurns: Message[] = turns.map((m, idx) => {
      if (idx === 0 && m.role === 'user' && system) {
        return { ...m, content: `${system}\n\n${m.content}` };
      }
      return m;
    });

    // If there was no initial user message, still include system in a synthetic user turn
    if (normalizedTurns.length === 0 && system) {
      normalizedTurns.push({ role: 'user', content: system, timestamp: Date.now() });
    }

    for (const m of normalizedTurns) {
      const role = m.role === 'assistant' ? 'model' : 'user';
      prompt += `<start_of_turn>${role}\n${m.content.trim()}\n<end_of_turn>\n`;
    }

    // Tell the model it's its turn
    prompt += `<start_of_turn>model\n`;

    return prompt;
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
        const { requestId, prompt } = queueRef.current[0];
        console.log('[EdgeAI] Processing request:', requestId, 'prompt length:', prompt.length);
        
        const SUMMARY_MARKER = '<<<SUMMARY_REQUEST>>>';
        const isSummary = prompt.startsWith(SUMMARY_MARKER);
        const userContent = isSummary ? prompt.slice(SUMMARY_MARKER.length).trim() : prompt;
        console.log('[EdgeAI] Mode:', isSummary ? 'summary' : 'chat', 'content length:', userContent.length);
        
        const userMessage: Message = { role: 'user', content: userContent, timestamp: Date.now() };

        const messagesForAI: Message[] = isSummary
          ? [{ role: 'system', content: SUMMARY_SYSTEM_PROMPT, timestamp: Date.now() }, userMessage]
          : [...conversationRef.current, userMessage];

        try {
          if (!context) {
            throw new Error('Model context is not initialized');
          }
          
          const promptText = formatGemmaPrompt(messagesForAI);
          console.log('[EdgeAI] Generated prompt length:', promptText.length);
          console.log('[EdgeAI] Prompt preview:', promptText.substring(0, 200) + '...');
          
          const completionParams = isSummary
            ? {
                prompt: promptText,
                n_predict: 100,
                temperature: 0.3,
                top_p: 0.8,
                repeat_penalty: 1.1,
                stop: ["<end_of_turn>", "</s>"]
              }
            : {
                prompt: promptText,
                n_predict: 180,
                temperature: 0.4,
                top_p: 0.8,
                repeat_penalty: 1.1,
                stop: ["<end_of_turn>", "</s>"]
              };
              
          console.log('[EdgeAI] Calling context.completion with params:', Object.keys(completionParams));
          const result = await context.completion(completionParams, () => {});
          
          console.log('[EdgeAI] Got result:', {
            hasText: !!result?.text,
            textLength: result?.text?.length ?? 0,
            textPreview: result?.text?.substring(0, 100)
          });

          let text = (result?.text ?? '').trim();

          // strip only template artifacts
          text = text
            .replace(/<start_of_turn>/g, '')
            .replace(/<end_of_turn>/g, '')
            .replace(/^\s*model\s*\n/i, '')
            .trim();

          if (!text) text = "(No output)";

          if (!isSummary) {
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
          EdgeAI.rejectRequest(requestId, 'GEN_ERR', errorMsg);
        } finally {
          queueRef.current.shift();
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
    queueRef.current.push({ requestId, prompt });
    processQueue().catch(err => {
      console.error('[EdgeAI] Queue processing error:', err);
      EdgeAI.rejectRequest(requestId, 'QUEUE_ERR', err?.message ?? 'Unknown queue error');
    });
  });

  return () => sub.remove();
}, [context]);

  if (isDownloading || !context) {
    return (
      <SafeAreaView style={styles.container}>
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" />
          <Text style={styles.loadingText}>
            {isDownloading
              ? `Downloading Model: ${downloadProgress.toFixed(1)}%`
              : 'Initializing AI Model...'}
          </Text>
        </View>
      </SafeAreaView>
    );
  }

  // Render native SwiftUI chat UI
  return (
    <SafeAreaView style={styles.container}>
      <NativeChatView style={{flex: 1}} />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: 'transparent'}, // allow SwiftUI materials
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {marginTop: 15, fontSize: 16, color: '#FFFFFF'},
});



export default App;
