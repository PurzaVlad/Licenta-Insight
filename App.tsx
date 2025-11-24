import React, {useState, useEffect} from 'react';
import {
  StyleSheet,
  View,
  Alert,
  SafeAreaView,
  ScrollView,
  Text,
  TouchableOpacity,
  ActivityIndicator,
  TextInput,
} from 'react-native';

import RNFS from 'react-native-fs';
import axios from 'axios';
import AsyncStorage from '@react-native-async-storage/async-storage';

import {initLlama, releaseAllLlama} from 'llama.rn';
import {downloadModel} from './src/api/model'; // Import from api

function App(): React.JSX.Element {
  type Message = {
    role: 'system' | 'user' | 'assistant';
    content: string;
    timestamp: number;
  };


  const INITIAL_CONVERSATION: Message[] = [
    {
      role: "system",
      content:
        "You are a computer scientist who writes algorithms. You always respond in English.",
    },
  ];

  const MODEL_FILENAME = "Phi-3-mini-4k-instruct-Q4_K_M.gguf";

  const MODEL_URL = "https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/resolve/main/Phi-3-mini-4k-instruct-Q4_K_M.gguf";

  const [conversation, setConversation] =
    useState<Message[]>(INITIAL_CONVERSATION);
  const [userInput, setUserInput] = useState('');
  const [context, setContext] = useState<any>(null);

  const [isDownloading, setIsDownloading] = useState(true);
  const [downloadProgress, setDownloadProgress] = useState(0);
  const [isGenerating, setIsGenerating] = useState(false);

  useEffect(() => {
    const prepareModel = async () => {
      try {
        const alreadyDownloaded = await AsyncStorage.getItem('model_ready');
        const filePath = `${RNFS.DocumentDirectoryPath}/${MODEL_FILENAME}`;
        const fileExists = await RNFS.exists(filePath);

        if (alreadyDownloaded === 'yes' && fileExists) {
          await loadModel(filePath);
          setIsDownloading(false);
          return;
        }

        // Use the imported downloadModel function
        const downloadedPath = await downloadModel(
          MODEL_FILENAME,
          MODEL_URL,
          setDownloadProgress,
        );
        await loadModel(downloadedPath);
        await AsyncStorage.setItem('model_ready', 'yes');
      } catch (error) {
        Alert.alert(
          'Startup Error',
          error instanceof Error ? error.message : 'Unknown error.',
        );
      } finally {
        setIsDownloading(false);
      }
    };

    prepareModel();

    return () => {
      releaseAllLlama();
    };
  }, []);

  // Removed the local downloadModel function

  const loadModel = async (filePath: string) => {
    const llamaContext = await initLlama({
      model: filePath,
      useAssets: false,
      use_mlock: true,
      n_ctx: 2048,
      n_gpu_layers: 0,
    });
    setContext(llamaContext);
  };

  const handleSendMessage = async () => {
    if (!context) {
      Alert.alert('Model not ready', 'The model is still loading.');
      return;
    }
    if (!userInput.trim()) return;

    const newConversation: Message[] = [
      ...conversation,
      {role: 'user', content: userInput, timestamp: Date.now()},
    ];

    setConversation(newConversation);
    setUserInput('');
    setIsGenerating(true);

    try {
      const result = await context.completion(
        {
          messages: newConversation,
          n_predict: 300,
          stop: ['<|end|>']
        },
        () => {},
      );

      if (result?.text) {
        setConversation(prev => [
          ...prev,
          {role: 'assistant', content: result.text.trim(), timestamp: Date.now()},
        ]);
      }
    } catch (error) {
      Alert.alert(
        'Generation Error',
        error instanceof Error ? error.message : 'Unknown error.',
      );
    } finally {
      setIsGenerating(false);
    }
  };

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView contentContainerStyle={styles.scrollView}>
        <Text style={styles.title}>AI</Text>

        {isDownloading ? (
          <View style={{padding: 20, alignItems: 'center'}}>
            <ActivityIndicator size="large" color="#2563EB" />
            <Text style={{marginTop: 10}}>
              Downloading Model: {downloadProgress.toFixed(1)}%
            </Text>
          </View>
        ) : (
          <View style={styles.chatContainer}>
            <Text style={styles.greetingText}>🦙 Model Ready. Chat below.</Text>

            {conversation.slice(1).map((msg, index) => (
              <View key={index} style={styles.messageWrapper}>

                {/* ORA MESAJULUI */}
                <Text style={styles.timestampText}>
                  {new Date(msg.timestamp).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})}
                </Text>

                <View
                  style={[
                    styles.messageBubble,
                    msg.role === 'user' ? styles.userBubble : styles.llamaBubble,
                  ]}>
                  <Text
                    style={[
                      styles.messageText,
                      msg.role === 'user' && styles.userMessageText,
                    ]}>
                    {msg.content}
                  </Text>
                </View>
              </View>
            ))}
          </View>
        )}
      </ScrollView>

      {!isDownloading && (
        <View style={styles.inputContainer}>
          <TextInput
            style={styles.input}
            placeholder="Type your message..."
            value={userInput}
            onChangeText={setUserInput}
          />

          <TouchableOpacity
            style={styles.sendButton}
            onPress={handleSendMessage}
            disabled={isGenerating}>
            <Text style={styles.buttonText}>
              {isGenerating ? 'Thinking…' : 'Send'}
            </Text>
          </TouchableOpacity>
        </View>
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: '#FFFFFF'},
  scrollView: {padding: 16},
  title: {
    fontSize: 32,
    fontWeight: '700',
    color: '#1E293B',
    marginVertical: 24,
    textAlign: 'center',
  },
  chatContainer: {
    flex: 1,
    backgroundColor: '#F8FAFC',
    borderRadius: 16,
    padding: 16,
    marginBottom: 16,
  },
  greetingText: {
    fontSize: 12,
    fontWeight: '500',
    textAlign: 'center',
    marginVertical: 12,
    color: '#64748B',
  },
  messageWrapper: {marginBottom: 16},
  messageBubble: {
    padding: 12,
    borderRadius: 12,
    maxWidth: '80%',
  },
  userBubble: {alignSelf: 'flex-end', backgroundColor: '#3B82F6'},
  llamaBubble: {
    alignSelf: 'flex-start',
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E2E8F0',
  },
  messageText: {fontSize: 16, color: '#334155'},
  userMessageText: {color: '#FFFFFF'},
  inputContainer: {flexDirection: 'column', gap: 12, margin: 16},
  input: {
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E2E8F0',
    borderRadius: 12,
    padding: 16,
  },
  sendButton: {
    backgroundColor: '#3B82F6',
    paddingVertical: 14,
    borderRadius: 12,
    alignItems: 'center',
  },
  timestampText: {
    fontSize: 10,
    color: '#94A3B8', // gri deschis
    marginBottom: 4,
    marginLeft: 4,
  },

  buttonText: {color: '#FFFFFF', fontSize: 16, fontWeight: '600'},
});

export default App;
