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

const MODEL_FILENAME = 'qwen2-1_5b-instruct-q4_k_m.gguf';
const MODEL_URL =
  'https://huggingface.co/Qwen/Qwen2-1.5B-Instruct-GGUF/resolve/main/qwen2-1_5b-instruct-q4_k_m.gguf';

const INITIAL_CONVERSATION: Message[] = [
  {
    role: 'system',
    content: 'You are a helpful AI assistant. Be concise and friendly.',
    timestamp: Date.now(),
  },
];

function App(): React.JSX.Element {
  const [context, setContext] = useState<any>(null);
  const [isDownloading, setIsDownloading] = useState(false);
  const [downloadProgress, setDownloadProgress] = useState(0);

  // Keep conversation in JS so you can pass it to the model
  const conversationRef = useRef<Message[]>(INITIAL_CONVERSATION);

  useEffect(() => {
    let cancelled = false;

    const prepareModel = async () => {
      setIsDownloading(true);
      try {
        const filePath = `${RNFS.DocumentDirectoryPath}/${MODEL_FILENAME}`;
        const fileExists = await RNFS.exists(filePath);

        if (!fileExists) {
          await downloadModel(MODEL_FILENAME, MODEL_URL, setDownloadProgress);
        }

        if (cancelled) return;

        const llamaContext = await initLlama({
          model: filePath,
          use_mlock: false,
        });

        if (cancelled) {
          try {
            releaseAllLlama();
          } catch {}
          return;
        }

        setContext(llamaContext);
      } catch (error: any) {
        console.error('AI Model Error:', error);
        Alert.alert('AI Model Error', error instanceof Error ? error.message : String(error));
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

  const sub = emitter.addListener('EdgeAIRequest', async (evt) => {
    const {requestId, prompt} = evt;
    try {
      const userMessage: Message = { role: 'user', content: prompt, timestamp: Date.now() };
      const messagesForAI: Message[] = [...conversationRef.current, userMessage];

      const result = await context.completion(
        { messages: messagesForAI, n_predict: 400, stop: ['<|im_end|>'] },
        () => {},
      );

      const text = (result?.text ?? '').trim();

      if (text.length > 0) {
        const assistantMessage: Message = { role: 'assistant', content: text, timestamp: Date.now() };
        conversationRef.current = [...messagesForAI, assistantMessage];
      } else {
        conversationRef.current = messagesForAI;
      }

      EdgeAI.resolveRequest(requestId, text);
    } catch (e: any) {
      EdgeAI.rejectRequest(requestId, 'GEN_ERR', e?.message ?? 'Unknown error');
    }
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
  container: {flex: 1, backgroundColor: '#000'}, // let SwiftUI handle theming
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {marginTop: 15, fontSize: 16, color: '#FFFFFF'},
});



export default App;
